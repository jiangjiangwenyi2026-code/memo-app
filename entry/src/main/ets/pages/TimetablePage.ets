/**
 * 文件路径：entry/src/main/ets/pages/TimetablePage.ets
 * 用途：课表录入页。课表规则（timetable 表）此前只有每日结算在消费、没有任何录入入口，
 *       本页补上「先有录入，后有课表」的第一环。
 * 版式决定（按需求定稿）：不做「7 列 × 十几行」的整周网格——手机上格子太小点不准，
 *       改成按天分页：顶部 7 个星期 tab，选中某天只列这一天的课，按节次升序。
 * 弹窗实现说明：故意不用 @CustomDialog——编辑课要「预填原值 + 多一个删除按钮」，
 *       CustomDialog 的 builder 参数在构造时绑定、二次打开预填值容易不刷新；
 *       改用页面内的模态遮罩 + 卡片，全部走 @State，预填 / 重置都可控。
 * 职责纪律：数据库只调 DbHelper 的 insertRule / getAllRules / updateRule / deleteRule，
 *           页面里不写一行 SQL；纯计算（文案、解析）放模块级函数，方便复用。
 */

import { DbHelper } from '../data/DbHelper';
import { TimetableRule, TimetableException, ExceptionType, WeekRepeatMode } from '../data/Types';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { rebuildTimetableOfDay } from '../logic/DailyRollover';
import { pushCard } from '../logic/CardPush';
import { startOfDay } from '../viewmodel/EntryDisplay';

/** 星期 tab 的展示描述：value 就是库里的 weekday（1=周一 … 7=周日） */
interface WeekdayTab {
  value: number;
  /** 单字标签（一 / 二 / …）：tab 上拼「周」前缀显示，弹窗芯片里直接用单字省宽度 */
  label: string;
}

/** 单双周三选一的展示描述 */
interface WeekModeOption {
  value: WeekRepeatMode;
  label: string;
}

/** 7 个 tab 固定不变，放模块级只建一份，避免每次刷新都重建字面量 */
const WEEKDAY_TABS: WeekdayTab[] = [
  { value: 1, label: '一' },
  { value: 2, label: '二' },
  { value: 3, label: '三' },
  { value: 4, label: '四' },
  { value: 5, label: '五' },
  { value: 6, label: '六' },
  { value: 7, label: '日' }
];

/** 单双周的三个选项：every 是默认态，排第一让最常见的情况少点一次 */
const WEEK_MODES: WeekModeOption[] = [
  { value: 'every', label: '每周' },
  { value: 'odd', label: '单周' },
  { value: 'even', label: '双周' }
];

/**
 * 调休弹窗里的三选一。「正常上课」不是一种例外类型，而是「这天没有例外」，
 * 所以不能直接用 ExceptionType（它只有 noClass / useWeekday 两个值），
 * 单独一个联合类型把三种选择都装下，保存时再把「正常」翻译成「只删不插」。
 */
type LeaveChoice = 'normal' | 'noClass' | 'useWeekday';

/** 调休三选一的展示描述 */
interface LeaveOption {
  value: LeaveChoice;
  label: string;
}

/** 调休的三个选项：「正常上课」排第一——改回正常是改错了要回退时最常点的那个 */
const LEAVE_OPTIONS: LeaveOption[] = [
  { value: 'normal', label: '正常上课' },
  { value: 'noClass', label: '这天不上课' },
  { value: 'useWeekday', label: '改上星期几的课' }
];

/**
 * 把 0 点时间戳写成「9月24日 周三」，调休弹窗里显示当前选中的是哪天。
 * 星期直接用 WEEKDAY_TABS 的字，省得再维护一份「日一二三四五六」。
 */
function dateText(dayStart: number): string {
  const d: Date = new Date(dayStart);
  const day: number = d.getDay();
  const weekday: number = day === 0 ? 7 : day;
  return `${d.getMonth() + 1}月${d.getDate()}日 周${WEEKDAY_TABS[weekday - 1].label}`;
}

/** 今天是星期几（1=周一 … 7=周日）。进页面默认落在今天：用户一进来看到的正是今天要上的课 */
function todayWeekday(): number {
  const day: number = new Date().getDay();
  return day === 0 ? 7 : day;
}

