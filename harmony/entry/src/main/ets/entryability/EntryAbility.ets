/**
 * CarLife 手机端主 Ability
 *
 * 职责：
 *   1. 加载主界面
 *   2. 把 UIAbilityContext 交给 BackgroundKeeper，供推流时申请长时任务
 *
 * 注意：**不在这里申请长时任务**。长时任务只在真正开始推流时才需要，
 * 应用一启动就申请既浪费也会在用户没连车机时弹无关通知。
 */

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

import { BackgroundKeeper } from '../core/BackgroundKeeper';

const DOMAIN: number = 0x0001;
const TAG: string = 'CarHi';

/** 全局状态（供 UI 读取与跨模块共享） */
export class CarLifeRuntime {
  /** 运行日志环形缓冲，供 UI 展示 */
  static logs: string[] = [];

  static addLog(text: string): void {
    const ts = new Date().toTimeString().substring(0, 8);
    CarLifeRuntime.logs.push(`[${ts}] ${text}`);
    if (CarLifeRuntime.logs.length > 300) {
      CarLifeRuntime.logs.shift();
    }
    hilog.info(DOMAIN, TAG, text);
  }
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    BackgroundKeeper.init(this.context);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
    BackgroundKeeper.release();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }
}
