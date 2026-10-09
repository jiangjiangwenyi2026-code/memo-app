/**
 * 文件路径：entry/src/main/ets/pages/Index.ets
 * 用途：主页。版式沿用已验收的骨架（上半「近期 / 随手记」两列、下半时间轴甘特），
 *       但数据全部换成 DbHelper 里的真实内容：页面加载时读库，勾选 / 新建后写库再刷新。
 *       职责纪律：数据库调用只出现在生命周期 / 点击回调里，build() 只做渲染；
 *       条目怎么变成界面数据（标题、时间文案、甘特条）全在 viewmodel/EntryDisplay.ets。
 * 新建入口：全 App 四个「+」（近期·今天 / 近期·明天 / 随手记 / 时间轴）共用
 *       components/NewEntryDialog 一个弹窗，保存统一走本页的 saveEntry 一个方法。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { emitter } from '@kit.BasicServicesKit';
import { DbHelper, SYNC_DONE_EVENT } from '../data/DbHelper';
import { EntryItem } from '../data/Types';
import { newId, rollover } from '../logic/DailyRollover';
import { groupRecent } from '../logic/SectionLogic';
import { planGanttReorder, planReorder } from '../logic/DragReorder';
import { rescheduleReminders } from '../logic/ReminderService';
import { sendDueNotifications } from '../logic/LocalNotifier';
import { pushCard } from '../logic/CardPush';
import { NewEntryDialog } from '../components/NewEntryDialog';
import {
  GanttBarData,
  GanttBeyondData,
  GANTT_DAYS,
  GANTT_MAX_SPAN_DAYS,
  GANTT_MIN_SPAN_DAYS,
  GANTT_PAST_DAYS,
  GANTT_SPAN_STEP_DAYS,
  ganttBeyond,
  ganttScaleStart,
  nextClassOf,
  NextClassData,
  NoteCardData,
  RecentCardData,
  TITLE_LOCATION_SEP,
  DAY_MS,
  displayTitle,
  sortForGantt,
  startOfDay,
  toGanttBar,
  toNoteCard,
  toRecentCard
} from '../viewmodel/EntryDisplay';

/** 「近期」里的一段：段名（今天 / 明天 / 过期）+ 该段的卡片列表 */
interface RecentSectionData {
  /** 分隔小标题文字 */
  label: string;
  /**
   * 段标题行「+」入口预填的日期（0 点时间戳）；null = 这一段不给「+」。
   * 今天 / 明天段各预填对应日期，过期段刻意不给入口：过期的事补录没有意义。
   */
  addDate: number | null;
  /** 段内卡片 */
  cards: RecentCardData[];
}

/**
 * 「下一节」那一行的 @Builder 参数壳。
 *
 * 为什么非得包一层对象：ArkUI 的 @Builder 收「值」时参数变了不重绘，只有收
 * 「对象字面量」才是按引用传递、才会跟着状态刷新。而这一块的外层 if 条件
 * （有下一节 → 还有下一节）压根不会翻转、分支本身也不重建，两头都指望不上——
 * 实测就是这个后果：勾掉第一节课之后，列表当场少了一条，这行字还写着原来那节。
 */
interface NextClassParam {
  /** 要显示的那一节 */
  next: NextClassData;
}

/** 甘特条在条容器里的纵向位置，用来把「拖到第几行」换算成落点 */
interface BarTop {
  id: string;
  top: number;
}

/**
 * 甘特条左侧勾选框占掉的宽度（vp）= 圆点 18 + 内边距 4×2 + 行间距 8。
 * 日期刻度行必须让出同样的宽度（见刻度行的 padding），否则刻度和横条会整体错开一格。
 * 改这个数就得同步改刻度行，两处必须一致。
 */
const GANTT_CHECK_W: number = 34;

/**
 * 平移时允许「今天」滑出视野的天数（vp 无关，单位是天）。
 * 设成 0 就是「今天必须永远留在窗口内」，那样往未来最多只能拖 GANTT_PAST_DAYS 天，
 * 手指划出去半屏画面纹丝不动，看着像卡住了——这正是原来那个毛病。
 * 留一点余量：今天滑出去之后刻度上不再画今天竖线（见 ganttTodayLine），
 * 再往回拖一点它就回来了。拖得更远也没意义——那是「想一次看更多天」，交给捏合缩小跨度。
 */
const GANTT_OVERSCROLL_DAYS: number = 7;

/**
 * 「今天」标记：一条细竖线 + 顶上的小圆点（合起来像个棒棒糖）。
 * 颜色用 text_secondary 那种冷灰而不是 accent —— accent 是饱和的蓝，
 * 压在橙 / 青横条上像被人划了一刀，配色一下就脏了；灰线读起来是条"辅助线"，
 * 不跟横条抢视线，但眼睛一瞥就能拿它当参照。
 * 竖线只画横条那一段（高度实测，见 ganttBarsH），不往下面的空白里拖——
 * 拖下去就成了一条莫名其妙贯穿整屏的线。
 */
const GANTT_TODAY_LINE_W: number = 1.5;
const GANTT_TODAY_LINE_OPACITY: number = 0.4;

/** 日期刻度的分格天数：一周一格。跨度和捏合的步长都是它的倍数，格线和横条才对得齐 */
const GANTT_TICK_DAYS: number = 7;
/** 刻度行高度（vp）。写成固定值是因为格子改用绝对定位了，得有东西把行高撑住 */
const GANTT_TICK_H: number = 18;

/**
 * 「近期」卡片宽到多少 vp，就把时间和标题并成一行（见 recentCard / isWideCard）。
 * 300 是量出来的：卡片内边距 12×2 + 勾选框 26 + 间距 8 + 时间文案约 40，
 * 剩下的才轮到标题——300 时标题还有 210 出头，13 个字的课名放得下。
 * 实测平板这张卡约 534，手机约 150，两边离阈值都很远，不用担心卡在边界上抖。
 */
const RECENT_ONE_LINE_MIN_W: number = 300;
/** 顶上圆点的直径（vp） */
const GANTT_TODAY_DOT_SIZE: number = 7;
/** 圆点中心离横条区上沿的距离（vp）：正好落在刻度行和横条之间那道空隙里 */
const GANTT_TODAY_DOT_GAP: number = 8;

/**
 * 单日事项在甘特上那个圆点的直径（vp）。
 * 用固定尺寸而不是按天数算宽度：一天在刻度里占多宽随跨度和屏幕变，
 * 按百分比画出来的点小得看不见（28 天刻度下一天只占屏幕的 3.6%，
 * 原先是 0.35 天 ≈ 1.25%，约 4 个像素），而且捏合缩放时点还会忽大忽小。
 */
const GANTT_POINT_SIZE: number = 10;

/**
 * 甘特条的 ForEach key：**光用条目 id 是不够的**，必须把会变的东西一起编进去。
 * 只用 id 的话，平移时间轴、捏合改跨度之后 id 都没变，ArkUI 判定这一项
 * 还是原来那个，直接复用旧组件、连里面的属性都不重算——于是刻度行跟着挪了、
 * 横条却钉在原地（刻度行的 key 带着格子里那串日期，天然会变，所以它反而是对的）。
 * 颜色由 id 决定、不随这些变，不进 key；位置、标题、截断状态都要进：
 * 任何一样变了就得重建这一行。
 */
function barKey(bar: GanttBarData): string {
  return `${bar.id}_${bar.startDay}_${bar.endDay}_${bar.clipped ? 1 : 0}_${bar.restDays}_${bar.title}`;
}

/**
 * 甘特条 / 圆点上的文案：被刻度右端截断的补一句倒计时，
 * 其余就是条目标题。横条和圆点两处共用这一段，免得以后改口径只改了一处。
 * 倒计时那句话（「剩 6 个周末」之类）在 toGanttBar 里就算好了（restLabel）：
 * 按距离换单位要用到截止日，那是数据层才知道的事，界面这一层只负责拼上去。
 */
function barLabel(bar: GanttBarData): string {
  if (bar.clipped) {
    return `${bar.title} · ${bar.restLabel}`;
  }
  return bar.title;
}

/**
 * 宽屏（平板）的标题整串：课表条目的教室在数据层被切出去了（见 toRecentCard），
 * 平板一行排得下，在这儿拼回来——不然平板上教室就凭空没了。
 */
function cardTitleFull(card: RecentCardData): string {
  return card.location.length > 0
    ? `${card.title}${TITLE_LOCATION_SEP}${card.location}`
    : card.title;
}

/**
 * 窄屏（手机）卡片的第二行：「08:00 · 南129」，时间 + 教室。
 * 教室原本跟着课程名挤在同一行，手机上这一列才 150 来 vp，
 * 挤下来就是「高等数学A · …」——教室被省略号吃掉。挪到这一行来两个都看得见。
 * 非课表条目没有教室，这里就是时间本身（「截止 18:00」「逾期 3 天」原样）。
 */
function cardSubLine(card: RecentCardData): string {
  const parts: string[] = [];
  if (card.timeText !== null) {
    parts.push(card.timeText);
  }
  if (card.location.length > 0) {
    parts.push(card.location);
  }
  return parts.join(TITLE_LOCATION_SEP);
}

/**
 * 课程配色档位 → 卡片底色 / 文字色（course_0..3）。
 * 一门课一个色，取自华为课表那种「同色块成片、一眼分得出几门课」的做法；
 * 底色是极浅的同色系，字是深一档的同色系，对比度够但不会花。
 * 档位在数据层按课程名算好（EntryDisplay 的 tintOf）。
 */
function courseBg(tint: number): Resource {
  if (tint === 0) {
    return $r('app.color.course_0_bg');
  }
  if (tint === 1) {
    return $r('app.color.course_1_bg');
  }
  if (tint === 2) {
    return $r('app.color.course_2_bg');
  }
  if (tint === 3) {
    return $r('app.color.course_3_bg');
  }
  if (tint === 4) {
    return $r('app.color.course_4_bg');
  }
  return $r('app.color.course_5_bg');
}

function courseFg(tint: number): Resource {
  if (tint === 0) {
    return $r('app.color.course_0_fg');
  }
  if (tint === 1) {
    return $r('app.color.course_1_fg');
  }
  if (tint === 2) {
    return $r('app.color.course_2_fg');
  }
  if (tint === 3) {
    return $r('app.color.course_3_fg');
  }
  if (tint === 4) {
    return $r('app.color.course_4_fg');
  }
  return $r('app.color.course_5_fg');
}

/**
 * 甘特条配色档位 → 底色（半透明淡彩）/ 文字色（深一档的同色）。
 * 与课程卡片同一套路数：不糊一块死色，而是「淡淡的彩色 + 同色的字」，
 * 所以条看起来是通透的而不是贴上去的一块。
 * 文字**不能用白色**：底色一旦半透明，白字压在浅色背景上就糊了；
 * 浅色主题配深色字、深色主题配亮色字，两套都在 color.json 里，跟着主题自动切。
 */
function barBg(tint: number): Resource {
  if (tint === 0) {
    return $r('app.color.bar_0_bg');
  }
  if (tint === 1) {
    return $r('app.color.bar_1_bg');
  }
  if (tint === 2) {
    return $r('app.color.bar_2_bg');
  }
  if (tint === 3) {
    return $r('app.color.bar_3_bg');
  }
  if (tint === 4) {
    return $r('app.color.bar_4_bg');
  }
  return $r('app.color.bar_5_bg');
}

function barFg(tint: number): Resource {
  if (tint === 0) {
    return $r('app.color.bar_0_fg');
  }
  if (tint === 1) {
    return $r('app.color.bar_1_fg');
  }
  if (tint === 2) {
    return $r('app.color.bar_2_fg');
  }
  if (tint === 3) {
    return $r('app.color.bar_3_fg');
  }
  if (tint === 4) {
    return $r('app.color.bar_4_fg');
  }
  return $r('app.color.bar_5_fg');
}

/**
 * 日期的中文展示（如「2026年12月12日」）：「远期安排」浮层里条目的日期用，
 * 格式与新建 / 编辑弹窗日期行（NewEntryDialog.dateText）保持一致。
 */
