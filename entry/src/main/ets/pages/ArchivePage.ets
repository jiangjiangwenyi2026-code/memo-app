/**
 * 文件路径：entry/src/main/ets/pages/ArchivePage.ets
 * 用途：归档页——「已完成」和「回收站」两块放在一起。
 *       「已完成」= 勾掉的条目 + 过期满 7 天自动退场的条目（规格：满 7 天后进「已完成」隐藏）；
 *       「回收站」= 软删除（deleted=1）的条目，能恢复，也能彻底删除。
 * 职责纪律：与 Index 一致——数据库调用只出现在生命周期 / 点击回调里，build() 只做渲染；
 *       每次操作后全量重读，不做局部增删修补。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { DbHelper } from '../data/DbHelper';
import { EntryItem } from '../data/Types';
import { isOverdueArchived } from '../logic/SectionLogic';
import { pushCard } from '../logic/CardPush';
import { DAY_MS, displayTitle, startOfDay } from '../viewmodel/EntryDisplay';

/** 归档页列表里的一行 */
interface ArchiveRowData {
  id: string;
  title: string;
  /** 副标题：完成于 / 逾期多少天 / 删除于 */
  subText: string;
  /** 排序用的时间戳，列表按它降序 */
  ts: number;
}

@Entry
@Component
struct ArchivePage {
  private db: DbHelper | undefined = undefined;

  /** 首次读库是否完成：没加载完不显示空状态，避免闪一句误导性的提示 */
  @State loaded: boolean = false;

  /** 当前分段：'done' 已完成 / 'trash' 回收站 */
  @State tab: string = 'done';

