/**
 * 文件路径：entry/src/main/ets/entryformability/EntryFormAbility.ets
 * 用途：桌面服务卡片的生命周期宿主（FormExtensionAbility）。
 *       核心卖点在这里落地：主屏面板常驻显示「今天要做的事」，不勾不消失。
 * 关键取舍：onAddForm 是同步回调但读数据库是异步的——没法在里面 await 查库，
 *       所以先同步返回一份占位数据让卡片立刻能显示，再异步查库用
 *       formProvider.updateForm 把真实内容回填进去，用户只会看到一瞬间的「加载中」。
 */

import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DbHelper } from '../data/DbHelper';
import { EntryItem } from '../data/Types';
import { rollover } from '../logic/DailyRollover';
import { rescheduleReminders, wokenByApp } from '../logic/ReminderService';
import { sendDueNotifications } from '../logic/LocalNotifier';
import { groupRecent } from '../logic/SectionLogic';
import { CARD_GANTT_DAYS, GanttBarData, ganttScaleStart, nextClassOf, NextClassData, sortForGantt, startOfDay, TITLE_LOCATION_SEP, toGanttBar, toNoteCard, toRecentCard } from '../viewmodel/EntryDisplay';

const DOMAIN = 0x0000;
const TAG = 'EntryFormAbility';

/**
 * 卡片「今天」段最多显示几条，**单位是条目数不是行数**（行数由每条的 LINES_PER_ITEM 折算）。
 * 原来是 4：今天排了 5 节课就折叠成「还有 1 条…」，用户看得到「还有」却看不到是什么。
 * 上半区是 layoutWeight(1) 的弹性区，4*4 / 6*4 两种尺寸高度相同且都富余，
 * 只画 4 条时下半截全空着。6 条覆盖「5 节课 + 一两条手写待办」的日常，
 * 每条最多两行算，最坏占 12 行，上半区放得下。
 */
const TODAY_MAX_LINES: number = 6;
/**
 * 卡片「今天」段**实际画几条**。比 TODAY_MAX_LINES 小——这是空间决定的，不是口径决定的。
 *
 * TODAY_MAX_LINES(6) 的立论是「每条最多两行、最坏 12 行也放得下」，那句话是错的：
 * 卡片端 capLine 已经把每条截到不折行（见 capLine 的说明），所以实际是**一条一行**，
 * 而一行实测占 35px（平板 2456×1600，密度约 1.75）。上半区从卡片顶到分隔线一共 359px，
 * 扣掉上下 padding 21px×2 和「近期」标题、「下一节」行、「今天/明天」两个小标题，
 * 留给条目的只有约 203px ≈ 5.8 行。今天推满 6 条正好把 203px 吃干净，
 * 「明天」段（标题 33px + 一条 35px）没地方放，**整段溢出到下半区压在「时间轴」标题上**
 * ——2026-09-28 用户报的「卡片有冲突重叠部分」就是这个，放大截图能看到「时间轴」
 * 三个字底下压着「明天」的残影。
 *
 * 所以折叠到 3 条：3 条(105) + more 行(27) + 明天标题(33) + 明天一条(35) = 200px，
 * 刚好落在 203px 里。宁可少画今天的两条（more 行提示「还有 N 条…」，进 App 能看全），
 * 也不能让明天的提醒彻底看不见——明天那条往往是「12:30 抢票截止」这种错过就没了的事。
 *
 * 别再按「最坏 12 行」去放大这个数：那条推理假设的是每条会折两行，而 capLine 从源头上
 * 就不让它折。真要放大，先装机截图量一遍剩余高度。
 *
 * **只用于 4*4 档**（平板横屏那档）。6*4 档（手机竖屏）上半区高得多，不折叠，见 refreshCard
 * 里 todayCap 的分档说明。
 */
const CARD_TODAY_MAX: number = 3;
/**
 * 「明天」段行数：今天的优先级更高，版面紧张时先保今天——卡片高度是固定的，
 * 下半区多画一根甘特条，上半区就得让出一行的空间
 */
const TOMORROW_MAX_LINES: number = 3;
/**
 * 卡片「明天」段实际画几条。理由同 CARD_TODAY_MAX：明天只占得起一条，
 * 多出的折进「还有 N 条…」。留在 TODAY_MAX_LINES 那套口径的上限是 3（主界面用），
 * 卡片这里按上半区剩下的位置算，只能给 1。
 */
