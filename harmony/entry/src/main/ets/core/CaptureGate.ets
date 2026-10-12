/**
 * 录屏授权门控（CaptureGate）
 *
 * 背景（这段结论有官方文档依据，不是推测）：
 *   鸿蒙在手机/平板上调用 OH_AVScreenCapture 启动采集时，**系统强制弹出隐私保护/
 *   授权弹框**，应用无法绕过，也没有「记住授权」的持久化开关：
 *     - OH_AVScreenCapture_StrategyForPickerPopUp(false) 只关掉「选择共享内容」
 *       弹窗（PC/2in1 的选择器语义），**不影响手机端的隐私保护弹窗**。
 *     - 官方文档「约束与限制」明确写着：录屏取码流场景下，屏幕录制启动时会弹出
 *       隐私保护弹框。（参见 avscreencapture-c-basic-process.md）
 *     - 唯一免弹窗的权限 ohos.permission.CUSTOM_SCREEN_RECORDING 官方标注
 *       仅 PC/2in1 生效（API 22+），且属受限开放权限，需华为审批上架，
 *       手机端不适用。
 *
 * 既然弹框消不掉，本模块的目标就变成「把弹框压低到系统下限」：
 *   1) 一次会话只主动启动一次采集；用户拒绝后不再自动重弹（否则会无限骚扰）。
 *   2) 采集中断重试也必须占用配额 —— 避免"重试 5 次弹 5 次框"。
 *   3) 弹框前先给 UI 一个明确提示，让用户知道要点「允许」。
 *   4) 用户主动点「重新授权」时才重置配额。
 *
 * 状态区分（关键）：
 *   - PENDING  ：尚未尝试过，允许弹一次
 *   - GRANTED  ：用户已允许，采集正在/曾经正常运行
 *   - DENIED   ：用户明确拒绝 —— 未重试已耗尽配额且没出过帧
 *   - EXHAUSTED：重试次数用尽，需要用户手动恢复
 */
export enum CaptureGrantState {
  /** 尚未尝试 */
  PENDING = 0,
  /** 本次会话内已获得授权（采集成功出过帧） */
  GRANTED = 1,
  /** 用户拒绝授权 */
  DENIED = 2,
  /** 自动尝试次数已用完 */
  EXHAUSTED = 3
}

/** 一次会话内允许"主动弹授权框"的最大次数 */
const MAX_LAUNCH_ATTEMPTS: number = 3;
/** 连续启动失败多少次后，判定用户已拒绝（每次都失败通常是"允许"被点了取消） */
const DENY_THRESHOLD: number = 2;

export class CaptureGate {
  private static state: CaptureGrantState = CaptureGrantState.PENDING;
  /** 本次会话已主动发起采集启动的次数 */
  private static launchAttempts: number = 0;
  /** 连续启动失败（尚未出帧）的次数 */
  private static consecutiveFailures: number = 0;

  /** 当前授权门控状态 */
  static get current(): CaptureGrantState {
    return CaptureGate.state;
  }

  /** 是否允许再弹一次授权框 */
  static get canLaunch(): boolean {
    if (CaptureGate.state === CaptureGrantState.GRANTED) {
      return true;    // 已授权，重启采集属正常行为
    }
    return CaptureGate.launchAttempts < MAX_LAUNCH_ATTEMPTS;
  }

  /** 是否处于"用户拒绝，需要人工干预"的状态 */
  static get needsUserAction(): boolean {
    return CaptureGate.state === CaptureGrantState.DENIED
      || CaptureGate.state === CaptureGrantState.EXHAUSTED;
  }

  /** 给 UI 展示的可读状态 */
  static get label(): string {
    switch (CaptureGate.state) {
      case CaptureGrantState.GRANTED: return '已授权';
      case CaptureGrantState.DENIED: return '已拒绝授权';
      case CaptureGrantState.EXHAUSTED: return '授权尝试已用尽';
      default: return '待授权';
    }
  }

  /**
   * 记录一次「即将主动启动采集」。
   * 调用时机：真正要弹框之前。
   * @returns true = 允许启动（会弹框）；false = 配额已尽，不要启动
   */
  static tryLaunch(): boolean {
    if (CaptureGate.state === CaptureGrantState.GRANTED) {
      return true;
    }
    if (CaptureGate.launchAttempts >= MAX_LAUNCH_ATTEMPTS) {
      CaptureGate.state = CaptureGrantState.EXHAUSTED;
      return false;
    }
    CaptureGate.launchAttempts++;
    return true;
  }

  /** 采集首次成功出帧 —— 视为用户已允许 */
  static markGranted(): void {
    CaptureGate.state = CaptureGrantState.GRANTED;
    CaptureGate.consecutiveFailures = 0;
  }

  /**
   * 采集启动失败（抛异常，通常是 STAGE_START_CAPTURE_FAILED = 用户点了取消）。
   * 连续失败达到阈值即判定为「用户拒绝」，后续不再自动弹框。
   */
  static markFailed(): void {
    CaptureGate.consecutiveFailures++;
    if (CaptureGate.state !== CaptureGrantState.GRANTED
      && CaptureGate.consecutiveFailures >= DENY_THRESHOLD) {
      CaptureGate.state = CaptureGrantState.DENIED;
    } else if (CaptureGate.launchAttempts >= MAX_LAUNCH_ATTEMPTS) {
      CaptureGate.state = CaptureGrantState.EXHAUSTED;
    }
  }

  /**
   * 用户主动恢复（UI 上的「重新授权」按钮）。
   * 清空配额与拒绝状态，允许再弹一次框。
   */
  static reset(): void {
    CaptureGate.state = CaptureGrantState.PENDING;
    CaptureGate.launchAttempts = 0;
    CaptureGate.consecutiveFailures = 0;
  }
}
