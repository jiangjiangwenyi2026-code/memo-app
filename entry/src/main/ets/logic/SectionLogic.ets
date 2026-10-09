/**
 * 文件路径：entry/src/main/ets/logic/SectionLogic.ets
 * 用途：「近期」三段流转的纯逻辑：判断单条条目属于哪一段（今天 / 明天 / 过期），
 *       以及把一批条目按段分组。只做计算，不碰数据库、不碰界面。
 */

import { EntryItem } from '../data/Types';

/** 「近期」的三段：今天 / 明天 / 过期 */
export type RecentSection = 'today' | 'tomorrow' | 'overdue';

/** 三段分组结果：overdue 过期、today 今天、tomorrow 明天，段内已排好序 */
export interface RecentGroups {
  overdue: EntryItem[];
  today: EntryItem[];
  tomorrow: EntryItem[];
}

/** 一天的毫秒数，用于从今天 0 点推明天 0 点 */
const DAY_MS: number = 24 * 60 * 60 * 1000;

/** 过期条目在「过期」段里的保留天数：满这么多天后不再进「近期」，归到归档页的「已完成」 */
export const OVERDUE_ARCHIVE_DAYS: number = 7;

/**
 * 判断一条已过期的条目是不是该归档了（规格：「满 7 天后进「已完成」隐藏」）。
 * 基准用 item.date（截止日）：有截止时刻的条目，它的 dueTime 也是从 date 推出来的同一天，
 * 所以两种过期情形共用 date 做基准就够了。
 * @param item 条目
 * @param now  当前毫秒时间戳
 * @returns true = 已过保留期，应当从「近期」退场
 */
export function isOverdueArchived(item: EntryItem, now: number): boolean {
  // 已勾掉的不算「过期归档」：它已经作为「完成」进归档页了，别重复算两遍
  if (item.done || item.date === null) {
    return false;
  }
  return item.date <= startOfDay(now) - OVERDUE_ARCHIVE_DAYS * DAY_MS;
}

/**
 * 这条此刻算不算「过期」——只看时刻，不管归档。
 * 判据与 sectionOf 同源：有截止时刻的比时刻（一过截止时刻立刻算过期），没有的比日期。
 * 抽出来共用是为了让搜索结果和主页不各说一套：同一条在主页的「过期」段里、
 * 搜出来却标「今天」，用户会以为搜索出了错。顺带也让「过期」只有一处定义，
 * 以后改判据不会漏掉另一个调用方。
 * 课表条目是特例：永不判「过期」（见函数内说明）。
 */
export function isOverdue(item: EntryItem, now: number): boolean {
  // 课表条目永不进「过期」段——规格给课表的是特殊待遇：过了上课时刻，下一次
  // 结算（开 App / 卡片刷新 / 回主页）就物理删掉，不标逾期天数、不归档。
  // 它的 dueTime 存的就是上课时刻，不特判的话每天上午 8:00 那节课一到 8:00
  // 就立刻从「今天」段掉进「过期」段——尤其两个结算点之间（比如 7:50 打开 App、
  // 一直看到 8:30），已过的课还在库里，没有这个特判它会突然掉进「过期」段。
  // 桌面卡片上「过期 N 条」也会把它算进去。
  // 特判放在 isOverdue 本身而不是调用方：这个函数是主页和搜索页共用的口径，
  // 改这里等于同时把两处都改对。
  if (item.source === 'timetable') {
    return false;
  }
  if (item.dueTime !== null) {
    return item.dueTime < now;
  }
  return item.date !== null && item.date < startOfDay(now);
}

/**
 * 判断一条条目属于「近期」的哪一段。按顺序判定，命中即返回：
 *   1. isOverdue 为真                      → overdue（判据见该函数）
 *   2. date === 今天 0 点（且没进 overdue）→ today
 *   3. date === 明天 0 点                  → tomorrow
 *   4. 其他（date 为 null、日期更远等）     → undefined，不进「近期」
 * 「今天 0 点」= now 所在自然日、本地时区的 0 点。
 * @param item 条目
 * @param now 当前毫秒时间戳
 * @returns 所属段；不属于「近期」返回 undefined
 */
