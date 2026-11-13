#!/usr/bin/env node
/**
 * gen_hero_motion.mjs — 首屏「窗口副屏→主屏→归位」运动的弹簧物理轨迹生成器。
 *
 * 运动模型（考虑加速度连续性）：
 *   位置进度 s(t) 由欠阻尼弹簧驱动（从 0 到 1）：
 *     s(t) = 1 - e^(-ζωₙt) · (cos(ω_d·t) + (ζωₙ/ω_d)·sin(ω_d·t))
 *   → 速度/加速度全程连续（解析函数），到达时自然过冲 ~4% 再回稳（拾起→加速→
 *     减速→轻微过冲→回稳），无关键帧折线拼接的加速度突变。
 *   路径：直线插值 + 垂直法线方向的弧线偏移 amp·sin(π·s)（进度参数化，过冲时
 *   弧线已自然回落）。尺寸用独立更快收敛的弹簧（先变大再到位，解耦于位移）。
 *
 * 输出（采样帧 → CSS @keyframes wf-motion，linear timing 精确复现曲线）：
 *   1) styles.css 首屏版（stage 百分比，translate% 参照自身落位矩形）
 *   2) focus.html / restore.html 暗色演示版（像素坐标）
 * 采样密度 40ms（25fps 采样，CSS 帧间线性插值，曲线平缓段无可见折角）。
 *
 * 用法：node scripts/gen_hero_motion.mjs   （幂等，重写标记段）
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const CYCLE = 7.5;          // 循环总时长 s
const SAMPLE_DT = 0.04;     // 采样步长 s
const LINEAR = 'linear';

/** 欠阻尼弹簧进度：0 → 1（带 ~4% 过冲回稳）。ωn 越大越快，ζ 越小过冲越大。 */
function spring(t, wn, zeta) {
  const wd = wn * Math.sqrt(1 - zeta * zeta);
  if (t <= 0) return 0;
  return 1 - Math.exp(-zeta * wn * t) * (Math.cos(wd * t) + (zeta * wn / wd) * Math.sin(wd * t));
}

/** 2×2 矩阵线性插值工具：轨迹分量 */
const lerp = (a, b, u) => a + (b - a) * u;
const clamp01 = (x) => Math.min(1, Math.max(0, x));

/**
 * 一次「从 A 到 B」的弹簧行程采样。
 * rect: {x,y,w,h}（A/B 两态矩形）；arcAmp: 弧线峰值（与 A→B 距离同单位）；
 * dur: 行程时长；t0: 循环内起始时刻；dim: {wn,zeta} 位移弹簧参数；
 * dimScale: 尺寸弹簧参数（更快收敛）；fade: {inD,outD} 淡入/淡出时长。
 * 返回 [{t, transform, opacity}]，transform = translate% + scale%（参照 B 矩形）。
 */
function sampleLeg({ A, B, arcAmp, dur, t0, dim, dimScale, fadeIn = 0.12, fadeOut = 0.16, px = false }) {
  const dx = B.x - A.x, dy = B.y - A.y;
  const dist = Math.hypot(dx, dy) || 1;
  // 垂直法线（取 y 分量为负的方向 = 弧线向上抬）
  let nx = -dy / dist, ny = dx / dist;
  if (ny > 0) { nx = -nx; ny = -ny; }
  const sx = B.w / A.w, sy = B.h / A.h; // A→B 尺寸比（用于 scale 终值反推）
  const frames = [];
  const n = Math.max(2, Math.round(dur / SAMPLE_DT));
  for (let i = 0; i <= n; i++) {
    const t = (i / n) * dur;
    // 弹簧进度允许 >1（过冲自然外插，位置越过目标再回稳——这就是「落定回弹」）
    const s = spring(t, dim.wn, dim.zeta);
    // 尺寸弹簧（更快收敛，几乎无过冲）：先变大再到位
    const sSize = spring(t, dimScale.wn, dimScale.zeta);
    const w = lerp(A.w, B.w, sSize);
    const h = lerp(A.h, B.h, sSize);
    // 位置：直线插值（弹簧进度，过冲外插）+ 弧线法线偏移（弧线只作用到达前）
    const arc = Math.sin(Math.PI * Math.min(1, Math.max(0, s))) * arcAmp;
    const x = lerp(A.x, B.x, s) + nx * arc;
    const y = lerp(A.y, B.y, s) + ny * arc;
    // transform：换算成 translate%（参照 B 尺寸）+ scale（A 尺寸/B 尺寸 · 尺寸弹簧）
    const k = px ? 1 : 100;
    const txPct = ((x - B.x) / B.w) * k;
    const tyPct = ((y - B.y) / B.h) * k;
    const scaleX = w / B.w;
    const scaleY = h / B.h;
    const transform = `translate(${txPct.toFixed(3)}%, ${tyPct.toFixed(3)}%) scale(${scaleX.toFixed(4)}, ${scaleY.toFixed(4)})`;
    // opacity：起飞 fadeIn 淡入，落定后保持，返程末 fadeOut 淡出由调用方处理
    const opacity = clamp01(t / fadeIn);
    frames.push({ t: t0 + t, transform, opacity });
  }
  return { frames, dist };
}

