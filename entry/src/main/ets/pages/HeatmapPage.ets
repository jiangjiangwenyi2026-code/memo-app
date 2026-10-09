/**
 * 文件路径：entry/src/main/ets/pages/HeatmapPage.ets
 * 用途：年度热力图——一整年 53 周 × 7 天的格子墙，哪天忙哪天闲一眼看完。
 *       数据来自 HeatmapLogic（口径、分档都在那边），本页只管画。
 * 版式：标题行（← 返回） + 摘要 + 格子墙 + 图例，与设置页同一套简洁风格。
 * 尺寸策略：格子边长自己算——53 列铺满一屏，手机每格 4vp 多、平板 18vp，
 *       差四倍，写死必然有一头崩。宽度来源是屏幕宽（display）减去各层内边距，
 *       不用 onAreaChange 量容器：那个回调给的是 px，换算成 vp 实测两轮都不对
 *       （一次偏大两倍多、一次只铺满半屏），而它报的多半是布局中途的值。
 *       格子宽高都取这个算出来的边长，不靠 aspectRatio——
 *       那个属性要等宽度定下来才算高度，在「先量内容后分宽度」的布局里会退化成
 *       压扁的长方形（实测七行挤成一条）。
 */

import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DbHelper } from '../data/DbHelper';
import { EntryItem } from '../data/Types';
import { HeatDayData, HeatmapData, formatMonthDay, toHeatmap } from '../logic/HeatmapLogic';
import { startOfDay } from '../viewmodel/EntryDisplay';

const DAY_MS: number = 24 * 60 * 60 * 1000;

/** 左侧星期标签占的宽度（vp）：一个汉字加一点余量 */
const WEEK_LABEL_W: number = 16;

/** 格子和格子之间的缝（vp） */
const CELL_GAP: number = 1.5;

/**
 * 页面左右各 16 的内边距 + 热力图卡左右各 12 的内边距（vp）。
 * 格子铺在卡片里，这两圈得先扣掉，不然算出来的格子偏大、最后几列会被挤出屏幕。
 */
const H_PADDING: number = 16 * 2 + 12 * 2;

/**
 * 星期标签只标一 / 三 / 五，隔行一个。
 * 七行全标在手机上会连成一条竖线，反而看不出是哪一行；隔行标才认得出上下。
 */
const ROW_LABELS: string[] = ['一', '', '三', '', '五', '', ''];

/** 一周七行，行号常量：ForEach 要的是数组，不在 build 里现造 */
const ROW_INDEXES: number[] = [0, 1, 2, 3, 4, 5, 6];

/** 图例的五档色块（0 = 空白档，一起画出来才看得出「没有颜色」也是一种档） */
const LEVELS: number[] = [0, 1, 2, 3, 4];

/**
 * 取不到格子时的替身。数据没加载完、或索引越界时用它顶上——
 * 这类绘制代码宁可画个空白格，也不能因为一个格子没取到就整页白屏。
 */
const EMPTY_DAY: HeatDayData = { day: 0, created: 0, done: 0, level: 0 };

/**
 * 深浅档位 → 颜色。0 档用专门的浅灰（heat_0），不能用卡片底色——
 * 两者同色的话空格子和卡片背景糊成一片，整面墙看着像没画出来（第一版就是这么翻车的）。
 */
function levelColor(level: number): Resource {
  if (level <= 0) {
    return $r('app.color.heat_0');
  }
  if (level === 1) {
    return $r('app.color.heat_1');
  }
  if (level === 2) {
    return $r('app.color.heat_2');
  }
  if (level === 3) {
    return $r('app.color.heat_3');
  }
  return $r('app.color.heat_4');
}

/** 月份标签：文字 + 这个月占几列（列数当 Row 里的权重用，宽度自动按比例分） */
interface MonthMark {
  text: string;
  cols: number;
}

@Entry
@Component
struct HeatmapPage {
  /** 数据库句柄：aboutToAppear 里初始化一次，之后只读 */
  private db: DbHelper | undefined = undefined;

  /** 是否读完：读的这几百毫秒里显示「加载中」，不显示一片空墙让人以为今年什么都没干 */
  @State loaded: boolean = false;

  /** 今年的热力图数据；null = 还没读出来 */
  @State hm: HeatmapData | null = null;

  /** 画的是哪一年。单独存一份：月份标签要造「今年 1 月 1 日」，而 hm.startDay 多半落在去年 12 月 */
  @State year: number = 0;

  /** 今天 0 点：给今天那格描个边，一屏三百多格里得知道自己在哪 */
  private today: number = startOfDay(Date.now());

  /** 格子边长（vp）。数据读完、知道有几列之后才算得出来，见 recalc */
  @State cellSize: number = 0;

  aboutToAppear(): void {
    this.load();
  }