const CARD_TOMORROW_MAX: number = 1;
/** 「随手记」列最多显示几行。右列本来就比左列矮，多给几行不额外占高度 */
const NOTE_MAX_LINES: number = 6;
/**
 * 近期条目单行上限，单位是**汉字宽**（见 capLine），不是字符数。
 * 6 对应 4*4 窄卡片：左列只占卡片一半宽，约放得下 6 个汉字。
 */
const RECENT_CHAR_CAP: number = 6;
/**
 * 随手记单行上限，同样以汉字宽计。两列都是 layoutWeight(1)，宽度与近期列**完全相同**，
 * 所以这里必须跟 RECENT_CHAR_CAP 取同一个值：写大一点（比如原来的 10）在宽卡片上
 * 加起来就是 16.5，越过了 12.5 那条折行红线，随手记第一条就会折行——和近期段当初
 * 一模一样的老毛病。宽度一样、上限就该一样，不再留「右列更窄」那种想当然的余量。
 */
const NOTE_CHAR_CAP: number = 6;
/**
 * 卡片上最多画几根甘特横条：画不下那么多，剩余的折成一行小字。
 * 给到 5 根：甘特区在卡片最下面，是唯一能靠「把条画紧凑些」换出容量的地方
 * （配合卡片端把条高压到 16、间距收到 5，5 根一共只比原来的 2 根多占 55vp）。
 * 上限只管「最多画几根」，实际画几根由当天有几件事决定，事少时不会白占地方。
 */
const GANTT_MAX_BARS: number = 5;

/**
 * 卡片甘特刻度画几档。3 档落在一根条的两端和中点上（见下面的计算）：
 * 跨度 14 天正好是两周，三档就是「今天前 3 天 / 4 天后 / 11 天后」各差一周，
 * 卡片宽度只放得下这么几个日期，再多就挤成一串糊字了。
 */
const CARD_TICKS: number = 3;

/** 一天的毫秒数：刻度按天偏移算日期用 */
const DAY_MS: number = 24 * 60 * 60 * 1000;

/**
 * 宽卡片（6*4）每行多放这么多**汉字宽**。6*4 比 4*4 宽一半，一行放得下的内容按比例多出来。
 *
 * 6.5 + RECENT_CHAR_CAP(6) = 12.5，即宽卡片左列一行最多 12.5 个汉字宽。
 * 这个数是量出来的，不是拍的：实测放 12 个汉字宽出头（「13:30 体育 · 综合训」）
 * 不折行，放到约 16 就折了。取 12.5 是留出字体渲染的误差余量——
 * 折行的代价很大（一个条目偷走两行、把后面的条目顶出 maxLines），
 * 少显示一两个字只是可惜。见 capLine 的说明。
 */
const WIDE_CHAR_BONUS: number = 6.5;

/**
 * 6*4 卡片在 formInfo.FormDimension 里的值。
 * 直接写字面量而不是引用枚举成员：那个成员叫 DIMENSION_6_4（少见的全大写风格），
 * 而且 API 12 才加进来，引用它会把本文件的编译门槛一并抬高。卡片尺寸本来就由
 * form_config 的 supportDimensions 声明，这个枚举值是稳定的。
 */
const DIMENSION_6_4: number = 7;

/**
 * 每个条目最多占几行：一行放不下就折到第二行。
 * 卡片端是让 Text 自己折行的，短条目自然只占一行，长的（带教室名的课表标题）
 * 占两行——比一刀切截断强：截断会丢掉「· 南129」这半截，而教室名恰恰是要看的信息。
 */
const LINES_PER_ITEM: number = 2;

/** 一条要画到卡片上的行：文案 + 这一条的配色档位（-1 = 不上色，用正文色） */
interface LineItem {
  text: string;
  tint: number;
}

/**
 * 拼行结果：正文**逐条**给（不是拼成一整块多行文本）+ 折叠提示（没折叠就为空串，卡片端按空串隐藏）。
 *
 * 为什么是一条一条给、而不是像早先那样 join('\n') 成一大串：
 * 卡片上要按条目上色——课表条目用本门课的颜色，而一个 Text 只能有一个颜色，
 * 拼成一整块就染不了了（要染只能整块一个色，那跟没染一样）。
 * 拆成逐条之后，卡片端一条一个 Text，各染各的。
 * 代价是卡片模板不能再靠一个 maxLines 兜底，得给每条自己限行——见那边 cardLine 的说明。
 */
interface LinesResult {
  texts: string[];
  /** 与 texts 一一对应：课表条目 0-5，其余 -1 */
  tints: number[];
  moreText: string;
}

/**
 * 把标题列表拼成卡片用的多行文本。
 * 为什么在 Ability 端而不是卡片端截断：卡片是静态渲染环境，组件能力有限，
 * 所有「装不下怎么办」的决策集中在这里算好，卡片只管按行画字。
 */