/** 把输入框里的字符串安全地转成整数，转不动就用兜底值——不让脏输入（空串 / 乱敲）进库 */
function parseIntSafe(value: string, fallback: number): number {
  const n: number = Number.parseInt(value, 10);
  return Number.isNaN(n) ? fallback : n;
}

/** 节次文案：单节「第3节」，连堂「第1-2节」 */
function periodText(rule: TimetableRule): string {
  if (rule.periodFrom === rule.periodTo) {
    return `第${rule.periodFrom}节`;
  }
  return `第${rule.periodFrom}-${rule.periodTo}节`;
}

/** 卡片副标题「节次 · 教室 · 上课时间」：空字段跳过，避免拼出「· ·」这种空洞分隔符 */
function detailLine(rule: TimetableRule): string {
  const parts: string[] = [periodText(rule)];
  if (rule.location !== '') {
    parts.push(rule.location);
  }
  if (rule.timeStart !== '') {
    parts.push(rule.timeStart);
  }
  return parts.join(' · ');
}

/** 起止周文案：单周「5周」，跨周「3-9周」 */
function weeksText(rule: TimetableRule): string {
  if (rule.weekFrom === rule.weekTo) {
    return `${rule.weekFrom}周`;
  }
  return `${rule.weekFrom}-${rule.weekTo}周`;
}

@Entry
@Component
struct TimetablePage {
  /** 数据库句柄：aboutToAppear 里初始化一次，之后只读 */
  private db: DbHelper | undefined = undefined;

  /** 首次读库是否完成：没加载完不显示空状态，避免闪一句误导性的「没课」 */
  @State loaded: boolean = false;

  /** 全部规则。getAllRules 已按星期、节次升序排好，按 tab 过滤即得当天课列表，不用再排 */
  @State allRules: TimetableRule[] = [];

  /** 当前选中的星期 tab（1=周一 … 7=周日），默认今天 */
  @State selectedDay: number = todayWeekday();

  /** 录入弹窗是否可见 */
  @State dialogVisible: boolean = false;

  /** 正在编辑的规则 id；空串 = 新增模式（决定保存走 insert 还是 update、要不要显示删除按钮） */
  @State editingId: string = '';

  // ── 弹窗表单字段。数字类字段用 string 存：TextInput 的 text 是字符串，
  //    保存时再 parseIntSafe，输入过程中的半截数字（如 "1"→""）不会把状态搞坏 ──
  @State formName: string = '';
  @State formLocation: string = '';
  @State formPeriodFrom: string = '1';
  @State formPeriodTo: string = '1';
  @State formTime: string = '08:00';
  @State formWeeks: WeekRepeatMode = 'every';
  @State formWeekFrom: string = '1';
  @State formWeekTo: string = '20';
  @State formWeekday: number = 1;

  /** 课名为空还点保存时置 true，亮一行红字提示而不是静默无反应 */
  @State formNameError: boolean = false;

  // ── 调休弹窗。与课程弹窗共用同一套「模态遮罩 + 页面内卡片」的做法 ──
  /** 调休弹窗是否可见 */
  @State leaveDialogVisible: boolean = false;
  /** 调休选中的日期（当天 0 点时间戳）。打开时落在今天 */
  @State leaveDate: number = startOfDay(Date.now());
  /** 那天当前的安排，三选一 */
  @State leaveChoice: LeaveChoice = 'normal';
  /** 选「改上星期几的课」时生效（1=周一 … 7=周日） */
  @State leaveWeekday: number = 1;

  aboutToAppear(): void {
    this.initAndLoad();
  }

  /** 初始化数据库并读全部规则。失败只记日志不崩溃：界面停留在空状态，下次进页面还能重试 */
  private async initAndLoad(): Promise<void> {
    try {
      this.db = await DbHelper.getInstance(getContext(this));
      await this.refresh();
    } catch (e) {
      hilog.error(0x0000, 'TimetablePage', `数据库初始化失败: ${JSON.stringify(e)}`);
    }
  }

