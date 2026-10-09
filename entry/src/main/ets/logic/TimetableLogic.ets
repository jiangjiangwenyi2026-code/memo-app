/**
 * 文件路径：entry/src/main/ets/logic/TimetableLogic.ets
 * 用途：课表展开的纯逻辑——把「按周重复的课表规则」展开成「某一天实际要上的课」。
 *       只做计算，不碰数据库、不碰界面；调休（例外日）在展开时一并处理。
 */

import { TimetableRule, TimetableException } from '../data/Types';

/**
 * 一节课在某一天的具体实例。规则是「每周几第几节有课」的模板，
 * 展开后才是「X 月 X 日 08:00 这节课」，两者是一对多的关系，
 * 所以展开结果不能复用 TimetableRule，得有自己的轻量结构。
 */
export interface TimetableOccurrence {
  /** 来自哪条规则。生成条目时写进 sourceRef，改课表后才能反向找到源头 */
  ruleId: string;
  /** 哪一天（当天 0 点的毫秒时间戳），即入参 dayStart */
  date: number;
  /** 课名 */
  name: string;
  /** 教室 */
  location: string;
  /** 第几节开始 */
  periodFrom: number;
  /** 第几节结束，连堂算一条不拆 */
  periodTo: number;
  /** 上课时间，如 "08:00"，卡片直接显示 */
  timeStart: string;
}

/** 一天的毫秒数，用于把「距学期开始的毫秒差」换算成周次 */
const DAY_MS: number = 24 * 60 * 60 * 1000;

/** 一周的毫秒数 */
const WEEK_MS: number = 7 * DAY_MS;

/**
 * 算某一天实际要上哪些课。
 *
 * 为什么要单独一个「按天展开」的函数：课表存的是规则，而「近期」展示、
 * 生成当天条目都只关心某一天，逐天展开可以让调用方不必一次性物化整个学期。
 *
 * 判定顺序有意是「例外优先」：调休日（如国庆补班、节假日）是对规则的
 * 整体覆盖，先看例外再筛规则，才能保证「这天不上课」压过一切规则、
 * 「这天改上星期 X 的课」用替代星期几去筛，而不是用自然历的星期几。
 *
 * @param rules          课表规则全集（是否已过滤由调用方决定）
 * @param exceptions     课表例外全集，只查 date === dayStart 的一条
 * @param dayStart       要展开的那天（当天 0 点的毫秒时间戳）
 * @param semesterStart  学期第一天（当天 0 点的毫秒时间戳），周次的基准
 * @param firstWeekIsOdd 第 1 周算不算单周，决定单双周与周次奇偶的对应关系
 * @returns 那天的课，按 periodFrom 升序；无课返回空数组
 */
export function expandDay(
  rules: TimetableRule[],
  exceptions: TimetableException[],
  dayStart: number,
  semesterStart: number,
  firstWeekIsOdd: boolean
): TimetableOccurrence[] {
  let weekday: number = weekdayOf(dayStart);

  // 例外先于规则：noClass 直接整天空，useWeekday 换掉星期几再筛规则
  const exception: TimetableException | undefined = findExceptionAt(exceptions, dayStart);
  if (exception !== undefined) {
    if (exception.type === 'noClass') {
      return [];
    }
    if (exception.type === 'useWeekday' && exception.weekday !== null) {
      weekday = exception.weekday;
    }
  }

  const weekNo: number = Math.floor((dayStart - semesterStart) / WEEK_MS) + 1;
  // 单双周不直接等于周次奇偶：第 1 周可以是单周也可以是双周（看学校），
  // firstWeekIsOdd 就是这个「错位」开关
  const isOddWeek: boolean = firstWeekIsOdd ? (weekNo % 2 === 1) : (weekNo % 2 === 0);

  const result: TimetableOccurrence[] = [];
  for (const rule of rules) {
    if (rule.weekday !== weekday) {
      continue;
    }
    if (rule.weeks === 'odd' && !isOddWeek) {
      continue;
    }
    if (rule.weeks === 'even' && isOddWeek) {
      continue;
    }
    if (weekNo < rule.weekFrom || weekNo > rule.weekTo) {
      continue;
    }
    const occurrence: TimetableOccurrence = {
      ruleId: rule.id,
      date: dayStart,
      name: rule.name,
      location: rule.location,
      periodFrom: rule.periodFrom,
      periodTo: rule.periodTo,
      timeStart: rule.timeStart
    };
    result.push(occurrence);
  }

  // 规则的传入顺序不保证按节次排，展示前必须自己排；复制后排序，不动入参数组
  const sorted: TimetableOccurrence[] = result.slice(0);
  sorted.sort((a: TimetableOccurrence, b: TimetableOccurrence): number => a.periodFrom - b.periodFrom);
  return sorted;
}

/**
 * 由 0 点时间戳求星期几（1=周一 … 7=周日）。
 * 之所以不用 getDay() 的原始值：它以 0=周日，和课表「1=周一」的约定错一位，
 * 在这一处换算掉，调用方就不用各自记这个坑。
 */
function weekdayOf(dayStart: number): number {
  const day: number = new Date(dayStart).getDay();
  return day === 0 ? 7 : day;
}

/** 在例外列表里找落在 dayStart 这一天的那条；同一天多条属于脏数据，取第一条即可 */
function findExceptionAt(exceptions: TimetableException[], dayStart: number): TimetableException | undefined {
  for (const exception of exceptions) {
    if (exception.date === dayStart) {
      return exception;
    }
  }
  return undefined;
}