  /**
   * 算格子边长：屏幕宽扣掉页面和卡片的内边距、星期标签、所有缝，剩下的平分给 cols 列。
   * 只信屏幕宽、不量容器（原因见文件头）。下限 2vp 是兜底：
   * 真到那一步说明屏比 53 格还窄，画出来是糊的，但绝不能是 0——
   * 宽高为 0 的组件 ArkUI 当它不存在，整面墙会凭空消失，比糊更糟。
   */
  private recalc(): void {
    const hm: HeatmapData | null = this.hm;
    if (hm === null) {
      return;
    }
    const screenW: number = px2vp(display.getDefaultDisplaySync().width);
    const usable: number = screenW - H_PADDING - WEEK_LABEL_W - CELL_GAP - (hm.cols - 1) * CELL_GAP;
    this.cellSize = Math.max(2, Math.floor(usable / hm.cols * 100) / 100);
  }

  private async load(): Promise<void> {
    try {
      const db: DbHelper = await DbHelper.getInstance(getContext(this));
      this.db = db;
      // 全部条目：含已勾掉的、含回收站里的。回顾过去时删掉的事也发生过，
      // 只统计「现在还在列表上的」会让上个月看起来很闲
      const active: EntryItem[] = await db.getAllActiveEntries();
      const deleted: EntryItem[] = await db.getDeletedEntries();
      const now: number = Date.now();
      this.year = new Date(now).getFullYear();
      this.hm = toHeatmap(active.concat(deleted), this.year, now);
      this.recalc();
    } catch (e) {
      hilog.error(0x0000, 'HeatmapPage', `读库失败: ${JSON.stringify(e)}`);
    }
    this.loaded = true;
  }

  /** 第 ci 列第 ri 行的格子；越界或没数据时给替身，绝不返回 undefined */
  private dayAt(ci: number, ri: number): HeatDayData {
    const hm: HeatmapData | null = this.hm;
    if (hm === null) {
      return EMPTY_DAY;
    }
    const idx: number = ci * 7 + ri;
    return idx >= 0 && idx < hm.days.length ? hm.days[idx] : EMPTY_DAY;
  }

  /** 列号数组 [0..cols-1]。ForEach 要数组，而列数是运行时才知道的 */
  private cols(): number[] {
    const hm: HeatmapData | null = this.hm;
    if (hm === null) {
      return [];
    }
    const out: number[] = [];
    for (let i = 0; i < hm.cols; i++) {
      out.push(i);
    }
    return out;
  }

  /**
   * 月份标签：从今年 1 月起每月一条，各自带上「占几列」。
   * 宽度交给 Row 按权重分（见 build），自己一格一格算像素是上一版的翻车点。
   */
  private monthMarks(): MonthMark[] {
    const hm: HeatmapData | null = this.hm;
    if (hm === null) {
      return [];
    }
    // 每个月第一天落在第几列：相对整年第一格的天数 ÷ 7
    const colOf: number[] = [];
    for (let m = 0; m < 12; m++) {
      const firstDay: number = startOfDay(new Date(this.year, m, 1).getTime());
      colOf.push(Math.round((firstDay - hm.startDay) / DAY_MS / 7));
    }
    const marks: MonthMark[] = [];
    for (let m = 0; m < 12; m++) {
      // 下个月的第一列就是本月的边界；12 月拿总列数当边界
      const next: number = m < 11 ? colOf[m + 1] : hm.cols;
      marks.push({ text: `${m + 1}月`, cols: Math.max(1, next - colOf[m]) });
    }
    return marks;
  }

  /** 今年一共记了多少、做了多少 */
  private summaryLine(): string {
    const hm: HeatmapData | null = this.hm;
    if (hm === null) {
      return '';
    }
    if (hm.totalCreated === 0 && hm.totalDone === 0) {
      return '今年还没有记录';
    }
    return `记了 ${hm.totalCreated} 条 · 完成 ${hm.totalDone} 条`;
  }

  /** 最忙的一天；一天都没动过时给空串，那一行不画 */
  private busiestLine(): string {
    const hm: HeatmapData | null = this.hm;
    if (hm === null || hm.busiest === null) {
      return '';
    }
    const b: HeatDayData = hm.busiest;
    return `最忙的一天 ${formatMonthDay(b.day)} · 动了 ${b.created + b.done} 次`;
  }