function buildLines(items: LineItem[], maxItems: number, charCap: number): LinesResult {
  const shown: number = Math.min(items.length, maxItems);
  const texts: string[] = [];
  const tints: number[] = [];
  for (let i = 0; i < shown; i++) {
    // 每条按「两行放得下」的容量截：一行装不完的让卡片端自己折到第二行。
    // 阈值放到两倍宽之后，带教室名的完整标题基本都落在容量内，等于不截。
    texts.push(capLine(items[i].text, charCap * LINES_PER_ITEM));
    tints.push(items[i].tint);
  }
  const rest: number = items.length - shown;
  const result: LinesResult = {
    texts: texts,
    tints: tints,
    moreText: rest > 0 ? `还有 ${rest} 条…` : ''
  };
  return result;
}

/**
 * 把一段逐条数据摊成卡片字段：`today1Text` / `today1Tint`、`today2Text` …（前缀由调用方给）。
 * 卡片模板不能用 ForEach，只能一个萝卜一个坑地摆字段。
 *
 * **必须按 maxItems 推满，一条都不能省**：@LocalStorageProp 只在收到新值时才更新，
 * 漏推的 key 会保留上一次的值——今天只有 2 条、不推 today3Text 的话，
 * 卡片上第 3 行还是上午那条「10:00 跨文化交际」，凭空多出一条幽灵。
 */
function putLines(data: Record<string, Object>, prefix: string, lines: LinesResult, maxItems: number): void {
  for (let i = 0; i < maxItems; i++) {
    data[`${prefix}${i + 1}Text`] = i < lines.texts.length ? lines.texts[i] : '';
    data[`${prefix}${i + 1}Tint`] = i < lines.tints.length ? lines.tints[i] : -1;
  }
  data[`${prefix}More`] = lines.moreText;
}

/**
 * 半角字符（数字、字母、半角符号、空格）在卡片上只占约半个汉字宽。
 * 0x1100 是个宽松的分界：汉字、全角标点都在它之上，ASCII 全在之下。
 */
function isNarrow(ch: string): boolean {
  return ch.charCodeAt(0) < 0x1100;
}

/**
 * 单行超长截断：尾部补省略号。**按显示宽度截，不按字符数截。**
 *
 * 为什么不能按字符数：`13:30 ` 这种前缀里数字和空格只占半个汉字宽，按字符数算会
 * 高估一行放得下的内容——估出来 18 字「放得下」，实际渲染出去超出了卡片列宽、
 * 自动折了行。一个条目折行就偷走一行，把后面的条目顶出 maxLines 之外：实测今天
 * 5 节课只画出 3 条 +「还有 1 条…」，条数和内容都对不上。卡片端的 maxLines 数的是
 * **视觉行**，这里给的是**条目数**，两边要对上，硬要求就是任何一条都不许折行。
 * 按宽度截之后「08:00 高等数学A · 南129」这类带数字的短行能完整留下，
 * 真正长的才截——比一刀切砍到 14 个字符强得多。
 *
 * @param maxWidth 一行最多占几个汉字宽。略小于实测可用宽度，留字体渲染的误差余量。
 */
function capLine(text: string, maxWidth: number): string {
  let w: number = 0;
  for (let i = 0; i < text.length; i++) {
    w += isNarrow(text[i]) ? 0.55 : 1;
    if (w > maxWidth) {
      return `${text.substring(0, i)}…`;
    }
  }
  return text;
}

/**
 * 拼一行近期条目的卡片文案：有时间就「08:00 高等数学 · 南129」，没时间只给标题。
 * 规格要求卡片上标上课时间/截止时刻（例「8:00 高等数学」）：课表给 "08:00"、
 * 非课表给 "截止 18:00"、没设时刻为 null——toRecentCard 的 timeText 已经按
 * 这个规矩算好了，之前只取 title 等于把 timeText 扔了，卡片上只看得到
 * 「高等数学 · 逸夫楼201」而看不到「8:00」。
 *
 * 教室要从 location 拼回来：toRecentCard 为照顾手机窄屏把「课程名 · 教室」切开了
 * （见那边的注释），卡片这一行没有折行余地，切开的后果就是教室凭空消失。
 */
function cardLine(e: EntryItem, now: number): LineItem {
  const card = toRecentCard(e, now);
  const title: string = card.location.length > 0
    ? `${card.title}${TITLE_LOCATION_SEP}${card.location}`
    : card.title;
  const text: string = card.timeText !== null ? `${card.timeText} ${title}` : title;
  // 档位直接借 toRecentCard 算好的（它只在课表条目上给 0-5，手写条目是 -1），
  // 别在这儿另算一套——两处各算各的，早晚会出现「App 里是绿的、卡片上是灰的」
  return { text: text, tint: card.tint };
}