  /** 保存 / 删除后全量重读：不做局部增删修补，库和界面永远对得上；一学期课表量级很小，无性能压力 */
  private async refresh(): Promise<void> {
    const db = this.db;
    if (db === undefined) {
      return;
    }
    this.allRules = await db.getAllRules();
    this.loaded = true;
  }

  /** 当前 tab 那一天的课。allRules 本身已按节次升序，filter 保序，直接可用 */
  private rulesOf(day: number): TimetableRule[] {
    return this.allRules.filter((rule: TimetableRule): boolean => rule.weekday === day);
  }

  /** 打开「新增」弹窗：字段全部归零，星期几默认跟当前 tab——在周三点 +，十有八九就是想加周三的课 */
  private openNew(): void {
    this.editingId = '';
    this.formName = '';
    this.formLocation = '';
    this.formPeriodFrom = '1';
    this.formPeriodTo = '1';
    this.formTime = '08:00';
    this.formWeeks = 'every';
    this.formWeekFrom = '1';
    this.formWeekTo = '20';
    this.formWeekday = this.selectedDay;
    this.formNameError = false;
    this.dialogVisible = true;
  }

  /** 打开「编辑」弹窗：同一个表单，预填原值，editingId 非空即多出删除按钮 */
  private openEdit(rule: TimetableRule): void {
    this.editingId = rule.id;
    this.formName = rule.name;
    this.formLocation = rule.location;
    this.formPeriodFrom = `${rule.periodFrom}`;
    this.formPeriodTo = `${rule.periodTo}`;
    this.formTime = rule.timeStart;
    this.formWeeks = rule.weeks;
    this.formWeekFrom = `${rule.weekFrom}`;
    this.formWeekTo = `${rule.weekTo}`;
    this.formWeekday = rule.weekday;
    this.formNameError = false;
    this.dialogVisible = true;
  }

