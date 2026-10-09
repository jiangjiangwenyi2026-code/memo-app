/**
 * 文件路径：entry/src/main/ets/logic/DragReorder.ets
 * 用途：拖拽落定后的重排计算——算出「哪些条目要改成什么样」，但不写库。
 *       写库由页面负责，这样这段逻辑是纯计算，能脱离界面单独验证。
 * 注意：本函数**会直接修改传入的 EntryItem 对象**（date / sortOrder / updatedAt），
 *       调用方传进来的数组应当是刚从库里读出来、不会被别处复用的。
 */

import { EntryItem } from '../data/Types';
import { sameTimeOnDay } from '../viewmodel/EntryDisplay';

/** 重排时相邻两条 sortOrder 的步长：留足空隙，以后插一条不用整体重排 */
const ORDER_STEP: number = 1000;

/**
 * 计算把 srcId 拖到目标位置之后，需要写库的条目列表。
 * @param all     全部有效条目（页面已经过滤掉 deleted 的）
 * @param srcId   被拖动的条目 id
 * @param dstId   落点目标条目 id；null = 落到目标段的末尾
 * @param dstDate 落点所在段的日期（归一化到 0 点的毫秒时间戳）；null = 随手记（无日期）
 * @param now     当前毫秒时间戳
 * @returns 需要写库的条目（含被改动的 src 自己）；无可改动时返回空数组
 */
export function planReorder(
  all: EntryItem[],
  srcId: string,
  dstId: string | null,
  dstDate: number | null,
  now: number
): EntryItem[] {
  const src: EntryItem | undefined = all.find((e: EntryItem): boolean => e.id === srcId);
  // 只有手写条目能拖。课表条目由规则生成；长期任务派生的待办改了 date 会击穿
  // DailyRollover 的幂等闸门（按 source + sourceRef + date 判重），今天再启动会重复生成。
  // 拖拽入口本来就没给这两类，这里是第二道闸，防止调用方漏判。
  if (src === undefined || src.source !== 'manual') {
    return [];
  }

  // 无准备期的长期任务（开始日 = 截止日）拖着改日期时，开始日必须跟着一起搬：
  // 不搬的话，把今天的事拖到明天，「开始日 今天 / 截止日 明天」就凭空有了准备期，
  // 甘特上冒出一根横条——用户只是挪了一天，不该多出一段准备期。
  // 必须在 src.date = dstDate 之前判：判据是「两个日期原本相等」。
  const noPrep: boolean = src.startDate !== null && src.startDate === src.date;
  // 换类：落点所在段的日期就是这条的新日期（null 即变随手记）。
  src.date = dstDate;
  // 拖回随手记 = 变回无日期，startDate 必须一起清掉。甘特上的长期任务恰恰带 startDate，
  // 而它的横条现在也能拖回随手记；留着就成了悬空值——条目已经没有截止日，
  // 「从哪天开始准备」无从谈起，之后再拖回时间轴时旧开始日还会悄悄复活。
  if (dstDate === null) {
    src.startDate = null;
  } else if (noPrep) {
    src.startDate = dstDate;
  }
  // 截止时刻必须跟着日期一起搬：dueTime 是绝对时间戳，只改 date 会让它悬空——
  // 拖到明天的那条一到今天的 18:00 就掉进过期段（还标「逾期 N 天」，日期明明
  // 是明天）；拖回随手记时 dueTime 还留着，同一条会同时出现在「随手记」列
  // 和「过期」段里，一份内容显示两次
  src.dueTime = dstDate === null ? null : sameTimeOnDay(src.dueTime, dstDate);
  src.updatedAt = now;

  // 目标桶：落在同一个日期下的其余条目。课表条目和长期任务派生的待办也要收进来：
  // 它们自己不能拖（拖拽入口就没给），但必须能当落点——规格明写「手写条目可以拖到
  // 课表前面或两节课之间」，落点若是课表条目而它不在桶里，findIndex 就找不到，
  // 条目只能落到末尾，看上去像拖拽没生效。
  const bucket: EntryItem[] = all.filter((e: EntryItem): boolean =>
    e.id !== srcId && e.date === dstDate);

  // 按当前顺序排好，才知道该插到第几格
  bucket.sort((a: EntryItem, b: EntryItem): number => {
    if (a.sortOrder !== b.sortOrder) {
      return a.sortOrder - b.sortOrder;
    }
    return a.createdAt - b.createdAt;
  });

  // 落点：有目标就插到它前面；目标不在这个桶里（比如拖到了课上）或没给目标，就落到末尾
  let insertAt: number = bucket.length;
  if (dstId !== null) {
    const at: number = bucket.findIndex((e: EntryItem): boolean => e.id === dstId);
    if (at >= 0) {
      insertAt = at;
    }
  }
  bucket.splice(insertAt, 0, src);

  // 整桶重排成 1000 / 2000 / 3000…。一次把顺序写死，比「只挪一条的相对位置」
  // 省心得多：不用关心旧值有多稀疏、会不会撞上。
  const changed: EntryItem[] = [];
  for (let i = 0; i < bucket.length; i++) {
    const item: EntryItem = bucket[i];
    const want: number = (i + 1) * ORDER_STEP;
    // src 一定要收进去——它的 date 变了，哪怕 sortOrder 碰巧没变也得写库
    if (item.sortOrder !== want || item.id === srcId) {
      item.sortOrder = want;
      item.updatedAt = now;
      changed.push(item);
    }
  }
  return changed;
}

/**
 * 甘特上上下拖动的重排：把 srcId 挪到 dstId 那一行的位置。
 * 只改 ganttOrder —— 甘特上的上下拖是调甘特自己的顺序，跟列表用的 sortOrder 无关，
 * date / startDate / dueTime 更是一个都不碰。
 * @param ganttItems 甘特上当前显示的那些条目，**已按当前显示顺序排好**（调用方负责）
 * @param srcId      被拖动的条目 id
 * @param dstId      落点那一行的条目 id
 * @param now        当前毫秒时间戳
 * @returns 需要写库的条目；无可改动时返回空数组
 */
export function planGanttReorder(
  ganttItems: EntryItem[],
  srcId: string,
  dstId: string,
  now: number
): EntryItem[] {
  const src: EntryItem | undefined = ganttItems.find((e: EntryItem): boolean => e.id === srcId);
  // 只有手写条目能排；没真挪动（落点就是自己）也直接返回
  if (src === undefined || src.source !== 'manual' || srcId === dstId) {
    return [];
  }
  const from: number = ganttItems.findIndex((e: EntryItem): boolean => e.id === srcId);
  const to: number = ganttItems.findIndex((e: EntryItem): boolean => e.id === dstId);
  if (from < 0 || to < 0) {
    return [];
  }
  const ordered: EntryItem[] = ganttItems.slice();
  ordered.splice(from, 1);
  // 摘掉 src 之后，原本排在它后面的元素下标都往前挪了一格
  ordered.splice(from < to ? to - 1 : to, 0, src);

  // 整段重编号成 1000 / 2000 / 3000…：把甘特上这几条的相对顺序一次写死。
  // 只写 ganttOrder，别的一律不动；没参与拖动的条目之间相对顺序不会变
  const changed: EntryItem[] = [];
  for (let i = 0; i < ordered.length; i++) {
    const item: EntryItem = ordered[i];
    const want: number = (i + 1) * ORDER_STEP;
    if (item.ganttOrder !== want) {
      item.ganttOrder = want;
      item.updatedAt = now;
      changed.push(item);
    }
  }
  return changed;
}
