/**
 * 文件路径：entry/src/main/ets/logic/DailyRollover.ets
 * 用途：每日结算——App 启动时把「课表 / 长期任务」两类源头流转成今天的条目，
 *       并清掉上课时刻已经过的课表条目。三步顺序固定，不能调换：
 *       先清已过的课 → 再把到期的长期任务落成今天待办 → 最后展开今天的课表。
 *       三步全部做成幂等：启动十次和启动一次，库里的结果完全一样。
 */

import { DbHelper } from '../data/DbHelper';
import { EntryItem, TimetableException, TimetableRule } from '../data/Types';
import { expandDay, TimetableOccurrence } from './TimetableLogic';
import { DAY_MS, sameTimeOnDay } from '../viewmodel/EntryDisplay';

/** id 生成用的自增序号：和时间戳、随机数一起拼，同一毫秒内连生成多条也不会撞 id */
let idSeq: number = 0;

/**
 * 每日结算入口。App 启动、读第一屏数据之前调用一次。
 * 为什么要放在读库之前：先清场再生成，随后的一次全量读库拿到的就是结算后的完整数据，
 * 不需要刷新两次界面。
 * @param db  已初始化的数据库句柄
 * @param now 当前毫秒时间戳（「今天」以它为准）
 */
export async function rollover(db: DbHelper, now: number): Promise<void> {
  // 「今天 0 点」是三步共用的基准：条目的 date 一律约定存 0 点时间戳，
  // 所有比较和生成都必须先归一化到 0 点，否则跨天边界会算错
  const todayStart: number = startOfDay(now);

  // ── 【1】清理已经没有意义的课表条目 ──
  // 放在最前：先清场再生成。课表条目一过上课时刻就没意义，物理删除不进回收站；
  // 昨天及更早的积压旧课表也在这一步一并扫掉——即使用户隔了很多天没打开 App，
  // 一次也能全部清干净。
  await db.deletePassedTimetableEntries(todayStart, now);

  // ── 【2】长期任务到期，生成今天的待办 ──
  // 长期任务的识别标志是 startDate 非空（Types.ets 里 startDate 就是「长期任务的开始日」）。
  // 前提约定：长期任务永远有开始日——新建时没填就用创建当天的 0 点写进去；
  // 单日事项则必然不带 startDate。所以「startDate !== null」是长期任务的充要判据，
  // 普通待办和生成出来的副本都不带 startDate，不会误伤，也不会自我复制。
  // 「到期」= 原条目的 date 已经到了或已经过了今天。不能只认 date === 今天：
  // 到期那天如果一次都没跑结算（没开 App、也没刷新过卡片），第二天 todayStart 一变，
  // 这条就再也取不出来，该长期任务永远不再派生出待办——「到期别忘」就成了
  // 「到期那天不开 App 等于没这件事」。放宽到 <=，迟到几天打开也补得上。
  // 边界：迟到满 7 天才打开时，补生成的条目 date 距今已够 OVERDUE_ARCHIVE_DAYS，
  // 一落地就按归档规则进「已完成」，不在「近期」冒出来。这是有意的——归档是主规则，
  // 不为这条边角情形破例；原长期任务自己还在甘特上，用户不会完全看不到这件事。
  const allActive: EntryItem[] = await db.getAllActiveEntries();
  // 已勾掉的长期任务要一并过滤掉：用户勾掉即宣告这条任务已完结，
  // 再为它派生今天的待办等于把勾掉的动作悄悄撤销了。
  // 开始日 = 截止日的（建的时候没留准备期）也不派生：它没有准备期可讲，
  // SectionLogic 认这种是单日事项、本体自己就会进「今天」段，
  // 再派生一条就成了同一件事在段里出现两张一样的卡片。
  const dueLongterms: EntryItem[] = allActive.filter((e: EntryItem): boolean =>
    e.startDate !== null && e.startDate !== e.date
    && !e.done && e.date !== null && e.date <= todayStart);
  for (const origin of dueLongterms) {
    // 上面的过滤已经排除了 date 为 null 的，这里只是把类型收窄成 number
    const dueDate: number | null = origin.date;
    if (dueDate === null) {
      continue;
    }
    // 幂等闸门：为这条长期任务生成过待办（哪怕已勾掉 / 已删）就不再生成。
    // 键取 dueDate 而不是今天——下面派生出的条目 date 就写成 dueDate，
    // (source, sourceRef, date) 这个键因此天然唯一：一条长期任务一辈子只派生一条
    // 待办，迟到几天补生成也不会第二天再冒出一条
    const generated: boolean = await db.hasEntryOfSource('longterm', origin.id, dueDate);
    if (generated) {
      continue;
    }
    const item: EntryItem = {
      id: newId(now),
      title: origin.title,
      body: origin.body,
      // 派生条目就落在原条目的到期日上（正常情况就是今天）：迟到补生成时它会是
      // 一条「逾期 N 天」的条目，用户一眼看得出是补的。这也是上面幂等闸门
      // 能按 dueDate 判的原因——键里的日期和这里的 date 是同一个值。
      date: dueDate,
      // 截止时刻跟着搬到同一天：dueTime 是绝对时间戳，直接继承 origin.dueTime
      // 会把那天的时刻配到另一个日期上，变成悬空值——原时刻已过的话，这条
      // 一生成就是过期，11:30 / 16:05 的重推还会被 pendingForReminder 静默摘掉。
      // 课表那条分支（todayStart + timeStartToOffset）也是这么现算的，这里对齐它。
      dueTime: sameTimeOnDay(origin.dueTime, dueDate),
      // 生成的待办不是长期任务本身，不写 startDate：否则它会在甘特上再画一根横条，
      // 和原条目重复；也没有 startDate 也不影响它进「今天」段（分段只看 date）。
      startDate: null,
      done: false,
      doneAt: null,
      source: 'longterm',
      sourceRef: origin.id,
      sortOrder: now,
      ganttOrder: null,
      deleted: false,
      createdAt: now,
      updatedAt: now
    };
    await db.insertEntry(item);
  }

  // ── 【3】课表展开，生成今天要上的课 ──
  await expandAndInsert(db, todayStart, now);
}

