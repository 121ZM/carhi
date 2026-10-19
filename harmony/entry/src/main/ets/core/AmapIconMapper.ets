/**
 * 高德转向类型 → CarHi 渲染器转向类型 的映射。
 *
 * ## 为什么要单独一个文件
 *
 * 两边是**两套独立枚举**：
 *   - 高德：`AmapIconType`（40+ 个值，含环岛进/出、匝道、立交桥、隧道…）
 *   - 我们：`HMI_TURN_*` 只有 5 个（无/左/右/直行/到达）
 *
 * 映射的价值在于**语义归类** —— 把高德的细粒度类型收敛到我们能画的 5 种，
 * 而不是画出 40 种箭头（native 侧 `IconTurn()` 只实现了这 5 种路径）。
 *
 * ## ★ 实测数据（2026-10-15 模拟导航，北京西站→天安门）
 *
 * `INaviInfo.mIcon` 实际取到的值：`-1` / `3` / `65`
 * —— 说明值域不是连续小整数，**必须按符号常量映射，不能猜数字**。
 *
 * ## 未覆盖类型怎么办
 *
 * 映射表外的值统一回落到 `HMI_TURN_STRAIGHT`（直行）——
 * 这是最保守的降级：画错箭头比画"直行"更容易误导驾驶员，
 * 但完全留空又会让导航卡看起来坏了。直行是"信息量最低但不会错"的选择。
 */

import { AmapIconType } from '@amap/amap_lbs_navi';
import { HMI_TURN_NONE, HMI_TURN_LEFT, HMI_TURN_RIGHT,
  HMI_TURN_STRAIGHT, HMI_TURN_ARRIVE } from './NativeHmiSource';

/**
 * 把高德的 `mIcon` 收敛成我们的 5 种转向类型。
 *
 * @param amapIcon 高德 `INaviInfo.mIcon` 的值
 * @returns 我们渲染器的 `HMI_TURN_*` 常量
 */
export function mapAmapIconToTurnType(amapIcon: number): number {
  // ---- 到达类（含途经点/服务区/收费站/隧道，都当作"接近节点"）----
  if (amapIcon === AmapIconType.ARRIVED_DESTINATION
    || amapIcon === AmapIconType.ARRIVED_WAYPOINT
    || amapIcon === AmapIconType.ARRIVED_SERVICE_AREA
    || amapIcon === AmapIconType.ARRIVED_TOLLGATE) {
    return HMI_TURN_ARRIVE;
  }

  // ---- 左转类（含左前/左后/环岛左/进左环/掉头）----
  if (amapIcon === AmapIconType.LEFT
    || amapIcon === AmapIconType.LEFT_FRONT
    || amapIcon === AmapIconType.LEFT_BACK
    || amapIcon === AmapIconType.LEFT_TURN_AROUND
    || amapIcon === AmapIconType.ENTRY_LEFT_RING
    || amapIcon === AmapIconType.LEAVE_LEFT_RING
    || amapIcon === AmapIconType.ENTRY_RING_LEFT
    || amapIcon === AmapIconType.ENTRY_LEFT_RING_LEFT
    || amapIcon === AmapIconType.ENTRY_LEFTRINGU_TURN) {
    return HMI_TURN_LEFT;
  }

  // ---- 右转类（含右前/右后/环岛右/进右环/右掉头）----
  if (amapIcon === AmapIconType.RIGHT
    || amapIcon === AmapIconType.RIGHT_FRONT
    || amapIcon === AmapIconType.RIGHT_BACK
    || amapIcon === AmapIconType.U_TURN_RIGHT
    || amapIcon === AmapIconType.ENTRY_RING_RIGHT
    || amapIcon === AmapIconType.ENTRY_LEFT_RING_RIGHT) {
    return HMI_TURN_RIGHT;
  }

  // ---- 直行类（含各种"继续"、环岛直行、道路设施类）----
  if (amapIcon === AmapIconType.STRAIGHT
    || amapIcon === AmapIconType.SPECIAL_CONTINUE
    || amapIcon === AmapIconType.ENTRY_RING_CONTINUE
    || amapIcon === AmapIconType.ENTRY_LEFT_RING_CONTINUE
    || amapIcon === AmapIconType.CROSSWALK
    || amapIcon === AmapIconType.OVERPASS
    || amapIcon === AmapIconType.UNDERPASS
    || amapIcon === AmapIconType.SQUARE
    || amapIcon === AmapIconType.PARK
    || amapIcon === AmapIconType.STAIRCASE
    || amapIcon === AmapIconType.LIFT
    || amapIcon === AmapIconType.CABLEWAY
    || amapIcon === AmapIconType.SKY_CHANNEL
    || amapIcon === AmapIconType.CHANNEL
    || amapIcon === AmapIconType.WALK_ROAD) {
    return HMI_TURN_STRAIGHT;
  }

  // ---- 环岛进/出：没有专用图标，按"直行"近似 ----
  if (amapIcon === AmapIconType.ENTER_ROUNDABOUT
    || amapIcon === AmapIconType.OUT_ROUNDABOUT) {
    return HMI_TURN_STRAIGHT;
  }

  // ---- 明确"无"（实测取到过 -1，对应 NONE/DEFAULT 语义）----
  if (amapIcon === AmapIconType.NONE || amapIcon === AmapIconType.DEFAULT) {
    return HMI_TURN_NONE;
  }

  // ---- 兜底：未覆盖的新类型 → 直行（信息量最低但不会错）----
  return HMI_TURN_STRAIGHT;
}

/**
 * 转向类型 → 中文动作词（用于导航卡主标题「前方 300m __」）。
 */
export function turnTypeActionText(turnType: number): string {
  switch (turnType) {
    case HMI_TURN_LEFT: return '左转';
    case HMI_TURN_RIGHT: return '右转';
    case HMI_TURN_ARRIVE: return '到达';
    case HMI_TURN_STRAIGHT: return '直行';
    default: return '继续行驶';
  }
}
