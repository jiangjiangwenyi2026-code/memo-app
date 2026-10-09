/**
 * 文件路径：entry/src/main/ets/logic/SearchLogic.ets
 * 用途：搜索的纯匹配逻辑——判断命不命中、截正文摘要、打来源标签、排序。
 *       只做计算，不碰数据库、不碰界面。
 */

import { EntryItem } from '../data/Types';
import { DAY_MS, startOfDay } from '../viewmodel/EntryDisplay';
import { isOverdue } from './SectionLogic';

/** 结果行里正文摘要最多显示多少个字 */
const SNIPPET_LEN: number = 48;

/** 一条搜索结果 */
export interface SearchHit {
  /** 命中的条目 */
  item: EntryItem;
  /** 来源标签：已完成 / 回收站 / 今天 / 明天 / 过期 / 长期 / 随手记 / 具体日期 */
  sourceLabel: string;
  /** 正文摘要：从命中位置附近截的片段；正文为空时为空串 */
  snippet: string;
  /** 是不是标题命中。标题命中比只在正文里命中更相关，排序时排前面 */
  titleHit: boolean;
}

/** 关键词归一化：去首尾空白 + 统一小写，让搜索对大小写不敏感 */
export function normalizeKeyword(raw: string): string {
  return raw.trim().toLowerCase();
}

/**
 * 一条条目是否命中关键词：标题或正文包含即算命中。
 * 关键词为空一律不命中——调用方靠这条避免空串把全库都捞出来。
 */
export function matchesKeyword(item: EntryItem, kw: string): boolean {
  if (kw.length === 0) {
    return false;
  }
  if (item.title.toLowerCase().includes(kw)) {
    return true;
  }
  return item.body.toLowerCase().includes(kw);
}

/**
 * 正文摘要：从命中位置附近截一段。
 * 关键词出现在正文很靠后的位置时，直接显示开头等于什么都没显示，
 * 要把命中点截进摘要里，用户才看得出「这条为什么被搜出来」。
 */
export function snippetOf(text: string, kw: string): string {
  if (text.length <= SNIPPET_LEN) {
    return text;
  }
  const at: number = text.toLowerCase().indexOf(kw);
  if (at < 0) {
    return `${text.substring(0, SNIPPET_LEN)}…`;
  }
  // 命中点往前留一点上下文，让关键词大致落在摘要中间
  let start: number = at - Math.floor((SNIPPET_LEN - kw.length) / 2);
  if (start < 0) {
    start = 0;
  }
  let end: number = start + SNIPPET_LEN;
  if (end > text.length) {
    end = text.length;
    start = Math.max(0, end - SNIPPET_LEN);
  }
  const head: string = start > 0 ? '…' : '';
  const tail: string = end < text.length ? '…' : '';
  return `${head}${text.substring(start, end)}${tail}`;
}

/**
 * 条目的来源标签。搜索结果是跨区混在一起的，必须标出这条原本在哪儿，
 * 不然「已完成的事」和「今天的事」混在一列里分不出来。
 */
export function sourceLabelOf(item: EntryItem, now: number): string {
  if (item.deleted) {
    return '回收站';
  }
  if (item.done) {
    return '已完成';
  }
  if (item.startDate !== null) {
    return '长期';
  }
  const dateMs: number | null = item.date;
  if (dateMs === null) {
    return '随手记';
  }
  const todayStart: number = startOfDay(now);
  // 与主页同一口径（复用 isOverdue）：有截止时刻的比时刻、没有的比日期。
  // 只看日期的话，一条今天 18:00 截止的事过了 18:00，在主页已经标着「过期」，
  // 搜出来却还写「今天」——用户会以为搜索出了错
  if (isOverdue(item, now)) {
    return '过期';
  }
  if (dateMs === todayStart) {
    return '今天';
  }
  if (dateMs === startOfDay(now + DAY_MS)) {
    return '明天';
  }
  const d: Date = new Date(dateMs);
  return `${d.getMonth() + 1}/${d.getDate()}`;
}

/**
 * 搜索：过滤命中项、打标签、截摘要、排序。
 * 排序：标题命中的排在只正文命中的前面；同组内最近改动的在前。
 * @param items 待搜条目（是否含回收站里的由调用方决定）
 * @param rawKeyword 用户输入的原样关键词
 * @param now 当前毫秒时间戳
 * @returns 命中的结果；关键词为空时返回空数组
 */
export function searchEntries(items: EntryItem[], rawKeyword: string, now: number): SearchHit[] {
  const kw: string = normalizeKeyword(rawKeyword);
  if (kw.length === 0) {
    return [];
  }
  const hits: SearchHit[] = [];
  for (const item of items) {
    if (!matchesKeyword(item, kw)) {
      continue;
    }
    hits.push({
      item: item,
      sourceLabel: sourceLabelOf(item, now),
      snippet: snippetOf(item.body, kw),
      titleHit: item.title.toLowerCase().includes(kw)
    });
  }
  hits.sort((a: SearchHit, b: SearchHit): number => {
    if (a.titleHit !== b.titleHit) {
      return a.titleHit ? -1 : 1;
    }
    return b.item.updatedAt - a.item.updatedAt;
  });
  return hits;
}