/** 把「静止段」帧插入采样表（静止：transform=rest 压扁态/主屏态，opacity 按交接） */
function holdFrames(list, tStart, tEnd, transform, opacity) {
  const n = Math.max(1, Math.round((tEnd - tStart) / SAMPLE_DT));
  for (let i = 0; i <= n; i++) {
    const t = tStart + (i / n) * (tEnd - tStart);
    list.push({ t, transform, opacity });
  }
}

/** 采样序列 → CSS keyframes 文本 */
function toKeyframes(frames, unit, name, extra = '') {
  const body = frames
    .map((f) => {
      const pct = ((f.t / CYCLE) * 100).toFixed(2);
      return `  ${pct}% { transform: ${f.transform.replace(/%/g, unit)}; opacity: ${f.opacity.toFixed(3)}; animation-timing-function: ${LINEAR}; }`;
    })
    .join('\n');
  return `@keyframes ${name} {\n${body}\n${extra}}`;
}

/* ================= 编排参数 ================= */

// 去程弹簧：ωn=2.53 ζ=0.72 → ~1.8s 过冲峰值 ~4%，2.6s 回稳（加速度全程连续）
const GO = { dur: 2.6, dim: { wn: 2.53, zeta: 0.72 }, dimScale: { wn: 3.4, zeta: 0.85 } };
// 返程弹簧：稍慢更从容
const BACK = { dur: 2.75, dim: { wn: 2.4, zeta: 0.7 }, dimScale: { wn: 3.2, zeta: 0.85 } };

const T_REST0_END = 0.5;      // 开场静止段结束
const T_GO_START = 0.5;       // 去程起点
const T_STAY0 = T_GO_START + GO.dur;   // 3.1 到达
const T_STAY1 = 4.55;         // 停留结束
const T_BACK_START = 4.55;    // 返程起点
const T_BACK_END = T_BACK_START + BACK.dur; // 7.3 回到 rest
// 7.3-7.5 静止段与循环头衔接

/* ================= 1) 首屏版（stage 百分比，win 基准=主屏落位矩形） ================= */
// 实测矩形（stage 百分比）：rest=副屏 1 格(2,2)；landing=主屏菜单栏以下全屏贴边
const wfRest = { x: 20.5, y: 30.57, w: 13.14, h: 10.64 };
const wfLand = { x: 10.62, y: 57.72, w: 78.76, h: 34.34 };
const wfArc = 5.5; // 弧线峰值（stage %，向上）

