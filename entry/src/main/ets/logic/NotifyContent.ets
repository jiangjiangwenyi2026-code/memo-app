/**
 * 文件路径：entry/src/main/ets/logic/NotifyContent.ets
 * 用途：算出「今天三个提醒槽位各自该推哪几条通知」——纯计算，只读数据库，不碰任何通知服务。
 *
 * 为什么单独抽出来：同一个 6:30 的汇总有两条投递路径——
 *   1. ReminderService：交给后台代理提醒（reminderAgentManager）去发，精确到分钟，
 *      但真机上受管控，未开通权限的应用额度为 0；
 *   2. LocalNotifier：卡片被系统唤醒时用普通通知（notificationManager）当场发，
 *      不需要任何权限，代价是只能发在唤醒点上。
 * 两条路谁发都得念同一套话，所以「算什么」归本文件，「怎么发」归那两个文件。
 * 内容口径与界面完全一致：分段复用 SectionLogic.groupRecent，标题复用 displayTitle。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { DbHelper } from '../data/DbHelper';
import { EntryItem, SettingsKey } from '../data/Types';
import { groupRecent } from './SectionLogic';
import { displayTitle, startOfDay } from '../viewmodel/EntryDisplay';

/** hilog 日志标签与域，排查提醒问题时按它过滤 */
const TAG: string = 'NotifyContent';
const DOMAIN: number = 0x0000;

/** 三条提醒的默认时间：用户没进过设置页也不能没有提醒——这是产品的核心价值 */
const DEFAULT_TIME1: string = '06:30';
const DEFAULT_TIME2: string = '11:30';
const DEFAULT_TIME3: string = '16:05';

/**
 * 四条通知各自的 notificationId。
 * 两条投递路径共用同一段：同一条提醒换个通道发，在通知栏里仍然是同一条，
 * 用户不会因为「代理提醒没响、普通通知补上」就看到两条一模一样的。
 */
const NOTIFY_ID_SUMMARY: number = 1001;
const NOTIFY_ID_TOMORROW: number = 1002;
const NOTIFY_ID_NOON: number = 1003;
const NOTIFY_ID_EVENING: number = 1004;

/** 一天的毫秒数，用于从今天 0 点推明天 0 点；口径与 SectionLogic 的 DAY_MS 保持一致 */
const DAY_MS: number = 24 * 60 * 60 * 1000;

/** 解析好的 "HH:mm"：小时与分钟已校验过范围 */
export interface ParsedTime {
  hour: number;
  minute: number;
}

/** 一条要推的通知 */
export interface NotifyItem {
  /** 通知 id，见上面的 NOTIFY_ID_* */
  notificationId: number;
  title: string;
  content: string;
}

/** 一个提醒槽位今天的内容 */
export interface SlotContent {
  /** 槽位序号 0/1/2，对应设置里的 notifyTime1/2/3 */
  index: number;
  /** 解析好的提醒时分——兜底提醒要排未来几天，拿它算时刻，不必再读一次设置 */
  time: ParsedTime;
  /** 这个槽位原定的触发时刻（今天 0 点 + time） */
  plannedTs: number;
  /** 该推的通知；空数组表示今天这个槽位没东西可推（比如事都做完了） */
  items: NotifyItem[];
}

/** 今天的提醒全貌 */
export interface SlotPlan {
  /** 三个槽位，顺序固定为早上 / 中午 / 傍晚；设置里时间格式坏掉的槽位会缺席 */
  slots: SlotContent[];
  /** 库里一条未完成的事都没有时为 false——那种日子不垫兜底提醒，免得天天准点喊「打开看看」 */
  hasUndone: boolean;
}

/** 三个槽位的静态配置：序号 + 设置键 + 默认时刻 */
interface SlotConfig {
  index: number;
  key: SettingsKey;
  fallback: string;
}

const SLOT_CONFIGS: SlotConfig[] = [
  { index: 0, key: 'notifyTime1', fallback: DEFAULT_TIME1 },
  { index: 1, key: 'notifyTime2', fallback: DEFAULT_TIME2 },
  { index: 2, key: 'notifyTime3', fallback: DEFAULT_TIME3 }
];

/**
 * 算出今天三个槽位各自该推什么。
 * @param db  数据库句柄（读条目与提醒时间设置）
 * @param now 当前毫秒时间戳
 * @returns 当天提醒全貌；某个槽位的时间设置格式不合法时该槽位直接缺席，不排错时刻
 */