/**
 * 从系统给的参数里取卡片尺寸（formInfo.FormDimension 的枚举值）。
 * onAddForm 和「系统主动带参刷新」的 onUpdateForm 都从这里取；
 * 取不到返回 undefined，调用方退回上次记下的值，绝不因此少显示内容。
 */
function readDimension(params: Record<string, Object> | undefined): number | undefined {
  if (params === undefined) {
    return undefined;
  }
  const raw: Object | undefined = params[formInfo.FormParam.DIMENSION_KEY];
  if (raw === undefined) {
    return undefined;
  }
  return raw as number;
}

export default class EntryFormAbility extends FormExtensionAbility {
  /**
   * 添加卡片时回调。返回值是同步的（不是 Promise），但查库是异步的，
   * 所以这里只做两件事：先返回占位数据，再从 want 里抠出 formId 异步回填真实内容。
   */
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = this.extractFormId(want);
    // 不 await：同步返回占位数据后，真实数据由 refreshCard 异步回填。
    // 尺寸只有这个回调和「系统主动带参刷新」的 onUpdateForm 给得到，refreshCard 会把它记进库
    this.refreshCard(formId, readDimension(want.parameters));
    // 占位数据：key 与 TodayCard.ets 里 @LocalStorageProp 的 key 一一对应。
    // 正文那三段（today* / tomorrow* / note*）不在这里手写，最后用 putLines 统一摊进去
    const placeholder: Record<string, Object> = {
      'overdueText': '',
      'nextText': '',
      'gantt1Title': '',
      'gantt1Left': 0,
      'gantt1Width': 0,
      'gantt1Tint': 0,
      'gantt1Rest': '',
      'gantt2Title': '',
      'gantt2Left': 0,
      'gantt2Width': 0,
      'gantt2Tint': 0,
      'gantt2Rest': '',
      'gantt3Title': '',
      'gantt3Left': 0,
      'gantt3Width': 0,
      'gantt3Tint': 0,
      'gantt3Rest': '',
      'gantt4Title': '',
      'gantt4Left': 0,
      'gantt4Width': 0,
      'gantt4Tint': 0,
      'gantt4Rest': '',
      'gantt5Title': '',
      'gantt5Left': 0,
      'gantt5Width': 0,
      'gantt5Tint': 0,
      'gantt5Rest': '',
      'ganttMore': '',
      'ganttEmpty': ''
    };
    // 首帧只有「今天」段第一行写「加载中…」，真实数据由 refreshCard 异步回填；
    // 三段都要按满额推（见 putLines 的说明），不然上一张卡片留下的旧值会滞留在新卡上
    putLines(placeholder, 'today',
      { texts: ['加载中…'], tints: [-1], moreText: '' }, TODAY_MAX_LINES);
    putLines(placeholder, 'tomorrow', { texts: [], tints: [], moreText: '' }, TOMORROW_MAX_LINES);
    putLines(placeholder, 'note', { texts: [], tints: [], moreText: '' }, NOTE_MAX_LINES);
    return formBindingData.createFormBindingData(placeholder);
  }

  /**
   * 系统按 form_config 的 updateDuration（30 分钟）和 scheduledUpdateTime 调这里。
   * 卡片常驻桌面的意义就在这：即使用户一整天不打开 App，面板上的内容也会被系统
   * 定时刷一遍，今天的事永远是「今天」的。
   */
  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    // 尺寸多数时候给不到（wantParams 只在系统主动带参刷新时才有值），
    // refreshCard 会退回读上次记下的那个，见那里的说明
    this.refreshCard(formId, readDimension(wantParams));
  }

  /**
   * 删卡片：数据都在库里，主界面不受任何影响；只需要顺手把这张卡片自己的尺寸记录
   * 一并抹掉，否则加一张删一张就攒下一行，settings 表只增不减。
   */
  onRemoveForm(formId: string): void {
    hilog.info(DOMAIN, TAG, `onRemoveForm, formId: ${formId}`);
    // 不 await：系统不等这个回调返回，而且删不掉也只是漏一行记账，不影响任何功能
    this.forgetDimension(formId);
  }

  /** 抹掉一张卡片的尺寸记录，见 onRemoveForm 的说明。失败只记日志，不往上抛 */
  private async forgetDimension(formId: string): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    try {
      const db: DbHelper = await DbHelper.getInstance(this.context);
      await db.deleteFormDimension(formId);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `清理卡片尺寸记录失败: ${JSON.stringify(e)}`);
    }
  }

  /** 卡片事件（本卡片是静态卡片，只做整卡点击拉起主界面，不走 message 事件） */
  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN, TAG, `onFormEvent, formId: ${formId}, message: ${message}`);
  }

  /** 供系统查询卡片状态：本卡片永远可正常渲染 */
  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  /**
   * 从 want 参数里取 formId。
   * want.parameters 可能为 undefined、值类型是 Object，都要判空收窄后再用，
   * 取不到返回空串（调用方对空串直接跳过回填，不会误刷别的卡片）。
   */
  private extractFormId(want: Want): string {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return '';
    }
    const raw: Object | undefined = params[formInfo.FormParam.IDENTITY_KEY];
    if (raw === undefined) {
      return '';
    }
    return raw as string;
  }

  /**
   * 定下这张卡片这次渲染按哪个尺寸走：优先用系统刚给的那个，给不到就用上次记下的。
   * 为什么要记账：每 30 分钟那次定时刷新只给 formId，不给尺寸，而卡片宽度
   * 决定了每行放得下多少字。卡片尺寸不会自己变，记一次就能一直用。
   * 为什么记账要带 formId：桌面上可能同时放着一张 4*4 和一张 6*4，共用一个键的话
   * 后加的那张会把先加的覆盖掉，窄卡片就会按宽档渲染、文字撑破版面。
   * 两处都拿不到（升级上来的老卡片，还没赶上一次带尺寸的回调）时返回 undefined，
   * 调用方按标准档渲染——宁可先窄一点，也不要在大卡片上猜错宽度。
   */
  private async resolveDimension(db: DbHelper, formId: string, dimension: number | undefined): Promise<number | undefined> {
    if (dimension !== undefined) {
      await db.setFormDimension(formId, `${dimension}`);
      return dimension;
    }
    const stored: string | undefined = await db.getFormDimension(formId);
    if (stored === undefined || stored.length === 0) {
      return undefined;
    }
    const value: number = parseInt(stored, 10);
    return isNaN(value) ? undefined : value;
  }

  /**
   * 查库、算数据、回填卡片，onAddForm 和 onUpdateForm 共用的唯一取数路径。
   * 整个方法自己兜错：卡片进程里任何一个环节抛错都不该让系统回调崩掉，
   * 最多这次刷新失败，卡片停留在上一次的内容上，下个刷新周期还有机会。
   */
  private async refreshCard(formId: string, dimension: number | undefined): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    try {
      // DbHelper 是单例，但 FormAbility 和 UIAbility 不一定是同一个进程实例，
      // 这里拿 FormExtensionAbility 自己的 context 初始化一份，和 Index 页的做法一致
      const db: DbHelper = await DbHelper.getInstance(this.context);
      const now: number = Date.now();

      // 卡片宽度决定每行放得下多少字：6*4 比 4*4 宽一半，硬用同一套字数上限
      // 会让宽卡片上每行都截在一半处，白白浪费多出来的宽度。
      // 行数上限则不跟着尺寸走——两种尺寸高度相同，见 TODAY_MAX_LINES 的说明
      const dim: number | undefined = await this.resolveDimension(db, formId, dimension);
      const wide: boolean = dim === DIMENSION_6_4;
      const recentCap: number = wide ? RECENT_CHAR_CAP + WIDE_CHAR_BONUS : RECENT_CHAR_CAP;
      const noteCap: number = wide ? NOTE_CHAR_CAP + WIDE_CHAR_BONUS : NOTE_CHAR_CAP;
      // 先结算再读库：不结算的话卡片上显示的是没流转过的旧数据
      // （昨天的课表条目还挂着、今天到期的长期任务还没生成待办）
      await rollover(db, now);

      // 提醒的两条投递路径都在这里走一遍。卡片被系统唤醒，是「用户没打开 App 时」
      // 唯一会醒过来的时刻，两条路都靠它：
      //   1. rescheduleReminders —— 把今天的提醒交给后台代理提醒去发。精确到分钟，
      //      但真机上这项能力受管控、未开通权限的应用额度为 0，能不能用由它自己探测；
      //   2. sendDueNotifications —— 代理提醒用不了时，用普通通知当场把到点的发出去。
      //      它依赖的正是「卡片此刻醒着」：form_config 让卡片从 6:25 起每 30 分钟醒一次，
      //      6:25 / 11:25 / 15:55 这三次分别落在 6:30 / 11:30 / 16:05 前，
      //      所以只会早几分钟，不会晚。
      // 与 App 进程并发是安全的：两边都是「先全消再全排」，notificationId 又固定
      //（1001-1004 / 2000+ 段），后写的覆盖先写的，不会叠成两条；已发标记落在数据库里，
      // 两次唤醒之间也不会重复发。
      // 单独兜一层错：提醒出问题是小事，不能连累下面的读库和卡片回填一起失败。
      try {
        // allowCatchup 平时为 true：卡片这条路径允许补推，它多半发生在用户没看着
        // 屏幕的时候——系统唤醒晚了几分钟，把刚过点的那条补上，才不至于整个白天都不响。
        // 但 App 主动推卡片时人是看着屏幕的（他刚在 App 里改完东西），那种时候补推
        // 就是打扰，要按 App 侧同一个口径关掉。唤醒来源分不出来，靠 App 推之前
        // 写下的 appPushTs 记号认，见 wokenByApp
        const fromApp: boolean = await wokenByApp(db, now);
        await rescheduleReminders(db, now, !fromApp);
        // 必须排在重排之后：它刚写下「代理提醒能不能用」的结论，这一步要读那个结论
        await sendDueNotifications(db, now);
      } catch (e) {
        hilog.error(DOMAIN, TAG, `卡片刷新时处理提醒失败: ${JSON.stringify(e)}`);
      }

      const all: EntryItem[] = await db.getAllActiveEntries();
      // 勾掉的条目从卡片退场：卡片只展示「还没做完的事」，这正是「不勾不消失」的语义
      const undone: EntryItem[] = all.filter((e: EntryItem): boolean => !e.done);

      // ── 近期三段：复用 SectionLogic 的分组，不在卡片里另写一套 ──
      const groups = groupRecent(undone, now);
      // 折叠与否**按规格分档**：4*4 那档（平板横屏）上半区只有约 405vp、放得下 5.8 条，必须折叠；
      // 6*4 那档（手机竖屏）上半区约 560vp、放得下近 20 条，折叠纯属白白藏内容。
      // 两档差的是**高度**，而高度跟 4*4 / 6*4 本身无关（两者是等高规格），
      // 差在设备桌面网格的行数：手机 6 行、平板 8 行，同样 4 行高的卡片在两边差出 150vp。
      // 所以这里是**借** dimension 分档，不是「宽卡片容量就大」——换了卡片规格这个档要重新量，
      // 量法见 CARD_TODAY_MAX 的注释（截图 + 数文字行的 y 间距）。
      const todayCap: number = wide ? TODAY_MAX_LINES : CARD_TODAY_MAX;
      const tomorrowCap: number = wide ? TOMORROW_MAX_LINES : CARD_TOMORROW_MAX;
      // 下面 putLines 仍按 TODAY_MAX_LINES / TOMORROW_MAX_LINES 推满 key——**推几条和画几条是两回事**：
      // 推满是为了把 today4/5/6Text 这些坑用空串占掉，否则它们会留着上一次的值变成幽灵行。
      const today: LinesResult = buildLines(
        groups.today.map((e: EntryItem): LineItem => cardLine(e, now)), todayCap, recentCap);
      const tomorrow: LinesResult = buildLines(
        groups.tomorrow.map((e: EntryItem): LineItem => cardLine(e, now)), tomorrowCap, recentCap);
      // 过期段不展开：卡片寸土寸金，过期的事只需要一行小字提醒用户进 App 看
      const overdueText: string = groups.overdue.length > 0 ? `过期 ${groups.overdue.length} 条` : '';

      // ── 「下一节」：与主界面同一口径（nextClassOf），拼成一行整串传给卡片 ──
      // 为什么在数据端拼好而不是把时刻、教室拆成两个字段：卡片那一行是定宽的小字，
      // 拆开就得在卡片里判「还有没有教室」「放不放得下」，判断逻辑会散到两处。
      // 地点没有就只写时刻，与主界面同一套规则；空串 = 今天没课或都上完了，整行不画。
      const next: NextClassData | null = nextClassOf(undone, now);
      const nextText: string = next === null
        ? ''
        : (next.location.length > 0 ? `${next.timeText} · ${next.location}` : next.timeText);

      // ── 随手记：date 为 null 的未勾条目，复用主界面的转换规则（只写正文时兜底显示正文） ──
      const notes: EntryItem[] = undone.filter((e: EntryItem): boolean => e.date === null);
      // 随手记一律不上色（tint 恒为 -1，卡片端就用正文色）：颜色在这套界面里是「哪门课」的标记，
      // 随手记是自己写的事、没有课可归；主界面那一列也是灰底黑字，两边口径得一致
      const noteLines: LinesResult = buildLines(
        notes.map((e: EntryItem): LineItem => ({ text: `· ${toNoteCard(e).text}`, tint: -1 })),
        NOTE_MAX_LINES, noteCap);

      // ── 时间轴甘特：复用 toGanttBar 的换算（起止裁剪进刻度），再换算成百分比宽度 ──
      // 与页面共用同一个刻度起点：必须走 ganttScaleStart，自己写 startOfDay 会丢掉「过去 3 天」
      const scaleStart: number = ganttScaleStart(now);
      // 与主页同一套规则：已过截止日的条排到最下面（规格：到期不消失、不标逾期天数，
      // 只是挪到甘特末尾）。卡片只画前 GANTT_MAX_BARS 根，不分这两段的话过期条会
      // 占掉名额，把还来得及的事挤出卡片
      const todayStart: number = startOfDay(now);
      const bars: GanttBarData[] = [];
      const expiredBars: GanttBarData[] = [];
      // 甘特顺序跟主页用的是同一套（ganttOrder，没拖过的退回 sortOrder），
      // 两边必须一致：卡片只取前 5 根，顺序不同就成了两套内容
      const ganttSource: EntryItem[] = sortForGantt(undone);
      for (const e of ganttSource) {
        // 卡片跨度固定 CARD_GANTT_DAYS（桌面卡片不做捏合 / 平移，需求已拍板）；
        // todayStart 显式传入：新签名里它不再从 scaleStart 反推
        const bar: GanttBarData | undefined = toGanttBar(e, scaleStart, CARD_GANTT_DAYS, todayStart);
        if (bar === undefined) {
          continue;
        }
        if (e.date !== null && e.date < todayStart) {
          expiredBars.push(bar);
        } else {
          bars.push(bar);
        }
      }
      const allBars: GanttBarData[] = bars.concat(expiredBars);
      const shownBars: GanttBarData[] = allBars.slice(0, GANTT_MAX_BARS);
      const ganttRest: number = allBars.length - shownBars.length;

      // ── 刻度：光有几根彩条看不出落在哪几天，卡片上也得标时间 ──
      // 三档取跨度的第 0 / 7 / 14 天（CARD_GANTT_DAYS = 14，正好各差一周），
      // 位置按「第几天 / 跨度」给，与条的百分比是同一套换算（见 toPct），
      // 两边各算各的才会出现「条在 10/2 上、刻度却不在」的错位。
      const ticks: string[] = [];
      for (let i = 0; i < CARD_TICKS; i++) {
        const dayOffset: number = Math.round(CARD_GANTT_DAYS * i / (CARD_TICKS - 1));
        const d: Date = new Date(scaleStart + dayOffset * DAY_MS);
        ticks.push(`${d.getMonth() + 1}/${d.getDate()}`);
      }

      // 行数上限也一并传下去，卡片端拿它当 Text 的 maxLines：正文本来就按这个数
      // 截过（见 buildLines），传过去只是第二道保险——万一哪天截断逻辑出岔子，
      // 卡片是「多出一行省略号」而不是把字叠到下半区的甘特上
      const data: Record<string, Object> = {
        'tick1': ticks.length > 0 ? ticks[0] : '',
        'tick2': ticks.length > 1 ? ticks[1] : '',
        'tick3': ticks.length > 2 ? ticks[2] : '',
        'overdueText': overdueText,
        'nextText': nextText,
        'gantt1Title': shownBars.length > 0 ? shownBars[0].title : '',
        'gantt1Left': shownBars.length > 0 ? toPct(shownBars[0].startDay) : 0,
        'gantt1Width': barWidthPct(shownBars[0]),
        'gantt1Tint': shownBars.length > 0 ? shownBars[0].tint : 0,
        'gantt1Point': barIsPoint(shownBars[0]),
        'gantt1Rest': shownBars.length > 0 ? barRest(shownBars[0]) : '',
        'gantt2Title': shownBars.length > 1 ? shownBars[1].title : '',
        'gantt2Left': shownBars.length > 1 ? toPct(shownBars[1].startDay) : 0,
        'gantt2Width': barWidthPct(shownBars[1]),
        'gantt2Tint': shownBars.length > 1 ? shownBars[1].tint : 0,
        'gantt2Point': barIsPoint(shownBars[1]),
        'gantt2Rest': shownBars.length > 1 ? barRest(shownBars[1]) : '',
        'gantt3Title': shownBars.length > 2 ? shownBars[2].title : '',
        'gantt3Left': shownBars.length > 2 ? toPct(shownBars[2].startDay) : 0,
        'gantt3Width': barWidthPct(shownBars[2]),
        'gantt3Tint': shownBars.length > 2 ? shownBars[2].tint : 0,
        'gantt3Point': barIsPoint(shownBars[2]),
        'gantt3Rest': shownBars.length > 2 ? barRest(shownBars[2]) : '',
        'gantt4Title': shownBars.length > 3 ? shownBars[3].title : '',
        'gantt4Left': shownBars.length > 3 ? toPct(shownBars[3].startDay) : 0,
        'gantt4Width': barWidthPct(shownBars[3]),
        'gantt4Tint': shownBars.length > 3 ? shownBars[3].tint : 0,
        'gantt4Point': barIsPoint(shownBars[3]),
        'gantt4Rest': shownBars.length > 3 ? barRest(shownBars[3]) : '',
        'gantt5Title': shownBars.length > 4 ? shownBars[4].title : '',
        'gantt5Left': shownBars.length > 4 ? toPct(shownBars[4].startDay) : 0,
        'gantt5Width': barWidthPct(shownBars[4]),
        'gantt5Tint': shownBars.length > 4 ? shownBars[4].tint : 0,
        'gantt5Point': barIsPoint(shownBars[4]),
        'gantt5Rest': shownBars.length > 4 ? barRest(shownBars[4]) : '',
        'ganttMore': ganttRest > 0 ? `还有 ${ganttRest} 项…` : '',
        'ganttEmpty': allBars.length === 0 ? '时间轴还没有安排' : ''
      };
      // 三段的正文逐条摊进去（today1Text / today2Text / …），键名与卡片模板一一对应
      putLines(data, 'today', today, TODAY_MAX_LINES);
      putLines(data, 'tomorrow', tomorrow, TOMORROW_MAX_LINES);
      putLines(data, 'note', noteLines, NOTE_MAX_LINES);
      await formProvider.updateForm(formId, formBindingData.createFormBindingData(data));
    } catch (e) {
      hilog.error(DOMAIN, TAG, `refreshCard failed: ${JSON.stringify(e)}`);
    }
  }
}