const wfFrames = [];
holdFrames(wfFrames, 0, T_GO_START, 'translate(12.55%, -79.06%) scale(0.167, 0.31)', 0);
{
  const leg = sampleLeg({ A: wfRest, B: wfLand, arcAmp: wfArc, dur: GO.dur, t0: T_GO_START, dim: GO.dim, dimScale: GO.dimScale });
  leg.frames.forEach(f => wfFrames.push({ ...f, opacity: Math.max(f.opacity, 0) }));
}
holdFrames(wfFrames, T_STAY0, T_STAY1, 'translate(0, 0) scale(1, 1)', 1);
{
  const leg = sampleLeg({ A: wfLand, B: wfRest, arcAmp: wfArc, dur: BACK.dur, t0: T_BACK_START, dim: BACK.dim, dimScale: BACK.dimScale });
  leg.frames.forEach(f => wfFrames.push({ ...f, opacity: 1 })); // 返程全程可见，尾部淡出由末尾覆写处理
}
holdFrames(wfFrames, T_BACK_END, CYCLE, 'translate(12.55%, -79.06%) scale(0.167, 0.31)', 0);
// 返程末尾淡出交还 mini：把 7.12-7.5s 的 opacity 覆写为渐隐
for (const f of wfFrames) {
  if (f.t > 7.12) f.opacity = clamp01((7.5 - f.t) / 0.38); // 7.12-7.5s 渐隐交还 mini
}
wfFrames.sort((a, b) => a.t - b.t);
// 去重同刻
const wfDedup = wfFrames.filter((f, i) => i === 0 || f.t > wfFrames[i - 1].t + 1e-6);
const wfKf = toKeyframes(wfDedup, '', 'wf-motion');

/* ================= 2) 暗色演示版（像素，focus：副屏→主屏） ================= */
const dRest = { x: 159, y: 184, w: 103, h: 67 };
const dLand = { x: 123, y: 314, w: 554, h: 164 };
const dArc = 14;
const dFrames = [];
holdFrames(dFrames, 0, T_GO_START, 'translate(36px, -130px) scale(0.186, 0.409)', 0);
{
  const leg = sampleLeg({ A: dRest, B: dLand, arcAmp: dArc, dur: GO.dur, t0: T_GO_START, dim: GO.dim, dimScale: GO.dimScale, px: true });
  leg.frames.forEach(f => dFrames.push(f));
}
holdFrames(dFrames, T_STAY0, T_STAY1, 'translate(0, 0) scale(1, 1)', 1);
holdFrames(dFrames, T_STAY1, T_BACK_START, 'translate(0, 0) scale(1, 1)', 1);
{
  const leg = sampleLeg({ A: dLand, B: dRest, arcAmp: dArc, dur: BACK.dur, t0: T_BACK_START, dim: BACK.dim, dimScale: BACK.dimScale, px: true });
  leg.frames.forEach(f => dFrames.push(f));
}
holdFrames(dFrames, T_BACK_END, CYCLE, 'translate(36px, -130px) scale(0.186, 0.409)', 0);
dFrames.sort((a, b) => a.t - b.t);
const dDedup = dFrames.filter((f, i) => i === 0 || f.t > dFrames[i - 1].t + 1e-6);
const dKf = toKeyframes(dDedup, 'px', 'win-motion');

/* ================= 3) restore.html（主屏→副屏，方向反转） ================= */
const rFrames = [];
holdFrames(rFrames, 0, T_GO_START, 'translate(0, 0) scale(1, 1)', 1);
{
  const leg = sampleLeg({ A: dLand, B: dRest, arcAmp: dArc, dur: GO.dur, t0: T_GO_START, dim: GO.dim, dimScale: GO.dimScale, px: true });
  leg.frames.forEach(f => rFrames.push(f));
}
holdFrames(rFrames, T_STAY0, T_STAY1, 'translate(36px, -130px) scale(0.186, 0.409)', 1);
holdFrames(rFrames, T_STAY1, T_BACK_START, 'translate(36px, -130px) scale(0.186, 0.409)', 1);
{
  const leg = sampleLeg({ A: dRest, B: dLand, arcAmp: dArc, dur: BACK.dur, t0: T_BACK_START, dim: BACK.dim, dimScale: BACK.dimScale, px: true });
  leg.frames.forEach(f => rFrames.push(f));
}
holdFrames(rFrames, T_BACK_END, CYCLE, 'translate(0, 0) scale(1, 1)', 1);
rFrames.sort((a, b) => a.t - b.t);
const rDedup = rFrames.filter((f, i) => i === 0 || f.t > rFrames[i - 1].t + 1e-6);
const rKf = toKeyframes(rDedup, 'px', 'win-motion');

