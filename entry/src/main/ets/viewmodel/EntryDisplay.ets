/**
 * 文件路径：entry/src/main/ets/viewmodel/EntryDisplay.ets
 * 用途：数据库条目（EntryItem）→ 界面展示数据的纯转换层。
 *       页面不在 build() 里做任何计算，也不直接拿 EntryItem 渲染：
 *       「显示什么标题、什么时间文案、甘特条画多长、用什么颜色」
 *       这些规则全部集中在这里。纯函数、不碰库不碰界面，方便单测与复用。
 */

import { EntryItem } from '../data/Types';

/** 甘特默认跨度（天）：全屏甘特捏合缩放的初始档位；桌面卡片不用它，改用下面的 CARD_GANTT_DAYS */
export const GANTT_DAYS: number = 28;

/** 刻度起点在「今天」之前留的天数：留几天"过去"，刚开头的事才看得见 */
export const GANTT_PAST_DAYS: number = 3;

/**
 * 桌面卡片的甘特跨度（天）。比全屏的 GANTT_DAYS 窄一半：
 * 卡片只有那么窄一条，28 天摊下来一天才十来个像素，三两天的小事就剩一根细线，
 * 标题一个字都露不出来；砍到 14 天，每根条宽度翻倍，近期的事才看得清。
 * 卡片不能缩放也不能平移（见下面「桌面卡片不缩放」那条），所以这个值就是卡片唯一的取值。
 * 砍掉的那部分有兜底：卡片本来就会在末尾给一行「还有 N 项…」。
 */
export const CARD_GANTT_DAYS: number = 14;

/**
 * 全屏甘特捏合缩放的范围与步长（天）。跨度只允许 7 的倍数：
 * 日期刻度按周等宽分格（一格 7 天），横条按「天数 / 跨度」的百分比定位，
 * 跨度不是 7 的倍数时刻度格边界和横条的百分比就对不齐。
 * 桌面卡片不缩放，永远用 CARD_GANTT_DAYS。
 */
export const GANTT_MIN_SPAN_DAYS: number = 7;
export const GANTT_MAX_SPAN_DAYS: number = 56;
export const GANTT_SPAN_STEP_DAYS: number = 7;

/** 一天的毫秒数。本项目所有时间戳一律是毫秒，跨天推算全靠它换算 */
export const DAY_MS: number = 24 * 60 * 60 * 1000;

/** 没写 startDate 的条目在甘特里画成「点」：一个只有 0.35 天宽的短条 */
const POINT_BAR_DAYS: number = 0.35;

/** 横条最小宽度（天）：再窄就看不见了，保个底 */
const MIN_BAR_DAYS: number = 0.2;

/** 甘特调色板：颜色数量够区分相邻几根条即可，多了反而花 */
const PALETTE: string[] = ['#5B8FF9', '#5AD8A6', '#F7B500', '#9C8BF5', '#F77234', '#36CFC9'];

/** 倒计时细到这个天数以内就说天数；再远就该换粗单位了，「还剩 47 天」这种数字听不出远近 */
const REST_FINE_DAYS: number = 30;

/**
 * 倒计时的说法，按距离换单位——越远说得越粗：
 * - 30 天以内：`剩 12 天`。这段是「得安排上了」，天数最有信息量
 * - 同年且超过 30 天：`剩 6 个周末`。天数在这个尺度上是个抽象数字，
 *   周末才是「你还有几次休息日能拿来干这件事」——「四级还剩 10 个周末」
 *   比「剩 75 天」扎心得多，这是这个换算唯一的理由
 * - 跨到明年：`剩 4 个月`。这时候数周末要数十几个，粗一个月更说明问题
 *
 * 周末个数按 7 天取整（75 天 = 10 个整周），不足一个整周的不算——
 * 「还剩 0 个周末」比「还剩 3 天」松得多，那种近处的事本来就走上面那档。
 * 跨年那档按日历月差算（9 月底到次年 3 月 = 5 个月），跟人掰手指数的口径一致，
 * 不拿天数除以 30——那是「3 个月」，跟日历对不上。
 *
 * @param days     距今天还有几天（至少 1）
 * @param dateMs   截止日的绝对时间戳，判跨年用
 * @param todayStart 今天 0 点，判年份用
 */
