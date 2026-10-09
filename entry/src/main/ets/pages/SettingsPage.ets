/**
 * 文件路径：entry/src/main/ets/pages/SettingsPage.ets
 * 用途：设置页。每日结算要算出「今天上什么课」，必须先知道两个基准：
 *       semesterStart（学期第一天，周次从它起算）和 firstWeekIsOdd（第 1 周算不算单周，
 *       决定单双周和周次奇偶的对应关系）。此前没有任何界面能填它们，
 *       课表展开实际上算不出来——本页补上这最后一环，顺带管每天三次的提醒时间。
 * 职责纪律：读写只走 DbHelper 的 getSetting / setSetting（键用 Types.ets 的 SettingsKey），
 *           页面里不写一行 SQL；日期 / 时间的格式换算放模块级纯函数，方便复用和单测。
 * 版式：沿用首页风格——圆角浅底卡片（#F2F3F5 + 圆角 12）、小号灰字做辅助信息、整页简约。
 */

import { DbHelper } from '../data/DbHelper';
import { SettingsKey } from '../data/Types';
import { startOfDay } from '../viewmodel/EntryDisplay';
import { pushCard } from '../logic/CardPush';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 一天里的某个时刻（时、分）。存库前会拼成 "HH:mm"，展示时直接用拼好的串 */
interface TimeOfDay {
  hour: number;
  minute: number;
}

/**
 * 一行设置卡的参数。**收成一个对象是必须的，不是风格问题**：
 * @Builder 只有「按引用传参」（实参写成对象字面量）时，内部 UI 才会跟着状态变量重建；
 * 摊成三个散参数就是按值传参，ArkUI 当它是常量，this.semesterStart 改了这行文字也不动。
 * 踩过的坑（2026-09-28）：用户报「无法设置第一天」——弹窗能弹、确定能点、库里也写进去了，
 * 就是那一行还写着「未设置，点我选择」，看着像功能坏了，其实是没重画。
 */
interface SettingRowParams {
  label: string;
  value: string;
  onTap: () => void;
}

/**
 * 时分数字拼成 "HH:mm"。
 * 个位数必须补零：库里的约定是固定两位（如 "06:30"），
 * 结算 / 提醒逻辑按冒号切分再 parseInt，补零与否都能读，但两位数展示对齐更整齐。
 */
function toTimeString(hour: number, minute: number): string {
  const h: string = hour < 10 ? `0${hour}` : `${hour}`;
  const m: string = minute < 10 ? `0${minute}` : `${minute}`;
  return `${h}:${m}`;
}

/**
 * "HH:mm" 解析回时、分。解析失败兜底 0 点：
 * 库里的值都由本页写入（格式受控），这个兜底只防手改数据库的脏数据，不值得为它报错。
 */
function parseTimeOfDay(text: string): TimeOfDay {
  const parts: string[] = text.split(':');
  const hour: number = parts.length > 1 ? Number.parseInt(parts[0], 10) : 0;
  const minute: number = parts.length > 1 ? Number.parseInt(parts[1], 10) : 0;
  return {
    hour: Number.isNaN(hour) ? 0 : hour,
    minute: Number.isNaN(minute) ? 0 : minute
  };
}