export async function buildSlotPlan(db: DbHelper, now: number): Promise<SlotPlan> {
  const todayStart: number = startOfDay(now);
  // 分段复用「近期」的规则，保证提醒内容和界面看到的完全一致
  const all: EntryItem[] = await db.getAllActiveEntries();
  const undone: EntryItem[] = all.filter((e: EntryItem): boolean => !e.done);
  const groups = groupRecent(undone, now);

  // 非课表在前、课表殿后：早上那一眼是为了安排自己要动手的事，课程时间固定，放末尾当背景即可。
  // 这个口径现在由 SectionLogic.sortInSection 统一负责，groups.today 出来就已经是这个顺序，
  // 不必再对调一次。
  const todayAll: EntryItem[] = groups.today;
  // 这里要单独补一批「明天到期的长期任务」，根因在 SectionLogic.sectionOf：
  // 它对 startDate 非空的条目一刀切返回 undefined。那个排除本身是对的——长期任务本体
  // 归甘特管，不排除的话到期当天它会和 DailyRollover 派生的待办副本在「今天」段
  // 出现两张同名卡片、6:30 汇总把同一件事念两遍；但它把 tomorrow 段也一起堵死了，
  // 而 tomorrow 段是「明天到期」通知的唯一数据源，于是长期任务在临期前一天从所有通知里消失。
  // 用户口径：「不管是不是长期，进到临期就一套标准：前一天的就早上发一次，当天的就三次。」
  // 筛选条件：startDate 非空（长期任务本体）、未完成（undone 已滤掉 done）、date 等于明天 0 点；
  // 数据直接从已读出的 undone 里筛，不再查一次库。
  // 开始日 = 截止日 的要排掉：那种没留准备期的本体现在已经按单日事项进了 groups.tomorrow，
  // 再补一遍就会在早上那条「明天到期」里把同一件事念两遍。
  const tomorrowStart: number = startOfDay(now + DAY_MS);
  const dueTomorrowLongTerm: EntryItem[] = undone.filter((e: EntryItem): boolean =>
    e.startDate !== null && e.startDate !== e.date && e.date === tomorrowStart);
  // 两组（groupRecent 的 tomorrow 段 + 补进来的长期任务）合并后统一按 sortOrder 升序、
  // 相同再按 createdAt 升序排一遍，好让长期任务插到正确位置而不是一律沉底。
  // 只补进 tomorrowAll（早上那条「明天到期」）就够了：中午/下午两轮走
  // pendingForReminder(todayAll, plannedTs)，只从 todayAll 里筛、压根不碰 tomorrowAll，
  // 所以长期任务天然只会在早上 06:30 出现一次，不会在中午/下午被推，无需额外过滤。
  const tomorrowMerged: EntryItem[] = groups.tomorrow.concat(dueTomorrowLongTerm);
  tomorrowMerged.sort((a: EntryItem, b: EntryItem): number => {
    if (a.sortOrder !== b.sortOrder) {
      return a.sortOrder - b.sortOrder;
    }
    return a.createdAt - b.createdAt;
  });
  // 上面这次重排只看 sortOrder、不看来源，会把 SectionLogic 摆好的「课表殿后」又搅乱，
  // 所以这里必须自己再对调一次。todayAll 那份顺序没被动过，不用。
  const tomorrowAll: EntryItem[] = putTimetableLast(tomorrowMerged);

  const slots: SlotContent[] = [];
  for (const cfg of SLOT_CONFIGS) {
    const time: ParsedTime | undefined = await loadNotifyTime(db, cfg.key, cfg.fallback);
    if (time === undefined) {
      continue;
    }
    const plannedTs: number = fireTimestampOf(todayStart, time);
    const slot: SlotContent = {
      index: cfg.index,
      time: time,
      plannedTs: plannedTs,
      items: buildItems(cfg.index, todayAll, tomorrowAll, plannedTs)
    };
    slots.push(slot);
  }
  const plan: SlotPlan = { slots: slots, hasUndone: undone.length > 0 };
  return plan;
}

/**
 * 某个槽位该推哪几条。
 *   0（早上）→ 两条：今日汇总 + 明天到期。两个关注点不同（今天要干什么 vs 提前看一眼明天），
 *              合并成一条会互相淹没；
 *   1/2（中午 / 傍晚）→ 一条：今天还没做完的非课表条目。
 * @param plannedTs 该槽位原定的触发时刻，中下午那条靠它筛「到点时还没过期」的条目
 */
