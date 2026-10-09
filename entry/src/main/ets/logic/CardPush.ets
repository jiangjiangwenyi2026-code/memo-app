/**
 * 文件路径：entry/src/main/ets/logic/CardPush.ets
 * 用途：把「让桌面卡片立刻重刷一遍」收成唯一入口，主页和各个子页面都调它。
 *
 * 为什么需要：卡片是静态卡片（form_config.json 里 isDynamic: false），系统只从 6:25 起
 * 每 30 分钟唤起它一次。在 App 里改完数据、直接回桌面看，卡片上还是旧内容，最长要等
 * 半小时才自己追上——用户会当成没改上。
 *
 * 为什么用 reloadAllForms 而不是自己读库拼数据再 updateForm：它是 UIAbility 侧唯一的
 * 入口，语义是「让系统去通知卡片进程自己重跑一遍 onUpdateForm」，而不是「主进程把数据
 * 塞过去」。这正好：卡片侧重跑时会顺带把跨天结算和提醒投递做掉，那两件事本来就只能
 * 发生在卡片进程里，跟在 App 侧搬一份数据出来是两条路。
 *
 * 为什么收成一个模块、不是在每个页面各写一份：需要它的不止主页——课表页、归档页、
 * 设置页都直接写库，用户从那些页面直接按 Home 回桌面时主页的 onPageShow 不会触发，
 * 卡片就一直是旧的。收成一处，这些页面各调一行就够，「推之前先留记号」这个共性
 * 也不会漏掉哪一处。定时器也因此是同一个，跨页面挨着来的两次调用照样合并。
 */

import { formProvider } from '@kit.FormKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DbHelper } from '../data/DbHelper';

/** hilog 日志标签与域，排查卡片刷新问题时按它过滤 */
const TAG: string = 'CardPush';
const DOMAIN: number = 0x0000;

/**
 * 连续推送的合并窗口。
 * 为什么要合并：连续勾掉好几条、拖拽落点、保存后紧跟着刷新、从一个页面返回主页，
 * 都会在几百毫秒里连着调好几次 pushCard。风险不是「重复劳动」，而是卡片进程被并发
 * 唤起好几遍、每遍都跑一次跨天结算，而那边「先查后插」的闸门不是原子的
 * （同 Index.ets 里 loading 那段注释的道理）。合并之后一串操作只落成一次推送。
 */
const MERGE_MS: number = 400;

/** 等待中的合并定时器；-1 表示当前没有等待中的推送 */
let pushTimer: number = -1;

/**
 * 通知桌面上的卡片重刷一遍。同一个合并窗口内的多次调用只落成一次推送。
 * 桌面上没放卡片时什么都不会发生（reloadAllForms 返回 0）。
 * @param ctx 调用方的 context。页面里传 getContext(this) 或 getUIContext().getHostContext() 都行；
 *            拿不到时整个调用被忽略
 * @param db  数据库句柄，用来写「App 刚推过」的记号；拿不到时只推、不写记号
 */
export function pushCard(ctx: common.Context | undefined, db: DbHelper | undefined): void {
  if (ctx === undefined) {
    return;
  }
  if (pushTimer !== -1) {
    clearTimeout(pushTimer);
  }
  pushTimer = setTimeout((): void => {
    pushTimer = -1;
    // 定时器回调里没有调用方在等，不 await
    pushCardNow(ctx, db);
  }, MERGE_MS);
}

/** 真正去推的那一步，说明见 pushCard */
async function pushCardNow(ctx: common.Context, db: DbHelper | undefined): Promise<void> {
  // 写记号单独兜一层错：它只是「让卡片别补推提醒」这个附加好处，写不进去最多是卡片
  // 那边多补一条，绝不能因此把下面真正要办的推送一起带走
  if (db !== undefined) {
    try {
      // 先写记号再推，顺序不能反：卡片进程被唤起后会读它，从而知道这次是人刚在 App 里
      // （而不是系统例行唤醒），于是跳过提醒补推——人正看着屏幕时补推是打扰
      // （见 ReminderService 的 wokenByApp）。反过来的话卡片进程可能先读后写，
      // 读到的还是上一次的旧记号。
      await db.setSetting('appPushTs', `${Date.now()}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `写 appPushTs 记号失败: ${JSON.stringify(e)}`);
    }
  }
  try {
    const count: number = await formProvider.reloadAllForms(ctx as common.UIAbilityContext);
    hilog.info(DOMAIN, TAG, `已通知 ${count} 张卡片重刷`);
  } catch (e) {
    // 推不上不是错，只是慢半小时（系统每 30 分钟还会自己唤起卡片一次）：
    // 不弹提示、不影响任何主流程，留条日志就够了
    hilog.error(DOMAIN, TAG, `通知卡片刷新失败: ${JSON.stringify(e)}`);
  }
}
