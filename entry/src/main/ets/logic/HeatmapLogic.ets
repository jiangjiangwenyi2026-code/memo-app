/**
 * 文件路径：entry/src/main/ets/logic/HeatmapLogic.ets
 * 用途：年度热力图的数据层。把库里的条目按「天」归堆，供热力图那一屏画格子。
 * 口径：一格 = 一天，颜色深浅看这天的**动作次数** = 当天记了几条 + 当天完成了几条。
 *       为什么把两件事加在一起：这面墙回答的是「这天我在备忘录里动了几次手」，
 *       记下来和做完都是动作；只算完成数的话，忙着一堆事但还没勾完的日子会一片空白，
 *       只算新建数又看不出「做完了没有」。详情里两个数分开给（见 HeatDayData）。
 * 什么不算：课表条目和长期任务到期自动生成的条目，它们的 createdAt 是系统展开出来的，
 *       不是用户动作——不排掉的话每天上课都算「你今天记了 5 条」，整面墙全是噪声。
 *       但**完成**不分来源：勾掉一节课也是动手了，照算。
 */

import { EntryItem } from '../data/Types';
import { startOfDay } from '../viewmodel/EntryDisplay';

const DAY_MS: number = 24 * 60 * 60 * 1000;

/**
 * 深浅分档的阈值（上限，含）。四档加一个空格，和 GitHub 那面墙一样分五级。
 * 1 条就上色：这面墙是给自己看的，一天只做了一件事也值得留个印子。
 */
const LEVEL_1_MAX: number = 1;
const LEVEL_2_MAX: number = 3;
const LEVEL_3_MAX: number = 6;

/** 热力图里的一格 = 一天 */
export interface HeatDayData {
  /** 那天 0 点的毫秒时间戳 */
  day: number;
  /** 那天记了几条（只算手写的） */
  created: number;
  /** 那天完成了几条（不分来源） */
  done: number;
  /** 深浅档位 0-4；0 = 那天什么都没干，画底色 */
  level: number;
}

/** 一整年的热力图数据 */
export interface HeatmapData {
  /** 第一格那天，即 1 月 1 日所在那一周的周一（可能落在去年 12 月） */
  startDay: number;
  /** 列数 = 周数，通常 53 */
  cols: number;
  /**
   * 全年格子，长度 = cols × 7，按时间顺序一列一列排。
   * 两头的跨年周也在里面（那些天不属于这一年，永远是空的）：
   * 留着是为了让每一列都满 7 格，画的时候不用判「这列缺了几格」。
   */
  days: HeatDayData[];
  /** 今年记了多少条 */
  totalCreated: number;
  /** 今年完成了多少条 */
  totalDone: number;
  /** 今年最忙的那天（动作最多）；一天都没动过时为 null */
  busiest: HeatDayData | null;
}

/** 动作次数 → 深浅档位 */
function levelOf(count: number): number {
  if (count <= 0) {
    return 0;
  }
  if (count <= LEVEL_1_MAX) {
    return 1;
  }
  if (count <= LEVEL_2_MAX) {
    return 2;
  }
  if (count <= LEVEL_3_MAX) {
    return 3;
  }
  return 4;
}

/**
 * 这一年第一格是哪天：1 月 1 日所在那一周的周一。
 * 周一打头（不是周日）：国人看星期从周一数起，热力图左边第一行是「一」才对得上。
 */
function yearStartMonday(year: number): number {
  const jan1: number = startOfDay(new Date(year, 0, 1).getTime());
  // getDay() 里周日是 0，换成「周一 = 0」的排法才是往回退的天数
  const weekday: number = new Date(jan1).getDay();
  const back: number = (weekday + 6) % 7;
  return jan1 - back * DAY_MS;
}

/**
 * 这一年铺满整周要几列。末尾那周不满也要占一整列，所以是「首尾相差的天数 ÷ 7 向上取整」。
 * 直接用 (endDay - startDay) / DAY_MS / 7 会差一列：算的是间隔不是天数，
 * 而格子数是天数（首尾都算）。2026 年正好 53 列。
 */
function weekColsOf(startDay: number, year: number): number {
  const dec31: number = new Date(year, 11, 31).getTime();
  const weekday: number = new Date(dec31).getDay();
  const forward: number = 7 - ((weekday + 6) % 7) - 1;
  const endDay: number = startOfDay(dec31) + forward * DAY_MS;
  return Math.round(((endDay - startDay) / DAY_MS + 1) / 7);
}

/**
 * 时间戳落在第几格；不在今年（含跨年周里属于别年的那几天）返回 -1。
 * 判年份用日历年份而不是格子范围：跨年周那几格虽然画得出来，
 * 但把去年 12 月 30 日记的事算进今年的墙，摘要数字就对不上了。
 */
function dayIndexOf(ts: number, startDay: number, year: number, cellCount: number): number {
  if (new Date(ts).getFullYear() !== year) {
    return -1;
  }
  const idx: number = Math.round((startOfDay(ts) - startDay) / DAY_MS);
  return idx >= 0 && idx < cellCount ? idx : -1;
}

/**
 * 算出这一年的热力图数据。
 * @param items 全部条目，**含已勾掉和回收站里的**：回顾过去时，删掉的事也发生过
 * @param year  画哪一年（调用方给当前年份）
 * @param now   当前时刻，只用来判「今天」是哪一格（由页面另画描边，这里不参与）
 */
export function toHeatmap(items: EntryItem[], year: number, now: number): HeatmapData {
  const startDay: number = yearStartMonday(year);
  const cols: number = weekColsOf(startDay, year);
  const cellCount: number = cols * 7;
  const days: HeatDayData[] = [];
  for (let i = 0; i < cellCount; i++) {
    days.push({ day: startDay + i * DAY_MS, created: 0, done: 0, level: 0 });
  }

  let totalCreated: number = 0;
  let totalDone: number = 0;
  for (const item of items) {
    // 记：只认手写的（原因见文件头。课表 / 长期任务自动生成的两类都排除）
    if (item.source === 'manual') {
      const ci: number = dayIndexOf(item.createdAt, startDay, year, cellCount);
      if (ci >= 0) {
        days[ci].created++;
        totalCreated++;
      }
    }
    // 做：不分来源，勾了就是做了
    const doneAt: number | null = item.doneAt;
    if (item.done && doneAt !== null) {
      const di: number = dayIndexOf(doneAt, startDay, year, cellCount);
      if (di >= 0) {
        days[di].done++;
        totalDone++;
      }
    }
  }

  let busiest: HeatDayData | null = null;
  for (const d of days) {
    d.level = levelOf(d.created + d.done);
    if (d.level === 0) {
      continue;
    }
    // 平手时留先遇到的那天（也就是较早的）：说「最忙的一天」时指向更早的那次更有意义
    if (busiest === null || d.created + d.done > busiest.created + busiest.done) {
      busiest = d;
    }
  }

  return {
    startDay: startDay,
    cols: cols,
    days: days,
    totalCreated: totalCreated,
    totalDone: totalDone,
    busiest: busiest
  };
}

/**
 * 日期 → 「9月28日」。热力图页的摘要行和格子详情用，
 * 与新建弹窗的中文日期风格一致（那里带年份，这里一年只在顶上写一次年份，格子里不必重复）。
 */
export function formatMonthDay(ts: number): string {
  const d: Date = new Date(ts);
  return `${d.getMonth() + 1}月${d.getDate()}日`;
}
