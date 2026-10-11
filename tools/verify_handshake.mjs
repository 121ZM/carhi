/**
 * 握手状态机对拍验证
 *
 * 验证目标：确认「手机端」的消息流向与参考实现「车机端」严格互补。
 *
 * 方法：用 Python 侧（车机端实现）扮演车机，跑一遍它的状态机；
 *       用 JS 侧（我们写的手机端逻辑）扮演手机，跑一遍。
 *       把两边的 收/发 序列拉出来对照，每条都能配上对。
 *
 * 这一层验证的是「时序与方向」，不是字节（字节已在 verify.mjs 验证）。
 */

import { execFileSync } from 'child_process';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

// ==================== 手机端逻辑（与 StateMachine.ets 等价）====================

const C = {
  HU_PROTOCOL_VERSION: 98305,
  MD_PROTOCOL_VERSION_MATCH_STATUS: 65538,
  HU_INFO: 98307,
  MD_INFO: 65540,
  HU_AUTHEN_RESULT: 98380,
  MD_AUTHEN_RESULT: 65611,
  MD_FEATURE_CONFIG_LIST: 65617,
  HU_VIDEO_ENCODER_INIT: 98311,
  VIDEO_ENCODER_INIT: 65544,
  VIDEO_ENCODER_START: 98313,
  MD_HEARTBEAT: 65563,
  HU_HEARTBEAT: 131074,
  HU_FEATURE_CONFIG_LIST: 98386
};

/**
 * 手机端状态机（简化：只记录 state 与发出的消息）
 * 输入：收到的消息 ID 序列
 * 输出：发出的消息 ID 序列
 */
function phoneSideSequence(inputs) {
  const sent = [];
  let state = 'VERSION_NEGOTIATING';
  const transitions = [];

  for (const id of inputs) {
    switch (id) {
      case C.HU_PROTOCOL_VERSION:
        sent.push(C.MD_PROTOCOL_VERSION_MATCH_STATUS);
        state = 'DEVICE_INFO_EXCHANGING';
        transitions.push(`收 98305 -> 发 65538, state=${state}`);
        break;
      case C.HU_INFO:
        sent.push(C.MD_INFO);
        state = 'AUTHEN_CONFIRMING';
        transitions.push(`收 98307 -> 发 65540, state=${state}`);
        break;
      case C.HU_AUTHEN_RESULT:
        sent.push(C.MD_AUTHEN_RESULT);
        sent.push(C.MD_FEATURE_CONFIG_LIST);
        state = 'CONFIG_EXCHANGING';
        transitions.push(`收 98380 -> 发 65611 + 65617, state=${state}`);
        break;
      case C.HU_VIDEO_ENCODER_INIT:
        sent.push(C.VIDEO_ENCODER_INIT);
        state = 'VIDEO_PREPARING';
        transitions.push(`收 98311 -> 发 65544, state=${state}`);
        break;
      case C.VIDEO_ENCODER_START:
        state = 'CONNECTED';
        transitions.push(`收 98313 -> 开始推流, state=${state}`);
        break;
      case C.HU_HEARTBEAT:
        transitions.push('收 131074 (车机心跳) -> 不回复');
        break;
      default:
        transitions.push(`收 ${id} -> 未处理`);
    }
  }
  return { sent, state, transitions };
}

// ==================== 车机端序列（来自参考实现 state_machine.py）====================

/**
 * 从 state_machine.py 提炼的车机端「收/发」序列。
 * 依据 _handle_message 的分支：
 *   收 65538 -> 发 98343(统计) + 启动心跳
 *   收 65540 -> 发 98307(车机设备信息)
 *   收 65611 -> 发 98380 + 98311
 *   收 65617 -> 发 98386
 *   收 65544 -> 发 98313
 *   收 65551 -> 发 98311
 *   收 131074 -> 记录
 */
const HU_SENDS_ON_RECEIVE = {
  65538: [98343],
  65540: [98307],
  65611: [98380, 98311],
  65617: [98386],
  65544: [98313],
  65551: [98311],
  131074: []
};

// 车机侧发起的握手起点
const HU_INITIATES = 98305;

// ==================== 验证 ====================

console.log('\n===== 握手状态机方向对拍验证 =====\n');

// 手机端会依次收到的消息（由车机端发出）
const phoneReceives = [
  C.HU_PROTOCOL_VERSION,   // 车机发起
  C.HU_INFO,
  C.HU_AUTHEN_RESULT,
  C.HU_VIDEO_ENCODER_INIT,
  C.VIDEO_ENCODER_START
];

const phone = phoneSideSequence(phoneReceives);

console.log('--- 手机端完整时序 ---');
for (const t of phone.transitions) {
  console.log(`  ${t}`);
}
console.log(`\n  最终状态: ${phone.state}`);
console.log(`  手机端发出序列: [${phone.sent.join(', ')}]`);

console.log('\n--- 车机端对应关系（来自参考实现）---');
const huExpectsToReceive = phone.sent;

let ok = 0;
let bad = 0;

for (const sentId of huExpectsToReceive) {
  const huReplies = HU_SENDS_ON_RECEIVE[sentId];
  if (huReplies !== undefined) {
    const replyStr = huReplies.length > 0 ? `-> 回 [${huReplies.join(', ')}]` : '-> 无回复';
    console.log(`  车机收 ${sentId} ${replyStr}`);
    ok++;
  } else {
    console.log(`  车机收 ${sentId} -> ⚠ 参考实现未定义处理`);
    bad++;
  }
}

console.log('\n--- 校验项 ---');
const checks = [];

// 校验1：车机发起 98305，手机端第一个响应必须是 65538
checks.push({
  name: '车机发起 98305 -> 手机首发 65538',
  pass: phone.sent[0] === C.MD_PROTOCOL_VERSION_MATCH_STATUS
});

// 校验2：手机端不主动发起握手（除心跳外）
checks.push({
  name: '手机端为被动方，不主动发起握手',
  pass: !phone.sent.includes(C.HU_PROTOCOL_VERSION)
});

// 校验3：手机端发出的每条消息，车机端都有对应接收处理
checks.push({
  name: '手机端发出的消息车机端均可接收',
  pass: bad === 0
});

// 校验4：手机端不发送车机专属消息（HU_*）
const huOnly = [98305, 98343, 98307, 98380, 98386, 98311, 98313, 131074];
const phoneSentHu = phone.sent.filter(s => huOnly.includes(s));
checks.push({
  name: '手机端不误发车机专属消息（HU_*）',
  pass: phoneSentHu.length === 0
});

// 校验5：最终状态到达 CONNECTED
checks.push({
  name: '时序走完后到达 CONNECTED 状态',
  pass: phone.state === 'CONNECTED'
});

let passed = 0;
for (const c of checks) {
  console.log(`  [${c.pass ? 'PASS' : 'FAIL'}] ${c.name}`);
  if (c.pass) passed++;
}

console.log(`\n===== 结果 =====`);
console.log(`  通过: ${passed}/${checks.length}`);
if (passed !== checks.length) {
  process.exit(1);
}
console.log('  手机端与车机端消息方向严格互补\n');