/** 时间戳转「2026年9月1日」式文案。设置页只有这一处要中文长日期，不必抽到公共层 */
function formatChineseDate(ts: number): string {
  const d: Date = new Date(ts);
  return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`;
}

@Entry
@Component
struct SettingsPage {
  /** 数据库句柄：aboutToAppear 里初始化一次，之后只读 */
  private db: DbHelper | undefined = undefined;

  /** 首次读库是否完成：没加载完不显示默认值，避免把「还没读到的」闪成「用户存的」误导一下 */
  @State loaded: boolean = false;

  /**
   * 本学期第一天（当天 0 点毫秒时间戳）。null = 还没设置。
   * 为什么不像其他设置那样给默认值：随便挑个日期会把周次全算错，
   * 宁可显示「未设置」让用户亲自定（结算侧 DailyRollover 对未设置另有兜底）。
   */
  @State semesterStart: number | null = null;

  /** 第 1 周算不算单周。默认 true（多数学校第 1 周是单周），与 DailyRollover 的兜底一致 */
  @State firstWeekIsOdd: boolean = true;

  /** 三次提醒时间（"HH:mm"）。默认值与 Types.ets 里 settings 表的注释保持一致 */
  @State notifyTime1: string = '06:30';
  @State notifyTime2: string = '11:30';
  @State notifyTime3: string = '16:05';

  aboutToAppear(): void {
    this.initAndLoad();
  }

  /** 初始化数据库并读全部设置。失败只记日志不崩溃：界面停留在默认值，下次进页面还能重试 */
  private async initAndLoad(): Promise<void> {
    try {
      this.db = await DbHelper.getInstance(getContext(this));
      await this.loadSettings();
    } catch (e) {
      hilog.error(0x0000, 'SettingsPage', `数据库初始化失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 读五个设置项。没存过的项用默认值顶上并顺手写回库：
   * 写回后库里永远是完整的一套，结算逻辑不用每次都走「undefined 兜底」的慢路径，
   * 用户也能在设置页看到「实际生效的值」而不是「代码里的兜底值」。
   */
  private async loadSettings(): Promise<void> {
    const db = this.db;
    if (db === undefined) {
      return;
    }
    // 学期第一天刻意不给默认值（见字段注释），读到什么存的就是什么
    const semesterRaw: string | undefined = await db.getSetting('semesterStart');
    this.semesterStart = semesterRaw !== undefined ? startOfDay(Number(semesterRaw)) : null;

    const oddRaw: string | undefined = await db.getSetting('firstWeekIsOdd');
    if (oddRaw === undefined) {
      this.firstWeekIsOdd = true;
      await db.setSetting('firstWeekIsOdd', '1');
    } else {
      this.firstWeekIsOdd = oddRaw === '1';
    }

    // 三个提醒时间共用一个「缺了就补默认值」的小方法，避免三段几乎一样的代码
    this.notifyTime1 = await this.ensureSetting(db, 'notifyTime1', '06:30');
    this.notifyTime2 = await this.ensureSetting(db, 'notifyTime2', '11:30');
    this.notifyTime3 = await this.ensureSetting(db, 'notifyTime3', '16:05');

    this.loaded = true;
  }

  /** 读一个提醒时间：库里没有就用默认值并写回，保证「显示的 = 库里的 = 生效的」三者一致 */
  private async ensureSetting(db: DbHelper, key: SettingsKey, fallback: string): Promise<string> {
    const raw: string | undefined = await db.getSetting(key);
    if (raw !== undefined) {
      return raw;
    }
    await db.setSetting(key, fallback);
    return fallback;
  }

  /** 弹系统日期选择器改学期第一天。选中后归一化到 0 点再入库，和库里「日期存 0 点」的约定一致 */
  private openSemesterPicker(): void {
    this.getUIContext().showDatePickerDialog({
      start: new Date(2020, 0, 1),
      end: new Date(2100, 11, 31),
      // 已设置过就从已选的日期接着选，没设置过从今天开始——学期开头总在「今天附近」
      selected: this.semesterStart !== null ? new Date(this.semesterStart) : new Date(),
      onDateAccept: (value: Date) => {
        this.saveSemesterStart(startOfDay(value.getTime()));
      }
    });
  }

  /**
   * 存学期第一天：先改状态（界面立即刷新），再写库。
   * 界面先变是有意的（乐观更新，操作手感跟手），但**失败必须让用户知道**——
   * 界面显示新值、库里还是旧值，下次打开又变回去，比报错更让人摸不着头脑。
   */
  private async saveSemesterStart(ts: number): Promise<void> {
    this.semesterStart = ts;
    const db = this.db;
    if (db === undefined) {
      return;
    }
    try {
      await db.setSetting('semesterStart', `${ts}`);
      // 学期第一天影响课表的周次，今天展开的课可能跟着变；推一把卡片，
      // 用户从这一页直接按 Home 回桌面时卡片才是新的
      pushCard(getContext(this), db);
    } catch (e) {
      hilog.error(0x0000, 'SettingsPage', `保存学期第一天失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '设置没存上，请重试' });
    }
  }

  /** 单双周开关拨动：界面即时变文案，"1" / "0" 按库里约定入库；存不上要说一声 */
  private async saveFirstWeek(isOdd: boolean): Promise<void> {
    this.firstWeekIsOdd = isOdd;
    const db = this.db;
    if (db === undefined) {
      return;
    }
    try {
      await db.setSetting('firstWeekIsOdd', isOdd ? '1' : '0');
      // 单双周影响课表周次，理由同 saveSemesterStart
      pushCard(getContext(this), db);
    } catch (e) {
      hilog.error(0x0000, 'SettingsPage', `保存单双周失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '设置没存上，请重试' });
    }
  }

  /** 某个提醒时间当前显示值。设置项各存各的 @State，这里用 if 收拢而不是动态属性访问 */
  private currentNotifyValue(key: SettingsKey): string {
    if (key === 'notifyTime1') {
      return this.notifyTime1;
    }
    if (key === 'notifyTime2') {
      return this.notifyTime2;
    }
    return this.notifyTime3;
  }

  /** 弹系统时间选择器改某个提醒时间。选中后拼 "HH:mm" 入库 */
  private openTimePicker(key: SettingsKey): void {
    const current: TimeOfDay = parseTimeOfDay(this.currentNotifyValue(key));
    this.getUIContext().showTimePickerDialog({
      // 年月日随意给一个合法日期，时间选择器只取时分；24 小时制和库里 "HH:mm" 格式对齐
      selected: new Date(2020, 0, 1, current.hour, current.minute),
      useMilitaryTime: true,
      onAccept: (value: TimePickerResult) => {
        this.saveNotifyTime(key, toTimeString(value.hour, value.minute));
      }
    });
  }

  /** 存某个提醒时间：先按 key 把值写回对应的 @State（界面刷新），再写库；存不上要说一声 */
  private async saveNotifyTime(key: SettingsKey, value: string): Promise<void> {
    if (key === 'notifyTime1') {
      this.notifyTime1 = value;
    } else if (key === 'notifyTime2') {
      this.notifyTime2 = value;
    } else {
      this.notifyTime3 = value;
    }
    const db = this.db;
    if (db === undefined) {
      return;
    }
    try {
      await db.setSetting(key, value);
      // 改了提醒时间要推一把卡片：重排提醒这件事发生在卡片进程里，
      // 推醒它，新的提醒时间才会立刻生效（不然要等它下次自己醒）
      pushCard(getContext(this), db);
    } catch (e) {
      hilog.error(0x0000, 'SettingsPage', `保存提醒时间失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '设置没存上，请重试' });
    }
  }

  /** 分组小标题：沿用首页「小灰字标签」的辅助信息风格 */
  @Builder
  sectionCaption(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .margin({ top: 8 })
  }

  /**
   * 通用的一行设置卡：左边标签、右边当前值，点整张卡触发选择器。
   * 热区是整张卡而不是右侧文字：好点，也和课表页「点卡片进编辑」的交互一致。
   * 参数为什么包成对象见 SettingRowParams 的注释——那是这行的刷新开关。
   */
  @Builder
  settingRow(params: SettingRowParams) {
    Row() {
      Text(params.label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      // Blank 把当前值顶到行末，标签和值自然分居两端
      Blank()
      Text(params.value)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
    }
    .alignItems(VerticalAlign.Center)
    .padding(12)
    .borderRadius(12)
    .backgroundColor($r('app.color.bg_subtle'))
    .width('100%')
    .onClick(() => {
      params.onTap();
    })
  }

  build() {
    Column() {
      // 标题行：返回箭头 + 页名，和课表页同一个版式，页与页之间不换花样
      Row({ space: 8 }) {
        Text('←')
          .fontSize(20)
          .fontColor($r('app.color.text_primary'))
          .padding(6)
          .onClick(() => {
            // 跳转走 UIContext 的 router：全局 router.back 已废弃
            this.getUIContext().getRouter().back();
          })
        Text('设置')
          .fontSize(18)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 10, right: 16, top: 12 })

      // 设置项不多但小屏也要放得下：列表内部滚动，标题行保持稳定
      Scroll() {
        Column({ space: 12 }) {
          // ── 学期基准：课表展开的两个前置设置 ──
          this.sectionCaption('学期')
          this.settingRow({
            label: '本学期第一天',
            value: this.semesterStart !== null ? formatChineseDate(this.semesterStart) : '未设置，点我选择',
            onTap: (): void => {
              this.openSemesterPicker();
            }
          })

          // 单双周开关：文案跟着开关状态变（两种文案本身就是设置项的含义说明，不用再加副标题）
          Row() {
            Text(this.firstWeekIsOdd ? '第 1 周是单周' : '第 1 周是双周')
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.firstWeekIsOdd })
              .onChange((isOn: boolean) => {
                this.saveFirstWeek(isOn);
              })
          }
          .alignItems(VerticalAlign.Center)
          .padding(12)
          .borderRadius(12)
          .backgroundColor($r('app.color.bg_subtle'))
          .width('100%')

          // ── 提醒时间：一天三次 ──
          this.sectionCaption('三次提醒时间')
          // 说明文案讲清「推什么」：不解释的话用户会以为提醒只推汇总
          Text('早上那次是今日汇总；三次都会推没勾掉的事')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          this.settingRow({
            label: '早上',
            value: this.notifyTime1,
            onTap: (): void => {
              this.openTimePicker('notifyTime1');
            }
          })
          this.settingRow({
            label: '中午',
            value: this.notifyTime2,
            onTap: (): void => {
              this.openTimePicker('notifyTime2');
            }
          })
          this.settingRow({
            label: '下午',
            value: this.notifyTime3,
            onTap: (): void => {
              this.openTimePicker('notifyTime3');
            }
          })

          // 返回入口：显式给一张「返回」卡，不逼用户去找左上角的小箭头
          Text('返回')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)
            .padding(12)
            .borderRadius(12)
            .backgroundColor($r('app.color.bg_subtle'))
            .width('100%')
            .margin({ top: 12 })
            .onClick(() => {
              this.getUIContext().getRouter().back();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