/**
 * 展开某一天的课表并落成条目。每日结算和「改完调休重算那一天」共用这一段——
 * 两处对「怎么从规则算出条目」的理解必须一致，所以不复制第二份。
 * @param dayStart 要展开的那天（当天 0 点的毫秒时间戳）
 * @param now      生成时刻：写进 createdAt / updatedAt，也用来生成 id；
 *                 上课时刻早于它的课直接不生成（见循环内的说明）
 */
async function expandAndInsert(db: DbHelper, dayStart: number, now: number): Promise<void> {
  // 学期设置从 settings 表读；读不到就用兜底值，宁可按默认展开也不能让结算整体失败：
  // semesterStart 兜底为要展开的那天（即第 1 周，本周的课照常展开），firstWeekIsOdd 兜底为 true。
  const semesterStartRaw: string | undefined = await db.getSetting('semesterStart');
  // 归一化到 0 点：expandDay 按「毫秒差 / 一周」算周次，起点如果不是 0 点会带出半天误差
  const semesterStart: number =
    semesterStartRaw !== undefined ? startOfDay(Number(semesterStartRaw)) : dayStart;
  const firstWeekIsOddRaw: string | undefined = await db.getSetting('firstWeekIsOdd');
  const firstWeekIsOdd: boolean =
    firstWeekIsOddRaw !== undefined ? firstWeekIsOddRaw === '1' : true;

  const rules: TimetableRule[] = await db.getAllRules();
  // expandDay 接收例外全集，但一天最多一条例外：只查这一天这一条，包成数组传进去
  const exception: TimetableException | undefined = await db.getExceptionByDate(dayStart);
  const exceptions: TimetableException[] = exception !== undefined ? [exception] : [];
  const occurrences: TimetableOccurrence[] =
    expandDay(rules, exceptions, dayStart, semesterStart, firstWeekIsOdd);

  // 课表条目要按上课顺序拿一串靠前的 sortOrder，定序依据是这节课自己的上课时刻
  for (const occ of occurrences) {
    // 上课时刻已经过的课不生成。这一步和【1】的删除必须配套：只删不跳的话，
    // 幂等闸门查的是「条目此刻在不在库里」，刚被删掉的课它查不到，下次结算
    // 就会重新插回库里——界面上的课删了又冒、冒了又删，永远循环。
    // 判断放在闸门查询之前：已过的课连查库都省一次。
    // 本函数也被「改完调休重算那一天」共用，重算同样不会把已过的课算回来。
    const dueTime: number = dayStart + timeStartToOffset(occ.timeStart);
    if (dueTime < now) {
      continue;
    }
    // 幂等闸门：同一条规则这天已经生成过条目就跳过（调休改星期几也不影响：
    // 判定的是「这条规则 + 这天」有没有生成过，而不是「这节课」）
    const exists: boolean = await db.hasEntryOfSource('timetable', occ.ruleId, dayStart);
    if (exists) {
      continue;
    }
    const item: EntryItem = {
      id: newId(now),
      // 教室非空时拼进标题，如「高等数学 · 逸夫楼201」；为空就只显示课名
      title: occ.location.length > 0 ? `${occ.name} · ${occ.location}` : occ.name,
      body: '',
      date: dayStart,
      dueTime: dueTime,
      // 课表条目过了上课时刻，下一次结算就被【1】清掉，没有甘特横条的概念
      startDate: null,
      done: false,
      doneAt: null,
      source: 'timetable',
      sourceRef: occ.ruleId,
      // 基准取「明天 0 点」，让值恒为负：这串值如今只用来定**课表内部**的先后（早课在前）。
      // 整组课表排在手写条目上面还是下面，已由 SectionLogic.sortInSection 定死（课表殿后），
      // 跟这里的值无关了。同一时刻上多节课的概率极低，真碰上由 createdAt 兜底。
      //
      // 为什么不用循环下标（原来写的是 i - occurrences.length）：那是「这一批展开出几节课」
      // 里的相对位置，不是绝对顺序。规则分批录入、或一天里分几次启动 App 结算时，每批拿到的
      // occurrences.length 不同，算出来的值会跨批次撞车——实测 13:30 的课排到了 08:00 前面，
      // 另有两节课并列在同一个值上。改用 dueTime 定序后，一节课的排序值只取决于它自己几点上，
      // 跟哪一批生成、那批有几节课都无关，重复结算也必然得到同一个值。
      sortOrder: dueTime - (dayStart + DAY_MS),
      ganttOrder: null,
      deleted: false,
      createdAt: now,
      updatedAt: now
    };
    await db.insertEntry(item);
  }
}