  @State doneRows: ArchiveRowData[] = [];
  @State trashRows: ArchiveRowData[] = [];

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    try {
      this.db = await DbHelper.getInstance(getContext(this));
      await this.refresh();
    } catch (e) {
      hilog.error(0x0000, 'ArchivePage', `归档页读库失败: ${JSON.stringify(e)}`);
    }
  }

  /** 重读两块列表。已完成和回收站各一次查询，互不干扰 */
  private async refresh(): Promise<void> {
    const db = this.db;
    if (db === undefined) {
      return;
    }
    try {
      const now: number = Date.now();
      const todayStart: number = startOfDay(now);

      // ── 已完成：从「未删除」的集合里挑两类 ──
      // 一类是用户勾掉的，另一类是过期太久自动退场的（规格：满 7 天后进「已完成」隐藏）
      const active: EntryItem[] = await db.getAllActiveEntries();
      const doneRows: ArchiveRowData[] = [];
      for (const item of active) {
        if (item.done) {
          const at: number = item.doneAt !== null ? item.doneAt : item.updatedAt;
          doneRows.push({
            id: item.id,
            title: displayTitle(item),
            subText: `完成于 ${formatDay(at)}`,
            ts: at
          });
        } else if (isOverdueArchived(item, now)) {
          const date: number = item.date !== null ? item.date : todayStart;
          const days: number = Math.max(1, Math.floor((todayStart - date) / DAY_MS));
          doneRows.push({
            id: item.id,
            title: displayTitle(item),
            subText: `${formatDay(date)} 到期 · 已逾期 ${days} 天`,
            ts: date
          });
        }
      }
      doneRows.sort((a: ArchiveRowData, b: ArchiveRowData): number => b.ts - a.ts);

      // ── 回收站：软删除的条目，最近删的排最前 ──
      const deleted: EntryItem[] = await db.getDeletedEntries();
      const trashRows: ArchiveRowData[] = [];
      for (const item of deleted) {
        trashRows.push({
          id: item.id,
          title: displayTitle(item),
          subText: `删除于 ${formatDay(item.updatedAt)}`,
          ts: item.updatedAt
        });
      }
      trashRows.sort((a: ArchiveRowData, b: ArchiveRowData): number => b.ts - a.ts);

      this.doneRows = doneRows;
      this.trashRows = trashRows;
      this.loaded = true;
    } catch (e) {
      hilog.error(0x0000, 'ArchivePage', `归档页刷新失败: ${JSON.stringify(e)}`);
    }
  }

  /** 已完成 → 删除：走软删进回收站，还能找回（找回时勾也会一并撤掉，见 restore） */
  private async moveToTrash(id: string): Promise<void> {
    const db = this.db;
    if (db === undefined) {
      return;
    }
    try {
      await db.softDeleteEntry(id);
      await this.refresh();
      // 条目进出回收站都会改变桌面上看得见的内容，推一把卡片；
      // 用户很可能从这一页直接按 Home 回桌面，不推的话卡片会一直停在旧内容上
      pushCard(getContext(this), db);
    } catch (e) {
      hilog.error(0x0000, 'ArchivePage', `移入回收站失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '移入回收站失败，请重试' });
    }
  }

  /**
   * 回收站 → 恢复：清掉软删标记，条目回到主界面。
   * 从「已完成」删进来的那些同时会被撤掉勾（restoreEntry 里一并清 done），
   * 否则它带着勾回去，主界面按勾过滤不放它出来，一按恢复就跳回「已完成」，像是没反应。
   */
  private async restore(id: string): Promise<void> {
    const db = this.db;
    if (db === undefined) {
      return;
    }
    try {
      await db.restoreEntry(id);
      await this.refresh();
      // 条目进出回收站都会改变桌面上看得见的内容，推一把卡片；
      // 用户很可能从这一页直接按 Home 回桌面，不推的话卡片会一直停在旧内容上
      pushCard(getContext(this), db);
    } catch (e) {
      hilog.error(0x0000, 'ArchivePage', `恢复条目失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '恢复失败，请重试' });
    }
  }

  /**
   * 回收站 → 彻底删除：先弹确认框。
   * 物理删除不可逆，绝不能让一次误触就把内容抹掉，这一步是必须的。
   */
  private confirmHardDelete(row: ArchiveRowData): void {
    this.getUIContext().showAlertDialog({
      title: '彻底删除',
      message: `「${row.title}」删掉就找不回来了，确定吗？`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.danger_alt'),
        action: () => {
          this.hardDelete(row.id);
        }
      }
    });
  }

  private async hardDelete(id: string): Promise<void> {
    const db = this.db;
    if (db === undefined) {
      return;
    }
    // 物理删除不可逆，失败提示更不能省：用户以为删干净了、其实还在，
    // 或者反过来以为没删掉又去删一次，两种都不好
    try {
      await db.hardDeleteEntry(id);
      await this.refresh();
      // 条目进出回收站都会改变桌面上看得见的内容，推一把卡片；
      // 用户很可能从这一页直接按 Home 回桌面，不推的话卡片会一直停在旧内容上
      pushCard(getContext(this), db);
    } catch (e) {
      hilog.error(0x0000, 'ArchivePage', `彻底删除失败: ${JSON.stringify(e)}`);
      this.getUIContext().getPromptAction().showToast({ message: '删除失败，请重试' });
    }
  }

  /** 顶栏：一个返回箭头 + 页面标题 */
  @Builder
  topBar() {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor($r('app.color.text_primary'))
        .padding({ left: 2, right: 12, top: 2, bottom: 2 })
        .onClick(() => {
          this.getUIContext().getRouter().back();
        })
      Text('归档')
        .fontSize(18)
        .fontColor($r('app.color.text_primary'))
        .fontWeight(FontWeight.Medium)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 分段切换：「已完成」/「回收站」 */
  @Builder
  tabBar() {
    Row({ space: 20 }) {
      this.tabButton('已完成', 'done')
      this.tabButton('回收站', 'trash')
    }
    .width('100%')
    .margin({ top: 14 })
  }

  /** 单个分段按钮：选中态加粗变深，下面垫一根短横线 */
  @Builder
  tabButton(label: string, value: string) {
    Column() {
      Text(label)
        .fontSize(15)
        .fontColor(this.tab === value ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
        .fontWeight(this.tab === value ? FontWeight.Medium : FontWeight.Normal)
      // 短横线比整条边框轻，和主界面的细线风格保持一致
      Column()
        .width(24)
        .height(2)
        .margin({ top: 6 })
        .backgroundColor(this.tab === value ? $r('app.color.button_primary_bg') : '#00000000')
    }
    .onClick(() => {
      this.tab = value;
    })
  }

  /** 一行归档条目：左边标题 + 副标题，右边按当前分段给操作 */
  @Builder
  archiveRow(row: ArchiveRowData) {
    Row({ space: 8 }) {
      Column() {
        Text(row.title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
        Text(row.subText)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.tab === 'done') {
        Text('删除')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 8, right: 2, top: 6, bottom: 6 })
          .onClick(() => {
            this.moveToTrash(row.id);
          })
      } else {
        Text('恢复')
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .padding({ left: 8, right: 2, top: 6, bottom: 6 })
          .onClick(() => {
            this.restore(row.id);
          })
        Text('彻底删除')
          .fontSize(13)
          .fontColor($r('app.color.danger_alt'))
          .padding({ left: 8, right: 2, top: 6, bottom: 6 })
          .onClick(() => {
            this.confirmHardDelete(row);
          })
      }
    }
    .alignItems(VerticalAlign.Center)
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
      this.tabBar()
      // 列表区：只有这一块滚动，顶栏和分段钉在上面
      Scroll() {
        Column({ space: 8 }) {
          if (this.tab === 'done') {
            if (this.loaded && this.doneRows.length === 0) {
              this.emptyHint('还没有完成的事')
            }
            ForEach(this.doneRows, (row: ArchiveRowData) => {
              this.archiveRow(row)
            }, (row: ArchiveRowData): string => row.id)
          } else {
            if (this.loaded && this.trashRows.length === 0) {
              this.emptyHint('回收站是空的')
            }
            ForEach(this.trashRows, (row: ArchiveRowData) => {
              this.archiveRow(row)
            }, (row: ArchiveRowData): string => row.id)
          }
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

/**
 * 天级日期文案（如 "9/23"）。归档页只关心是哪天，不显示时分——
 * 这层信息密度已经够低，再标到分钟反而啰嗦。
 */
function formatDay(ts: number): string {
  const d: Date = new Date(ts);
  return `${d.getMonth() + 1}/${d.getDate()}`;
}