export function sectionOf(item: EntryItem, now: number): RecentSection | undefined {
  // 长期任务本体（startDate 非空）不进「近期」：它归甘特管，到期那天由 DailyRollover
  // 生成一条只看今天的待办来代表它。两者 date 都等于截止日、同名，不排除就会在
  // 「今天」段出现两张一样的卡片，6:30 汇总也会把同一件事念两遍。
  // 例外：开始日 = 截止日 的（建的时候没留准备期），它没有横条可画、甘特上只剩一个点，
  // 而那个点按新口径又不画了——再不放进「近期」就彻底没地方看见它。所以这种按单日事项
  // 对待，照常进今天 / 明天段；配套改动有两处，缺一不可：
  //   DailyRollover 不为它派生待办（本体自己就在段里了，派生会变成两张一样的卡片）；
  //   NotifyContent 的「明天到期」也不再补它（它已经进了 groups.tomorrow，补了就念两遍）。
  if (item.startDate !== null && item.startDate !== item.date) {
    return undefined;
  }
  if (isOverdue(item, now)) {
    // 过期满 7 天的从「近期」退场，去归档页找
    return isOverdueArchived(item, now) ? undefined : 'overdue';
  }
  const todayStart = startOfDay(now);
  if (item.date === todayStart) {
    return 'today';
  }
  if (item.date === startOfDay(now + DAY_MS)) {
    return 'tomorrow';
  }
  return undefined;
}

/**
 * 把一批条目分成三段（过期 / 今天 / 明天），不属于「近期」的直接丢弃。
 * 段内顺序：非课表在前、课表殿后；每一组内部按 sortOrder 升序、再按 createdAt 升序。
 * 界面 / 卡片 / 通知三处共用这一份，改口径只改这里。
 * @param items 条目列表（是否先过滤 deleted 由调用方决定，本函数只管分段）
 * @param now 当前毫秒时间戳
 * @returns 三段分组结果
 */
export function groupRecent(items: EntryItem[], now: number): RecentGroups {
  const overdue: EntryItem[] = [];
  const today: EntryItem[] = [];
  const tomorrow: EntryItem[] = [];
  for (const item of items) {
    const section: RecentSection | undefined = sectionOf(item, now);
    if (section === 'overdue') {
      overdue.push(item);
    } else if (section === 'today') {
      today.push(item);
    } else if (section === 'tomorrow') {
      tomorrow.push(item);
    }
  }
  const groups: RecentGroups = {
    overdue: sortInSection(overdue),
    today: sortInSection(today),
    tomorrow: sortInSection(tomorrow)
  };
  return groups;
}

/** 取 ts 所在自然日、本地时区的 0 点毫秒时间戳 */
function startOfDay(ts: number): number {
  const d = new Date(ts);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/**
 * 段内排序：非课表在前、课表殿后；每一组内部按 sortOrder 升序、createdAt 升序；
 * 不改动传入数组。
 *
 * 课表为什么固定沉底：这一段回答的是「今天我要动手做什么」。课几点上不由用户安排，
 * 摆在末尾当背景看就行；他自己敲进去的待办才是要盯的，顶在上面。
 * 通知里的汇总本来就是这个口径（NotifyContent 的 putTimetableLast），
 * 现在统一到这儿，三个调用方（界面 / 卡片 / 通知）才算一套规则。
 *
 * 代价是课表条目再也拖不到非课表上面——这是明确要的结果。非课表之间、
 * 以及课表之间仍然各按各的 sortOrder 摆，拖拽照常好使。
 *
 * 原来走的是另一条路：DailyRollover 生成课时给一串靠前的 sortOrder，靠值本身排到最上面。
 * 那条路依赖「生成那一刻算出来的数」，改口径就得把历史数据全量重算；沉底在比较器里
 * 定死则立刻对所有存量条目生效，不用碰数据库。
 */
function sortInSection(items: EntryItem[]): EntryItem[] {
  const copied: EntryItem[] = items.slice(0);
  copied.sort((a: EntryItem, b: EntryItem): number => {
    const ra: number = a.source === 'timetable' ? 1 : 0;
    const rb: number = b.source === 'timetable' ? 1 : 0;
    if (ra !== rb) {
      return ra - rb;
    }
    if (a.sortOrder !== b.sortOrder) {
      return a.sortOrder - b.sortOrder;
    }
    return a.createdAt - b.createdAt;
  });
  return copied;
}