/**
 * 重算某一天的课表条目：先清掉那天已生成的课表条目，再按最新规则 + 调休重新展开。
 *
 * 为什么需要它：expandAndInsert 的幂等闸门按「规则 + 日期」判重，用户改完调休之后再走
 * 一次结算会被闸门整条挡住——设了「今天不上课」，列表里的课还在；设了「改上周三的课」，
 * 课还停在原来的星期几上，等于调休白设。所以改调休那条路必须先清后展。
 * 只清 source = 'timetable' 的条目：用户自己写的待办一条都不碰。
 * 副作用：那天的课会按新安排重新生成，之前勾掉的状态不保留——用户改的本来就是
 * 「这天到底上不上课」，按新课表重排正是他要的结果。上课时刻已过的课不会被
 * 算回来（expandAndInsert 生成前就跳过），和每日结算的口径一致。
 * @param dayStart 要重算的那天（当天 0 点的毫秒时间戳）
 * @param now      生成时刻，透传给 expandAndInsert
 */
export async function rebuildTimetableOfDay(db: DbHelper, dayStart: number, now: number): Promise<void> {
  await db.deleteTimetableEntriesOfDay(dayStart);
  await expandAndInsert(db, dayStart, now);
}

/**
 * 生成一个不重复的条目 id：「时间戳 - 自增序号 - 随机数」。
 * 一次结算可能连生成十几条，时间戳相同、随机数也可能撞，
 * 中间垫一层模块内自增序号，保证同一进程内绝不重复。
 * 页面手工新建条目也复用它：id 只要求全局唯一，生成方是谁无所谓。
 */
export function newId(now: number): string {
  idSeq += 1;
  return `${now}-${idSeq}-${Math.floor(Math.random() * 1000000)}`;
}

/**
 * 取 ts 所在自然日、本地时区的 0 点毫秒时间戳。
 * 与 SectionLogic 里的同名函数保持一致：logic 层不依赖 viewmodel，
 * 这个 4 行的小函数在各 logic 文件里各自持有一份是刻意的取舍。
 */
function startOfDay(ts: number): number {
  const d = new Date(ts);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/**
 * 把 "HH:mm" 形式的上课时间（如 "08:00"）换算成当天的毫秒偏移。
 * 解析失败按 0 点（偏移 0）处理：课表规则的 timeStart 来自用户输入，
 * 一条坏数据不该让整个每日结算失败。
 */
function timeStartToOffset(timeStart: string): number {
  const parts: string[] = timeStart.split(':');
  if (parts.length !== 2) {
    return 0;
  }
  const hours: number = Number(parts[0]);
  const minutes: number = Number(parts[1]);
  if (Number.isNaN(hours) || Number.isNaN(minutes)) {
    return 0;
  }
  return (hours * 60 + minutes) * 60 * 1000;
}