/* ================= 数值验证：速度连续性 ================= */
function smoothnessReport(frames) {
  // 相邻采样帧速度差（加速度的离散近似）：弹簧解析曲线下应无跳变（< 数十 %/s²）
  const pts = frames.map(f => ({
    t: f.t,
    tx: parseFloat((f.transform.match(/translate\(([-\d.]+)/) || [])[1] ?? '0'),
  })).filter(p => Number.isFinite(p.tx));
  let maxDv = 0;
  for (let i = 2; i < pts.length; i++) {
    const dt1 = pts[i - 1].t - pts[i - 2].t, dt2 = pts[i].t - pts[i - 1].t;
    if (dt1 <= 0 || dt2 <= 0) continue;
    const v1 = (pts[i - 1].tx - pts[i - 2].tx) / dt1;
    const v2 = (pts[i].tx - pts[i - 1].tx) / dt2;
    if (Number.isFinite(v1) && Number.isFinite(v2)) maxDv = Math.max(maxDv, Math.abs(v2 - v1));
  }
  return maxDv.toFixed(1);
}
console.log(`[gen_hero_motion] wf frames=${wfDedup.length}, focus=${dDedup.length}, restore=${rDedup.length}`);
console.log(`[gen_hero_motion] 相邻帧速度最大跳变（translate%/s，越小越丝滑）：wf=${smoothnessReport(wfDedup)}`);

/* ================= 辅助动画相位（7.5s 统一时间轴，采样为阶梯关键帧） ================= */

// 阶梯关键帧：[[pct, opacity], ...] 已排序 → keyframes 文本
function stepKf(points) {
  const body = points.map(([p, o]) => `  ${p.toFixed(2)}% { opacity: ${o.toFixed(3)}; }`).join('\n');
  return '@keyframes {' + '\n' + body + '\n}';
}

// 时间轴：去程弹簧 0.75→3.1s（10%→41.3%），停留 3.1→4.55s（41.3→60.7%），
// 返程弹簧 4.75→7.3s（63.3→97.3%），首尾静止
const MINI = [[0, 1], [9, 1], [12, 0], [94, 0], [96, 1], [100, 1]];
const SLOT_GO = [[0, 0], [10, 0], [13, 1], [94, 1], [97, 0], [100, 0]];   // focus：离开期间空位
const SLOT_BACK = [[0, 1], [9, 1], [12, 0], [100, 0]];                    // restore：主屏期间空位
const DETAIL_GO = [[0, 0], [16, 0], [30, 1], [59, 1], [63, 0], [100, 0]]; // focus：落位后完整终端
const DETAIL_BACK = [[0, 1], [8, 1], [11, 0], [41, 0], [45, 1], [93, 1], [96, 0], [100, 1]]; // restore：主屏大窗显示完整内容
const MINILINE_GO = [[0, 1], [16, 1], [30, 0], [59, 0], [63, 1], [100, 1]];
const MINILINE_BACK = [[0, 0], [8, 0], [11, 1], [41, 1], [45, 0], [93, 0], [96, 1], [100, 0]];
const KEY = [[0, 0], [5, 0], [6.5, 1], [9, 0], [57.5, 0], [59, 1], [62, 0], [100, 0]]; // ⌃Q 双脉冲
const BADGE_GO = [[0, 0], [46, 0], [49, 1], [58, 1], [61, 0], [100, 0]];
const BADGE_BACK = [[0, 0], [63, 0], [66, 1], [78, 1], [81, 0], [100, 0]];

function writeHelperKf(html, name, points) {
  const kf = `@keyframes ${name}{${points.map(([p, o]) => `${p}%{opacity:${o.toFixed(3)}}`).join('')}}`;
  const re = new RegExp(`@keyframes ${name}\\{[^}]*\\}`);
  if (!re.test(html)) throw new Error(`keyframes ${name} not found`);
  return html.replace(re, kf);
}

/* ================= 写入 ================= */
const MARK_BEGIN = '/* AUTO-GENERATED by scripts/gen_hero_motion.mjs — do not hand-edit */';
const MARK_END = '/* END AUTO-GENERATED */';

// 1) styles.css：替换标记段（不存在则追加到 .wf-win 动画声明后）
const cssPath = join(ROOT, 'src', 'styles.css');
let css = readFileSync(cssPath, 'utf-8');
const cssBlock = `${MARK_BEGIN}\n${wfKf}\n${MARK_END}`;
if (css.includes(MARK_BEGIN)) {
  css = css.replace(new RegExp(`${MARK_BEGIN.replace(/[*/]/g, '\\$&')}[\\s\\S]*?${MARK_END.replace(/[*/]/g, '\\$&')}`), cssBlock);
} else {
  css = css.replace('animation: wf-motion 7.5s ease-in-out infinite;', `animation: wf-motion 7.5s ${LINEAR} infinite;\n${cssBlock}`);
}
writeFileSync(cssPath, css);

// 2) focus.html：win 动画改 wf-motion + 替换标记段
const focusPath = join(ROOT, 'demos-src', 'focus.html');
let focus = readFileSync(focusPath, 'utf-8');
focus = focus.replace(
  /@keyframes fly\{[\s\S]*?\n\}/,
  `${MARK_BEGIN}\n${dKf.replace('@keyframes win-motion', '@keyframes fly')}\n${MARK_END}`
);
focus = focus.replace(/\.win\{position:absolute;[^}]*animation:fly 5s ease-in-out infinite,lift 5s ease-in-out infinite;z-index:3\}/,
  '.win{position:absolute;left:123px;top:314px;width:554px;height:164px;background:#0d2233;border:1.5px solid #2f9fce;border-radius:6px;overflow:hidden;animation:fly 7.5s linear infinite;transform-origin:0 0;z-index:3}');