/**
 * 被右端截断的条补「· 剩 6 个周末」这类倒计时，与全屏甘特（Index.ets 的 barLabel）同一口径。
 * 那句话本身在 toGanttBar 里就算好了（restLabel）——按距离换单位要用到截止日，
 * 卡片和全屏两侧各拼一套早晚会走样。这里只负责加那个「· 」和判有没有。
 * 没截断返回空串，卡片端按空串原样显示标题。
 */
function barRest(bar: GanttBarData): string {
  return bar.clipped ? `· ${bar.restLabel}` : '';
}

/**
 * 窄到这个程度（占卡片刻度的百分比）的条，就不画成条、改画成点。
 * 15 是按卡片内容宽约 290vp 估的：三个 10 号字加左右边距约 40vp，
 * 也就是宽度不到约 44vp 的条，标题就该挪到条外面去了。
 */
const NARROW_BAR_PCT: number = 15;

/**
 * 这一档的条宽度百分比。没有这一档（数组里没这个下标）时给 0，
 * 和原来 `shownBars.length > N ? ... : 0` 的空值处理一致。
 */
function barWidthPct(bar: GanttBarData | undefined): number {
  return bar === undefined ? 0 : toPct(bar.endDay - bar.startDay);
}

/**
 * 这一档该不该画成「点」。两种情况：
 * 1. 本来就是单日事项（isPoint）—— 一直是这么画的；
 * 2. 条太窄（宽度不到 NARROW_BAR_PCT）—— 卡片上的横条是把标题写在条里的，
 *    条一窄标题就被省略号吃光。点这条画法把名字挪到点外面，名字占的是行内
 *    剩余空间、不受点宽限制，一定看得见（用户要求「保证能看到字」）。
 *
 * 宽度用的是 barWidthPct，和 ganttNWidth 是同一个算式：
 * 两边一旦各算各的，就会出现「宽度够画条、却被判成点」这种自相矛盾的画法。
 */
function barIsPoint(bar: GanttBarData | undefined): number {
  if (bar === undefined) {
    return 0;
  }
  return bar.isPoint || barWidthPct(bar) < NARROW_BAR_PCT ? 1 : 0;
}

/**
 * 天数 → 相对卡片刻度的百分比（保留一位小数），卡片端直接拼进 width("xx%")。
 * 分母必须与上面 toGanttBar 传的跨度同用 CARD_GANTT_DAYS，两处对齐，
 * 条的百分比定位才和实际刻度一致。
 */
function toPct(days: number): number {
  return Math.round(days / CARD_GANTT_DAYS * 1000) / 10;
}