  build() {
    Column() {
      // 标题行：与设置页 / 课表页同一个版式，页与页之间不换花样
      Row() {
        Text('←')
          .fontSize(20)
          .fontColor($r('app.color.text_primary'))
          .padding(6)
          .onClick(() => {
            // 跳转走 UIContext 的 router：全局 router.back 已废弃
            this.getUIContext().getRouter().back();
          })
        Text('热力图')
          .fontSize(18)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 10, right: 16, top: 12 })

      Scroll() {
        Column({ space: 12 }) {
          // ── 摘要卡：数字先说清楚。格子小的时候全靠这几行字把意思兜住 ──
          Column() {
            Text(`${this.year} 年`)
              .fontSize(16)
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
            Text(this.loaded ? this.summaryLine() : '加载中…')
              .fontSize(13)
              .fontColor($r('app.color.text_body'))
              .margin({ top: 6 })
            if (this.busiestLine().length > 0) {
              Text(this.busiestLine())
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 4 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .borderRadius(12)
          .backgroundColor($r('app.color.bg_subtle'))

          // ── 格子墙 ──
          // 这张卡用白底（bg_card），不是摘要卡那种浅灰：空格子自己就是一种颜色（heat_0），
          // 画在浅灰卡上会跟底色糊在一起，得靠白底才衬得出来
          Column() {
            if (this.hm !== null) {
              // 月份标签行：每条宽度 = 该月占的列数 ×（格子 + 一道缝），
              // 于是每条正好盖住它那个月的格子，自然对齐
              Row() {
                ForEach(this.monthMarks(), (mk: MonthMark) => {
                  Text(mk.text)
                    .fontSize(10)
                    .fontColor($r('app.color.text_secondary'))
                    .width(mk.cols * (this.cellSize + CELL_GAP))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }, (mk: MonthMark) => `m${mk.text}_${mk.cols}`)
              }
              .width('100%')
              // 左边让出星期标签那一列（含它与格子之间那道缝），标签才落在格子上方
              .margin({ left: WEEK_LABEL_W + CELL_GAP, bottom: 4 })

              // 格子墙本体：左边一列星期标签，右边一周一列。
              // 为什么套一层 Stack 而不是把标签列放进 Row：放进去就得给标签列一个
              // height('100%')，而 Row 的高度又要靠格子的 aspectRatio 撑——两头互相等，
              // 结果是格子被压扁（实测七行挤成一条）。Stack 先把格子墙量完定高，
              // 再让标签列按那个高度撑满，顺序是定的，不打架。
              Stack({ alignContent: Alignment.TopStart }) {
                // 一列 = 一周。宽高都是算好的 cellSize，走确定的数，
                // 不依赖「先测量后分配」那套时序
                Row({ space: CELL_GAP }) {
                  ForEach(this.cols(), (ci: number) => {
                    Column({ space: CELL_GAP }) {
                      ForEach(ROW_INDEXES, (ri: number) => {
                        Column()
                          .width(this.cellSize)
                          .height(this.cellSize)
                          .borderRadius(2)
                          .backgroundColor(levelColor(this.dayAt(ci, ri).level))
                          // 今天描个边：三百多格里全是色块，不标一下找不到「现在」在哪
                          .borderWidth(this.dayAt(ci, ri).day === this.today ? 1 : 0)
                          .borderColor($r('app.color.text_secondary'))
                      }, (ri: number) => {
                        // level 和 cellSize 都进 key：数据后到、或格子大小变了，这一格要重画
                        const d: HeatDayData = this.dayAt(ci, ri);
                        return `d${d.day}_${d.level}_${this.cellSize}`;
                      })
                    }
                  }, (ci: number) => `c${ci}_${this.cellSize}`)
                }
                .padding({ left: WEEK_LABEL_W + CELL_GAP })

                // 星期标签：高度直接算出来（七格加六道缝），正好等于右边格子列的高度。
                // 不能用 height('100%')——那要等 Stack 先有高度，而 Stack 的高度又要等
                // 子元素，两头互等的结果是标签列按别处的尺寸撑开，把整堵墙顶得老高
                // （实测标签一格之间隔了 160vp，格子被甩在上面一小条里）
                Column({ space: CELL_GAP }) {
                  ForEach(ROW_INDEXES, (ri: number) => {
                    Text(ROW_LABELS[ri])
                      .fontSize(9)
                      .fontColor($r('app.color.text_secondary'))
                      .width('100%')
                      .layoutWeight(1)
                      .textAlign(TextAlign.Start)
                  }, (ri: number) => `lb${ri}`)
                }
                .width(WEEK_LABEL_W)
                .height(7 * this.cellSize + 6 * CELL_GAP)
              }
              .width('100%')
              .onAreaChange((oldValue: Area, newValue: Area): void => {
                // 只在屏幕 / 窗口尺寸变了时重算（旋转、分屏）。回调里的宽高不拿来用，
                // 它给的是布局中途的值；触发一下就够了，尺寸还是按屏幕宽自己算
                this.recalc();
              })

              // 图例：少 → 多。格子太小分不清深浅时，至少知道「深 = 忙」
              Row({ space: 4 }) {
                Blank()
                Text('少')
                  .fontSize(10)
                  .fontColor($r('app.color.text_secondary'))
                ForEach(LEVELS, (lv: number) => {
                  Column()
                    .width(10)
                    .height(10)
                    .borderRadius(2)
                    .backgroundColor(levelColor(lv))
                }, (lv: number) => `lg${lv}`)
                Text('多')
                  .fontSize(10)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .margin({ top: 8 })
            }
          }
          .width('100%')
          .padding(12)
          .borderRadius(12)
          .backgroundColor($r('app.color.bg_card'))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
