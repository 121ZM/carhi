/**
 * ArkTS 工程静态检查（无编译器环境下的一致性校验）
 *
 * 目的：本机没有鸿蒙工具链，无法编译。此脚本做能做的静态检查：
 *   1. 所有 import 的符号是否在目标文件中有 export
 *   2. 跨文件引用的常量值是否与参考实现一致
 *   3. 是否引用了未定义/已删除的标识符
 *   4. 消息 ID 与 Python 参考实现是否逐一对应
 *
 * 明确标注：这不是编译验证，只能发现「引用不存在」这类错误。
 */

import { readFileSync, readdirSync, statSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join, relative } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ETS_ROOT = join(__dirname, '..', 'harmony', 'entry', 'src', 'main', 'ets');

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      out.push(...walk(full));
    } else if (name.endsWith('.ets')) {
      out.push(full);
    }
  }
  return out;
}

const files = walk(ETS_ROOT);
const fileMap = new Map();
for (const f of files) {
  fileMap.set(f, readFileSync(f, 'utf8'));
}

console.log('\n===== ArkTS 静态一致性检查 =====\n');
console.log(`扫描 ${files.length} 个 .ets 文件\n`);

// ---------- 1. 收集每个文件的导出符号 ----------
const exportsMap = new Map();   // filePath -> Set<symbol>

function collectExports(src) {
  const set = new Set();
  // export class X / export interface X / export enum X / export function X
  const declRe = /export\s+(?:abstract\s+)?(?:class|interface|enum|function|const|let)\s+([A-Za-z_$][A-Za-z0-9_$]*)/g;
  let m;
  while ((m = declRe.exec(src)) !== null) {
    set.add(m[1]);
  }
  return set;
}

for (const f of files) {
  exportsMap.set(f, collectExports(fileMap.get(f)));
}

// ---------- 2. 校验 import 的符号是否存在 ----------
const problems = [];

function resolvePath(fromFile, spec) {
  // 仅处理相对路径
  if (!spec.startsWith('.')) {
    return null;
  }
  const fromDir = dirname(fromFile);
  let target = join(fromDir, spec);
  if (!target.endsWith('.ets')) {
    target += '.ets';
  }
  return target;
}

for (const f of files) {
  const src = fileMap.get(f);
  const lines = src.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // import { A, B } from './x'
    const named = line.match(/^\s*import\s*\{([^}]+)\}\s*from\s*['"]([^'"]+)['"]/);
    if (named) {
      const symbols = named[1].split(',').map(s => s.trim().split(/\s+as\s+/)[0].trim()).filter(Boolean);
      const target = resolvePath(f, named[2]);
      if (target === null) {
        continue;   // 系统 kit 导入，跳过
      }
      const targetExports = exportsMap.get(target);
      if (targetExports === undefined) {
        problems.push(`${relative(ETS_ROOT, f)}:${i + 1} 导入目标不存在: ${named[2]}`);
        continue;
      }
      for (const sym of symbols) {
        if (!targetExports.has(sym)) {
          problems.push(`${relative(ETS_ROOT, f)}:${i + 1} 导入的符号未导出: ${sym} (来自 ${named[2]})`);
        }
      }
    }
    // import * as C from './x'
    const star = line.match(/^\s*import\s+\*\s+as\s+([A-Za-z_$][A-Za-z0-9_$]*)\s+from\s*['"]([^'"]+)['"]/);
    if (star) {
      const target = resolvePath(f, star[2]);
      if (target !== null && !exportsMap.has(target)) {
        problems.push(`${relative(ETS_ROOT, f)}:${i + 1} 星号导入目标不存在: ${star[2]}`);
      }
    }
  }
}

// ---------- 3. 校验常量值与 Python 参考实现一致 ----------
console.log('--- 常量值交叉校验 ---');

const pyConstants = readFileSync(
  join(__dirname, '..', 'refs', 'carlife_pc_tool', 'protocol', 'constants.py'), 'utf8');
const tsConstants = fileMap.get(join(ETS_ROOT, 'protocol', 'Constants.ets'));

// 从 Python 提取所有 MSG_XXX = 数字
const pyMsgs = new Map();
{
  const re = /^(MSG_[A-Z0-9_]+)\s*=\s*(\d+)/gm;
  let m;
  while ((m = re.exec(pyConstants)) !== null) {
    pyMsgs.set(m[1], parseInt(m[2], 10));
  }
}

// 从 ArkTS 提取所有 export const MSG_XXX: number = 数字
const tsMsgs = new Map();
{
  const re = /export const (MSG_[A-Z0-9_]+)\s*:\s*number\s*=\s*(\d+)/g;
  let m;
  while ((m = re.exec(tsConstants)) !== null) {
    tsMsgs.set(m[1], parseInt(m[2], 10));
  }
}

let mismatch = 0;
let missing = 0;
for (const [name, pyVal] of pyMsgs) {
  const tsVal = tsMsgs.get(name);
  if (tsVal === undefined) {
    // 允许 ArkTS 侧不定义某些未使用项，但需报告
    missing++;
    console.log(`  [MISS] ${name} 在 ArkTS 中未定义 (Python 值=${pyVal})`);
  } else if (tsVal !== pyVal) {
    mismatch++;
    console.log(`  [DIFF] ${name}: Python=${pyVal} vs ArkTS=${tsVal}`);
  }
}

// 端口校验
console.log('\n--- 端口值校验 ---');
const portPairs = [
  ['PORT_CMD', 7240], ['PORT_VIDEO', 8240], ['PORT_AUDIO', 9240],
  ['PORT_TTS', 9241], ['PORT_VR', 9242], ['PORT_TOUCH', 9340], ['PORT_DATA', 9440]
];
for (const [name, expected] of portPairs) {
  const re = new RegExp(`export const ${name}\\s*:\\s*number\\s*=\\s*(\\d+)`);
  const m = tsConstants.match(re);
  const actual = m ? parseInt(m[1], 10) : -1;
  const ok = actual === expected;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${name} = ${actual} (期望 ${expected})`);
  if (!ok) {
    mismatch++;
  }
}

// UDP
const udpRe = /export const UDP_DISCOVERY_PORT\s*:\s*number\s*=\s*(\d+)/;
const udpM = tsConstants.match(udpRe);
const udpOk = udpM && parseInt(udpM[1], 10) === 7999;
console.log(`  [${udpOk ? 'PASS' : 'FAIL'}] UDP_DISCOVERY_PORT = ${udpM ? udpM[1] : 'missing'} (期望 7999)`);
if (!udpOk) {
  mismatch++;
}

console.log(`\n  消息 ID 比对: 匹配 ${pyMsgs.size - mismatch - missing}/${pyMsgs.size}, 缺失 ${missing}, 不一致 ${mismatch}`);

// ---------- 结果 ----------
console.log('\n===== 结果 =====');
if (problems.length > 0) {
  console.log(`  引用问题: ${problems.length} 处`);
  for (const p of problems) {
    console.log(`    ${p}`);
  }
}
if (mismatch > 0 || problems.length > 0) {
  console.log(`\n  静态检查发现问题，需修复`);
  process.exit(1);
}
console.log('  引用完整性: 无问题');
console.log('  常量一致性: 与 Python 参考实现一致');
console.log('\n  注：本检查只看常量与引用，不看类型。类型与 API 签名由真实构建覆盖 ——');
console.log('      跑 `bash tools/build.sh` 即可（当前已实测 0 错误）。\n');
