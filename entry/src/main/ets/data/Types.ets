/**
 * 文件路径：entry/src/main/ets/data/Types.ets
 * 用途：本地 relationalStore 数据库的四张表（条目 / 课表规则 / 课表例外 / 设置）
 *       的字段类型定义，与 docs/规格.md「三、数据模型」一一对应。
 *       类型只在本文件声明一次，其余页面一律 import，禁止重复定义。
 */

/** 条目来源：手写 / 由课表展开 / 由长期任务到期生成。用来源字段区分行为（如课表条目过点即删），不再另建表 */
export type EntrySource = 'manual' | 'timetable' | 'longterm';

/** 课表的按周重复方式：每周 / 单周 / 双周 */
export type WeekRepeatMode = 'every' | 'odd' | 'even';

/** 课表例外类型：这一天不上课 / 这一天改上星期 X 的课 */
export type ExceptionType = 'noClass' | 'useWeekday';

/** 表 1：entry（条目）。今天 / 明天 / 过期 / 随手记 / 长期全在这一张表，靠日期字段区分，不靠类型字段 */
export interface EntryItem {
  /** 唯一编号（uuid），三端同步时靠它认同一条数据 */
  id: string;
  /** 标题，允许空字符串（随手记常常只写正文） */
  title: string;
  /** 正文，允许空字符串 */
  body: string;
  /** 哪一天（当天 0 点的毫秒时间戳）。随手记为 null，有值才进「近期」的日期分段 */
  date: number | null;
  /** 截止时刻（毫秒时间戳）。没有就为 null；一过这个时刻立刻掉进「过期」 */
  dueTime: number | null;
  /** 长期任务的开始日。填了甘特画横条，不填只画一个点 */
  startDate: number | null;
  /** 是否勾掉 */
  done: boolean;
  /** 勾掉的时刻，未勾为 null */
  doneAt: number | null;
  /** 来源，决定条目的流转行为 */
  source: EntrySource;
  /** 来自课表哪一格 / 哪条长期任务的引用，手写条目为 null */
  sourceRef: string | null;
  /** 拖动排序用，越大越靠后 */
  sortOrder: number;
  /**
   * 甘特上的排列位置。跟 sortOrder 是两套：
   * sortOrder 管「今天 / 随手记」列表里的顺序，ganttOrder 只管甘特从上到下的顺序。
   * 用户在甘特上拖条时只改这个，列表顺序一个字不动。
   * null = 从没在甘特上拖过 —— 甘特排序时退回用 sortOrder 顶替，
   * 所以升级前的老数据（全是 null）顺序不会变。
   */
  ganttOrder: number | null;
  /** 软删除标记，回收站靠它，物理上不删行 */
  deleted: boolean;
  /** 创建时刻（毫秒时间戳） */
  createdAt: number;
  /** 最后修改时刻（毫秒时间戳）。三端冲突判定只比这个字段，留最近一次修改 */
  updatedAt: number;
}

/** 表 2：timetable（课表规则）。课表是「规则」不是「条目」，按周次展开成某一天的具体课 */
export interface TimetableRule {
  /** 唯一编号（uuid） */
  id: string;
  /** 星期几，1=周一 … 7=周日 */
  weekday: number;
  /** 第几节开始 */
  periodFrom: number;
  /** 第几节结束，连堂就是 1→2，展开时算一条不拆 */
  periodTo: number;
  /** 课名 */
  name: string;
  /** 教室，允许空字符串 */
  location: string;
  /** 按周重复方式：every（每周）/ odd（单周）/ even（双周） */
  weeks: WeekRepeatMode;
  /** 起始周 */
  weekFrom: number;
  /** 结束周 */
  weekTo: number;
  /** 上课时间，如 "08:00"。卡片上就显示这个，不另存时间戳 */
  timeStart: string;
}

/** 表 3：timetableException（课表例外，调休用）。用户手动标「这天不上课」或「这天改上星期 X 的课」 */
export interface TimetableException {
  /** 唯一编号（uuid） */
  id: string;
  /** 哪一天（当天 0 点的毫秒时间戳） */
  date: number;
  /** 例外类型：noClass（这天不上课）/ useWeekday（改上星期 X 的课） */
  type: ExceptionType;
  /** 仅 type = useWeekday 时用，表示改上星期几（1=周一 … 7=周日），其余情况为 null */
  weekday: number | null;
}

/** 表 4：settings 的合法 key，收窄成字面量联合，防止读写拼错键名 */
export type SettingsKey =
  'semesterStart' | 'firstWeekIsOdd' | 'notifyTime1' | 'notifyTime2' | 'notifyTime3';

/**
 * 表 4 里「程序内部记账」用的 key。与 SettingsKey 分开是因为用途不同：
 * 上面那批是用户能在设置页看见、改动的，下面这批是代码自己读写的状态，
 * 不该出现在设置页里，也不该被用户改。两者共用 settings 表存，只是语义分开。
 */
export type RuntimeKey =
  /**
   * 后台代理提醒这条投递路径在这台设备上能不能用："1" 能用 / "0" 不能用。
   * 真机对代理提醒有管控，未开通权限的应用额度为 0，publish 一律失败；
   * 实测结论由 ReminderService 每次重排时写回，LocalNotifier 读它决定要不要自己顶上。
   */
  'reminderQuota' |
  /**
   * 三个提醒槽位各自「今天已经发过了」的日期（当天 0 点时间戳的字符串形式）。
   * 卡片每 30 分钟醒一次，同一个槽位的窗口会横跨两次唤醒，没有它就会重复发。
   */
  'notifySent1' | 'notifySent2' | 'notifySent3' |
  /**
   * App 刚推过卡片的时刻（毫秒时间戳的字符串形式）。App 每次改完数据要通知卡片
   * 重刷时先把它写进 settings；卡片进程读到这个记号还很新，就知道这次唤醒是
   * App 主动推的、不是系统例行唤醒——那种时候人正看着屏幕，不该补推提醒
   * （见 ReminderService 的 wokenByApp）。
   */
  'appPushTs';

/** 表 4：settings（设置，键值对）。value 统一按字符串存，读出来再转对应类型 */
export interface SettingItem {
  /** 设置键，含义见 SettingsKey */
  key: SettingsKey;
  /**
   * 设置值（字符串）：
   * semesterStart —— 本学期第一天（毫秒时间戳），学期周次全靠它算，是设置项不写死在代码里；
   * firstWeekIsOdd —— 第 1 周算不算单周，"1" / "0"；
   * notifyTime1 / 2 / 3 —— 每天三次提醒的时间，默认 "06:30" / "11:30" / "16:05"
   */
  value: string;
}
