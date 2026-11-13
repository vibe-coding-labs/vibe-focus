#!/usr/bin/env node
/**
 * check_hero_motion.mjs — 首屏动画的确定性门禁（只读）。
 *
 * 检查三件事，任何一条不满足即 exit 1：
 *   1) 合成通道约束：wf-motion 之外的视觉元素不得动画 left/top/width/height/margin
 *      （布局属性每帧重排 = 卡顿根因，见 commit 4b85ec1）。
 *   2) 关键帧连续性：解析 @keyframes wf-motion 的 translate 分量，相邻采样帧的
 *      速度差（加速度离散近似）必须低于阈值——折线拼接时代实测 ~1890%/s。
 *   3) 覆盖完整性：rest/landing 两端关键帧必须精确落在目标坐标（防布局改动后
 *      忘记回填，见 commit f7914e6 的归位偏移事故）。
 *
 * 用法：node website/scripts/check_hero_motion.mjs [styles.css 路径]
 */

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const cssPath = process.argv[2] ?? join(ROOT, 'src', 'styles.css');
const css = readFileSync(cssPath, 'utf-8');

const failures = [];
const notes = [];

/* ---------- 1) 合成通道约束 ---------- */
// 抓所有 @keyframes 块，检查是否动画了布局属性
const kfBlocks = [...css.matchAll(/@keyframes\s+([A-Za-z0-9_-]+)\s*\{([\s\S]*?)\n\s*\}/g)];
const LAYOUT_PROPS = /\b(left|top|right|bottom|width|height|margin[a-z-]*|padding[a-z-]*)\s*:/;
for (const [, name, body] of kfBlocks) {
  // 白名单：这些 keyframes 只改 opacity/transform/filter 等合成属性
  const offending = LAYOUT_PROPS.exec(body);
  if (offending) {
    // 允许暗色演示页的像素 translate 里出现的数字，但属性名必须是 transform
    const prop = offending[1];
    const inTransform = new RegExp(`transform:[^;]*${prop}`).test(body);
    if (!inTransform) failures.push(`@keyframes ${name} 动画了布局属性 "${prop}"（应走 transform/opacity）`);
  }
}
notes.push(`扫描 ${kfBlocks.length} 组 @keyframes 的动画属性`);

/* ---------- 2) wf-motion 连续性 ---------- */
const wf = css.match(/@keyframes\s+wf-motion\s*\{([\s\S]*?)\n\s*\}/);
if (!wf) {
  failures.push('未找到 @keyframes wf-motion（首屏主动画）');
} else {
  const pts = [];
  const frameRe = /([\d.]+)%\s*\{\s*transform:\s*translate\(\s*([-\d.]+)%\s*,\s*([-\d.]+)%\s*\)\s*scale\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)/g;
  let m;
  while ((m = frameRe.exec(wf[1]))) {
    pts.push({ pct: +m[1], tx: +m[2], ty: +m[3] });
  }
  if (pts.length < 10) {
    failures.push(`wf-motion 关键帧样本过少（${pts.length}），无法判定连续性`);
  } else {
    const CYCLE = 7.5;
    let maxDv = 0, maxDvAt = 0;
    for (let i = 2; i < pts.length; i++) {
      const dt1 = ((pts[i - 1].pct - pts[i - 2].pct) / 100) * CYCLE;
      const dt2 = ((pts[i].pct - pts[i - 1].pct) / 100) * CYCLE;
      if (dt1 <= 0 || dt2 <= 0) continue;
      const v1 = (pts[i - 1].tx - pts[i - 2].tx) / dt1;
      const v2 = (pts[i].tx - pts[i - 1].tx) / dt2;
      const dv = Math.abs(v2 - v1);
      if (dv > maxDv) { maxDv = dv; maxDvAt = pts[i].pct; }
    }
    // 阈值：弹簧解析轨迹 ~40ms 采样实测 < 40%/s²；折线拼接时代 ~1890
    const THRESHOLD = 120;
    if (maxDv > THRESHOLD) {
      failures.push(`wf-motion 相邻帧速度跳变 ${maxDv.toFixed(1)}%/s 超过阈值 ${THRESHOLD}（位置 ${maxDvAt}%）——加速度不连续`);
    }
    notes.push(`wf-motion ${pts.length} 帧，最大速度跳变 ${maxDv.toFixed(1)}%/s（阈值 ${THRESHOLD}）`);
  }

  /* ---------- 3) 端点覆盖 ---------- */
  // rest 压扁态与 landing 全屏态必须出现（防止布局改动后漏改端点）
  const hasRest = pts.some((p) => Math.abs(p.tx - 12.55) < 1.5);
  const hasLand = pts.some((p) => Math.abs(p.tx) < 0.05 && Math.abs(p.ty) < 0.05);
  if (!hasRest) failures.push('wf-motion 缺少 rest 端点（translate x≈12.55%，窗口起飞/归位原格）');
  if (!hasLand) failures.push('wf-motion 缺少 landing 端点（translate≈0，主屏全屏落位）');
}

/* ---------- 输出 ---------- */
for (const n of notes) console.log(`  · ${n}`);
if (failures.length) {
  console.error('\nFAIL check_hero_motion:');
  for (const f of failures) console.error(`  ✗ ${f}`);
  process.exit(1);
}
console.log('\nPASS check_hero_motion: 合成通道 + 加速度连续性 + 端点覆盖 全部满足');