  /** 保存（新增 / 编辑共用）：先校验课名，再组装规则写库，最后关弹窗 + 全量刷新列表 */
  private async saveCourse(): Promise<void> {
    const name: string = this.formName.trim();
    if (name.length === 0) {
      this.formNameError = true;
      return;
    }
    const db = this.db;
    if (db === undefined) {
      return;
    }
    const from: number = parseIntSafe(this.formPeriodFrom, 1);
    // 结束节 / 结束周小于开始时直接抬平：连堂填反（2 和 1）按 1-1 存，不静默产出非法区间
    const to: number = Math.max(parseIntSafe(this.formPeriodTo, from), from);
    const weekFrom: number = parseIntSafe(this.formWeekFrom, 1);
    const weekTo: number = Math.max(parseIntSafe(this.formWeekTo, weekFrom), weekFrom);
    // timeStart 列 NOT NULL 且卡片要显示它：清空了就退回 08:00，保证永远有可读时间
    const time: string = this.formTime.trim().length > 0 ? this.formTime.trim() : '08:00';
    const rule: TimetableRule = {
      // 新增时现拼 id：时间戳 + 随机数，同一毫秒连点两次也不撞
      id: this.editingId !== '' ? this.editingId : `${Date.now()}-${Math.floor(Math.random() * 1000000)}`,
      weekday: this.formWeekday,
      periodFrom: from,
      periodTo: to,
      name: name,
      location: this.formLocation.trim(),
      weeks: this.formWeeks,
      weekFrom: weekFrom,
      weekTo: weekTo,
      timeStart: time
    };
    // 关弹窗挪进 try：写库失败时不关，弹窗留在原地，用户填的内容不丢，
    // 可以直接再点一次保存；关窗了再报错就变成「内容没了还得重填」
    try {
      if (this.editingId !== '') {
        await db.updateRule(rule);
      } else {
        await db.insertRule(rule);
      }
      this.dialogVisible = false;
      await this.refresh();
      // 课表数据变了，推一把桌面卡片：用户很可能从这一页直接按 Home 回桌面，
      // 那样子页面的改动主页收不到，卡片会一直停在旧内容上
      pushCard(getContext(this), db);
    } catch (e) {
      hilog.error(0x0000, 'TimetablePage', `保存课表失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败，请重试' });
    }
  }

  /** 删除当前编辑中的规则。课表是「规则」不是「条目」，没有回收站概念，直接物理删 */
  private async deleteCourse(): Promise<void> {
    const db = this.db;
    if (db === undefined || this.editingId === '') {
      return;
    }
    // 同理：删失败就别关弹窗，那条规则还在，用户能再试
    try {
      await db.deleteRule(this.editingId);
      this.dialogVisible = false;
      await this.refresh();
      // 课表数据变了，推一把桌面卡片：用户很可能从这一页直接按 Home 回桌面，
      // 那样子页面的改动主页收不到，卡片会一直停在旧内容上
      pushCard(getContext(this), db);
    } catch (e) {
      hilog.error(0x0000, 'TimetablePage', `删除课表失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '删除失败，请重试' });
    }
  }

  /** 打开调休弹窗：默认落在今天，并把那天已有的调休读出来预填 */
  private async openLeave(): Promise<void> {
    await this.loadLeave(startOfDay(Date.now()));
    this.leaveDialogVisible = true;
  }

  /**
   * 读某一天已有的调休，填进弹窗表单。那天没设过就落到「正常上课」。
   * 先把三个字段归零再查：查库失败时停在「正常上课」上，
   * 不会把上一天残留的选择留在界面上，用户看着是「正常」、保存下去却是别的。
   */
  private async loadLeave(dayStart: number): Promise<void> {
    this.leaveDate = dayStart;
    this.leaveChoice = 'normal';
    this.leaveWeekday = 1;
    const db = this.db;
    if (db === undefined) {
      return;
    }
    try {
      const exception: TimetableException | undefined = await db.getExceptionByDate(dayStart);
      // 日期守卫：await 期间用户可能又通过日期选择器改了日期（this.leaveDate 已是新日期）。
      // 这时查回来的是「旧日期」的调休，直接填会把旧值错配到新日期的表单上，
      // 所以什么都不填、直接放弃本次结果，让后发起的那次 loadLeave 负责填。
      if (this.leaveDate !== dayStart) {
        return;
      }
      if (exception === undefined) {
        return;
      }
      this.leaveChoice = exception.type;
      if (exception.type === 'useWeekday' && exception.weekday !== null) {
        this.leaveWeekday = exception.weekday;
      }
    } catch (e) {
      hilog.error(0x0000, 'TimetablePage', `读调休失败: ${JSON.stringify(e)}`);
      // 方法开头已把表单归零成「正常上课」，查库失败时界面显示的是假状态：
      // 不提示的话，用户就此点保存会把那天真有的调休静默删掉
      this.getUIContext().getPromptAction().showToast({ message: '没读出那天的调休，请重开一次' });
    }
  }

  /** 改调休日期：弹系统日期选择器，选完立刻重读那天已有的调休 */
  private pickLeaveDate(): void {
    this.getUIContext().showDatePickerDialog({
      // 起始限到今天 0 点：给已经过去的日子设调休没有意义——
      // 那天的课表早被每日结算清掉，重算出的条目回主界面也会被当过期课表扫掉
      start: new Date(startOfDay(Date.now())),
      end: new Date(2100, 11, 31),
      selected: new Date(this.leaveDate),
      onDateAccept: (value: Date) => {
        // 归一化到 0 点：库里的 date 一律是 0 点时间戳，带时分就查不到已有的调休
        const picked: Date = new Date(value.getTime());
        picked.setHours(0, 0, 0, 0);
        this.loadLeave(picked.getTime());
      }
    });
  }

  /**
   * 保存调休。先删掉那天的旧例外，再按当前选择决定要不要插一条新的——
   * 「正常上课」就是只删不插，所以改回正常和设置调休是同一条路径。
   *
   * 存完必须重算那天的课表：每日结算的幂等闸门按「规则 + 日期」判重，光改库不重算的话，
   * 界面上那天的课还是老样子（设了「不上课」课还在），等于调休白设。
   * 详见 DailyRollover.rebuildTimetableOfDay 的说明。
   */
  private async saveLeave(): Promise<void> {
    const db = this.db;
    if (db === undefined) {
      return;
    }
    const dayStart: number = this.leaveDate;
    // 显式收窄成 ExceptionType：「正常」在这一步已经被排除了，
    // 不写成 'normal' 之外的两值之一，后面建例外对象时类型对不上
    const type: ExceptionType = this.leaveChoice === 'useWeekday' ? 'useWeekday' : 'noClass';
    try {
      await db.deleteExceptionByDate(dayStart);
      if (this.leaveChoice !== 'normal') {
        const exception: TimetableException = {
          // 一天最多一条，且上面刚把旧行删干净了，id 现拼即可，不会撞主键
          id: `${Date.now()}-${Math.floor(Math.random() * 1000000)}`,
          date: dayStart,
          type: type,
          // 只有「改上星期几的课」才带星期几，另两种存 null
          weekday: type === 'useWeekday' ? this.leaveWeekday : null
        };
        await db.insertException(exception);
      }
      // 只有「今天及更早」才立刻重算：今天已经结算过，幂等闸门会挡住例行重算，
      // 必须在这里手动重排一次，界面上那天的课才会立刻跟着调休变。
      // 未来日期跳过重算：重算的语义是「先清掉那天的条目、再重新展开插入」，
      // 对未来某天执行会把那天的课表条目提前物化进数据库、提前出现在主界面甘特上；
      // 而且根本不需要——每日结算（DailyRollover.rollover）在那一天到来时会读
      // 当天的调休例外再展开，到那天自然就是对的。
      const isTodayOrBefore: boolean = dayStart <= startOfDay(Date.now());
      if (isTodayOrBefore) {
        await rebuildTimetableOfDay(db, dayStart, Date.now());
      }
      this.leaveDialogVisible = false;
      await this.refresh();
      // 课表数据变了，推一把桌面卡片：用户很可能从这一页直接按 Home 回桌面，
      // 那样子页面的改动主页收不到，卡片会一直停在旧内容上
      pushCard(getContext(this), db);
      this.getUIContext().getPromptAction().showToast({
        message: isTodayOrBefore ? '已保存，今天的课表已重排' : '已保存，到那天自动生效'
      });
    } catch (e) {
      hilog.error(0x0000, 'TimetablePage', `保存调休失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败，请重试' });
    }
  }

  /** 星期 tab：选中态反色（深底白字），一眼能看出当前停在哪一天 */
  @Builder
  weekdayTab(tab: WeekdayTab) {
    Text(`周${tab.label}`)
      .fontSize(13)
      .fontColor(tab.value === this.selectedDay ? Color.White : $r('app.color.text_body'))
      .fontWeight(tab.value === this.selectedDay ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .padding({ top: 8, bottom: 8 })
      .borderRadius(10)
      .backgroundColor(tab.value === this.selectedDay ? $r('app.color.button_primary_bg') : 'transparent')
      .layoutWeight(1)
      .onClick(() => {
        this.selectedDay = tab.value;
      })
  }

  /**
   * 一节课的卡片：左侧课名 + 「节次 · 教室 · 上课时间」灰字，右侧单双周徽标 + 起止周。
   * 每周上的课不标徽标（标了反而噪音），只有单周 / 双周才值得提醒。
   * 点整张卡即进入编辑，热区大、好点。
   */
  @Builder
  courseCard(rule: TimetableRule) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(rule.name)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(detailLine(rule))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Column({ space: 4 }) {
        if (rule.weeks !== 'every') {
          Text(rule.weeks === 'odd' ? '单周' : '双周')
            .fontSize(11)
            .fontColor($r('app.color.text_body'))
            .backgroundColor($r('app.color.border'))
            .borderRadius(8)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        }
        Text(weeksText(rule))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.End)
    }
    .alignItems(VerticalAlign.Center)
    .padding(12)
    .borderRadius(12)
    .backgroundColor($r('app.color.bg_subtle'))
    .width('100%')
    .onClick(() => {
      this.openEdit(rule);
    })
  }

  /** 表单字段的小标题：统一小号灰字，和首页的辅助信息风格一致 */
  @Builder
  fieldLabel(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor($r('app.color.text_secondary'))
  }

  /** 单行文本输入：统一浅底圆角外观，弹窗里所有输入框长一个样 */
  @Builder
  formInput(text: string, placeholder: string, numberOnly: boolean, onType: (value: string) => void) {
    TextInput({ text: text, placeholder: placeholder })
      .onChange((value: string) => {
        onType(value);
      })
      .type(numberOnly ? InputType.Number : InputType.Normal)
      .height(40)
      .backgroundColor($r('app.color.bg_subtle'))
      .borderRadius(8)
      .padding({ left: 12, right: 12 })
      .width('100%')
  }

  /** 录入弹窗本体：新增 / 编辑共用一个表单，字段顺序按需求定稿排列 */
  @Builder
  formDialog() {
    Column() {
      Text(this.editingId !== '' ? '改这节课' : '加一节课')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 14 })

      // 字段多，小屏可能放不下：内容区允许滚动，标题和按钮永远露在外面
      Scroll() {
        Column({ space: 14 }) {
          // 课名（唯一必填项）
          Column({ space: 6 }) {
            this.fieldLabel('课名')
            this.formInput(this.formName, '必填', false, (value: string): void => {
              this.formName = value;
            })
            if (this.formNameError) {
              Text('课名必填')
                .fontSize(11)
                .fontColor($r('app.color.danger'))
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 教室（可空）
          Column({ space: 6 }) {
            this.fieldLabel('教室')
            this.formInput(this.formLocation, '可空', false, (value: string): void => {
              this.formLocation = value;
            })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 节次：开始 — 结束，连堂就填 1 和 2
          Column({ space: 6 }) {
            this.fieldLabel('节次（连堂就填开始和结束两节）')
            Row({ space: 8 }) {
              TextInput({ text: this.formPeriodFrom, placeholder: '开始' })
                .onChange((value: string) => {
                  this.formPeriodFrom = value;
                })
                .type(InputType.Number)
                .height(40)
                .backgroundColor($r('app.color.bg_subtle'))
                .borderRadius(8)
                .padding({ left: 12, right: 12 })
                .layoutWeight(1)
              Text('—')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
              TextInput({ text: this.formPeriodTo, placeholder: '结束' })
                .onChange((value: string) => {
                  this.formPeriodTo = value;
                })
                .type(InputType.Number)
                .height(40)
                .backgroundColor($r('app.color.bg_subtle'))
                .borderRadius(8)
                .padding({ left: 12, right: 12 })
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 上课时间
          Column({ space: 6 }) {
            this.fieldLabel('上课时间')
            this.formInput(this.formTime, '如 08:00', false, (value: string): void => {
              this.formTime = value;
            })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 单双周三选一
          Column({ space: 6 }) {
            this.fieldLabel('单双周')
            Row({ space: 8 }) {
              ForEach(WEEK_MODES, (mode: WeekModeOption) => {
                Text(mode.label)
                  .fontSize(13)
                  .fontColor(mode.value === this.formWeeks ? Color.White : $r('app.color.text_body'))
                  .textAlign(TextAlign.Center)
                  .padding({ top: 8, bottom: 8 })
                  .borderRadius(10)
                  .backgroundColor(mode.value === this.formWeeks ? $r('app.color.button_primary_bg') : $r('app.color.bg_subtle'))
                  .layoutWeight(1)
                  .onClick(() => {
                    this.formWeeks = mode.value;
                  })
              }, (mode: WeekModeOption): string => mode.value)
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 起止周
          Column({ space: 6 }) {
            this.fieldLabel('周次（起始 — 结束）')
            Row({ space: 8 }) {
              TextInput({ text: this.formWeekFrom, placeholder: '起始周' })
                .onChange((value: string) => {
                  this.formWeekFrom = value;
                })
                .type(InputType.Number)
                .height(40)
                .backgroundColor($r('app.color.bg_subtle'))
                .borderRadius(8)
                .padding({ left: 12, right: 12 })
                .layoutWeight(1)
              Text('—')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
              TextInput({ text: this.formWeekTo, placeholder: '结束周' })
                .onChange((value: string) => {
                  this.formWeekTo = value;
                })
                .type(InputType.Number)
                .height(40)
                .backgroundColor($r('app.color.bg_subtle'))
                .borderRadius(8)
                .padding({ left: 12, right: 12 })
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 星期几：默认跟当前 tab，但允许在弹窗里改（补录别天的课不必先切 tab）
          Column({ space: 6 }) {
            this.fieldLabel('星期几')
            Row({ space: 6 }) {
              ForEach(WEEKDAY_TABS, (tab: WeekdayTab) => {
                Text(tab.label)
                  .fontSize(13)
                  .fontColor(tab.value === this.formWeekday ? Color.White : $r('app.color.text_body'))
                  .textAlign(TextAlign.Center)
                  .padding({ top: 8, bottom: 8 })
                  .borderRadius(10)
                  .backgroundColor(tab.value === this.formWeekday ? $r('app.color.button_primary_bg') : $r('app.color.bg_subtle'))
                  .layoutWeight(1)
                  .onClick(() => {
                    this.formWeekday = tab.value;
                  })
              }, (tab: WeekdayTab): string => `${tab.value}`)
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .constraintSize({ maxHeight: 460 })
      .width('100%')

      // 按钮区：编辑模式多一个「删除」；课名不合法时保存不关弹窗，红字提示留在上面
      Row({ space: 12 }) {
        if (this.editingId !== '') {
          Button('删除')
            .layoutWeight(1)
            .backgroundColor($r('app.color.bg_subtle'))
            .fontColor($r('app.color.danger'))
            .onClick(() => {
              this.deleteCourse();
            })
        }
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('app.color.bg_subtle'))
          .fontColor($r('app.color.text_body'))
          .onClick(() => {
            this.dialogVisible = false;
          })
        Button('保存')
          .layoutWeight(1)
          .backgroundColor($r('app.color.button_primary_bg'))
          .onClick(() => {
            this.saveCourse();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .padding(20)
    .width('88%')
    .borderRadius(16)
    .backgroundColor($r('app.color.bg_card'))
  }

  /**
   * 调休弹窗：选日期 + 三选一（正常上课 / 这天不上课 / 改上星期几的课）。
   * 版式与课程弹窗一致，三选一做成竖排整行按钮——选项文字较长，
   * 横排三等分会把「改上星期几的课」挤成两行。
   */
  @Builder
  leaveDialog() {
    Column() {
      Text('调休')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 14 })

      // 日期行：整行可点，点开系统日期选择器
      Column({ space: 6 }) {
        this.fieldLabel('哪一天')
        Row() {
          Text(dateText(this.leaveDate))
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Text('改')
            .fontSize(13)
            .fontColor($r('app.color.button_primary_bg'))
        }
        .width('100%')
        .height(40)
        .padding({ left: 12, right: 12 })
        .borderRadius(8)
        .backgroundColor($r('app.color.bg_subtle'))
        .onClick(() => {
          this.pickLeaveDate();
        })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      // 三选一
      Column({ space: 6 }) {
        this.fieldLabel('这天怎么安排')
        Column({ space: 8 }) {
          ForEach(LEAVE_OPTIONS, (option: LeaveOption) => {
            Text(option.label)
              .fontSize(13)
              .fontColor(option.value === this.leaveChoice ? Color.White : $r('app.color.text_body'))
              .textAlign(TextAlign.Center)
              .padding({ top: 10, bottom: 10 })
              .borderRadius(10)
              .backgroundColor(option.value === this.leaveChoice
                ? $r('app.color.button_primary_bg')
                : $r('app.color.bg_subtle'))
              .width('100%')
              .onClick(() => {
                this.leaveChoice = option.value;
              })
          }, (option: LeaveOption): string => option.value)
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .margin({ top: 14 })

      // 只有选了「改上星期几的课」才出现星期芯片，其余两种选择下这块整个不渲染
      if (this.leaveChoice === 'useWeekday') {
        Column({ space: 6 }) {
          this.fieldLabel('上星期几的课')
          Row({ space: 4 }) {
            ForEach(WEEKDAY_TABS, (tab: WeekdayTab) => {
              Text(tab.label)
                .fontSize(13)
                .fontColor(tab.value === this.leaveWeekday ? Color.White : $r('app.color.text_body'))
                .textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 8 })
                .borderRadius(10)
                .backgroundColor(tab.value === this.leaveWeekday
                  ? $r('app.color.button_primary_bg')
                  : $r('app.color.bg_subtle'))
                .layoutWeight(1)
                .onClick(() => {
                  this.leaveWeekday = tab.value;
                })
            }, (tab: WeekdayTab): string => `${tab.value}`)
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ top: 14 })
      }

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('app.color.bg_subtle'))
          .fontColor($r('app.color.text_body'))
          .onClick(() => {
            this.leaveDialogVisible = false;
          })
        Button('保存')
          .layoutWeight(1)
          .backgroundColor($r('app.color.button_primary_bg'))
          .onClick(() => {
            this.saveLeave();
          })
      }
      .width('100%')
      .margin({ top: 18 })
    }
    .padding(20)
    .width('88%')
    .borderRadius(16)
    .backgroundColor($r('app.color.bg_card'))
  }

  build() {
    // 根 Stack 居中：主内容铺满，弹窗卡片落在屏幕中央；遮罩和弹窗按声明顺序叠在上层
    Stack({ alignContent: Alignment.Center }) {
      // 主内容：内层 Stack 负责「+」固定在右下角
      Stack({ alignContent: Alignment.BottomEnd }) {
        Column() {
          // 标题行：返回箭头 + 页名
          Row({ space: 8 }) {
            Text('←')
              .fontSize(20)
              .fontColor($r('app.color.text_primary'))
              .padding(6)
              .onClick(() => {
                this.getUIContext().getRouter().back();
              })
            Text('课表')
              .fontSize(18)
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
            Blank()
            // 调休入口放标题行右侧：它是低频操作，占一整行不值当，
            // 但放在这里随时够得着，不必翻设置页
            Text('调休')
              .fontSize(13)
              .fontColor($r('app.color.text_body'))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(8)
              .backgroundColor($r('app.color.bg_subtle'))
              .onClick(() => {
                this.openLeave();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: 10, right: 16, top: 12 })

          // 7 个星期 tab 一行铺满
          Row({ space: 4 }) {
            ForEach(WEEKDAY_TABS, (tab: WeekdayTab) => {
              this.weekdayTab(tab)
            }, (tab: WeekdayTab): string => `${tab.value}`)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .margin({ top: 12 })

          // 当天的课，按节次升序；只有列表内部滚动，tab 和标题保持稳定
          Scroll() {
            Column({ space: 8 }) {
              if (this.loaded && this.rulesOf(this.selectedDay).length === 0) {
                Text('这一天还没有课，点右下角 + 加一节')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .margin({ top: 24 })
              }
              ForEach(this.rulesOf(this.selectedDay), (rule: TimetableRule) => {
                this.courseCard(rule)
              }, (rule: TimetableRule): string => rule.id)
            }
            .width('100%')
            // 底部留白：最后一张卡不被右下角的「+」挡住
            .padding({ left: 16, right: 16, top: 16, bottom: 88 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .width('100%')
        }
        .width('100%')
        .height('100%')

        // 右下角「+」：深底圆钮，和整页灰白调形成唯一的强对比，高频入口要显眼
        Text('+')
          .fontSize(24)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .width(48)
          .height(48)
          .borderRadius(24)
          .backgroundColor($r('app.color.button_primary_bg'))
          .margin(20)
          .onClick(() => {
            this.openNew();
          })
      }
      .width('100%')
      .height('100%')

      // 弹窗遮罩：点遮罩即取消，等价于系统对话框的 autoCancel 手感
      if (this.dialogVisible) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.4)')
          .onClick(() => {
            this.dialogVisible = false;
          })
      }
      // 弹窗本体：声明在遮罩之后，天然盖在遮罩上面
      if (this.dialogVisible) {
        this.formDialog()
      }

      // 调休弹窗同一套叠法。两个弹窗不会同时开，谁的状态为真就挂谁
      if (this.leaveDialogVisible) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.4)')
          .onClick(() => {
            this.leaveDialogVisible = false;
          })
      }
      if (this.leaveDialogVisible) {
        this.leaveDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