export function restText(days: number, dateMs: number, todayStart: number): string {
  if (days <= REST_FINE_DAYS) {
    return `剩 ${days} 天`;
  }
  const end = new Date(dateMs);
  const today = new Date(todayStart);
  if (end.getFullYear() !== today.getFullYear()) {
    const months: number = (end.getFullYear() - today.getFullYear()) * 12
      + (end.getMonth() - today.getMonth());
    // 减到 0 或负数说明跨年但不足一个月，那种事走不到这一档（days > 30），兜个底而已
    return `剩 ${Math.max(1, months)} 个月`;
  }
  return `剩 ${Math.max(1, Math.floor(days / 7))} 个周末`;
}

/** 「近期」卡片的展示数据 */
/**
 * 课表条目把教室拼进标题时用的分隔符（见 DailyRollover：`${name} · ${location}`）。
 * 导出给界面用：窄屏把教室挪到第二行、宽屏又拼回一行，两边都得用同一个分隔符，
 * 各写一个字面量早晚会走样。
 */
export const TITLE_LOCATION_SEP: string = ' · ';

/** 课程配色的档数，与 color.json 里 course_0..course_5 一一对应 */
const TINT_COUNT: number = 6;

/**
 * 散列时用的乘子和模数。乘 131 是常见的字符串散列做法；模数取个大质数、
 * 最后才折回档位——**不能直接拿逐字符累加和对 TINT_COUNT 取模**：
 * 中文字符码点分布得很密，累加和全是 6 的倍数量级，实测「体育」和「新概念武器」
 * 两门课算出来都是第 3 档、画成一模一样的蓝。质数取模把这种规律打散了。
 * 乘子与 TINT_COUNT 互质（131 % 6 = 5）也是必要的：乘子模 6 若等于 1
 * （如 31、7），乘完还是同余，等于没乘。
 */
const TINT_MUL: number = 131;
const TINT_MOD: number = 1000003;

/**
 * 按课程名取一个稳定的配色档位（0..TINT_COUNT-1）。
 * 同一门课永远同一档，几门不同的课大概率岔开，且不用维护一张课程-颜色表。
 *
 * 为什么按课名而不是按条目 id：课表条目是每日结算时「删掉那天的、再按规则重新展开」
 * 生成出来的（见 DailyRollover），id 每次重建都换一批，按 id 取色会让同一门课天天变颜色。
 */
function tintOf(name: string): number {
  let h: number = 0;
  for (let i = 0; i < name.length; i++) {
    h = (h * TINT_MUL + name.charCodeAt(i)) % TINT_MOD;
  }
  return h % TINT_COUNT;
}

export interface RecentCardData {
  /** 条目 id：点勾选框时靠它回库里找条目 */
  id: string;
  /** 卡片标题。课表条目的「课程名 · 教室」在数据层就切成了两半（见 toRecentCard） */
  title: string;
  /** 时间文案；null 表示不显示时间 */
  timeText: string | null;
  /**
   * 教室（课表条目才有，其余恒为空串）。
   * 单独一个字段而不是拼在 title 里：窄屏一行放不下「课程名 · 教室」，
   * 界面得能把教室挪到第二行跟时间作伴；拼成一串在界面层切不动——
   * 界面不知道哪个「·」是拼教室用的，手写条目的标题里用户自己就可能打「·」。
   */
  location: string;
  /** 是否可以拖动：只有手写条目能拖（课表条目由规则生成、长期任务派生的待办改了日期会重复生成） */
  draggable: boolean;
  /**
   * 配色档位 0-5（对应 color.json 里的 course_N_bg / course_N_fg）；-1 = 不上色。
   * 只给课表条目上色，手写条目保持灰底：一眼分得出「课」和「我记的事」，
   * 颜色在这里是分类用的，不是装饰——而且满屏花块反而看不清哪条是自己写的。
   */
  tint: number;
}

