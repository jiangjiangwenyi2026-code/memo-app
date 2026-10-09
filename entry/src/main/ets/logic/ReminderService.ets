/**
 * 文件路径：entry/src/main/ets/logic/ReminderService.ets
 * 用途：把「今天剩余的提醒」交给后台代理提醒整个重排一遍（全消再全排）。
 *       为什么要整个重排：reminderAgentManager 的提醒在 publish 那一刻内容就写死了，
 *       用户 6:30 推过之后 11 点勾掉两条，如果不在勾掉时重排，11:30 那条还会把
 *       已经做完的事再念一遍——那提醒就成了骚扰。所以每次打开 App、每次数据变化后
 *       都调一次 rescheduleReminders，把今天还没到点的提醒按最新数据全部换掉。
 *       不记 reminderId 做增量更新：全消再全排最简单，也不会漏。
 *
 * 分工：「算什么内容」在 NotifyContent.ets，「怎么投递」在本文件。之所以分开，是因为
 * 同一条提醒有第二条投递路径——真机上代理提醒受管控（未开通权限的应用额度为 0），
 * 得由 LocalNotifier 用普通通知顶上，两条路必须念同一套文案。
 */

import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DbHelper } from '../data/DbHelper';
import { buildSlotPlan, fireTimestampOf, SlotPlan } from './NotifyContent';
import { DAY_MS, startOfDay } from '../viewmodel/EntryDisplay';

/** hilog 日志标签与域，排查提醒问题时按它过滤 */
const TAG: string = 'ReminderService';
const DOMAIN: number = 0x0000;

/** 点开提醒要拉起的应用：本 App 的包名与主页 Ability */
const BUNDLE_NAME: string = 'com.wenyi.memoapp';
const ABILITY_NAME: string = 'EntryAbility';

/**
 * 兜底提醒往前垫几天：扛得住「连着几天没打开 App」，又不至于把提醒条数堆到系统上限。
 * 5 天 × 3 条 = 15 条，加上当天的精确提醒也远在 30 条上限之内。
 */
const FALLBACK_DAYS: number = 5;
/**
 * 补推窗口：提醒时刻刚过、不超过这么久的话，改成「马上补一条」而不是直接放弃。
 * 为什么需要：卡片由系统每 30 分钟唤醒一次，6:25 那次负责排 6:30 的汇总，但系统调度
 * 不保证准点——唤醒晚了几分钟，那条汇总就整个白天都补不上了。
 * 为什么不能对所有路径生效：用户正开着 App 时补推是纯打扰（他已经在看那些事了），
 * 所以只有卡片刷新那条路径允许补推，见 rescheduleReminders 的 allowCatchup。
 */
const CATCHUP_WINDOW_MS: number = 10 * 60 * 1000;
/** 补推时往后垫的分钟数：publishCalendar 只精确到分钟，垫足两分钟才不会落回过去 */
const CATCHUP_DELAY_MINUTES: number = 2;
/** 兜底提醒的 notificationId 段：2000 + 第几天 * 10 + 第几条，与精确提醒的 1001-1004 隔开 */
const FALLBACK_ID_BASE: number = 2000;
/** 兜底文案：与当天实际内容无关，只为把人叫进 App 里看真实数据 */
const FALLBACK_TITLES: string[] = ['今天的事', '还有事没做完', '还有事没做完'];
const FALLBACK_BODIES: string[] = [
  '打开看看今天要做什么',
  '打开看看，把做完的勾掉',
  '打开看看，把做完的勾掉'
];

/** 代理提醒可用性的探测累计：本次重排到底排过没有、有没有失败过 */
interface QuotaProbe {
  /** 是否至少尝试排过一条。一条都没排时不能下结论，否则会把上次的结论覆盖掉 */
  attempted: boolean;
  /** 尝试过的那些是不是全部成功。只要有一条失败就认为这条路不可用 */
  allOk: boolean;
}

/**
 * 把提醒整个重排一遍：先 cancelAllReminders 全消，再按最新数据重新 publish。
 * 排两部分：
 *   1. 「今天还没到点的」精确提醒——内容按库里的最新数据现算；
 *   2. 「未来几天的」兜底提醒——通用文案，保证连着几天不开 App 也不会一条不响。
 * 顺带把「代理提醒在这台设备上到底能不能用」的结论写进设置，供 LocalNotifier 判断
 * 要不要改由普通通知顶上（真机管控下额度为 0，本函数的 publish 会稳定失败）。
 * @param db           数据库句柄（读条目与提醒时间设置）
 * @param now          当前毫秒时间戳
 * @param allowCatchup 刚过去的提醒要不要补推。卡片刷新传 true；用户主动打开 App 传 false
 *                     ——他正在看那些事，再补一条提醒是纯打扰
 */