function buildItems(index: number, todayAll: EntryItem[], tomorrowAll: EntryItem[],
  plannedTs: number): NotifyItem[] {
  const items: NotifyItem[] = [];
  if (index === 0) {
    // 没有条目就不推：不推「今天有 0 件事」这种空通知
    if (todayAll.length > 0) {
      const summary: NotifyItem = {
        notificationId: NOTIFY_ID_SUMMARY,
        title: `今天有 ${todayAll.length} 件事`,
        content: buildLines(todayAll)
      };
      items.push(summary);
    }
    if (tomorrowAll.length > 0) {
      const tomorrow: NotifyItem = {
        notificationId: NOTIFY_ID_TOMORROW,
        title: '明天到期',
        content: buildLines(tomorrowAll)
      };
      items.push(tomorrow);
    }
    return items;
  }
  // 该念哪些条目按「原定时刻」算，不是按补推后的时刻：这条提醒的语义是
  // 「11:30 那一刻还没做完的事」，晚发十几分钟不该因此少念几条
  const pending: EntryItem[] = pendingForReminder(todayAll, plannedTs);
  if (pending.length === 0) {
    // 全勾完了不排（不推空通知）
    return items;
  }
  const noonOrEvening: NotifyItem = {
    notificationId: index === 1 ? NOTIFY_ID_NOON : NOTIFY_ID_EVENING,
    title: `还有 ${pending.length} 件事没完成`,
    content: buildLines(pending)
  };
  items.push(noonOrEvening);
  return items;
}

/**
 * 读设置里的提醒时间并解析成时分。
 * 没设置过用默认值（不能因为用户没进过设置页就静默没有提醒）；
 * 设置过但格式坏了才放弃这一条，记日志方便排查。
 */
async function loadNotifyTime(db: DbHelper, key: SettingsKey, fallback: string): Promise<ParsedTime | undefined> {
  const stored: string | undefined = await db.getSetting(key);
  const raw: string = stored !== undefined && stored.length > 0 ? stored : fallback;
  const time: ParsedTime | undefined = parseHHmm(raw);
  if (time === undefined) {
    hilog.warn(DOMAIN, TAG, `提醒时间格式不合法(${key}=${raw})，本条提醒不排`);
  }
  return time;
}

/** 解析 "HH:mm"，格式不对或超出范围返回 undefined（宁可这一条不排，也不能排错时刻） */
function parseHHmm(value: string): ParsedTime | undefined {
  const parts: string[] = value.split(':');
  if (parts.length !== 2 || parts[0].length === 0 || parts[1].length === 0) {
    return undefined;
  }
  const hour: number = Number.parseInt(parts[0], 10);
  const minute: number = Number.parseInt(parts[1], 10);
  if (Number.isNaN(hour) || Number.isNaN(minute)) {
    return undefined;
  }
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
    return undefined;
  }
  const time: ParsedTime = { hour: hour, minute: minute };
  return time;
}

/**
 * 某天 0 点 + 时分 → 那一天的该时刻毫秒时间戳。
 * 导出给 ReminderService 排「未来几天的兜底提醒」用，省得它把时分换算再写一遍。
 */
export function fireTimestampOf(dayStart: number, time: ParsedTime): number {
  return dayStart + time.hour * 60 * 60 * 1000 + time.minute * 60 * 1000;
}

/**
 * 把课表条目挪到列表末尾（非课表在前）。
 * groupRecent 已把非课表按 sortOrder / createdAt 排好、课表保持相对顺序，
 * 这里只做「前后对调」，两类各自的顺序不动。
 */
function putTimetableLast(items: EntryItem[]): EntryItem[] {
  const normal: EntryItem[] = [];
  const timetable: EntryItem[] = [];
  for (const item of items) {
    if (item.source === 'timetable') {
      timetable.push(item);
    } else {
      normal.push(item);
    }
  }
  return normal.concat(timetable);
}

/**
 * 过滤出中下午提醒该念的条目：非课表、且到触发那一刻截止时刻还没过去。
 * 课表不参与：早上汇总里有就够了，中午再推「你还有节课没勾」没有意义；
 * 截止时刻已过的不参与：错过了不再推人，列表里会标逾期。
 */
function pendingForReminder(todayAll: EntryItem[], fireTs: number): EntryItem[] {
  const pending: EntryItem[] = [];
  for (const item of todayAll) {
    if (item.source === 'timetable') {
      continue;
    }
    // 注意跟 fireTs 比、不是跟 now 比：发布发生在现在，念的是触发那一刻的情况，
    // 截止时刻夹在两者之间的条目到点必然已经逾期，提前把它摘掉
    if (item.dueTime !== null && item.dueTime < fireTs) {
      continue;
    }
    pending.push(item);
  }
  return pending;
}

/** 把条目列成通知正文：一行一个标题，用换行分隔 */
function buildLines(items: EntryItem[]): string {
  const lines: string[] = [];
  for (const item of items) {
    // 标题复用「近期」卡片的展示规则：标题空就用正文兜底，两个都空有占位文案。
    // 只取标题，所以直接调 displayTitle 而不是 toRecentCard——后者要 now 算逾期天数，
    // 提醒正文念「逾期 3 天」没有意义
    lines.push(displayTitle(item));
  }
  return lines.join('\n');
}