/** 「下一节」提示行的展示数据：只在「近期」列头下面那一行用 */
export interface NextClassData {
  /** 上课时刻，如 "13:30" */
  timeText: string;
  /** 教室；课表规则里没填教室时为空串，界面不画那半截 */
  location: string;
}

/** 「随手记」卡片的展示数据 */
export interface NoteCardData {
  /** 条目 id：点勾选框时靠它回库里找条目 */
  id: string;
  /** 展示的短句 */
  text: string;
  /** 是否可以拖动：只有手写条目能拖（课表条目由规则生成、长期任务派生的待办改了日期会重复生成） */
  draggable: boolean;
}

/** 甘特横条的展示数据：startDay / endDay 是相对刻度第一天偏移的天数，允许小数 */
export interface GanttBarData {
  /** 条目 id：当 ForEach 的 key 用，刷新前后能对上同一条 */
  id: string;
  /** 横条里的任务名 */
  title: string;
  /** 从刻度第几天开始（0 = 刻度第一天） */
  startDay: number;
  /** 到刻度第几天结束（不含） */
  endDay: number;
  /** 横条颜色（hex），按条目 id 稳定取色。给桌面卡片用——那边只能收字符串 */
  color: string;
  /**
   * 横条配色档位，与 color 同一套哈希（见 stableTint）。
   * App 内的横条用这个 + 资源色画，才能跟着深色模式换一套配色；
   * 和 color 并存不是冗余：一个给卡片、一个给 App 内，来源相同、出口不同。
   */
  tint: number;
  /** 截止日超出刻度右端、条被截断：条内文案要补倒计时 */
  clipped: boolean;
  /** 被截断时距离真正截止还有几天（至少 1）；没截断时为 0。进 ForEach 的 key 用 */
  restDays: number;
  /**
   * 被截断时要补的倒计时文案（如「剩 10 个周末」），没截断时为空串。
   * 在这里算好而不是留给界面拼：文案要按截止日换单位（见 restText），
   * 而截止日只有这一层知道；两个界面（全屏甘特、桌面卡片）也就不会各写一套口径。
   */
  restLabel: string;
  /** 能不能勾 / 点开改：只有手写条目可以；课表条目由规则生成，改了下次展开会被覆盖 */
  editable: boolean;
  /** 截止日的绝对时间戳（毫秒）：拖动平移时用它算目标日期并写回 */
  dateMs: number;
  /**
   * 是不是「点」：单日事项（没开「需要提前准备」的）、以及开始日 = 截止日的长期任务，
   * 都没有长度可画，在甘特里只是钉在日期上的一个圆点。
   * 界面靠它换一套画法：名字不画在条里，改画在点外面——
   * 点只有 0.35 天宽（28 天刻度下约屏幕的 1.25%），名字画进去一个字都显示不出来。
   */
  isPoint: boolean;
}

/**
 * 取 ts 所在自然日、本地时区的 0 点毫秒时间戳。
 * 为什么要归一化：date / startDate 入库时都约定是「当天 0 点」，
 * 甘特刻度第一天也必须是 0 点，否则「按天算偏移」会带出半天误差。
 */