export async function rescheduleReminders(db: DbHelper, now: number, allowCatchup: boolean): Promise<void> {
  // 先全消：内容写死的旧提醒是数据变化前的过时快照，留着必然念旧账
  await reminderAgentManager.cancelAllReminders();

  const plan: SlotPlan = await buildSlotPlan(db, now);
  const probe: QuotaProbe = { attempted: false, allOk: true };

  // ── 今天还没到点的精确提醒 ──
  for (const slot of plan.slots) {
    const fireTs: number = effectiveFireTs(slot.plannedTs, now, allowCatchup);
    // 过了太久就不排：提醒只对「今天剩余」负责，隔了半天再补推是翻旧账
    if (fireTs <= now) {
      continue;
    }
    for (const item of slot.items) {
      const ok: boolean = await publishCalendar(fireTs, item.notificationId, item.title, item.content);
      recordProbe(probe, ok);
    }
  }

  // ── 未来几天先垫上通用文案的兜底 ──
  // 上面那几条只在打开 App 或卡片刷新时才排得出来，不垫的话哪天连卡片都没醒过，
  // 哪天就一条都不响
  await scheduleFallbacks(startOfDay(now), plan, probe);

  // 只有真的尝试过才写结论：今天一条都没得排时写下去，会把上一次的结论覆盖成「能用」，
  // 于是 LocalNotifier 不再顶上，而代理提醒其实还是发不出来
  if (probe.attempted) {
    await db.setSetting('reminderQuota', probe.allOk ? '1' : '0');
  }
}

/** 累计一次投递结果：只要有一条失败，代理提醒这条路就按不可用处理 */
function recordProbe(probe: QuotaProbe, ok: boolean): void {
  probe.attempted = true;
  if (!ok) {
    probe.allOk = false;
  }
}

/**
 * 给未来几天先垫上「兜底提醒」：每天那三次，文案与当天内容无关。
 *
 * 为什么需要：上面那些精确提醒只在重排时才排得出来（reminderAgent 的提醒内容在 publish
 * 那一刻就写死，数据变了只能整个重排），所以只要某天既没打开 App、卡片也没被系统唤醒，
 * 那天就一条提醒都不会响——而且用户完全无感知，会以为「没提醒就是没事」。这里用一个跟
 * 内容无关的通用文案把未来 FALLBACK_DAYS 天垫上。
 *
 * 为什么不跟精确提醒打架：两者时刻完全相同（比如都是 6:30），但每次重排都先
 * cancelAllReminders，旧兜底一并被消掉——用户当天打开 App，那天的兜底就被换成
 * 带真实内容的精确提醒；没打开，兜底留着顶上。二选一，不会响两次。
 *
 * @param todayStart 今天 0 点
 * @param plan       今天的提醒全貌——用它的 hasUndone 判要不要垫、用它的 slot.time 算时刻，
 *                   不再单独读一次设置，免得两处对「提醒时间」的理解走岔
 * @param probe      投递结果累计，传给调用方写回可用性结论
 */
async function scheduleFallbacks(todayStart: number, plan: SlotPlan, probe: QuotaProbe): Promise<void> {
  // 手头一条未完成的事都没有时不垫：那种日子本来就没安排，
  // 再天天准点喊「打开看看」就成了骚扰
  if (!plan.hasUndone) {
    return;
  }
  for (let day = 1; day <= FALLBACK_DAYS; day++) {
    const dayStart: number = todayStart + day * DAY_MS;
    for (const slot of plan.slots) {
      const ok: boolean = await publishCalendar(fireTimestampOf(dayStart, slot.time),
        FALLBACK_ID_BASE + day * 10 + slot.index, FALLBACK_TITLES[slot.index], FALLBACK_BODIES[slot.index]);
      recordProbe(probe, ok);
    }
  }
}

/**
 * 这条提醒实际该在什么时候触发。
 *   时刻还没到         → 原样返回
 *   刚过（在补推窗口内）→ 返回「下一个整分 + CATCHUP_DELAY_MINUTES 分」，立刻补推
 *   过太久了           → 原样返回，调用方按 <= now 跳过（补推成翻旧账就没意义了）
 * 只有 allowCatchup 为真（卡片刷新那条路径）才补推。
 */
