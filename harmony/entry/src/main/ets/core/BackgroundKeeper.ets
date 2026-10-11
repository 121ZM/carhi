/**
 * 长时任务保活（后台持续推流的前提）
 *
 * 为什么需要：用户把导航切到前台后，本应用会退到后台，系统默认会冻结它 ——
 * 推流会断。必须申请"长时任务"才能继续跑。
 *
 * 模式选择（有 SDK 文档依据，不是猜的）：
 *   - BackgroundMode.AUDIO_RECORDING = 3
 *     官方用途描述："recording and screen capture in the background"
 *     —— 这是**唯一**明确覆盖"屏幕采集"的模式。
 *   - 对比 BackgroundMode.DATA_TRANSFER = 1
 *     用途是"上传下载"，且文档明确写着超过 10 分钟不更新进度会被系统取消 ——
 *     对持续投屏场景是错的。
 */

import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'CarLifeBackground';

export class BackgroundKeeper {
  private static context: common.UIAbilityContext | null = null;
  private static active: boolean = false;

  /** 由 EntryAbility 在启动时注入上下文 */
  static init(context: common.UIAbilityContext): void {
    BackgroundKeeper.context = context;
  }

  /** 是否已持有长时任务 */
  static get isActive(): boolean {
    return BackgroundKeeper.active;
  }

  /**
   * 申请长时任务。幂等：已持有则直接返回。
   * 失败不抛异常（例如用户关闭了通知权限），由调用方决定是否提示。
   */
  static async acquire(): Promise<boolean> {
    const ctx = BackgroundKeeper.context;
    if (ctx === null) {
      console.warn(`${TAG} context not ready, skip`);
      return false;
    }
    if (BackgroundKeeper.active) {
      return true;
    }

    try {
      // 通知点击后跳回本应用
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name
      };
      const agentInfo: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(agentInfo);

      await backgroundTaskManager.startBackgroundRunning(
        ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_RECORDING,
        agent
      );
      BackgroundKeeper.active = true;
      console.info(`${TAG} continuous task acquired (AUDIO_RECORDING)`);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      console.error(`${TAG} startBackgroundRunning failed: ${err.message}`);
      return false;
    }
  }

  /** 释放长时任务 */
  static async release(): Promise<void> {
    const ctx = BackgroundKeeper.context;
    if (ctx === null || !BackgroundKeeper.active) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`${TAG} stopBackgroundRunning failed: ${err.message}`);
    }
    BackgroundKeeper.active = false;
  }
}
