/**
 * 文件路径：entry/src/main/ets/pages/SearchPage.ets
 * 用途：搜索页——一个输入框 + 结果列表。
 *       搜标题和正文，范围覆盖全部条目（含已完成的和回收站里的），
 *       因为规格定的是「藏起来的东西也要能搜到」。
 * 职责纪律：与 Index 一致——数据库只在进页面时读一次并缓存，
 *       之后每次输入都只在这个缓存上过滤，不反复查库；build() 只做渲染。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { DbHelper } from '../data/DbHelper';
import { EntryItem } from '../data/Types';
import { SearchHit, searchEntries } from '../logic/SearchLogic';
import { displayTitle } from '../viewmodel/EntryDisplay';

@Entry
@Component
struct SearchPage {
  /** 全库条目缓存：进页面读一次，之后输入只在内存里过滤，不反复查库 */
  private allItems: EntryItem[] = [];

  /** 首次读库是否完成 */
  @State loaded: boolean = false;

  /** 输入框里的关键词（原样保留，归一化交给 SearchLogic） */
  @State keyword: string = '';

  @State hits: SearchHit[] = [];

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    try {
      const db: DbHelper = await DbHelper.getInstance(getContext(this));
      // 活跃条目（deleted=0，含已勾掉的）+ 回收站里的，一起搜：
      // 「已完成 / 归档的也要能搜到」是规格里明写的
      const active: EntryItem[] = await db.getAllActiveEntries();
      const deleted: EntryItem[] = await db.getDeletedEntries();
      this.allItems = active.concat(deleted);
      this.loaded = true;
      // 读库是异步的，输入框又带 defaultFocus：用户完全可能在读完之前就打了字，
      // 那一次过滤跑在空缓存上、结果必然是「没有找到」。这里补算一次，
      // 否则得再敲或删一个字符结果才出来，看着像搜不到。
      if (this.keyword.trim().length > 0) {
        this.hits = searchEntries(this.allItems, this.keyword, Date.now());
      }
    } catch (e) {
      hilog.error(0x0000, 'SearchPage', `搜索页读库失败: ${JSON.stringify(e)}`);
    }
  }

  /** 关键词变了：在已缓存的条目上重新过滤，不查库 */
  private onKeywordChange(value: string): void {
    this.keyword = value;
    this.hits = searchEntries(this.allItems, value, Date.now());
  }

  /** 顶栏：返回箭头 + 输入框 */
  @Builder
  topBar() {
    Row({ space: 6 }) {
      Text('‹')
        .fontSize(26)
        .fontColor($r('app.color.text_primary'))
        .padding({ left: 2, right: 4, top: 2, bottom: 2 })
        .onClick(() => {
          this.getUIContext().getRouter().back();
        })
      TextInput({ placeholder: '搜索标题和正文' })
        .placeholderColor($r('app.color.text_secondary'))
        .fontSize(15)
        .height(38)
        .borderRadius(10)
        .backgroundColor($r('app.color.bg_subtle'))
        .padding({ left: 12, right: 12 })
        .layoutWeight(1)
        .defaultFocus(true)
        .onChange((value: string) => {
          this.onKeywordChange(value);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 一行结果：标题 + 来源标签，下面跟一段正文摘要 */
  @Builder
  hitRow(hit: SearchHit) {
    Column() {
      Row() {
        Text(displayTitle(hit.item))
          .fontSize(15)
          // 已完成 / 回收站里的用灰字：一眼看出这是翻出来的旧东西，不是待办
          .fontColor(hit.item.done || hit.item.deleted ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(hit.sourceLabel)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 正文和标题是同一句时不重复显示（随手记常常只写了正文，标题为空）
      if (hit.snippet.length > 0 && hit.item.title.length > 0) {
        Text(hit.snippet)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
          .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(12)
    .backgroundColor($r('app.color.bg_subtle'))
    .width('100%')
  }

  /** 空状态提示：与主界面同款灰字，绝不露假数据 */
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

  build() {
    Column() {
      this.topBar()
      // 结果区：只有这一块滚动，输入框钉在上面
      Scroll() {
        Column({ space: 8 }) {
          if (this.keyword.trim().length === 0) {
            this.emptyHint('输入关键词，搜标题和正文')
          } else if (this.loaded && this.hits.length === 0) {
            this.emptyHint('没有找到')
          }
          ForEach(this.hits, (hit: SearchHit) => {
            this.hitRow(hit)
          }, (hit: SearchHit): string => hit.item.id)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .margin({ top: 12 })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .backgroundColor($r('app.color.bg_page'))
    .alignItems(HorizontalAlign.Start)
  }
}