function effectiveFireTs(plannedTs: number, now: number, allowCatchup: boolean): number {
  if (plannedTs > now) {
    return plannedTs;
  }
  if (!allowCatchup || now - plannedTs > CATCHUP_WINDOW_MS) {
    return plannedTs;
  }
  // 先取整到分再往后垫：publishCalendar 构造的时刻 second 固定为 0，
  // 只垫几秒会被抹回「上一个整分」——那是过去，系统不会触发
  const minuteMs: number = 60 * 1000;
  return Math.floor(now / minuteMs) * minuteMs + CATCHUP_DELAY_MINUTES * minuteMs;
}

/**
 * 造一条日历型提醒并在指定时刻触发。
 * @returns 是否排成功。调用方靠这个结论判断代理提醒这条路在这台设备上能不能用
 *          —— 真机管控下额度为 0，这里会稳定失败
 */
async function publishCalendar(fireTs: number, notificationId: number, title: string, content: string): Promise<boolean> {
  const d: Date = new Date(fireTs);
  const dateTime: reminderAgentManager.LocalDateTime = {
    year: d.getFullYear(),
    // SDK 的月份是 1–12，JS 的 getMonth() 是 0–11，必须 +1（year/day/hour/minute 两边一致）
    month: d.getMonth() + 1,
    day: d.getDate(),
    hour: d.getHours(),
    minute: d.getMinutes(),
    second: 0
  };
  // 刻意不设 slotType：该字段类型来自 @ohos.notification 的 SlotType，
  // NotificationKit 并不导出那个命名空间，写了类型就对不上；不设走系统默认通道
  const wantAgent: reminderAgentManager.WantAgent = {
    pkgName: BUNDLE_NAME,
    abilityName: ABILITY_NAME
  };
  const request: reminderAgentManager.ReminderRequestCalendar = {
    reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
    dateTime: dateTime,
    title: title,
    content: content,
    notificationId: notificationId,
    wantAgent: wantAgent
  };
  let ok: boolean = true;
  await reminderAgentManager.publishReminder(request).catch((e: BusinessError): void => {
    ok = false;
    // code 单独打出来：1700002 在真机管控下不是「条数超了」而是「没有额度」
    // —— 未开通代理提醒权限的应用额度就是 0，第一条就失败
    hilog.error(DOMAIN, TAG, `发布提醒失败(${title}) code=${e.code}: ${JSON.stringify(e)}`);
  });
  return ok;
}

/**
 * 「App 刚推过卡片」这条记号的有效期。
 * 取值要盖住「App 调 reloadAllForms 到卡片进程真的醒过来读库」这段延迟（实测是秒级），
 * 又不能太长：卡片每 30 分钟被系统唤醒一次，记号留得越久，越容易把一次
 * 「系统自己醒」误判成「App 推的」而白白漏掉补推。2 分钟是这两头的折中。
 */
export const APP_PUSH_WINDOW_MS: number = 2 * 60 * 1000;

/**
 * 这次卡片唤醒是不是 App 刚推的。
 * 为什么要问：App 主动推卡片时人正看着手机（他刚在 App 里改完东西），补推刚过去的
 * 提醒是打扰——App 侧自己的重排就是按这个口径传 allowCatchup = false 的
 * （见 pages/Index.ets 里 rescheduleReminders 那处调用）。但 reloadAllForms 不带参数、
 * onUpdateForm 也分不出唤醒来源，只能靠 App 推之前写进 settings 的这个时刻戳来认。
 * @param db  数据库句柄
 * @param now 当前毫秒时间戳
 * @returns true 表示这次唤醒来得太近，应当按「人正在看」处理、不补推
 */
export async function wokenByApp(db: DbHelper, now: number): Promise<boolean> {
  try {
    const raw: string | undefined = await db.getSetting('appPushTs');
    if (raw === undefined) {
      return false;
    }
    const ts: number = Number(raw);
    // now - ts 落在 [0, 窗口) 才算数：负数说明系统时钟被往回调过，那种不能认
    return !Number.isNaN(ts) && now - ts >= 0 && now - ts < APP_PUSH_WINDOW_MS;
  } catch (e) {
    // 查不出来就按「不是 App 推的」处理：补推是卡片这条路径的默认行为，
    // 出错时退回它更安全
    hilog.error(DOMAIN, TAG, `读 appPushTs 失败: ${JSON.stringify(e)}`);
    return false;
  }
}