function formatChineseDate(ts: number): string {
  const d: Date = new Date(ts);
  return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`;
}

/**
 * 甘特顶部的一个刻度格：一周一格，标这一周第一天的日期（如「9/25」）。
 *
 * x 是在刻度区里的位置（vp），**随平移连续变化**——这是关键：
 * 上一版把刻度写成 `Row + layoutWeight(1)`，格子被等分钉死在屏幕上，
 * 拖的时候横条在滑、日期却一动不动，只在跨过格边界的那一下突然全换成新日期，
 * 看起来就是「一跳一跳的突变」。现在格子锚在具体日期上，跟横条一起滑。
 *
 * key 里必须带上 x（不能只用 k）：ArkUI 的 ForEach 见到 key 没变就整项复用、
 * 连组件属性都不重算（同一个坑见上面 barKey 的注释），key 里不带位置的话
 * 格子又会钉回原地。
 */
interface GanttTick {
  key: string;
  label: string;
  /** 格子左沿在刻度区里的位置（vp，不含左侧勾选框那一段） */
  x: number;
  /** 格子宽度 = 一周 */
  w: number;
}

@Entry
@Component
struct Index {
  /** 数据库句柄：aboutToAppear 里初始化一次，之后只读 */
  private db: DbHelper | undefined = undefined;

  /** 首次读库是否完成：没加载完不显示空状态，避免闪一句误导性的提示 */
  @State loaded: boolean = false;

  /** 读库失败过：空状态改说「没读出来」并给一个重试入口，免得用户以为东西丢了 */
  @State loadFailed: boolean = false;

  /** 「近期」三段的展示数据（SectionLogic.groupRecent 的结果转换而来） */
  @State sections: RecentSectionData[] = [];

  /**
   * 「下一节」提示行：今天还没上的最近一节课；null = 今天没课或都上完了，整行不画。
   * 在 refresh 里跟着 sections 一起算（口径见 nextClassOf）。
   */
  @State nextClass: NextClassData | null = null;

  /** 「随手记」列：date 为 null 且未删除、未勾掉的条目 */
  @State notes: NoteCardData[] = [];

  /** 甘特横条：未勾掉且有日期的条目 */
  @State ganttBars: GanttBarData[] = [];

  /** 甘特顶部日期刻度 */
  /** 甘特顶部刻度格（一周一格）。x 随平移连续变化，所以整行刻度跟着横条一起滑 */
  @State ganttTicks: GanttTick[] = [];

  /** 甘特下方那行灰字：刻度之外还有几项安排、最近的一项还有几天 */
  @State ganttBeyondText: string = '';

  /** 排到刻度之外的条目本体（ganttBeyond 返回，按开始时间从近到远）：「远期安排」浮层的内容 */
  @State ganttBeyondItems: EntryItem[] = [];

  /** 「远期安排」浮层是否可见：点甘特下方那行灰字打开，点遮罩或某一行关闭 */
  @State beyondSheetVisible: boolean = false;

  /** 刻度区实测宽度换算出的「一格多少 vp」：拖动时把手指位移换算成天数全靠它 */
  @State ganttDayPx: number = 0;

  /**
   * 「今天」竖线在刻度区里的横向位置（vp，不含左侧勾选框那一段）。
   * 负数 = 今天不在视野内，不画。
   * 它和横条用同一套换算（天数差 × ganttDayPx），所以平移 / 捏合时相对横条永远钉死，
   * 这就是替掉原来那个每 7 天才跳一次的「本周」标签的东西。
   */
  @State ganttTodayX: number = -1;

  /**
   * 横条区在时间轴里的纵向位置与高度（vp，相对刻度行那一层）。
   * 「今天」竖线只画横条这一段的长度就是靠它——写死高度不行，横条数量是变的。
   */
  @State ganttBarsTop: number = 0;
  @State ganttBarsH: number = 0;

  /** 「近期」卡片实测宽度（vp，由 recentCard 的 onAreaChange 填），决定条目排一行还是两行 */
  @State recentCardW: number = 0;

  /**
   * 甘特当前可见天数（缩放级别）：7 的倍数，捏合在
   * [GANTT_MIN_SPAN_DAYS, GANTT_MAX_SPAN_DAYS] 之间一档一档地调。
   * 刻意不跨启动保留：甘特的价值是「一眼看到离今天还剩多少天」，
   * 隔天打开时昨天存的偏移量已经指错地方，不如每次都回到默认窗口。
   */
  @State ganttSpanDays: number = GANTT_DAYS;

  /** 甘特平移：视图起始日相对默认起点（ganttScaleStart）偏移的天数，正数 = 往未来看 */
  @State ganttOffsetDays: number = 0;

  /** 正在被拖动的甘特条 id；空串 = 没有拖动 */
  @State draggingBarId: string = '';

  /** 条上拖拽的方向：'' 还没定 / 'pan' 左右拖 = 平移视野 / 'reorder' 上下拖 = 调顺序 */
  @State barDragMode: string = '';
  /** 上下拖排序中：这条要落到的目标行号（this.ganttBars 的下标），-1 = 还没定 */
  @State dragBarRow: number = -1;
  /** 上下拖排序中：条相对原位要往下挪多少 vp（纯视觉反馈，不落库） */
  @State dragBarDy: number = 0;
  /** 每根条在甘特条容器里的纵向位置（vp），由条上的 onAreaChange 填 */
  private barTops: BarTop[] = [];
  /** 一次拖拽开始时按 this.ganttBars 顺序快照的行位置，拖动全程都用它算落点 */
  private dragRowTops: number[] = [];

  /** 新建弹窗是否可见：四个入口共用的一个模态 */
  @State entryDialogVisible: boolean = false;

  /** 正在编辑的条目 id；空串 = 新建态。非空时保存走 updateEntry、按钮区多一个删除 */
  @State entryEditingId: string = '';

  /** 编辑时预填进弹窗的内容 */
  @State entryDialogText: string = '';

/** 编辑长期任务时预填的「从哪天开始准备」；0 = 新建，弹窗自己退回今天 */
@State entryDialogPrepDate: number = 0;

/** 编辑时预填的截止时刻（绝对时间戳）；0 = 没设（新建时一律 0） */
@State entryDialogDueTime: number = 0;

  /** 弹窗预填日期：今天 / 明天入口预填对应日期，随手记入口为 null（无日期），时间轴入口预填刚选的截止日 */
  @State entryDialogDate: number | null = null;

  /** 弹窗开关初值：只有时间轴入口默认打开（时间轴天生是排长期任务的地方），其余入口默认关 */
  @State entryDialogNeedPrep: boolean = false;

  /**
   * 正在被拖动的条目 id；空串 = 没有拖拽进行中。
   * 刻意用普通成员变量而不是 @State：拖拽期间重渲染是多余的风险，
   * 真正需要驱动界面的只有下面那个悬停高亮。
   */
  private draggingId: string = '';

  /**
   * 当前拖拽是不是从甘特横条上拖起来的。
   * 甘特条的拖拽本次只做一件事：拖回「随手记」变回无日期（需求「长期 → 拖回随手记」）。
   * 近期段、时间轴、已完成投放条对条来的拖拽一律不接——拖到别处松手等于取消。
   * 刻意用普通成员而不是 @State：它只影响手势回调里的判断，不需要驱动界面。
   * 每个拖拽源的 onDragStart 都必须给它赋值（卡片 false / 横条 true），
   * 否则上一次被忽略的拖拽留下的旧值会把下一次卡片拖拽的落点也堵死。
   */
  private draggingFromGantt: boolean = false;

  /** 捏合进行中（不驱动界面，普通成员即可）：条上的单指拖拽和视图平移都要在这期间让路 */
  private ganttPinching: boolean = false;

  /** 捏合开始时的跨度：onActionUpdate 里按它和当前 scale 算目标跨度，避免逐帧累计误差 */
  private pinchStartSpan: number = GANTT_DAYS;

  /** 平移手势开始时的 offset：onActionUpdate 里按它加手指增量 */
  private panStartOffset: number = 0;

  /** 平移过程中最近一次的手指累计位移：捏合结束后重新对基准用（见 endPinch） */
  private panLastOffsetX: number = 0;

  /** 刻度行实测宽度（vp）：捏合改跨度时宽度不变、onAreaChange 不会再触发，靠它重算 ganttDayPx */
  private ganttScaleWidth: number = 0;

  /** 最近一次读库得到的未完成条目：平移 / 捏合只在内存里重算甘特，不必每帧回库 */
  private lastUndone: EntryItem[] = [];

  /** 当前拖拽悬停在哪张卡片上（用来高亮落点）；空串 = 没悬停在任何卡片上 */
  @State dropTargetId: string = '';

  /** 拖拽进行中时才显示底部「已完成」投放条；平时完全不出现，不占版面 */
  @State showDoneZone: boolean = false;

  /** 拖拽悬停到投放条上了（用来把它点亮，让人知道松手会落在这儿） */
  @State dropOnDone: boolean = false;

  /**
   * 通知权限没开。这个状态必须露在界面上：权限关着时所有提醒都静默失效
   * （publishReminder 失败、系统不报错、App 也看不出异常），
   * 用户只会得出「没提醒就是没事」的结论——那是这个产品最隐蔽的一种坏法。
   */
  @State notifyOff: boolean = false;

  /**
   * 端云同步跑完时被叫一下，重读数据库。
   *
   * 存成字段而不是普通方法：emitter.off 退订靠的是「同一个函数引用」，
   * 写成普通方法的话，每次读 this.onSyncDone 拿到的都是一个新函数，退不掉，
   * 页面来回进出几趟就会叠上好几份，同步一次刷好几遍。
   */
  private onSyncDone = (): void => {
    this.refresh();
  };

  aboutToAppear(): void {
    // 先订阅、再初始化：同步正是在初始化里发起的，而且可能几秒后就跑完，
    // 顺序反了就漏掉第一次广播 —— 那恰好是新装完、最需要刷新的那一次。
    emitter.on({ eventId: SYNC_DONE_EVENT }, this.onSyncDone);
    this.initAndLoad();
  }

  /** 页面销毁时退订，免得同一个页面实例的回调留在 emitter 里 */
  aboutToDisappear(): void {
    emitter.off(SYNC_DONE_EVENT, this.onSyncDone);
  }

  /**
   * 从子页面返回时重跑一次初始化。Index 只是被别的页面盖住、组件并不销毁，
   * aboutToAppear 不会再触发；而「恢复一条」「加一节课」「改学期第一天」这些
   * 都发生在子页面，不重跑的话主页还停在旧数据上——归档页刚恢复的条目在主页
   * 哪里都不出现，看着像被删掉了。rollover 和 refresh 都是幂等的，重跑无副作用。
   */
  onPageShow(): void {
    this.initAndLoad();
  }

  /**
   * 初始化是否正在进行。首次进入时 aboutToAppear 和 onPageShow 会接连触发，
   * 不挡的话两个异步初始化并发跑：rollover 里「先查后插」的幂等闸门不是原子的，
   * 可能重复生成课表条目或长期派生的待办。onPageShow 的本意只是「从子页面回来重读」。
   */
  private loading: boolean = false;

  /** 初始化数据库并读第一屏数据。失败只记日志不崩溃：界面停留在空状态，下次进页面还能重试 */
  private async initAndLoad(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    try {
      this.db = await DbHelper.getInstance(getContext(this));
      // 每日结算必须先于 refresh：先清掉过期课表、生成今天到期的长期待办和课表条目，
      // 随后这一次全量读库拿到的才是结算后的完整数据，界面不用刷两次
      await rollover(this.db, Date.now());
      await this.refresh();
    } catch (e) {
      hilog.error(0x0000, 'Index', `数据库初始化失败: ${JSON.stringify(e)}`);
    } finally {
      // 失败也要复位：否则一次读库出错就把后面所有 onPageShow 的重试入口永久堵死
      this.loading = false;
    }
  }

  /**
   * 从库里重读全部有效条目，重算三块界面数据。
   * 勾选 / 新建之后都走这一个方法：不做局部增删修补，全量重算最不容易出现
   * 「库里和界面对不上」的问题；本地库一屏数据量很小，性能无压力。
   */
  private async refresh(): Promise<void> {
    const db = this.db;
    if (db === undefined) {
      return;
    }
    // 读库失败就保持上一屏的数据不动（比清空成白屏好），并把失败说出来
    let all: EntryItem[] = [];
    try {
      all = await db.getAllActiveEntries();
    } catch (e) {
      hilog.error(0x0000, 'Index', `读库失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '数据没读出来，请重试' });
      // 不能只 toast 一句就 return：loaded 永远不置位，而三块空状态提示都挂在
      // loaded 上，整个主页是一片白，用户只会当自己确实没记过东西
      this.loadFailed = true;
      this.loaded = true;
      return;
    }
    const now: number = Date.now();
    // 「今天 / 明天」段的新建与拖入落点，用的是真正的今天 0 点。
    // 绝不能拿甘特视图起点顶替：那是刻度起点（含 GANTT_PAST_DAYS 天的「过去」余量，
    // 还可能被平移挪走），用它当日期会把新条目写到 3 天前，一落库就掉进「过期」段。
    const todayStart: number = startOfDay(now);

    // 勾掉的条目从三块列表里全部退场（数据仍在库里，done / doneAt 都有记录）
    const undone: EntryItem[] = all.filter((e: EntryItem): boolean => !e.done);

    // 「近期」三段：分段规则在 SectionLogic，这里只把结果转成展示数据。
    // addDate 顺便决定哪一段给「+」入口：今天 / 明天预填各自日期，过期刻意不给
    const groups = groupRecent(undone, now);
    const sections: RecentSectionData[] = [];
    // 今天 / 明天两段无条件进列表：段头行末的「+」是这两天唯一的快捷添加入口
    // （给不给入口由 addDate 决定，见 sectionHeader）。段里没内容时把整段藏掉，
    // 用户就再也没法一键往今天/明天加事，只能绕去搜索或甘特——而他多半
    // 正是因为「今天想加条事」才点开这个界面的。空段留着，只是卡片列表为空。
    // 「过期」段相反：它只是条只读的提醒，没内容就该消失，也不提供添加。
    sections.push({
      label: '今天',
      addDate: todayStart,
      cards: groups.today.map((e: EntryItem): RecentCardData => toRecentCard(e, now))
    });
    sections.push({
      label: '明天',
      addDate: todayStart + DAY_MS,
      cards: groups.tomorrow.map((e: EntryItem): RecentCardData => toRecentCard(e, now))
    });
    if (groups.overdue.length > 0) {
      sections.push({
        label: '过期',
        addDate: null,
        cards: groups.overdue.map((e: EntryItem): RecentCardData => toRecentCard(e, now))
      });
    }
    this.sections = sections;

    // 「下一节」：今天还没上的最近一节课，没有就是 null（列头下面那一行整行不画）。
    // 只在这里算、不放进 recomputeGantt：平移 / 捏合甘特跟下一节课没关系，
    // 而每次结算（打开 / 勾选 / 新建）都会走 refresh，跟课表条目的生命周期是同一个口径——
    // 上完一节课后这行要等到下次结算才换，和「已过的课下次结算才消失」一致
    this.nextClass = nextClassOf(undone, now);

    // 「随手记」：没有日期的条目
    this.notes = undone
      .filter((e: EntryItem): boolean => e.date === null)
      .map((e: EntryItem): NoteCardData => toNoteCard(e));

    // 甘特重算收进 recomputeGantt：平移 / 捏合之后也要重算，那条路不回库，
    // 所以这里先把未完成条目存进 lastUndone，两边共用同一个方法
    this.lastUndone = undone;
    this.recomputeGantt(now);
    this.loadFailed = false;
    this.loaded = true;

    // 顺手查一次通知权限：关着的话提醒一条都不会响，而且系统不报错、界面也看不出异常。
    // 放在 refresh 里是因为它覆盖「打开 / 勾选 / 新建」三种时机，用户去开完权限回来能自动撤掉提示。
    // 系统服务异常时这个查询也会抛，兜住——权限查不出来不该连累刷新
    try {
      this.notifyOff = !notificationManager.isNotificationEnabledSync();
    } catch (e) {
      hilog.error(0x0000, 'Index', `查询通知权限失败: ${JSON.stringify(e)}`);
      this.notifyOff = false;
    }

    // 提醒重排放 refresh 末尾：refresh 在打开 / 勾选 / 新建之后都会走到，
    // 正好覆盖「每次打开 App」和「每次数据变化」两种时机。提醒内容在 publish
    // 时就写死，不重排的话勾掉的事到点还会再念一遍。
    // 整个重排失败绝不影响页面刷新：提醒是附属能力，不能因为它挂了连界面也不刷
    try {
      // allowCatchup = false：用户主动打开 App 时不补推刚过去的那条——他正在看这些事，
      // 再推一条提醒纯属打扰。补推只留给卡片刷新那条路径（它多半发生在人没看屏幕时）
      await rescheduleReminders(db, now, false);
      // 代理提醒在真机上受管控、可能一条都发不出来，这里让普通通知顶上。
      // 必须紧跟其后：上一步刚写下「代理提醒能不能用」的结论，这一步要读它。
      // 窗口是「计划时刻前 10 分钟到后 30 分钟」，所以用户 6:20 打开 App 时
      // 6:30 那条也会当场发出去——早几分钟，但总好过卡片被删掉后就彻底没提醒
      await sendDueNotifications(db, now);
    } catch (e) {
      hilog.error(0x0000, 'ReminderService', `重排提醒失败: ${JSON.stringify(e)}`);
    }

    // 数据变化后再推一把桌面卡片。放在最后、且不 await：卡片刷新是增强，失败了
    // 最多是「这次没同步上」（系统每 30 分钟还会自己唤起卡片一次），绝不能拖住界面。
    pushCard(this.getUIContext().getHostContext(), this.db);
  }

  /**
   * 点提示时拉起系统的通知授权框，回来再查一次权限、把提示撤掉。
   * 系统策略上用户之前拒绝过就可能不再弹框，那种情况必须给一条明确的出路——
   * 否则这就是个按了没反应的死按钮，用户只能一直对着提示。
   */
  private async enableNotify(): Promise<void> {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    try {
      await notificationManager.requestEnableNotification(ctx as common.UIAbilityContext);
    } catch (e) {
      hilog.error(0x0000, 'Index', `拉起通知授权失败: ${JSON.stringify(e)}`);
    }
    try {
      this.notifyOff = !notificationManager.isNotificationEnabledSync();
    } catch (e) {
      hilog.error(0x0000, 'Index', `查询通知权限失败: ${JSON.stringify(e)}`);
      this.notifyOff = false;
    }
    if (this.notifyOff) {
      this.getUIContext().getPromptAction().showToast({ message: '请到「设置 > 通知」里允许本应用通知' });
    }
  }

  /**
   * 勾掉一条：updateEntry 把 done 置 true、doneAt 置当前时间，然后整页刷新。
   * 为什么不用 softDeleteEntry：软删是「回收站」语义，勾掉是「完成」语义，
   * 回收站还得能找回内容，两者不能混用一个标记。
   */
  private async markDone(id: string): Promise<void> {
    const db = this.db;
    if (db === undefined) {
      return;
    }
    try {
      const item: EntryItem | undefined = await db.getEntryById(id);
      if (item === undefined || item.done) {
        return;
      }
      item.done = true;
      item.doneAt = Date.now();
      item.updatedAt = Date.now();
      await db.updateEntry(item);
      await this.refresh();
    } catch (e) {
      hilog.error(0x0000, 'Index', `勾选失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '没勾上，请重试' });
    }
  }

  /**
   * 拖拽落定：把 srcId 放到目标位置上（换类 + 段内重排一起做完）。
   * dstId 为 null 表示落到目标段末尾；dstDate 为 null 表示落到「随手记」（无日期）。
   * 整个方法自己兜错：拖拽失败最多是这一次没生效，绝不能让页面崩溃。
   */
  private async handleDropOnEntry(srcId: string, dstId: string | null, dstDate: number | null): Promise<void> {
    const db = this.db;
    // 拖到自己身上等于没动，直接收尾
    if (db === undefined || srcId.length === 0 || srcId === dstId) {
      this.clearDragState();
      return;
    }
    try {
      const all: EntryItem[] = await db.getAllActiveEntries();
      const changes: EntryItem[] = planReorder(all, srcId, dstId, dstDate, Date.now());
      for (const item of changes) {
        await db.updateEntry(item);
      }
      if (changes.length > 0) {
        await this.refresh();
      }
    } catch (e) {
      hilog.error(0x0000, 'Index', `拖拽落库失败: ${JSON.stringify(e)}`);
    } finally {
      this.clearDragState();
    }
  }

  /**
   * 拖到底部「已完成」区松手：把这条勾掉。
   * 与勾选框走同一个 markDone，不另写一套完成逻辑——需求里这两种只是入口不同。
   */
  private async handleDropOnDone(): Promise<void> {
    const srcId: string = this.draggingId;
    this.clearDragState();
    const db = this.db;
    if (db === undefined || srcId.length === 0) {
      return;
    }
    try {
      // 和拖拽排序同一道闸：只有手写条目能这么完成。
      // 课表条目由规则生成（过了上课时刻，下一次结算就被清掉），长期任务派生的待办勾掉之后，
      // 甘特上那根原条会跟着变味，都不该从这条路进来。
      const item: EntryItem | undefined = await db.getEntryById(srcId);
      if (item === undefined || item.source !== 'manual') {
        return;
      }
      await this.markDone(srcId);
    } catch (e) {
      hilog.error(0x0000, 'Index', `拖到已完成区失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 拖到甘特区：打开这条的编辑弹窗，由用户决定开不开长期开关、填不填开始日。
   * 开了开关就是长期任务；不开、只留日期，就是普通的带日期条目。
   */
  private async handleDropOnTimeline(srcId: string): Promise<void> {
    // 甘特条拖回甘特区 = 原地取消：改期只剩「点开弹窗」一条路
    const fromGantt: boolean = this.draggingFromGantt;
    this.clearDragState();
    if (srcId.length === 0 || fromGantt) {
      return;
    }
    const db = this.db;
    if (db === undefined) {
      return;
    }
    try {
      const item: EntryItem | undefined = await db.getEntryById(srcId);
      if (item === undefined) {
        return;
      }
      // 本来有日期就预填原日期；随手记拖过来的没日期，预填今天 0 点。
      // 预填值必须在 openEditEntry 里一次设完——弹窗是 if 条件挂载的，
      // visible 置 true 之后再想改就晚了
      const prefillDate: number = item.date !== null ? item.date : startOfDay(Date.now());
      this.openEditEntry(item, prefillDate);
    } catch (e) {
      // 本方法是 async、由 onDrop 直接调用（没有 await），抛出去就是未捕获的
      // Promise rejection——记日志兜底
      hilog.error(0x0000, 'Index', `拖到甘特区打开编辑失败: ${JSON.stringify(e)}`);
    }
  }

  /** 清掉拖拽状态：每次拖拽收尾（成功 / 失败 / 取消）都要走一遍 */
  private clearDragState(): void {
    this.draggingId = '';
    this.draggingFromGantt = false;
    this.dropTargetId = '';
    this.showDoneZone = false;
    this.dropOnDone = false;
  }

  /**
   * 打开新建弹窗：四个入口唯一走的方法，差别只在预填值。
   * 弹窗组件由 build() 里的 if 条件挂载，每次打开都重建一遍，
   * 这里的预填值总能可靠地进到弹窗里（@CustomDialog 二次打开不刷新预填值，所以弃用它）。
   */
  private openEntryDialog(date: number | null, needPrep: boolean): void {
    // 四个新建入口一律清掉编辑态：否则「点甘特条进编辑 → 取消 → 再点 + 新建」
    // 这一次新建会带着上一条的 id 走成编辑，把原条目悄悄改掉
    this.entryEditingId = '';
    this.entryDialogText = '';
    this.entryDialogPrepDate = 0;
    this.entryDialogDueTime = 0;
    this.entryDialogDate = date;
    this.entryDialogNeedPrep = needPrep;
    this.entryDialogVisible = true;
  }

  /**
   * 打开编辑弹窗：和新建共用同一个组件，只是多带 id 和原值。
   * 内容取 body——新建时文本一律存进 body、title 留空（见 saveEntry）。
   * dateOverride 只给「拖到甘特区」这条路用：预填一个具体日期。
   * 不传（点甘特条进编辑）时原样用 item.date，包括 null——那条路的行为不能变。
   */
  private openEditEntry(item: EntryItem, dateOverride?: number): void {
    this.entryEditingId = item.id;
    this.entryDialogText = item.body;
    this.entryDialogDate = dateOverride !== undefined ? dateOverride : item.date;
    this.entryDialogNeedPrep = item.startDate !== null;
    this.entryDialogPrepDate = item.startDate !== null ? item.startDate : 0;
    // 库里 dueTime 是 number | null，弹窗的预填值用 0 表示「没设」，这里做一次转换
    this.entryDialogDueTime = item.dueTime !== null ? item.dueTime : 0;
    this.entryDialogVisible = true;
  }

  /**
   * 点甘特条：手写条目进编辑弹窗；课表条目把人送到课表页。
   * 课表条目改不了也勾不了——它由课表规则每天展开生成，改了当天、明天又被规则覆盖回去，
   * 让人以为改生效了反而是骗人。与其点了没反应，不如直接送到能改的地方。
   */
  private async openGanttBar(bar: GanttBarData): Promise<void> {
    if (!bar.editable) {
      // pushUrl 会抛异常，而本方法是 async、由 onClick 直接调用（没有 await），
      // 抛出去就是一个未捕获的 Promise rejection。跳转失败概率很低，
      // 但真失败时不该把页面带崩——记一条日志就够了
      try {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/TimetablePage' });
      } catch (e) {
        hilog.error(0x0000, 'Index', `跳课表页失败: ${JSON.stringify(e)}`);
      }
      return;
    }
    const db = this.db;
    if (db === undefined) {
      return;
    }
    try {
      const item: EntryItem | undefined = await db.getEntryById(bar.id);
      if (item !== undefined) {
        this.openEditEntry(item);
      }
    } catch (e) {
      hilog.error(0x0000, 'Index', `打开条目失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '打开失败，请重试' });
    }
  }

  /** 记下一根条的纵向位置。onAreaChange 里调，位置变了会再调一次 */
  private recordBarTop(id: string, top: number): void {
    for (const t of this.barTops) {
      if (t.id === id) {
        t.top = top;
        return;
      }
    }
    this.barTops.push({ id: id, top: top });
  }

  /**
   * 拖拽起手时快照一次行位置（按 this.ganttBars 的顺序），拖动全程都用它 ——
   * 拖动中途 ganttBars 重算会让位置漂移，边拖边取就会抖
   */
  private snapshotGanttRows(): void {
    const tops: number[] = [];
    for (const b of this.ganttBars) {
      let y: number = -1;
      for (const t of this.barTops) {
        if (t.id === b.id) {
          y = t.top;
          break;
        }
      }
      tops.push(y);
    }
    this.dragRowTops = tops;
  }

  /**
   * 上下拖排序的跟手：按手指的纵向位移，算出这条要落在第几行。
   * 算法是「把手指位置换算成容器里的 y，找纵坐标离它最近的那一行」——
   * 不用位移除以行高，因为甘特的行高不统一（圆点行和横条行不一样高）
   */
  private updateBarRow(bar: GanttBarData, offsetY: number): void {
    let myIdx: number = -1;
    for (let i = 0; i < this.ganttBars.length; i++) {
      if (this.ganttBars[i].id === bar.id) {
        myIdx = i;
        break;
      }
    }
    if (myIdx < 0 || myIdx >= this.dragRowTops.length) {
      return;
    }
    const myTop: number = this.dragRowTops[myIdx];
    if (myTop < 0) {
      return;
    }
    const targetY: number = myTop + offsetY;
    let best: number = myIdx;
    let bestDist: number = Math.abs(myTop - targetY);
    for (let i = 0; i < this.dragRowTops.length; i++) {
      if (this.dragRowTops[i] < 0) {
        continue;
      }
      const d: number = Math.abs(this.dragRowTops[i] - targetY);
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    this.dragBarRow = best;
    // 条直接挪到目标行的那一格上：看到的就是松手后的样子（吸附到整行，不跟手连续位移）
    this.dragBarDy = this.dragRowTops[best] - myTop;
  }

  /** 清掉条上拖拽的全部状态：每次收尾（提交 / 取消 / 手势被打断）都要走一遍 */
  private resetBarDrag(): void {
    this.draggingBarId = '';
    this.barDragMode = '';
    this.dragBarRow = -1;
    this.dragBarDy = 0;
  }

  /** 上下拖排序落定：把这条挪到目标行那一行的位置，只改甘特自己的顺序、不动任何日期 */
  private async commitBarReorder(bar: GanttBarData): Promise<void> {
    const row: number = this.dragBarRow;
    const dstId: string = row >= 0 && row < this.ganttBars.length ? this.ganttBars[row].id : '';
    this.resetBarDrag();
    // 课表条不给排；落点就是自己 = 没真挪动
    if (!bar.editable || dstId.length === 0 || dstId === bar.id) {
      return;
    }
    const db = this.db;
    if (db === undefined) {
      return;
    }
    // 甘特上这些条目，按当前显示顺序取出来（顺序就是 this.ganttBars 的顺序）
    const ganttItems: EntryItem[] = [];
    for (const b of this.ganttBars) {
      const it: EntryItem | undefined = this.lastUndone.find((e: EntryItem): boolean => e.id === b.id);
      if (it !== undefined) {
        ganttItems.push(it);
      }
    }
    try {
      const changes: EntryItem[] = planGanttReorder(ganttItems, bar.id, dstId, Date.now());
      for (const item of changes) {
        await db.updateEntry(item);
      }
      if (changes.length > 0) {
        await this.refresh();
      }
    } catch (e) {
      hilog.error(0x0000, 'Index', `拖动调序失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '没拖动，请重试' });
    }
  }

  /** 甘特视图起始日（0 点时间戳）= 默认刻度起点 + 平移偏移 */
  private ganttViewStart(now: number): number {
    return ganttScaleStart(now) + this.ganttOffsetDays * DAY_MS;
  }

  /**
   * 平移边界：两边各留 GANTT_OVERSCROLL_DAYS 天余量，今天可以滑出视野。
   * 之所以不把今天钉死在窗口内：那样往未来最多只能拖 GANTT_PAST_DAYS 天，
   * 手指划出去半屏而画面纹丝不动，用起来像卡住——比起「今天跑出视野」，
   * 「拖不动」才是更难受的那个。
   * 今天滑出去之后刻度上不再画今天竖线（ganttTodayX 变负），往回拖一点它就回来。
   */
  private clampGanttOffset(offset: number): number {
    const min: number = GANTT_PAST_DAYS - (this.ganttSpanDays - 1) - GANTT_OVERSCROLL_DAYS;
    const max: number = GANTT_PAST_DAYS + GANTT_OVERSCROLL_DAYS;
    return Math.min(max, Math.max(min, offset));
  }

  /**
   * 「近期」条目排一行还是两行：看**卡片自己**有多宽，不看屏幕。
   * 不拿屏幕宽判是因为「近期」只是页面里的一列——平板上它跟右边并排、只占小半屏，
   * 手机竖屏占满、横过来又变宽，窗口还能随手拖大小；
   * 只有卡片量出来的宽度才真正等于「这行字有多少地方可放」。
   * 宽度由 recentCard 的 onAreaChange 填进来；首帧还没量到时 recentCardW = 0，
   * 判定为窄屏（两行）——反正紧接着的布局就会把它改成实际值。
   */
  private isWideCard(): boolean {
    return this.recentCardW >= RECENT_ONE_LINE_MIN_W;
  }

  /** 用当前跨度重算「一格多少 vp」：捏合改了跨度而刻度行宽度没变，onAreaChange 不会再触发 */
  private syncGanttDayPx(): void {
    this.ganttDayPx = this.ganttScaleWidth > GANTT_CHECK_W
      ? (this.ganttScaleWidth - GANTT_CHECK_W) / this.ganttSpanDays
      : 0;
    // 竖线位置 = 天数差 × 这个值，跟着一起更新，
    // 免得捏合之后线还停在老位置（onAreaChange 那条路也不会再触发一次）
    this.refreshTodayLine();
  }

  /**
   * 重算顶部刻度格。网格锚在 ganttScaleStart 上（不随平移变），所以格线落在**固定日期**上，
   * 平移时整行跟着横条一起滑——这正是「刻度写成一排等分的 Text」做不到的。
   * 可见窗口两端各多算一格：边缘上那半格也得有日期，否则拖到一半就空了。
   * 跨度最大 56 天，所以最多也就七八格，每帧重建一遍不心疼。
   */
  private buildTicks(now: number, viewStart: number): void {
    const ticks: GanttTick[] = [];
    if (this.ganttDayPx > 0) {
      const weekMs: number = GANTT_TICK_DAYS * DAY_MS;
      const anchor: number = ganttScaleStart(now);
      const endMs: number = viewStart + this.ganttSpanDays * DAY_MS;
      const kFirst: number = Math.floor((viewStart - anchor) / weekMs) - 1;
      const kLast: number = Math.ceil((endMs - anchor) / weekMs) + 1;
      for (let k = kFirst; k <= kLast; k++) {
        const startMs: number = anchor + k * weekMs;
        const x: number = (startMs - viewStart) / DAY_MS * this.ganttDayPx;
        const d: Date = new Date(startMs);
        ticks.push({
          key: `${k}_${x.toFixed(2)}`,
          label: `${d.getMonth() + 1}/${d.getDate()}`,
          x: x,
          w: GANTT_TICK_DAYS * this.ganttDayPx
        });
      }
    }
    this.ganttTicks = ticks;
  }

  /**
   * 重算「今天」竖线的横向位置（vp，刻度区内的偏移；负数 = 不画）。
   * 和横条同一套换算：今天和视图起点差几天，就落在一格 vp 的几倍上，
   * 所以平移 / 捏合时这条线相对横条永远钉死——这正是原来「本周」标签做不到的
   * （它挂的是 7 天宽的整格，横条却在按天连续滑动，两者最多差 7 天）。
   * 今天不在当前窗口里时为负，调用方据此不渲染。
   */
  private refreshTodayLine(): void {
    if (this.ganttDayPx <= 0) {
      this.ganttTodayX = -1;
      return;
    }
    const now: number = Date.now();
    const days: number = (startOfDay(now) - this.ganttViewStart(now)) / DAY_MS;
    // 允许正好落在右边界上（days === spanDays 时线在刻度末端，压着最后一格右沿）
    this.ganttTodayX = days >= 0 && days <= this.ganttSpanDays ? days * this.ganttDayPx : -1;
  }

  /**
   * 只重算甘特三样（横条、日期刻度、刻度外提示），不回库。
   * 平移 / 捏合期间随时会走这里，数据已经在内存里（lastUndone），没必要每帧读一次数据库。
   * 已过截止日的仍排到最下面——规格：甘特条到期不消失、不标逾期天数，只是挪到最下面。
   */
  private recomputeGantt(now: number): void {
    const todayStart: number = startOfDay(now);
    const viewStart: number = this.ganttViewStart(now);
    const bars: GanttBarData[] = [];
    const expiredBars: GanttBarData[] = [];
    // 甘特有自己的顺序（ganttOrder，在甘特上上下拖出来的），和列表的 sortOrder 分开。
    // 这里排一次，后面「过期的推到最后」在此基础上做
    const ordered: EntryItem[] = sortForGantt(this.lastUndone);
    for (const e of ordered) {
      const bar: GanttBarData | undefined = toGanttBar(e, viewStart, this.ganttSpanDays, todayStart);
      if (bar === undefined) {
        continue;
      }
      if (e.date !== null && e.date < todayStart) {
        expiredBars.push(bar);
      } else {
        bars.push(bar);
      }
    }
    this.ganttBars = bars.concat(expiredBars);
    this.buildTicks(now, viewStart);
    // 竖线跟着这一帧的视图起点走：平移是每帧都调这里的，线才会跟横条一起滑
    this.refreshTodayLine();
    // 刻度之外的远期安排：不画条，但必须让人知道它们还在。周数跟着当前跨度走
    const beyond: GanttBeyondData = ganttBeyond(this.lastUndone, viewStart, this.ganttSpanDays, now);
    // 条目本体一并存下：灰字点开后的「远期安排」浮层直接拿它渲染
    this.ganttBeyondItems = beyond.items;
    const weeks: number = Math.round(this.ganttSpanDays / GANTT_SPAN_STEP_DAYS);
    this.ganttBeyondText = beyond.count > 0
      ? `${weeks} 周之外还有 ${beyond.count} 项，最近的一项 ${beyond.nearestDays} 天后开始`
      : '';
  }

  /**
   * 捏合缩放：跨度按 7 天一档取整（刻度按周等宽分格，只有 7 的倍数刻度和横条才对得齐），
   * 以窗口中心那天为锚——捏的时候画面中间那几天尽量不动，两侧收拢 / 展开。
   * scale > 1（两指张开）= 放大 = 可见天数变少；scale < 1（两指捏拢）= 缩小 = 看到更多天。
   */
  private applyPinchScale(scale: number): void {
    if (scale <= 0) {
      return;
    }
    let span: number = Math.round(this.pinchStartSpan / scale / GANTT_SPAN_STEP_DAYS) * GANTT_SPAN_STEP_DAYS;
    if (span < GANTT_MIN_SPAN_DAYS) {
      span = GANTT_MIN_SPAN_DAYS;
    }
    if (span > GANTT_MAX_SPAN_DAYS) {
      span = GANTT_MAX_SPAN_DAYS;
    }
    if (span === this.ganttSpanDays) {
      return;
    }
    const center: number = this.ganttOffsetDays + this.ganttSpanDays / 2;
    this.ganttSpanDays = span;
    this.ganttOffsetDays = this.clampGanttOffset(Math.round(center - span / 2));
    this.syncGanttDayPx();
    this.recomputeGantt(Date.now());
  }

  /** 捏合收尾：撤掉「捏合中」标记，清掉可能被第一根手指带起的条拖拽和平移基准 */
  private endPinch(): void {
    this.ganttPinching = false;
    // 捏合结束时第一根手指可能还压在横条上没抬：不清的话，剩下这根手指一动，
    // 那根条会突然接着被拖走。resetBarDrag 把条上拖拽的状态一次收干净，不会误触提交
    this.resetBarDrag();
    // 平移同理：第一根手指的 Pan 手势还活着，把它的基准挪到「当前偏移 + 此刻的手指位置」，
    // 之后的手指位移从零重新起算，视图不会按捏合前的累计位移猛跳一下
    this.panStartOffset = this.ganttOffsetDays
      + (this.ganttDayPx > 0 ? this.panLastOffsetX / this.ganttDayPx : 0);
  }

  /**
   * 时间轴的「+」：先弹系统日期选择器问截止日，选完再打开内容弹窗。
   * 为什么先问日期：时间轴入口的语义是「在甘特上放一根横条」，横条必须有截止端；
   * 开关也默认打开——从时间轴进来十有八九是要排需要提前准备的长期任务，
   * 和近期 / 随手记入口（默认单日事项）刚好互补。
   */
  private openTimelineEntry(): void {
    this.getUIContext().showDatePickerDialog({
      start: new Date(2000, 0, 1),
      end: new Date(2100, 11, 31),
      selected: new Date(),
      onDateAccept: (value: Date) => {
        // 选择器回传的 Date 带系统时间的时分秒，归一化到 0 点再预填
        this.openEntryDialog(startOfDay(value.getTime()), true);
      }
    });
  }

  /**
   * 统一保存：新建（四个入口）和编辑（甘特条点进来）都走这一个方法。
   * - 编辑态（entryEditingId 非空）：取出原条目，只覆盖内容 / 日期 / 开始日 / 截止时刻四个字段。
   *   id、done、doneAt、source、sourceRef、sortOrder、createdAt 一律原样保留——
   *   尤其 done 和 sortOrder：改一次内容不该把「已完成」状态抹掉，也不该让条目跳到列表末尾。
   * - 新建态：字段含义同原来——date 可空（随手记就是无日期）；startDate 只在
   *   「需要提前准备」开关打开时有值（开 = 长期任务，关 = 单日事项）；
   *   source 一律 manual；
   * - dueTime 由弹窗组装好传进来（当天 0 点 + 时分偏移），没设就是 null；
   * - 日期入库前统一归一化到 0 点，和库里「日期存 0 点」的约定保持一致；
   * - 内容统一放 body：随手记常常只写正文，title 留空由展示层兜底。
   */
  private async saveEntry(text: string, date: number | null, startDate: number | null,
    dueTime: number | null): Promise<void> {
    const db = this.db;
    if (db === undefined || text.length === 0) {
      return;
    }
    try {
      const now: number = Date.now();
      const normalizedDate: number | null = date !== null ? startOfDay(date) : null;
      const normalizedStart: number | null = startDate !== null ? startOfDay(startDate) : null;
      // 先把编辑态取走再清空：下面两条分支都要用到这个判断
      const editingId: string = this.entryEditingId;
      this.entryEditingId = '';
      if (editingId.length > 0) {
        const target: EntryItem | undefined = await db.getEntryById(editingId);
        if (target !== undefined) {
          target.body = text;
          target.date = normalizedDate;
          target.startDate = normalizedStart;
          target.dueTime = dueTime;
          target.updatedAt = now;
          await db.updateEntry(target);
        }
        await this.refresh();
        return;
      }
      const item: EntryItem = {
        id: newId(now),
        title: '',
        body: text,
        date: normalizedDate,
        dueTime: dueTime,
        startDate: normalizedStart,
        done: false,
        doneAt: null,
        source: 'manual',
        sourceRef: null,
        sortOrder: now,
        ganttOrder: null,
        deleted: false,
        createdAt: now,
        updatedAt: now
      };
      await db.insertEntry(item);
      await this.refresh();
    } catch (e) {
      hilog.error(0x0000, 'Index', `保存条目失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败，请重试' });
    }
  }

  /**
   * 删除正在编辑的条目：走软删（打 deleted 标记），和回收站语义一致——物理行留着还能找回。
   * 只有手写条目能进编辑弹窗（课表条目点了去课表页），所以这里不必再判 source。
   */
  private async deleteEntry(): Promise<void> {
    const db = this.db;
    if (db === undefined || this.entryEditingId.length === 0) {
      return;
    }
    const id: string = this.entryEditingId;
    // 关弹窗挪进 try：删失败就别关，条目还在，用户能再试一次。
    // entryEditingId 也留到写库成功之后再清：提前清掉的话失败后重试时上面判空
    // 直接 return（点了没反应），改点「保存」又会被 saveEntry 当成新建插一条重复的
    try {
      await db.softDeleteEntry(id);
      this.entryEditingId = '';
      this.entryDialogVisible = false;
      await this.refresh();
    } catch (e) {
      hilog.error(0x0000, 'Index', `删除条目失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '删除失败，请重试' });
    }
  }

  /**
   * 「下一节」提示行：标签 + 上课时刻 + 教室。排在「近期」列里、第一段「今天」上面。
   * 没有下一节课时整行不画（调用处的 if 挡着），不留空档——空着反而让人以为没加载出来。
   * 时刻用正文色加粗、比标签大一号：这一行扫一眼要看的是几点，不是「下一节」三个字。
   *
   * 参数必须包成对象传（见 NextClassParam）：传值的话状态变了它不重绘。
   */
  @Builder
  nextClassLine(param: NextClassParam) {
    Row({ space: 8 }) {
      Text('下一节')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Text(param.next.timeText)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .fontWeight(FontWeight.Medium)
      // 教室没填就只留时刻，不画一个孤零零的分隔点
      if (param.next.location.length > 0) {
        Text(`· ${param.next.location}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          // 时刻不能被挤走，教室太长就自己省略；窄屏上这一列才 150 来 vp
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ top: 12 })
  }

  /**
   * 分隔小标题（今天 / 明天 / 过期）。
   * 沿用已验收样式：小号灰字 + 一根细线断开三段，好找段又不抢卡片的注意力。
   * 今天 / 明天段的行末再放一个「+」：就近新建当天待办，省得为记一条今天的事
   * 还要跑到别处改日期；过期段刻意不给入口（addDate 为 null 不渲染）。
   */
  @Builder
  sectionHeader(section: RecentSectionData) {
    Row() {
      Text(section.label)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      // 细线填满标题右侧的剩余宽度，形成「标签 + 尾线」的分隔样式
      Row()
        .layoutWeight(1)
        .height(1)
        .backgroundColor($r('app.color.border'))
        .margin({ left: 8 })
      if (section.addDate !== null) {
        // 周围垫一圈内边距放大点击热区：13 号字的「+」直接点太容易点偏
        Text('+')
          .fontSize(18)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Medium)
          .padding({ left: 6, right: 2, top: 2, bottom: 2 })
          .onClick(() => {
            this.openEntryDialog(section.addDate, false);
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 圆形勾选框：空心圆 = 未勾，点一下即勾掉（写库 + 刷新后条目退场）。
   * 外层垫一圈内边距把点击热区放大：18 的圆直接点太容易点偏。
   */
  @Builder
  checkCircle(id: string) {
    Column() {
      Column()
        .width(18)
        .height(18)
        .borderRadius(9)
        .border({ width: 1.5, color: $r('app.color.border_strong') })
    }
    .padding(4)
    .onClick(() => {
      this.markDone(id);
    })
  }

  /** 拖拽时跟着手指走的预览卡片：做成本身卡片的缩小版，让用户看得出拖的是哪条 */
  @Builder
  dragCardPreview(title: string) {
    Text(title)
      .fontSize(15)
      .fontColor($r('app.color.text_primary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .borderRadius(12)
      .backgroundColor($r('app.color.bg_card'))
      .width(160)
  }

  /**
   * 「近期」的单条卡片：左边圆形勾选框 + 标题 / 时间文案。
   * 样式沿用已验收的圆角浅底；时间只在有值时才渲染。
   * 勾选框**不论来源一律渲染**，课表条目也有（2026-09-28 用户改的口径，
   * 理由见 toRecentCard 的注释）——原来课表条目是拿一个等宽空列占位、不给勾的。
   *
   * **排布随卡片宽度自适应**（见 isWideCard），两种排法**都是一行标题 + 一行时间封顶**：
   *   窄（手机）——标题一行、时间在下面一行。手机上这一列才 150 来 vp，
   *     标题自己就要折行，再挤个时间进去两头都读不全。
   *   宽（平板）——标题和时间**并成一行**，时间被顶到最右边。
   *     平板一张卡有 500 多 vp，还按两行排的话第一行空掉一大截，
   *     白白多占一行高度，一屏能看见的条目少一半。
   * 高度上刻意抠得紧（上下内边距 9、时间只隔 2）：这几段是每天要看几十遍的列表，
   * 一条省下的十几 vp 乘上四五条，就是一屏能多看见一两件事的区别。
   */
  @Builder
  recentCard(card: RecentCardData, sectionDate: number | null) {
    Row({ space: 8 }) {
      this.checkCircle(card.id)
      Column() {
        Row() {
          Text(this.isWideCard() ? cardTitleFull(card) : card.title)
            // 窄屏（手机）降一号：一列才 150 来 vp，15 号字一行放不下八个字，
            // 多出来的全是省略号，字号小一号反而能多看清一两个字
            .fontSize(this.isWideCard() ? 15 : 14)
            // 课表条目用本门课的颜色，手写条目保持正文色（见 RecentCardData.tint）
            .fontColor(card.tint >= 0 ? courseFg(card.tint) : $r('app.color.text_primary'))
            .fontWeight(card.tint >= 0 ? FontWeight.Medium : FontWeight.Normal)
            // 标题恒占一行：窄屏上原来放到两行、下面再挂一行时间，一块占三行，
            // 今天有三四件事就顶满一屏。有省略号兜底，宁可截断不折行
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.isWideCard() && card.timeText !== null) {
            Text(card.timeText)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .margin({ left: 12 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        if (!this.isWideCard() && cardSubLine(card).length > 0) {
          Text(cardSubLine(card))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Center)
    // 上下收紧、左右不动：左右 12 是文字离卡边的呼吸，压了会显得挤；
    // 上下压到 9 才真正降高度，而且和 18 的勾选圆圈配起来正好齐平
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .borderRadius(12)
    // 悬停高亮：拖到这张卡片上时换个底色，用户才知道会落在哪。
    // 课表条目用本门课的半透明色（一个色块一门课，扫一眼就分得出今天有几门课），
    // 手写条目保持灰底——颜色是给课做分类的，不是装饰
    .backgroundColor(this.dropTargetId === card.id
      ? $r('app.color.bg_drop')
      : (card.tint >= 0 ? courseBg(card.tint) : $r('app.color.bg_subtle')))
    .width('100%')
    // 量一下这张卡自己有多宽，「一行还是两行」就按它定（见 isWideCard）。
    // 每张卡都会触发一次，但值都一样，写完状态没变化就不会重排，不会打转。
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.recentCardW = newValue.width as number;
    })
    .draggable(card.draggable)
    .onDragStart((event: DragEvent): CustomBuilder => {
      this.draggingId = card.id;
      this.draggingFromGantt = false;
      this.showDoneZone = true;
      return () => { this.dragCardPreview(card.title); };
    })
    .onDragEnd(() => {
      // 只收投放条：onDrop 和 onDragEnd 的先后没有保证，
      // 这里绝不能碰 draggingId，否则可能把 onDrop 要用的源 id 抹掉
      this.showDoneZone = false;
      this.dropOnDone = false;
    })
    .onDragEnter(() => {
      // 拖到自己身上不高亮：落点和源同一张时什么都不会发生。
      // 甘特条来的拖拽也不高亮：近期段不接它（本次只做「拖回随手记」），
      // 点亮了再落空反而是骗人
      if (!this.draggingFromGantt && this.draggingId.length > 0 && this.draggingId !== card.id) {
        this.dropTargetId = card.id;
      }
    })
    .onDragLeave(() => {
      if (this.dropTargetId === card.id) {
        this.dropTargetId = '';
      }
    })
    .onDrop(() => {
      // 过期段不收：它的日期不是某一个具体值，拖进去没有合理答案可设。
      // 甘特条也不收：条来的拖拽只有「拖回随手记」一条路
      if (sectionDate === null || this.draggingFromGantt) {
        return;
      }
      this.handleDropOnEntry(this.draggingId, card.id, sectionDate);
    })
  }

  /**
   * 「随手记」的单条卡片：同样给一个勾选框，随手记也能勾掉清场。
   * 版式和「近期」的卡片（见 recentCard）是同一套：同样的圆角 12、同样的上下内边距 9、
   * 同样的字号（宽屏 15 / 窄屏 14）、同样的勾选圆圈 + 文字排布。
   * 两列并排摆着，卡片长得不一样就会显得一列是「正文」、一列是「附件」。
   *
   * 唯一没跟过去的是行数：近期**一行封顶**，随手记最多两行。
   * 近期一条是一件有时有地的摘要（「08:00 高等数学 · 南129」），截了也还看得懂；
   * 随手记是你自己敲进去的原话，截一半就成了残句——这里让它多占一行的余地。
   * 短句本来就只占一行，两列看着还是一样齐。
   */
  @Builder
  noteCard(note: NoteCardData) {
    Row({ space: 8 }) {
      this.checkCircle(note.id)
      Text(note.text)
        .fontSize(this.isWideCard() ? 15 : 14)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Center)
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .borderRadius(12)
    .backgroundColor(this.dropTargetId === note.id ? $r('app.color.bg_drop') : $r('app.color.bg_subtle'))
    .width('100%')
    .draggable(note.draggable)
    .onDragStart((event: DragEvent): CustomBuilder => {
      this.draggingId = note.id;
      this.draggingFromGantt = false;
      this.showDoneZone = true;
      return () => { this.dragCardPreview(note.text); };
    })
    .onDragEnd(() => {
      this.showDoneZone = false;
      this.dropOnDone = false;
    })
    .onDragEnter(() => {
      if (this.draggingId.length > 0 && this.draggingId !== note.id) {
        this.dropTargetId = note.id;
      }
    })
    .onDragLeave(() => {
      if (this.dropTargetId === note.id) {
        this.dropTargetId = '';
      }
    })
    .onDrop(() => {
      // 落进随手记 = 换类成无日期条目
      this.handleDropOnEntry(this.draggingId, note.id, null);
    })
  }

  /** 空状态提示：库里没内容时绝不露出假数据，只给一句灰字 */
  @Builder
  emptyHint(text: string) {
    Column() {
      Text(text)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ top: 24, bottom: 12 })
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 读库失败的兜底提示。刻意和 emptyHint 分开：那个说的是「没有内容」，
   * 这个必须说清「是没读出来」并给一个能点的重试——否则用户对着空白页分不清
   * 是自己没记过还是数据丢了，也没有任何能下手的地方。
   */
  @Builder
  loadFailedHint() {
    Column() {
      Text('数据没读出来')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Text('点这里重试')
        .fontSize(13)
        .fontColor($r('app.color.accent'))
        .margin({ top: 6 })
    }
    .width('100%')
    .padding({ top: 24, bottom: 12 })
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.initAndLoad();
    })
  }

  /**
   * 通知权限没开的提示。刻意做得比空状态显眼（有底色、可点、文案说清后果）：
   * 权限关着时所有提醒都静默失效，用户会得出「没提醒就是没事」的结论，
   * 而界面上完全看不出异常。这条提示是唯一的出口。
   */
  @Builder
  notifyOffHint() {
    Column() {
      Text('提醒没有打开')
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
      Text('点这里开启，否则到期不会提醒')
        .fontSize(12)
        .fontColor($r('app.color.accent'))
        .margin({ top: 4 })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .borderRadius(8)
    .backgroundColor($r('app.color.bg_subtle'))
    .onClick(() => {
      this.enableNotify();
    })
  }

  /**
   * 甘特单根条：左边勾选框（只有手写条目有）+ 右边刻度区里的图形。
   * 勾选框必须占掉一个固定宽度、不能叠在刻度里——刻度区的左右边界要和上面的日期刻度行
   * 一模一样（那边靠 GANTT_CHECK_W 的内边距对齐），叠进去两边就错开了。
   * 刻度区分两种画法，由 bar.isPoint 决定：
   *   有准备期的长期任务 → 一根有长度的横条，名字写在条里（条够宽，放得下）；
   *   单日事项、开始日 = 截止日的长期任务 → 一个圆点，名字写在点外面（见 ganttPoint）。
   */
  @Builder
  ganttBar(bar: GanttBarData) {
    Row({ space: 8 }) {
      if (bar.editable) {
        this.checkCircle(bar.id)
      } else {
        // 课表条目不给勾：它由规则生成，勾了下次展开又回来。
        // 但位置要占住，否则它的横条会比别人的整体左移一格
        Column().width(26)
      }
      Row() {
        if (bar.isPoint) {
          this.ganttPoint(bar)
        } else {
          // 透明占位列：宽度 = 起始天占刻度的比例，负责把横条推到正确的日期位置
          Column()
            .width(`${bar.startDay / this.ganttSpanDays * 100}%`)
          Text(barLabel(bar))
            .fontSize(11)
            .fontColor(barFg(bar.tint))
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .height(22)
            .borderRadius(11)
            .backgroundColor(barBg(bar.tint))
            .width(`${(bar.endDay - bar.startDay) / this.ganttSpanDays * 100}%`)
        }
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)
      // 上下拖排序时整条跟着手指吸附到目标行；左右拖平移走的是整个视图，这里不需要位移
      .translate({ y: this.draggingBarId === bar.id ? this.dragBarDy : 0 })
      .onClick(() => {
        this.openGanttBar(bar);
      })
      .gesture(
        PanGesture({ direction: PanDirection.All, distance: 8 })
          .onActionStart(() => {
            // 课表条目不给拖：它由规则生成，拖了下次展开又回来
            if (!bar.editable) {
              return;
            }
            this.draggingBarId = bar.id;
            this.barDragMode = '';
            this.dragBarRow = -1;
            this.dragBarDy = 0;
            // 左右拖平移要拿它当基准，和拖空白处那个平移是同一套
            this.panStartOffset = this.ganttOffsetDays;
            this.snapshotGanttRows();
          })
          .onActionUpdate((event: GestureEvent) => {
            // 只认自己那根条：别的条收到事件时一律不理
            if (this.draggingBarId !== bar.id || this.ganttDayPx <= 0) {
              return;
            }
            // 多指压上来（多半是双指捏合，其中一根恰好落在这根条上）：那是缩放不是拖条
            const fingerCount: number = event.fingerList === undefined ? 0 : event.fingerList.length;
            if (this.ganttPinching || fingerCount > 1) {
              this.barDragMode = '';
              this.dragBarRow = -1;
              this.dragBarDy = 0;
              return;
            }
            // 方向只定一次：定了之后整段手势都按它走，手指斜着动也不会来回跳
            if (this.barDragMode === '') {
              this.barDragMode = Math.abs(event.offsetX) >= Math.abs(event.offsetY) ? 'pan' : 'reorder';
            }
            if (this.barDragMode === 'pan') {
              // 左右拖 = 挪视野，和拖甘特区空白处完全一样（含"不取整、连续滑"那条，见那边注释）
              const target: number = this.panStartOffset - event.offsetX / this.ganttDayPx;
              const clamped: number = this.clampGanttOffset(target);
              if (clamped !== this.ganttOffsetDays) {
                this.ganttOffsetDays = clamped;
                this.recomputeGantt(Date.now());
              }
            } else {
              this.updateBarRow(bar, event.offsetY);
            }
          })
          .onActionEnd(() => {
            if (this.barDragMode === 'reorder') {
              this.commitBarReorder(bar);
            } else {
              this.resetBarDrag();
            }
          })
          .onActionCancel(() => {
            // 手势被系统打断（多指、下拉通知栏抢占、长按起拖等）时 onActionEnd 不触发
            this.resetBarDrag();
          })
      )
      // 拖回随手记的通路（需求「长期 → 拖回随手记：变回无日期」）。
      // 系统拖拽要长按约 500ms 不动才起手，条上的 PanGesture 8vp 就认领——
      // 条上拖动（左右平移 / 上下调序）先于长按成立，长按起拖时 Pan 已被系统拖拽打断（走上面的 onActionCancel），
      // 两条路天然错开。editable = source === 'manual'：课表条目和长期任务派生的待办不给拖
      .draggable(bar.editable)
      .onDragStart((event: DragEvent): CustomBuilder => {
        // 只标记来源，不亮「已完成」投放条：条来的拖拽只认随手记一个落点
        this.draggingId = bar.id;
        this.draggingFromGantt = true;
        return () => { this.dragCardPreview(bar.title); };
      })
      .onDragEnd(() => {
        // 与卡片同一条纪律：onDrop 和 onDragEnd 的先后没有保证，
        // 这里绝不能碰 draggingId，否则可能把 onDrop 要用的源 id 抹掉
        this.showDoneZone = false;
        this.dropOnDone = false;
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // 记下这条在条容器里的纵向位置，上下拖排序靠它把手指位置换算成「第几行」。
      // 回传的是相对父容器的位置；这里挂的是甘特条最外层 Row，它的父容器
      // 正好是那个 Column({ space: 12 })
      this.recordBarTop(bar.id, newValue.position.y as number);
    })
  }

  /**
   * 单日事项在甘特上的画法：一个圆点钉在日期位置上，名字写在点**外面**。
   * 名字为什么不画在点里：点的宽度只有 0.35 天（28 天刻度下约屏幕的 1.25%，四五个像素），
   * 名字挤进去一个字都显示不出来，屏幕上只剩一个「不知道是什么事」的色块——
   * 而它恰恰是「后天及以后的事」唯一的展示处（「近期」栏只到今天和明天），
   * 信息传不到就等于没画。点外面这一行整条都是空的，写名字不占别人的地方。
   * 名字写在点的右边还是左边，按点的位置定：过了刻度中线就改画左边——
   * 否则右边余下的天数不够，名字照样被挤没。
   */
  @Builder
  ganttPoint(bar: GanttBarData) {
    if (bar.startDay > this.ganttSpanDays / 2) {
      // 点靠右：名字放左边、右对齐贴着点，右边留白撑住点的位置
      Text(barLabel(bar))
        .fontSize(11)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ right: 6 })
      this.ganttDot(bar.tint)
      Column()
        .width(`${(this.ganttSpanDays - bar.startDay) / this.ganttSpanDays * 100}%`)
    } else {
      // 点靠左：左边留白把点推到日期位置上，名字跟在点后面
      Column()
        .width(`${bar.startDay / this.ganttSpanDays * 100}%`)
      this.ganttDot(bar.tint)
      Text(barLabel(bar))
        .fontSize(11)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.Start)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 6 })
    }
  }

  /**
   * 甘特上的单日圆点：颜色按条目取，和横条同一个档位（stableTint）。
   * 点用**实色**那一档（barFg）而不是横条那种半透明底色：点只有 10vp，
   * 淡淡的颜色铺在背景上就找不着了——横条够宽才经得起半透明。
   */
  @Builder
  ganttDot(tint: number) {
    Column()
      .width(GANTT_POINT_SIZE)
      .height(GANTT_POINT_SIZE)
      .borderRadius(GANTT_POINT_SIZE / 2)
      .backgroundColor(barFg(tint))
  }

  /**
   * 拖拽时浮在底部的「已完成」投放条（需求定的第二种完成方式，像扔回收站）。
   * 平时完全不占版面，只在拖拽那一刻出现，松手即消失。
   */
  @Builder
  dropToDoneZone() {
    Row() {
      Text('拖到这儿标记完成')
        .fontSize(13)
        .fontColor(this.dropOnDone ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
    }
    .width('100%')
    .height(48)
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .backgroundColor(this.dropOnDone ? $r('app.color.bg_drop_done') : $r('app.color.bg_subtle'))
    .borderWidth(1)
    .borderColor(this.dropOnDone ? $r('app.color.accent') : $r('app.color.border'))
    .margin({ left: 16, right: 16, bottom: 20 })
    .onDragEnter(() => {
      this.dropOnDone = true;
    })
    .onDragLeave(() => {
      this.dropOnDone = false;
    })
    .onDrop(() => {
      this.dropOnDone = false;
      this.handleDropOnDone();
    })
  }

  /**
   * 「远期安排」浮层的卡片：列出排到刻度之外的所有条目（ganttBeyondItems）。
   * 样式照抄新建 / 编辑弹窗那套——遮罩 + if 条件挂载的圆角卡片，
   * 圆角（16）、底色（bg_card）、内边距（20）与 NewEntryDialog 完全一致。
   * 条目可能有好几条：列表区套 Scroll，内容少时卡片随内容收缩，条数多时封顶滚动。
   */
  @Builder
  beyondSheetCard() {
    Column() {
      Text('远期安排')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 14 })
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.ganttBeyondItems, (item: EntryItem) => {
            Column() {
              Text(displayTitle(item))
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .maxLines(2)
              Text(item.date !== null ? formatChineseDate(item.date) : '')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(12)
            .borderRadius(12)
            .backgroundColor($r('app.color.bg_subtle'))
            .onClick(() => {
              // 先关本浮层、再开编辑弹窗：两个浮层不能同时出现
              this.beyondSheetVisible = false;
              this.openEditEntry(item);
            })
          }, (item: EntryItem): string => item.id)
        }
        .width('100%')
      }
      .width('100%')
      // 条数多时封顶在这里滚动，条数少时随内容收缩
      .constraintSize({ maxHeight: 360 })
      .scrollBar(BarState.Off)
    }
    .padding(20)
    .width('88%')
    .borderRadius(16)
    .backgroundColor($r('app.color.bg_card'))
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    // 根 Stack 居中：主内容铺满，新建弹窗（遮罩 + 卡片）声明在其后、落在屏幕中央；
    // 做法与 TimetablePage 的录入弹窗一致，不再走 @CustomDialog
    Stack({ alignContent: Alignment.Center }) {
      // 主内容：固定整页高度，整页不滚动，滚动只发生在两个分列内部
      Column() {
        // ── 上半部分：左「近期」右「随手记」，两列等宽 ──
        Row() {
          // 左列：近期（今天 / 明天 / 过期 三段）
          Column() {
            Row() {
              Text('近期')
                .fontSize(18)
                .fontColor($r('app.color.text_primary'))
                .fontWeight(FontWeight.Medium)
              // Blank 把两个入口顶到行末：搜索 / 归档都是低频入口，不占版面
              Blank()
              // 搜索是全局的（连已完成和回收站里的一起搜），所以放在列头而不是某一列内部
              Text('搜索')
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .fontWeight(FontWeight.Medium)
                .padding({ left: 8, top: 4, bottom: 4 })
                .onClick(() => {
                  this.getUIContext().getRouter().pushUrl({ url: 'pages/SearchPage' });
                })
              Text('归档')
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .fontWeight(FontWeight.Medium)
                .padding({ left: 8, top: 4, bottom: 4 })
                .onClick(() => {
                  this.getUIContext().getRouter().pushUrl({ url: 'pages/ArchivePage' });
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            // 列内滚动：只有这一小块滚动，整页保持稳定
            Scroll() {
              Column() {
                if (this.loaded && this.loadFailed) {
                  this.loadFailedHint()
                }
                // 读库失败时不叠加权限提示：那时界面本来就是空的，一次说清楚一件事
                if (this.loaded && !this.loadFailed && this.notifyOff) {
                  this.notifyOffHint()
                }
                // 判据是「三段的卡片全空」，不是「列表为空」：今天/明天两段现在恒定存在
                // （见 buildSections 里的说明），列表至少有两个元素，再拿 length === 0
                // 去判就永远不成立，这条空态提示会变成死代码。
                if (this.loaded && !this.loadFailed
                  && this.sections.every((s: RecentSectionData): boolean => s.cards.length === 0)) {
                  this.emptyHint('还没有内容')
                }
                // 「下一节」：今天还有没上的课就顶在这儿——「近期」列头下面、第一段上面。
                // 没有就整个不画，不占地方：空着一条反而像个没加载出来的格子。
                // 放在 Scroll 内部而不是钉在列头下面，是为了让它跟着列表一起滚——
                // 钉住的话「今天」段的标题滚上来会贴着它，像两行标题叠在一起
                if (this.nextClass !== null && !this.loadFailed) {
                  this.nextClassLine({ next: this.nextClass })
                }
                ForEach(this.sections, (section: RecentSectionData, idx: number) => {
                  Column() {
                    this.sectionHeader(section)
                    Column({ space: 8 }) {
                      ForEach(section.cards, (card: RecentCardData) => {
                        this.recentCard(card, section.addDate)
                      }, (card: RecentCardData): string => card.id)
                    }
                    .width('100%')
                    .margin({ top: 8 })
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  // 第一段贴顶，后面的段留出呼吸间距，把三段分开
                  .margin({ top: idx === 0 ? 12 : 20 })
                  .onDrop(() => {
                    // 过期段（addDate 为 null）不收；甘特条也不收（只做「拖回随手记」）
                    if (section.addDate === null || this.draggingFromGantt) {
                      return;
                    }
                    // dstId 传 null：落到这一段的末尾
                    this.handleDropOnEntry(this.draggingId, null, section.addDate);
                  })
                }, (section: RecentSectionData): string => {
                  // key 必须带上段里的卡片，不能只用 section.label：
                  // 「今天 / 明天」两段的 label 恒定不变，空段第一次进卡片时 ArkUI
                  // 判定该项没变化、直接复用旧组件树，内层卡片的 ForEach 不会重建——
                  // 数据已经在 @State 里（空态提示如期消失）、界面上却一张卡片都不出现，
                  // 重启 App 全量重建才恢复。把卡片集合编进 key，内容一变就重建这一段。
                  const fingerprint: string = section.cards
                    .map((c: RecentCardData): string => `${c.id}|${c.title}|${c.timeText}`)
                    .join(',');
                  return `${section.label}#${fingerprint}`;
                })
              }
              .width('100%')
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
          }
          .layoutWeight(1)
          .height('100%')
          .padding({ left: 16, right: 12, top: 16, bottom: 16 })
          .alignItems(HorizontalAlign.Start)

          // 两列之间的竖分隔线：一根细线即可，不做重边框
          Divider()
            .vertical(true)
            .height('100%')
            .color($r('app.color.border'))

          // 右列：随手记 + 右上角新建入口
          Column() {
            Row() {
              Text('随手记')
                .fontSize(18)
                .fontColor($r('app.color.text_primary'))
                .fontWeight(FontWeight.Medium)
              // Blank 把「+」顶到行末：新建是这一列的高频动作，入口放在列头右上角
              Blank()
              Text('+')
                .fontSize(22)
                .fontColor($r('app.color.text_primary'))
                .fontWeight(FontWeight.Medium)
                .onClick(() => {
                  // 随手记入口：日期预填「无日期」、开关默认关（记的就是一条无日期的随想）
                  this.openEntryDialog(null, false);
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            Scroll() {
              Column({ space: 8 }) {
                if (this.loaded && this.notes.length === 0) {
                  this.emptyHint('还没有随手记，点右上角 + 记一条')
                }
                ForEach(this.notes, (note: NoteCardData) => {
                  this.noteCard(note)
                }, (note: NoteCardData): string => note.id)
              }
              .width('100%')
              .onDrop(() => {
                // 落到列的空白处：放到随手记末尾
                this.handleDropOnEntry(this.draggingId, null, null);
              })
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
          }
          .layoutWeight(1)
          .height('100%')
          .padding({ left: 12, right: 16, top: 16, bottom: 16 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')

        // 上下半之间的横分隔线
        Divider()
          .width('100%')
          .color($r('app.color.border'))

        // ── 下半部分：时间轴甘特区 ──
        Column() {
          Row() {
            Text('时间轴')
              .fontSize(18)
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
            // Blank 把「+」「课表」顶到行末：时间轴的「+」先问截止日再开弹窗（见 openTimelineEntry），
            // 样式和右上半区的「+」保持一致的轻量文字按钮感
            Blank()
            Text('+')
              .fontSize(22)
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
              .padding({ left: 8, top: 2, bottom: 2 })
              .onClick(() => {
                this.openTimelineEntry();
              })
            // 热力图：回头看「这一年哪天忙哪天闲」，与甘特同属时间视角，就并排放在这里。
            // 极低频（一周未必点一次），所以用和「课表 / 设置」一样的轻量文字按钮
            Text('热力图')
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
              .padding({ left: 8, top: 4, bottom: 4 })
              .onClick(() => {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/HeatmapPage' });
              })
            // 课表录入是低频入口，放标题行右上角不占版面
            Text('课表')
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
              .padding({ left: 8, top: 4, bottom: 4 })
              .onClick(() => {
                // 跳转走 UIContext 的 router：全局 router.pushUrl 已废弃
                this.getUIContext().getRouter().pushUrl({ url: 'pages/TimetablePage' });
              })
            // 设置同样是低频入口，和课表并排同一风格：不填学期基准课表算不出来，入口必须可达
            Text('设置')
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
              .padding({ left: 8, top: 4, bottom: 4 })
              .onClick(() => {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/SettingsPage' });
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          // 刻度行往下这一整段要和「今天」竖线叠在一起，所以包一层 Stack：
          // 里面照旧纵向排（刻度行 → 横条区 → 远期灰字），竖线浮在上面、不参与布局。
          // 只包刻度行之后的部分：再往上就是标题行（时间轴 / 课表 / 设置），竖线穿过去只是平白压住字。
          Stack({ alignContent: Alignment.TopStart }) {
            Column() {
              // 日期刻度：按周分格，一周一格。
              // 每格用绝对定位、x 由日期算出来，所以平移时整行跟着横条一起滑——
              // 老板把格子写成 Row + layoutWeight，等分之后它们被钉死在屏幕上，
              // 拖起来日期纹丝不动、只在跨过格边界时整排突然换字，就是那个「一跳一跳的突变」。
              // tick.x 是相对刻度区的，渲染时要补上左边让给勾选框的 GANTT_CHECK_W。
              Stack({ alignContent: Alignment.TopStart }) {
                ForEach(this.ganttTicks, (tick: GanttTick) => {
                  Text(tick.label)
                    .fontSize(11)
                    .fontColor($r('app.color.text_secondary'))
                    .width(tick.w)
                    // 左对齐到这一格的**起点**，不用居中：一格是一周，居中会让日期字
                    // 浮在格子正中间——那已经是这一周的第四天了。9/25 起、今天 9/28 时，
                    // 「9/25」正好被推到 9/28 眼皮底下，和「今天」竖线挤在一起，
                    // 看着就像竖线没对准今天（竖线本身是按天数算的，一直是对的）。
                    .textAlign(TextAlign.Start)
                    .position({ x: GANTT_CHECK_W + tick.x, y: 0 })
                }, (tick: GanttTick): string => tick.key)
              }
              .width('100%')
              .height(GANTT_TICK_H)
              // 拖出窗口的那几格直接裁掉，否则会画到勾选框上、甚至盖住左边的「时间轴」
              .clip(true)
              .onAreaChange((oldValue: Area, newValue: Area) => {
                // 刻度区的实际宽度 ÷ 当前跨度 = 一格多少 vp，拖条和平移的手指位移换算全靠它。
                // 用实测宽度而不是写死值：不同机型屏幕宽度不一样。
                // 宽度存进 ganttScaleWidth：捏合改跨度时宽度不变、这里不再触发，由 syncGanttDayPx 重算。
                // 注意这个宽度含左边让给勾选框的那一段，所以要减掉 GANTT_CHECK_W；
                // onAreaChange 回传的 width 在运行时就是 vp 数值，直接当 number 用。
                this.ganttScaleWidth = newValue.width as number;
                this.syncGanttDayPx();
              })
              .margin({ top: 16 })
              // 横条区：几根圆角横条纵向排开，间距留足，保持疏朗
              Column({ space: 12 }) {
                if (this.loaded && this.ganttBars.length === 0) {
                  this.emptyHint('时间轴还没有安排')
                }
                ForEach(this.ganttBars, (bar: GanttBarData) => {
                  this.ganttBar(bar)
                }, (bar: GanttBarData): string => barKey(bar))
              }
              .width('100%')
              .margin({ top: 16 })
              // 量出横条区的位置和高度：「今天」竖线就画这一段，多一分都不画。
              // 写死高度不行——条数、有没有换行的长标题都会让它变
              .onAreaChange((oldValue: Area, newValue: Area) => {
                this.ganttBarsTop = newValue.position.y as number;
                this.ganttBarsH = newValue.height as number;
              })
              // 刻度之外的远期安排：只给一行灰字，不画条——
              // 画进刻度里会被挤到右端，看着像「这就要开始了」，那是误导。
              // 点开可看全部远期条目的浮层（beyondSheetCard），那些条目也就能改了
              if (this.ganttBeyondText.length > 0) {
                Text(this.ganttBeyondText)
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 12 })
                  // 上下垫一点内边距放大点击热区：11 号灰字直接点太容易点偏
                  .padding({ top: 2, bottom: 2 })
                  .onClick(() => {
                    this.beyondSheetVisible = true;
                  })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // 「今天」标记：一条细竖线 + 顶上的小圆点，像根棒棒糖插在横条区里。
            // 横轴换算和横条一模一样（天数差 × ganttDayPx），所以平移 / 捏合时
            // 它相对横条纹丝不动——用户要的就是这个不跟着滑的参照点。
            // 纵向只覆盖横条区（ganttBarsTop / ganttBarsH 是实测的），
            // 不往下面的空白里拖，也不往上盖住刻度行的日期。
            // 今天滑出视野时 ganttTodayX 为负，整组不渲染（见 refreshTodayLine）。
            // hitTestBehavior 必须关掉：它压在横条上面，不关就会吃掉横条的手势
            // （条上的左右拖 / 上下拖全失灵）。
            if (this.ganttTodayX >= 0 && this.ganttBarsH > 0) {
              // 竖线：从小圆点的圆心起、到横条区下沿止
              Column()
                .width(GANTT_TODAY_LINE_W)
                .height(this.ganttBarsH + GANTT_TODAY_DOT_GAP)
                .borderRadius(GANTT_TODAY_LINE_W)
                .backgroundColor($r('app.color.text_secondary'))
                .opacity(GANTT_TODAY_LINE_OPACITY)
                // x 要加上左边让给勾选框的那一段，和刻度行 / 横条用同一个原点；
                // 再减半个线宽，让线的中线正对那一天
                .position({
                  x: GANTT_CHECK_W + this.ganttTodayX - GANTT_TODAY_LINE_W / 2,
                  y: this.ganttBarsTop - GANTT_TODAY_DOT_GAP
                })
                .hitTestBehavior(HitTestMode.None)
              // 圆点：落在刻度行和横条之间那道空隙的正中，比竖线实一点，好认
              Column()
                .width(GANTT_TODAY_DOT_SIZE)
                .height(GANTT_TODAY_DOT_SIZE)
                .borderRadius(GANTT_TODAY_DOT_SIZE / 2)
                .backgroundColor($r('app.color.text_secondary'))
                .position({
                  x: GANTT_CHECK_W + this.ganttTodayX - GANTT_TODAY_DOT_SIZE / 2,
                  y: this.ganttBarsTop - GANTT_TODAY_DOT_GAP - GANTT_TODAY_DOT_SIZE / 2
                })
                .hitTestBehavior(HitTestMode.None)
            }
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 16 })
        .alignItems(HorizontalAlign.Start)
        .onDrop(() => {
          this.handleDropOnTimeline(this.draggingId);
        })
        .gesture(
          // 单指左右滑 = 平移时间窗口。只绑在下半区容器上，够不到上面两列的纵向滚动；
          // 方向限定横向，纵向滑动不会被它吃掉。手指落在横条上时条自己的拖拽（子组件）
          // 优先认领，平移只在标题行、刻度行、行间空白这些地方生效——条上左右拖
          // 也是平移视野（条内自己分流，见 ganttBar），空白处拖是挪视图，两边同一个行为
          PanGesture({ direction: PanDirection.Horizontal, distance: 8 })
            .onActionStart(() => {
              this.panStartOffset = this.ganttOffsetDays;
              this.panLastOffsetX = 0;
            })
            .onActionUpdate((event: GestureEvent) => {
              if (this.ganttDayPx <= 0) {
                return;
              }
              // 捏合进行中不平移，但记下当前手指位置：捏合结束（可能还剩一根手指按着）
              // 后续平移要以此为基准（见 endPinch），否则视图会按捏合前的累计位移猛跳
              if (this.ganttPinching) {
                this.panLastOffsetX = event.offsetX;
                return;
              }
              // 手指往右拖 = 时间轴整体往右挪 = 露出更早的日子，所以是减。
              // 偏移量保留小数：一天在屏幕上有一格多宽，取整就等于每拖过一格画面跳一下，
              // 手感是"一卡一卡"的。横条的定位本来就是「天数差 × 一格多少 vp」，
              // 小数天数照样算得对，所以这里不需要、也不该取整。
              const target: number = this.panStartOffset - event.offsetX / this.ganttDayPx;
              const clamped: number = this.clampGanttOffset(target);
              if (clamped !== this.ganttOffsetDays) {
                this.ganttOffsetDays = clamped;
                this.recomputeGantt(Date.now());
              }
            })
        )
        .parallelGesture(
          // 双指捏合 = 改时间轴跨度。必须用 parallelGesture：捏合的两根手指多半有一根
          // 压在横条上，普通父手势会输给条上的拖拽，只有两根都落在空白处才捏得动；
          // 并行之后与条那边的冲突由条内手势的多指守卫挡住（见 ganttBar）
          PinchGesture({ fingers: 2 })
            .onActionStart(() => {
              this.ganttPinching = true;
              this.pinchStartSpan = this.ganttSpanDays;
            })
            .onActionUpdate((event: GestureEvent) => {
              this.applyPinchScale(event.scale);
            })
            .onActionEnd(() => {
              this.endPinch();
            })
            .onActionCancel(() => {
              this.endPinch();
            })
        )
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_card'))

      // 拖拽中浮现的「已完成」投放条：挂在根 Stack 里当浮层，
      // 不挤动上面的两列和甘特（它们都是 layoutWeight，插进主 Column 会让卡片上移抖动）
      // hitTestBehavior(None)：这一层满屏容器自身不响应触摸，空白处照常点得到下面的卡片；
      // 里面的投放条是子节点，拖拽照常落得到它
      if (this.showDoneZone) {
        Column() {
          Blank()
          this.dropToDoneZone()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }

    // ── 新建 / 编辑弹窗：根 Stack 居中挂载，声明在主内容之后天然盖在上层 ──
    // 遮罩：点遮罩即取消，等价于系统对话框的 autoCancel 手感
    if (this.entryDialogVisible) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => {
          this.entryDialogVisible = false;
          // 遮罩取消也要清编辑态：留着上一条的 id，下一次误用会改错条目
          this.entryEditingId = '';
        })
    }
    // 弹窗本体：if 条件挂载保证每次打开都重建组件，预填值（日期 / 开关初值）总能可靠生效
    if (this.entryDialogVisible) {
      NewEntryDialog({
        initialDate: this.entryDialogDate,
        initialNeedPrep: this.entryDialogNeedPrep,
        isEdit: this.entryEditingId.length > 0,
        initialText: this.entryDialogText,
        initialPrepDate: this.entryDialogPrepDate,
        initialDueTime: this.entryDialogDueTime,
        onConfirm: (text: string, date: number | null, startDate: number | null,
          dueTime: number | null): void => {
          this.entryDialogVisible = false;
          // 编辑态由 saveEntry 自己取走并清空，这里不能提前清——
          // 提前清掉它就分不出这次是新建还是编辑了
          this.saveEntry(text, date, startDate, dueTime);
        },
        onCancel: (): void => {
          this.entryDialogVisible = false;
          this.entryEditingId = '';
        },
        onDelete: (): void => {
          this.deleteEntry();
        }
      })
    }

    // ── 「远期安排」浮层：与新建 / 编辑弹窗同一套做法（遮罩 + if 条件挂载的卡片）。
    // 两个浮层互斥：行点击先关本浮层再开编辑（见 beyondSheetCard），遮罩点击只关本浮层，
    // 任何时刻 at most 一个 visible 为 true ──
    // 遮罩：点遮罩即关，等价系统对话框的 autoCancel 手感
    if (this.beyondSheetVisible) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => {
          this.beyondSheetVisible = false;
        })
    }
    // 浮层本体：if 条件挂载，声明在遮罩之后天然盖在遮罩上层
    if (this.beyondSheetVisible) {
      this.beyondSheetCard()
    }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
