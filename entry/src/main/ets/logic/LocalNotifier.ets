/**
 * 文件路径：entry/src/main/ets/logic/LocalNotifier.ets
 * 用途：把到点的提醒用普通通知当场发出去——绕开后台代理提醒那条被管控的路。
 *
 * 为什么需要它：后台代理提醒（reminderAgentManager）在真机上是受管控的能力，
 * 未通过管控的应用提醒额度为 0，怎么排都不会响，而开通管控要企业开发者资质。
 * 卡片刷新是系统按时唤醒的（form_config：06:25 起每 30 分钟一次），在那个时刻
 * 调 notificationManager.publish 直接发一条普通通知，不经过代理提醒，因而不受管控。
 *
 * 精度：发出来的是「唤醒点」而不是「计划时刻」。唤醒序列 06:25 / 11:25 / 15:55
 * 恰好都落在三个计划时刻前 5–10 分钟，所以实际只会早几分钟，不会晚。
 *
 * 与代理提醒的分工：代理提醒探测到能用（reminderQuota = '1'）时本文件整体不动作，
 * 否则同一时刻会响两条。谁发都用同一套文案（NotifyContent.buildSlotPlan）、
 * 同一组 notificationId（1001–1004），所以通知栏里看到的始终是同一条。
 */

import { notificationManager } from '@kit.NotificationKit';
import { Want, wantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DbHelper } from '../data/DbHelper';
import { RuntimeKey } from '../data/Types';
import { buildSlotPlan, NotifyItem, SlotPlan } from './NotifyContent';
import { startOfDay } from '../viewmodel/EntryDisplay';

/** hilog 日志标签与域，排查提醒问题时按它过滤 */
const TAG: string = 'LocalNotifier';
const DOMAIN: number = 0x0000;

/** 点开通知要拉起的应用：本 App 的包名与主页 Ability */
const BUNDLE_NAME: string = 'com.wenyi.memoapp';
const ABILITY_NAME: string = 'EntryAbility';

/**
 * 提前量：唤醒点最多比计划时刻早这么久就把提醒发出去。
 * 卡片 06:25 醒来时 06:30 那条落在窗口里，发出来早 5 分钟——这是这套机制的天花板，
 * 因为能发通知的时刻只能是系统醒来的时刻，而 06:25 是离 06:30 最近的一次。
 */
const LEAD_MS: number = 10 * 60 * 1000;
/**
 * 迟到量：唤醒点比计划时刻晚这么久以内仍然补发。
 * 系统调度不保证准点，某次唤醒被跳过时（06:25 没醒），下一次 06:55 还在窗口内能补上；
 * 再往后的 07:25 已经超出窗口，不会补成翻旧账。
 */
const LATE_MS: number = 30 * 60 * 1000;

/** 三个槽位各自「今天已发过」的记账键，下标与 SlotContent.index 对齐 */
const SENT_KEYS: RuntimeKey[] = ['notifySent1', 'notifySent2', 'notifySent3'];

/**
 * 把到点的提醒发出去。在当前时刻刚好落在某个槽位窗口内、且今天还没发过时发一条。
 *
 * 调用点有两处，都是「系统替我们醒过来」的时刻：
 *   1. EntryFormAbility.refreshCard —— 卡片被系统定时唤醒（主力，不依赖用户操作）；
 *   2. Index.refresh —— 用户打开 App / 勾选 / 新建之后。这条覆盖「卡片被删掉，
 *      系统再也不会替我们醒过来」的情况。
 * 重复调用是安全的：已发标记落在数据库里，进程重启也不丢。
 *
 * @param db  数据库句柄
 * @param now 当前毫秒时间戳
 */