export function startOfDay(ts: number): number {
  const d = new Date(ts);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/**
 * 把一个时刻（绝对毫秒时间戳）的时分搬到指定自然日的 0 点上，得到「那一天的同一时刻」。
 * 传 null 原样返回 null。跨天搬条目时必须用它搬 dueTime——dueTime 是绝对时间戳，
 * 日期换了它还留在原地就成了悬空值（新日期配着旧日期的时刻），
 * 结果是一条「明天到期」的条目一到今天的 18:00 就掉进过期段。
 */
export function sameTimeOnDay(dueTime: number | null, dayStart: number): number | null {
  if (dueTime === null) {
    return null;
  }
  const d = new Date(dueTime);
  return dayStart + (d.getHours() * 60 + d.getMinutes()) * 60 * 1000;
}

/**
 * 甘特刻度的第一天 = 今天 0 点往前 GANTT_PAST_DAYS 天。
 * 页面和桌面卡片都必须调这个函数拿刻度起点，两边刻度才对得齐；
 * 千万不要各自写 startOfDay(now)，那样会把"过去 3 天"丢掉。
 */
export function ganttScaleStart(now: number): number {
  return startOfDay(now) - GANTT_PAST_DAYS * DAY_MS;
}

/** 展示标题：标题为空就用正文（随手记常常只写正文），两个都空时兜底一句占位 */
export function displayTitle(item: EntryItem): string {
  if (item.title.length > 0) {
    return item.title;
  }
  if (item.body.length > 0) {
    return item.body;
  }
  return '（无内容）';
}

/**
 * 甘特顺序的比较规则，分三档：
 * 1. 两条都在甘特上拖过（ganttOrder 都有值）→ 按 ganttOrder 排，这就是用户拖出来的顺序；
 * 2. 两条都没拖过 → 按列表顺序（sortOrder）排。升级前的老数据全是这一档，
 *    排出来和升级前一模一样，用户感觉不到这次改动；
 * 3. 一条拖过、一条没拖过 → 拖过的排前面。没拖过的是后来新建的（或刚加上日期的），
 *    排后面才对 —— 新加的排最后。
 *
 * 为什么不把两个键混成一个值比大小（`ganttOrder ?? sortOrder`）：
 * 两套键都是 1000 的倍数、量级会撞 —— 列表里拖排序也会把 sortOrder 写成 1000/2000/…，
 * 一条的 ganttOrder=1000 碰上另一条的 sortOrder=1000 就并列了，并列只能落到 createdAt 兜底，
 * 用户会看到「拖了、但没落到我要的位置」。分档比较不给它并列的机会。
 */
function compareGantt(a: EntryItem, b: EntryItem): number {
  const ka: number | null = a.ganttOrder;
  const kb: number | null = b.ganttOrder;
  if (ka !== null && kb !== null) {
    if (ka !== kb) {
      return ka - kb;
    }
  } else if (ka !== kb) {
    // 一个是 null 一个不是：有 ganttOrder 的排前面
    return ka === null ? 1 : -1;
  }
  if (a.sortOrder !== b.sortOrder) {
    return a.sortOrder - b.sortOrder;
  }
  return a.createdAt - b.createdAt;
}

/**
 * 把条目按甘特顺序排一份出来（不改原数组）。主页和桌面卡片都用它，
 * 保证两边从上到下的顺序一致 —— 卡片只画前 5 根，顺序不同就是两套内容。
 */
export function sortForGantt(items: EntryItem[]): EntryItem[] {
  return items.slice().sort(compareGantt);
}

/** 两位补零，拼时间文案用 */
function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/**
 * 时间文案规则：
 * - 日期已经过去的：标「逾期 N 天」（规格：不标红、不置顶），一眼看出拖了多久；
 * - 课表条目的 dueTime 存的是上课时刻，直接显示时刻（如 "08:00"），不带「截止」字样；
 * - 非课表条目有截止时刻才显示（如 "截止 18:00"），没有就为 null，界面不渲染。
 */
function formatTimeText(item: EntryItem, now: number): string | null {
  // 只对「日期已经过去」的条目算逾期天数：今天刚过截止时刻的条目 date 仍是今天，
  // 那种情况显示「截止 14:00」比「逾期 0 天」有用得多
  const todayStart: number = startOfDay(now);
  if (item.date !== null && item.date < todayStart) {
    const days: number = Math.max(1, Math.floor((todayStart - item.date) / DAY_MS));
    return `逾期 ${days} 天`;
  }
  if (item.dueTime === null) {
    return null;
  }
  const d = new Date(item.dueTime);
  const hm: string = `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
  return item.source === 'timetable' ? hm : `截止 ${hm}`;
}

/**
 * EntryItem → 「近期」卡片。now 决定「逾期 N 天」的 N，所以必须由调用方传进来。
 *
 * 卡片一律带勾选框，**课表条目也给**（2026-09-28 用户改的口径，规格里原来写的是「不给勾」）。
 * 起因是他早上看到今天全是课、左边一个圈都没有，没法处理「这节课不上了」。
 * 原来不给勾的理由是「勾了下次展开又回来」——这个理由不成立：
 * hasEntryOfSource 的判重**故意不过滤 done**，勾掉的课不会被重新生成出来。
 * 上课时刻一到，这条课仍照旧被 deletePassedTimetableEntries 物理删掉（跟勾没勾无关），
 * 所以勾掉那笔「已完成」最多躺到上课时刻，不会堆积。
 */
export function toRecentCard(item: EntryItem, now: number): RecentCardData {
  const full: string = displayTitle(item);
  // 课表条目的标题是「课程名 · 教室」一整串（见 DailyRollover），这里切开给界面更多余地：
  // 窄屏标题只放得下课程名，教室挪到第二行；宽屏排得下，界面再原样拼回去。
  // 只对课表条目切——手写条目标题里用户自己打的「·」是标题的一部分，不能动
  let title: string = full;
  let location: string = '';
  if (item.source === 'timetable') {
    const sep: number = full.indexOf(TITLE_LOCATION_SEP);
    if (sep >= 0) {
      title = full.substring(0, sep);
      location = full.substring(sep + TITLE_LOCATION_SEP.length);
    }
  }
  return {
    id: item.id,
    title: title,
    timeText: formatTimeText(item, now),
    location: location,
    draggable: item.source === 'manual',
    // 用切出来的课程名取色，不用带教室的整串：同一门课换教室时颜色不该跟着变
    tint: item.source === 'timetable' ? tintOf(title) : -1
  };
}

/**
 * 今天还没上的课里最近的那一节；没有就返回 null，界面整行不画。
 *
 * 为什么只认课表条目：这一行的用处是课间扫一眼就知道「接下来去哪」。
 * 手写条目本来就按时间排在下面「今天」段里，再提一遍是重复；而课表条目
 * 排在那一段的末尾（SectionLogic 定的课表殿后），要翻才能看到。
 *
 * 教室没有独立字段可读——entry 表里没有 location 列，生成条目时被拼进了标题。
 * 所以这里按分隔符从标题尾部切回来，而不是拿 sourceRef 回查 timetable 表：
 * 条目和规则会因为改课表而不同步（重算那天是整批删了重建），而标题在生成那一刻
 * 就写死了，跟列表里显示的同一个来源，切出来的必然和用户看到的一致。
 *
 * @param items 未完成条目全集（Index 传的是 lastUndone）
 * @param now   判定「还没上」的时刻
 * @returns 最近的一节课；今天没课、或课都上完了则 null
 */
export function nextClassOf(items: EntryItem[], now: number): NextClassData | null {
  // 课表条目只在当天生成，date 就是生成那天的 0 点。按它筛掉明天和历史遗留
  const todayStart: number = startOfDay(now);
  let best: EntryItem | null = null;
  // 最小的上课时刻单独拿一个 number 存着，不去读 best.dueTime：
  // 那个字段的类型是 number | null，编译器不会因为「赋给 best 时判过非空」就认它非空
  let bestDue: number = 0;
  for (const item of items) {
    if (item.source !== 'timetable' || item.date !== todayStart) {
      continue;
    }
    const due: number | null = item.dueTime;
    // done 也判一下：调用方传进来的已经是未勾掉的集合，但那样本函数就依赖调用方的
    // 过滤了——勾掉的课从列表退场了却还顶在「下一节」上，是这一行最难查的错法
    // dueTime 存的就是上课时刻（连堂课存第一节课的开始时刻）
    if (item.done || due === null || due <= now) {
      continue;
    }
    if (best === null || due < bestDue) {
      best = item;
      bestDue = due;
    }
  }
  if (best === null) {
    return null;
  }
  const title: string = displayTitle(best);
  const sep: number = title.indexOf(TITLE_LOCATION_SEP);
  const d = new Date(bestDue);
  return {
    timeText: `${pad2(d.getHours())}:${pad2(d.getMinutes())}`,
    location: sep >= 0 ? title.substring(sep + TITLE_LOCATION_SEP.length) : ''
  };
}

/** EntryItem → 「随手记」卡片 */
export function toNoteCard(item: EntryItem): NoteCardData {
  return {
    id: item.id,
    text: displayTitle(item),
    draggable: item.source === 'manual'
  };
}

/**
 * EntryItem → 甘特横条。date 为 null（随手记）没有时间维度，返回 undefined 不进甘特。
 * - 有 startDate：条从 startDate 画到 date（截止日）；
 * - 没有 startDate：在 date 那天画一个很短的条，视觉上是一个点；
 * - 起点晚于刻度末端的**不画**（返回 undefined）：硬画会被挤到刻度最右边，
 *   看着像「这就要开始了」，反而误导——它们由 ganttBeyond 汇总成一行灰字提示；
 * - 终点超出刻度右端的**裁到右端**并打上 clipped 标记，界面会补「剩 N 天」。
 * @param item       条目
 * @param scaleStart 刻度第一天（全屏页用「默认起点 + 平移偏移」；桌面卡片用 ganttScaleStart(now)）
 * @param spanDays   刻度一共显示多少天。全屏页随捏合缩放变化；桌面卡片固定传 CARD_GANTT_DAYS
 * @param todayStart 今天 0 点。「剩 N 天」按距今天算，而刻度起点可以被平移挪走，
 *                   从 scaleStart 反推今天（scaleStart + GANTT_PAST_DAYS * DAY_MS）只在
 *                   「默认窗口、未平移」时成立，所以今天必须显式传进来
 * @returns 甘特条数据；条目没有日期、或排到刻度之外时返回 undefined
 */
export function toGanttBar(item: EntryItem, scaleStart: number, spanDays: number,
  todayStart: number): GanttBarData | undefined {
  // 长期任务到期时自动生成的那条待办（source='longterm'）不进甘特：它只代表今天，
  // 没有 startDate，画出来是横条末端一个孤立的点，和原条目的横条重复。
  // 原条目自己（source='manual' + startDate）不受影响，照旧画横条。
  if (item.source === 'longterm') {
    return undefined;
  }
  if (item.date === null) {
    return undefined;
  }
  const dateMs: number = item.date;
  // 单日事项（没开「需要提前准备」的）只在「还没到」的时候上甘特：
  // 甘特是看「还剩多少天」的地方，今天和已经过去的事画上去没有任何信息量——
  // 今天的事「近期」栏里就有，过去的在那里还标着「逾期 N 天」，
  // 画到甘特上只是在今天那格、或者最下面杵一个小点，像没清干净的残留。
  // 未来的单日事项必须留着：「近期」栏只显示今天和明天，9/25 记的「9/28 交报告」
  // 在 9/26~9/27 那两天里，甘特上的这个点是唯一能看见它的地方。
  // 长期任务（有 startDate）不受这条限制：横条过期后照旧留在甘特最下面。
  if (item.startDate === null && dateMs <= todayStart) {
    return undefined;
  }
  // 长期任务若「开始日 = 截止日」（建的时候没留准备期），本质上就是一件单日的事，
  // 适用上面同一条口径：到时间了（今天 / 明天到期）它改成进「今天」「明天」段，
  // 甘特上就不再画那个点——栏里已经看得见的事，甘特上再来一个点就是重复。
  // 远期（后天及以后）的照旧画：「近期」段看不到它，那两天里甘特是它唯一露面的地方。
  // 有准备期的长期任务（开始日早于截止日）不受这条限制：那是一根有长度的横条，
  // 画的正是「要准备多久」，永远留在甘特上。
  if (item.startDate !== null && item.startDate === dateMs
    && dateMs <= todayStart + DAY_MS) {
    return undefined;
  }
  const startMs: number = item.startDate !== null ? item.startDate : dateMs;
  const rawStartDay: number = (startMs - scaleStart) / DAY_MS;
  // 整根都在刻度右边的（远期安排）：不画。判断必须在裁剪之前做，
  // 否则裁完就看不出它本来在哪了——那正是原来把远期条画到末尾的根因。
  if (rawStartDay >= spanDays) {
    return undefined;
  }
  let startDay: number = rawStartDay;
  // 没有 startDate 的画「点」：在截止日当天垫一段极短的长度
  let endDay: number = item.startDate === null ? startDay + POINT_BAR_DAYS : (dateMs - scaleStart) / DAY_MS;
  // 截断标记要在裁剪之前算：裁完就分不出「本来就这么短」和「被切短的」了
  const clipped: boolean = endDay > spanDays;
  // 倒计时按「距今天」算，不是「距刻度右端」：右端会随跨度和平移一起漂，
  // 拿它当基准数字就不可信了。今天由调用方显式传入（todayStart），见函数头注释
  const restDays: number = clipped
    ? Math.max(1, Math.ceil((dateMs - todayStart) / DAY_MS))
    : 0;
  // 天数只用来喂 ForEach 的 key（数字变了说明条读的位置变了），
  // 给人看的那句话由 restText 按距离换单位——同一件事两种粒度，
  // 别把它俩合并成一个字段，key 要的是稳定可比，文案要的是好读
  const restLabel: string = clipped ? restText(restDays, dateMs, todayStart) : '';
  if (startDay < 0) {
    startDay = 0;
  }
  if (endDay < startDay + MIN_BAR_DAYS) {
    endDay = startDay + MIN_BAR_DAYS;
  }
  if (endDay > spanDays) {
    endDay = spanDays;
    // 裁到末端后起点可能贴得太近，往回让出最小宽度；这里只往左让，
    // 绝不会把远处的条拉进刻度内——原来的 bug 就是反向拉了
    if (startDay > endDay - MIN_BAR_DAYS) {
      startDay = endDay - MIN_BAR_DAYS;
    }
  }
  // 只有「一天」的条画成点：单日事项本身没有长度，开始日 = 截止日的长期任务
  // 同样只有一天、也没长度可讲，两者用同一套画法。
  // 判据用 item.startDate === dateMs 而不是「两者都非空」：有准备期的长期任务
  // 才配得上横条，那种才看得出「要准备多久」。
  const isPoint: boolean = item.startDate === null || item.startDate === dateMs;
  const bar: GanttBarData = {
    id: item.id,
    title: displayTitle(item),
    startDay: startDay,
    endDay: endDay,
    color: stableColor(item.id),
    tint: stableTint(item.id),
    clipped: clipped,
    restDays: restDays,
    restLabel: restLabel,
    editable: item.source === 'manual',
    dateMs: dateMs,
    isPoint: isPoint
  };
  return bar;
}

/** 刻度窗口外的远期安排汇总：甘特下方那行灰字用 */
export interface GanttBeyondData {
  /** 完全排在刻度之外的条数 */
  count: number;
  /** 最近的一条还有几天才开始（相对今天，至少 1） */
  nearestDays: number;
  /**
   * 排到刻度之外的条目本体，按开始时间从近到远排好序。
   * count 就是这个列表的长度（同一份判定里数出来、收集起来的）。
   * 甘特下方那行灰字现在可以点开「远期安排」浮层，浮层直接拿这个列表渲染，
   * 让用户看得到也点得到那些画不进刻度的条目。
   */
  items: EntryItem[];
}

/**
 * 统计「排到刻度之外」的条目——它们的起点晚于刻度最后一天，画不进甘特。
 * 不画不等于不存在：不给提示的话，用户会以为这些安排丢了。
 * 除了 count / nearestDays，还把条目本体按开始时间从近到远一并返回，
 * 供灰字点开的「远期安排」浮层渲染。
 * 判定条件与 toGanttBar 里那条 return undefined 完全一致，两边不能各写一套；
 * 收集条目和数 count 用的是同一个循环里的同一个分支，天然不会不一致。
 */
export function ganttBeyond(items: EntryItem[], scaleStart: number, spanDays: number, now: number): GanttBeyondData {
  const todayStart: number = startOfDay(now);
  let count: number = 0;
  let nearestMs: number = Number.MAX_SAFE_INTEGER;
  const beyondItems: EntryItem[] = [];
  for (const item of items) {
    if (item.source === 'longterm' || item.date === null) {
      continue;
    }
    const startMs: number = item.startDate !== null ? item.startDate : item.date;
    if ((startMs - scaleStart) / DAY_MS < spanDays) {
      continue;
    }
    // 数数和收集在同一个分支里：count 恒等于 beyondItems.length，两处口径不可能漂移
    count++;
    beyondItems.push(item);
    if (startMs < nearestMs) {
      nearestMs = startMs;
    }
  }
  // 按开始时间从近到远：浮层里最近的排最上面。排序键就是上面判定用的那个
  // startMs（有 startDate 用 startDate，否则用截止日），和筛选口径保持一致。
  // 走到这里的条目 date 必非 null，兜底的 MAX_SAFE_INTEGER 只是为了过类型检查
  beyondItems.sort((a: EntryItem, b: EntryItem): number => {
    const sa: number = a.startDate !== null ? a.startDate : (a.date !== null ? a.date : Number.MAX_SAFE_INTEGER);
    const sb: number = b.startDate !== null ? b.startDate : (b.date !== null ? b.date : Number.MAX_SAFE_INTEGER);
    return sa - sb;
  });
  let nearestDays: number = 0;
  if (count > 0) {
    nearestDays = Math.max(1, Math.round((nearestMs - todayStart) / DAY_MS));
  }
  const data: GanttBeyondData = {
    count: count,
    nearestDays: nearestDays,
    items: beyondItems
  };
  return data;
}

/** 条目 id 的哈希：取色用，同一个 id 永远同一个值 */
function hashOf(id: string): number {
  let hash: number = 0;
  for (let i = 0; i < id.length; i++) {
    hash = (hash * 31 + id.charCodeAt(i)) % 1000003;
  }
  return hash;
}

/**
 * 按条目 id 稳定取一个颜色（hex 字符串）：颜色由 id 哈希决定，同一条每次刷新算出来都一样，
 * 界面不会闪变；不同条目靠哈希散开，尽量不撞色。
 * 给**桌面卡片**用——卡片模板只能拿到字符串，给不了资源色。
 */
export function stableColor(id: string): string {
  return PALETTE[hashOf(id) % PALETTE.length];
}

/**
 * 按条目 id 稳定取一个配色档位（0..PALETTE.length-1），哈希与 stableColor 同一套，
 * 所以 App 内的横条和桌面卡片上的同一条永远是同一个颜色档。
 * 给 **App 内的甘特条**用：那边的条要画成「半透明淡彩底 + 同色文字」，
 * 而这一对颜色在深色模式下必须整体换成另一套（浅底深字 → 深底亮字），
 * 只有资源色（$r）能跟着主题切；hex 字符串换不了。
 */
export function stableTint(id: string): number {
  return hashOf(id) % PALETTE.length;
}