// lift keyframes 不再被引用，删除
focus = focus.replace(/@keyframes lift\{[\s\S]*?\n\}\n/, '');
// 3) restore.html：同构
const restorePath = join(ROOT, 'demos-src', 'restore.html');
let restore = readFileSync(restorePath, 'utf-8');
restore = restore.replace(
  /@keyframes fly\{[\s\S]*?\n\}/,
  `${MARK_BEGIN}\n${rKf.replace('@keyframes win-motion', '@keyframes fly')}\n${MARK_END}`
);
restore = restore.replace(/\.win\{position:absolute;[^}]*animation:fly 5s ease-in-out infinite,lift 5s ease-in-out infinite;z-index:3\}/,
  '.win{position:absolute;left:123px;top:314px;width:554px;height:164px;background:#0d2233;border:1.5px solid #2f9fce;border-radius:6px;overflow:hidden;animation:fly 7.5s linear infinite;transform-origin:0 0;z-index:3}');
restore = restore.replace(/@keyframes lift\{[\s\S]*?\n\}\n/, '');
writeFileSync(restorePath, restore);

// 暗色页辅助动画：7.5s 统一时间轴相位 + duration 同步
for (const entry of [['focus', focus], ['restore', restore]]) {
  const p = entry[0];
  let htmlRef = entry[1];
  const isGo = p === 'focus';
  htmlRef = writeHelperKf(htmlRef, 's', isGo ? SLOT_GO : SLOT_BACK);
  htmlRef = writeHelperKf(htmlRef, 'dt', isGo ? DETAIL_GO : DETAIL_BACK);
  htmlRef = writeHelperKf(htmlRef, 'dtr', isGo ? MINILINE_GO : MINILINE_BACK);
  htmlRef = writeHelperKf(htmlRef, 'k', KEY);
  htmlRef = writeHelperKf(htmlRef, 'b', isGo ? BADGE_GO : BADGE_BACK);
  htmlRef = htmlRef.replace(/ 5s ease infinite/g, ' 7.5s linear infinite');
  htmlRef = htmlRef.replace(/animation:blink 1s steps\(1\) infinite,dt 7.5s linear infinite/g, 'animation:blink 1s steps(1) infinite,dt 7.5s linear infinite');
  if (p === 'focus') focus = htmlRef; else restore = htmlRef;
}
writeFileSync(focusPath, focus);
writeFileSync(restorePath, restore);
console.log('[gen_hero_motion] written: styles.css, demos-src/focus.html, demos-src/restore.html');