export async function sendDueNotifications(db: DbHelper, now: number): Promise<void> {
  // 代理提醒能用就让它发：两条路都发的话同一时刻会响两条
  if (await isReminderAgentUsable(db)) {
    return;
  }
  // 通知权限关着时 publish 会静默失败（系统不报错、界面也看不出异常），干脆不试。
  // 主界面有引导入口把用户带去开权限，开完这里自然就通了
  if (!isNotificationOn()) {
    return;
  }
  const plan: SlotPlan = await buildSlotPlan(db, now);
  const todayStart: number = startOfDay(now);
  for (const slot of plan.slots) {
    if (!inWindow(slot.plannedTs, now)) {
      continue;
    }
    if (await hasSentToday(db, slot.index, todayStart)) {
      continue;
    }
    if (slot.items.length === 0) {
      // 今天这个槽位没东西可推（事都做完了）：不写已发标记，
      // 万一下次唤醒前用户又添了新的事，那条还发得出去
      continue;
    }
    const ok: boolean = await publishAll(slot.items);
    if (ok) {
      // 只有真发成功才记账：发失败（比如系统服务忙）时不记，下次唤醒还会重试
      await db.setSetting(SENT_KEYS[slot.index], `${todayStart}`);
    }
  }
}

/**
 * 代理提醒这条路在这台设备上能不能用。
 * 默认按「不能用」处理：这项能力在真机上受管控，未开通权限的应用额度为 0，
 * 而个人开发者拿不到这个权限。读不到标记（还没探测过）时也按不能用处理，
 * 宁可多发一条普通通知，也不要一条都不响。标记由 ReminderService 每次重排时写回。
 */
async function isReminderAgentUsable(db: DbHelper): Promise<boolean> {
  const stored: string | undefined = await db.getSetting('reminderQuota');
  return stored === '1';
}

/** 通知权限是否开着。系统服务异常时按「关着」处理：宁可不发，也不要在没权限时反复试 */
function isNotificationOn(): boolean {
  try {
    return notificationManager.isNotificationEnabledSync();
  } catch (e) {
    return false;
  }
}

/** now 是否落在「这个槽位该发」的窗口里：计划时刻前 LEAD_MS 到后 LATE_MS 之间 */
function inWindow(plannedTs: number, now: number): boolean {
  return now >= plannedTs - LEAD_MS && now <= plannedTs + LATE_MS;
}

/**
 * 这个槽位今天是不是已经发过了。
 * 用数据库记而不是内存变量：卡片进程会被系统随时回收重建，内存标记一丢就会重发。
 */
async function hasSentToday(db: DbHelper, index: number, todayStart: number): Promise<boolean> {
  const stored: string | undefined = await db.getSetting(SENT_KEYS[index]);
  return stored === `${todayStart}`;
}

/**
 * 把一个槽位的几条通知一起发出去。任意一条失败就整体算失败，下次唤醒还会重试
 * ——重复发一条总好过整条提醒丢掉。
 */
async function publishAll(items: NotifyItem[]): Promise<boolean> {
  // 点通知要能拉起主界面，所以先造一个 WantAgent 挂在通知上。
  // 造不出来（系统服务忙）就整体不发——点了没反应的通知不如不发
  const target: Want = { bundleName: BUNDLE_NAME, abilityName: ABILITY_NAME };
  const agentInfo: wantAgent.WantAgentInfo = {
    wants: [target],
    actionType: wantAgent.OperationType.START_ABILITY,
    requestCode: 0,
    actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
  };
  let ok: boolean = true;
  try {
    // agent 刻意不写类型标注：WantAgent 这个类型名在当前 SDK 的模块解析下取不到
    // （写成 wantAgent.WantAgent 会报「no exported member」），让返回值自己推断就行，
    // 推断出来的就是同一个类型
    const agent = await wantAgent.getWantAgent(agentInfo);
    for (const item of items) {
      const request: notificationManager.NotificationRequest = {
        id: item.notificationId,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: item.title, text: item.content }
        },
        // 刻意不设 notificationSlotType：走系统默认通道（OTHER_TYPES，有提示音）。
        // 通知渠道一旦建出来就不能改类型，选错了没法补救，默认值最稳
        wantAgent: agent
      };
      await notificationManager.publish(request).catch((e: BusinessError): void => {
        ok = false;
        hilog.error(DOMAIN, TAG, `发通知失败(${item.title}): ${JSON.stringify(e)}`);
      });
    }
  } catch (e) {
    hilog.error(DOMAIN, TAG, `创建 WantAgent 失败，本次不发: ${JSON.stringify(e)}`);
    return false;
  }
  return ok;
}
