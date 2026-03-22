import React from 'react';
import {
  AbsoluteFill,
  useCurrentFrame,
  interpolate,
  spring,
} from 'remotion';

// Color palette - enhanced for better visual appeal
const COLORS = {
  bgDark: '#0a1929',
  bgDarker: '#050f18',
  cyan: '#00d4ff',
  cyanLight: '#5ce1ff',
  cyanGlow: 'rgba(0, 212, 255, 0.4)',
  monitorBg: '#0d2137',
  monitorBorder: '#1a3a52',
  monitorBorderActive: '#00d4ff',
  codeBg: '#0a1929',
  codeLine1: '#00d4ff',
  codeLine2: '#5ce1ff',
  codeLine3: '#8dd4df',
  successGreen: '#00d084',
  textLight: '#ffffff',
  textMuted: '#8b9dc3',
  textSecondary: '#6b7c9c',
  windowBorder: '#2a3f52',
  highlight: '#ffd700',
  // MacBook colors - more realistic
  macbookSpaceGray: '#2d2d2d',
  macbookDarkGray: '#1a1a1a',
  macbookAluminum: '#3d3d3d',
  macbookKeyboard: '#1f1f1f',
  macbookKey: '#2a2a2a',
  macbookKeyHighlight: '#3a3a3a',
  notchBlack: '#000000',
  // Enhanced glow colors
  glowCyan: 'rgba(0, 212, 255, 0.6)',
  glowGold: 'rgba(255, 215, 0, 0.5)',
};

// Canvas dimensions - 标准 16:9，所有元素安全显示
const CANVAS = {
  width: 1280,
  height: 720,
};

type Rect = {
  x: number;
  y: number;
  width: number;
  height: number;
};

// MacBook Pro - 缩小以适应画布
const MACBOOK = {
  width: 360,
  height: 230,
  borderRadius: 12,
};

const MACBOOK_GEOMETRY = {
  bezelHorizontalRatio: 0.028,
  bezelTopRatio: 0.022,
  bezelBottomRatio: 0.035,
  baseHeightRatio: 0.16,
  baseExtensionRatio: 0.06,
  notchWidthRatio: 0.12,
  notchHeightRatio: 0.018,
};

const MONITOR_GEOMETRY = {
  bezel: 12,
  standWidthRatio: 0.15,
  standHeightRatio: 0.08,
  baseWidthRatio: 0.25,
  baseHeightRatio: 0.03,
};

const getMacBookScreenRect = (macbook: Rect): Rect => {
  const bezelHorizontal = macbook.width * MACBOOK_GEOMETRY.bezelHorizontalRatio;
  const bezelTop = macbook.height * MACBOOK_GEOMETRY.bezelTopRatio;
  const bezelBottom = macbook.height * MACBOOK_GEOMETRY.bezelBottomRatio;
  const baseHeight = macbook.height * MACBOOK_GEOMETRY.baseHeightRatio;

  return {
    x: macbook.x + bezelHorizontal,
    y: macbook.y + bezelTop,
    width: macbook.width - bezelHorizontal * 2,
    height: macbook.height - baseHeight - bezelTop - bezelBottom,
  };
};

const getExternalMonitorScreenRect = (monitor: Rect): Rect => {
  const standHeight = monitor.height * MONITOR_GEOMETRY.standHeightRatio;
  const baseHeight = monitor.height * MONITOR_GEOMETRY.baseHeightRatio;

  return {
    x: monitor.x + MONITOR_GEOMETRY.bezel,
    y: monitor.y + MONITOR_GEOMETRY.bezel,
    width: monitor.width - MONITOR_GEOMETRY.bezel * 2,
    height: monitor.height - MONITOR_GEOMETRY.bezel * 2 - standHeight - baseHeight,
  };
};

const assertRectInside = (inner: Rect, outer: Rect, label: string) => {
  const epsilon = 0.5;
  if (inner.x < outer.x - epsilon ||
    inner.y < outer.y - epsilon ||
    inner.x + inner.width > outer.x + outer.width + epsilon ||
    inner.y + inner.height > outer.y + outer.height + epsilon) {
    throw new Error(`${label} is outside of screen bounds`);
  }
};

// External monitors - 适当大小
const MONITOR = {
  mbScreenWidth: MACBOOK.width * (1 - MACBOOK_GEOMETRY.bezelHorizontalRatio * 2),
  mbScreenHeight: MACBOOK.height * (1 - MACBOOK_GEOMETRY.baseHeightRatio - MACBOOK_GEOMETRY.bezelTopRatio - MACBOOK_GEOMETRY.bezelBottomRatio),
  scale: 1.3,
};

MONITOR.width = Math.round(MONITOR.mbScreenWidth * MONITOR.scale);
MONITOR.height = Math.round(MONITOR.mbScreenHeight * MONITOR.scale);

// Calculate positions for 1280x720 canvas
const totalMonitorsWidth = MONITOR.width * 2 + 40;
const monitorsStartX = (CANVAS.width - totalMonitorsWidth) / 2;
const monitorsY = 50;

const macbookX = (CANVAS.width - MACBOOK.width) / 2;
const macbookY = CANVAS.height - MACBOOK.height - 40;

// Cloud Code editor content
const CODE_CONTENT = {
  title: 'Cloud Code',
  lines: [
    { content: 'import { Agent } from "cloud-code";', color: COLORS.cyan },
    { content: 'import { AIAssistant } from "@cloud/ai";', color: COLORS.cyan },
    { content: '', color: COLORS.textMuted },
    { content: 'const agent = new Agent({', color: COLORS.cyanLight },
    { content: '  model: "claude-opus",', color: COLORS.codeLine3 },
    { content: '  capabilities: ["code", "review", "debug"]', color: COLORS.codeLine3 },
    { content: '});', color: COLORS.cyanLight },
    { content: '', color: COLORS.textMuted },
    { content: '// Start coding with AI', color: COLORS.textMuted },
    { content: 'await agent.initialize();', color: COLORS.cyan },
  ],
};

// Cloud Code Window Component
const CloudCodeWindow: React.FC<{
  x: number;
  y: number;
  width: number;
  height: number;
  isFocused?: boolean;
  isActive?: boolean;
  opacity?: number;
  zIndex?: number;
}> = ({ x, y, width, height, isFocused = false, isActive = false, opacity = 1, zIndex = 1 }) => {
  const scale = width / 280; // Base scale for content

  return (
    <div
      style={{
        position: 'absolute',
        left: x,
        top: y,
        width: width,
        height: height,
        backgroundColor: COLORS.codeBg,
        borderRadius: 8,
        border: `2px solid ${isFocused ? COLORS.cyan : isActive ? COLORS.highlight : COLORS.windowBorder}`,
        opacity: opacity,
        boxShadow: isFocused
          ? `0 0 30px ${COLORS.cyanGlow}, 0 8px 32px rgba(0,0,0,0.5)`
          : '0 4px 20px rgba(0,0,0,0.4)',
        overflow: 'hidden',
        zIndex: zIndex,
      }}
    >
      {/* Title bar - macOS style */}
      <div
        style={{
          height: Math.round(26 * scale),
          backgroundColor: isFocused ? `${COLORS.cyan}15` : COLORS.monitorBg,
          borderBottom: `1px solid ${isFocused ? COLORS.cyan : COLORS.monitorBorder}`,
          display: 'flex',
          alignItems: 'center',
          paddingLeft: Math.round(12 * scale),
          paddingRight: Math.round(12 * scale),
          gap: Math.round(8 * scale),
        }}
      >
        {/* Traffic lights */}
        <div style={{ display: 'flex', gap: Math.round(6 * scale) }}>
          <div style={{ width: Math.round(10 * scale), height: Math.round(10 * scale), borderRadius: '50%', backgroundColor: '#ff5f56' }} />
          <div style={{ width: Math.round(10 * scale), height: Math.round(10 * scale), borderRadius: '50%', backgroundColor: '#ffbd2e' }} />
          <div style={{ width: Math.round(10 * scale), height: Math.round(10 * scale), borderRadius: '50%', backgroundColor: '#27ca40' }} />
        </div>
        {/* Window title */}
        <div
          style={{
            marginLeft: 'auto',
            marginRight: 'auto',
            color: isFocused ? COLORS.cyan : COLORS.textMuted,
            fontSize: Math.round(11 * scale),
            fontFamily: 'system-ui, -apple-system, sans-serif',
            fontWeight: isFocused ? 600 : 500,
          }}
        >
          {CODE_CONTENT.title}
        </div>
        <div style={{ width: Math.round(40 * scale) }} />
      </div>

      {/* Code content area */}
      <div
        style={{
          padding: Math.round(10 * scale),
          height: `calc(100% - ${Math.round(26 * scale)}px)`,
          backgroundColor: COLORS.codeBg,
          fontFamily: 'Menlo, Monaco, Consolas, monospace',
          fontSize: Math.round(9 * scale),
          lineHeight: 1.5,
          overflow: 'hidden',
        }}
      >
        {CODE_CONTENT.lines.map((line, idx) => (
          <div key={idx} style={{ display: 'flex', alignItems: 'center', height: Math.round(14 * scale) }}>
            <span style={{ color: COLORS.textSecondary, marginRight: Math.round(12 * scale), userSelect: 'none' }}>
              {(idx + 1).toString().padStart(2, ' ')}
            </span>
            <span style={{ color: line.color || COLORS.textLight }}>
              {line.content}
            </span>
          </div>
        ))}
      </div>

      {/* Focus indicator */}
      {isFocused && (
        <div style={{
          position: 'absolute',
          top: Math.round(4 * scale),
          right: Math.round(4 * scale),
          width: Math.round(6 * scale),
          height: Math.round(6 * scale),
          borderRadius: '50%',
          backgroundColor: COLORS.cyan,
          boxShadow: `0 0 8px ${COLORS.cyan}`,
        }} />
      )}
    </div>
  );
};

// Enhanced MacBook Pro Component with better glow effects
const MacBookPro: React.FC<{
  x: number;
  y: number;
  width: number;
  height: number;
  isActive?: boolean;
  glowIntensity?: number;
}> = ({ x, y, width, height, isActive = false, glowIntensity = 0 }) => {
  // Screen dimensions (thin bezels like real MBP)
  const baseHeight = height * MACBOOK_GEOMETRY.baseHeightRatio;
  const bezelHorizontal = width * MACBOOK_GEOMETRY.bezelHorizontalRatio;
  const bezelTop = height * MACBOOK_GEOMETRY.bezelTopRatio;
  const bezelBottom = height * MACBOOK_GEOMETRY.bezelBottomRatio;
  const screenWidth = width - bezelHorizontal * 2;
  const screenHeight = height - baseHeight - bezelTop - bezelBottom;

  // Base/keyboard proportions
  const baseExtension = width * MACBOOK_GEOMETRY.baseExtensionRatio;

  // Notch dimensions (like MBP 14/16)
  const notchWidth = width * MACBOOK_GEOMETRY.notchWidthRatio;
  const notchHeight = height * MACBOOK_GEOMETRY.notchHeightRatio;

  return (
    <div style={{ position: 'absolute', left: x, top: y, width: width, height: height }}>
      {/* Enhanced Glow effect */}
      {glowIntensity > 0 && (
        <div style={{
          position: 'absolute',
          top: -40,
          left: -50,
          right: -50,
          bottom: -30,
          background: `radial-gradient(ellipse at center bottom, ${COLORS.glowCyan} 0%, ${COLORS.glowGold} 20%, transparent 60%)`,
          opacity: glowIntensity,
          pointerEvents: 'none',
          filter: 'blur(30px)',
        }} />
      )}

      {/* Screen bezel - outer frame */}
      <div style={{
        position: 'absolute',
        left: 0,
        top: 0,
        width: width,
        height: height - baseHeight,
        background: `linear-gradient(145deg, ${COLORS.macbookSpaceGray} 0%, ${COLORS.macbookDarkGray} 50%, ${COLORS.macbookSpaceGray} 100%)`,
        borderRadius: MACBOOK.borderRadius,
        boxShadow: isActive || glowIntensity > 0
          ? `0 0 ${80 * glowIntensity}px ${COLORS.cyan}, 0 25px 70px rgba(0,0,0,0.7), inset 0 1px 2px rgba(255,255,255,0.15)`
          : '0 10px 40px rgba(0,0,0,0.5), inset 0 1px 2px rgba(255,255,255,0.1)',
        overflow: 'hidden',
        border: glowIntensity > 0
          ? `2px solid ${COLORS.cyan}`
          : '1px solid rgba(255,255,255,0.1)',
      }}>
        {/* Inner bezel gradient */}
        <div style={{
          position: 'absolute',
          top: 0,
          left: 0,
          right: 0,
          bottom: 0,
          background: `linear-gradient(180deg, ${COLORS.macbookDarkGray} 0%, ${COLORS.macbookSpaceGray} 50%, ${COLORS.macbookDarkGray} 100%)`,
          borderRadius: MACBOOK.borderRadius,
        }} />

        {/* Screen area */}
        <div style={{
          position: 'absolute',
          left: bezelHorizontal,
          top: bezelTop,
          width: screenWidth,
          height: screenHeight,
          backgroundColor: COLORS.monitorBg,
          borderRadius: 6,
          overflow: 'hidden',
          boxShadow: isActive || glowIntensity > 0
            ? `inset 0 0 ${100 * glowIntensity}px rgba(0,0,0,0.3), 0 0 30px ${COLORS.cyanGlow}`
            : 'inset 0 0 60px rgba(0,0,0,0.3)',
        }}>
          {/* Screen reflection */}
          <div style={{
            position: 'absolute',
            top: 0,
            left: 0,
            right: 0,
            height: '55%',
            background: 'linear-gradient(180deg, rgba(255,255,255,0.05) 0%, transparent 100%)',
            pointerEvents: 'none',
          }} />

          {/* Screen border glow when active */}
          {(isActive || glowIntensity > 0) && (
            <div style={{
              position: 'absolute',
              top: 0,
              left: 0,
              right: 0,
              bottom: 0,
              border: `2px solid ${COLORS.cyan}`,
              borderRadius: 6,
              opacity: glowIntensity,
              pointerEvents: 'none',
              boxShadow: `0 0 20px ${COLORS.cyan}, inset 0 0 20px ${COLORS.cyanGlow}`,
            }} />
          )}
        </div>

        {/* Notch */}
        <div style={{
          position: 'absolute',
          top: bezelTop - 1,
          left: '50%',
          transform: 'translateX(-50%)',
          width: notchWidth,
          height: notchHeight + 2,
          backgroundColor: COLORS.notchBlack,
          borderRadius: '0 0 10px 10px',
          zIndex: 10,
          boxShadow: '0 2px 8px rgba(0,0,0,0.5)',
        }}>
          {/* Camera lens */}
          <div style={{
            position: 'absolute',
            top: '35%',
            left: '50%',
            transform: 'translate(-50%, -50%)',
            width: 7,
            height: 7,
            backgroundColor: '#1a1a1a',
            borderRadius: '50%',
            boxShadow: 'inset 0 0 3px rgba(255,255,255,0.3), 0 0 2px rgba(0,0,0,0.8)',
          }}>
            <div style={{
              position: 'absolute',
              top: '30%',
              left: '30%',
              width: 2,
              height: 2,
              backgroundColor: '#0d3b5c',
              borderRadius: '50%',
              boxShadow: '0 0 2px rgba(0,212,255,0.5)',
            }} />
          </div>
        </div>

        {/* Apple logo (subtle on bezel) */}
        <div style={{
          position: 'absolute',
          bottom: height * 0.03,
          left: '50%',
          transform: 'translateX(-50%)',
          width: 18,
          height: 22,
          opacity: glowIntensity > 0 ? 0.3 : 0.15,
        }}>
          <svg viewBox="0 0 16 20" fill="currentColor" style={{ color: glowIntensity > 0 ? COLORS.cyan : COLORS.textLight, filter: glowIntensity > 0 ? `drop-shadow(0 0 5px ${COLORS.cyan})` : 'none' }}>
            <path d="M10.5 0c-.8.1-1.7.6-2.2 1.2-.5.6-.9 1.5-.8 2.4.9.1 1.8-.4 2.3-1 .6-.6.9-1.5.8-2.4-.1 0-.1 0 0 0zm-2.9 3.3c-1.1 0-1.5.6-2.3.6-.8 0-1.3-.6-2.2-.6-.8 0-1.7.5-2.3 1.3-1 1.5-.9 4.4 1.6 7.3.6.7 1.4 1.5 2.4 1.5.9 0 1.3-.6 2.2-.6.9 0 1.2.6 2.2.6 1.4 0 2.4-1.3 3.1-2.1-1.8-.9-2.9-2.7-2.9-4.7 0-1.8 1-2.8 2.1-3.3-.3-.7-.9-1.1-1.5-1.1-.6 0-1.4.4-2.4.4z"/>
          </svg>
        </div>
      </div>

      {/* Hinge */}
      <div style={{
        position: 'absolute',
        top: height - baseHeight - 4,
        left: -baseExtension,
        width: width + baseExtension * 2,
        height: 8,
        background: `linear-gradient(180deg, ${COLORS.macbookDarkGray} 0%, ${COLORS.macbookSpaceGray} 100%)`,
        borderRadius: '4px 4px 0 0',
        zIndex: 5,
        boxShadow: '0 -2px 4px rgba(0,0,0,0.3)',
      }} />

      {/* Base/Keyboard deck */}
      <div style={{
        position: 'absolute',
        bottom: 0,
        left: -baseExtension,
        width: width + baseExtension * 2,
        height: baseHeight,
        background: `linear-gradient(180deg, ${COLORS.macbookAluminum} 0%, ${COLORS.macbookSpaceGray} 30%, ${COLORS.macbookDarkGray} 100%)`,
        borderRadius: '0 0 18px 18px',
        boxShadow: '0 12px 35px rgba(0,0,0,0.5), 0 5px 15px rgba(0,0,0,0.4)',
        zIndex: 6,
      }}>
        {/* Top edge highlight */}
        <div style={{
          position: 'absolute',
          top: 0,
          left: 0,
          right: 0,
          height: 2,
          background: 'linear-gradient(90deg, transparent, rgba(255,255,255,0.15), transparent)',
        }} />

        {/* Keyboard area */}
        <div style={{
          position: 'absolute',
          top: baseHeight * 0.08,
          left: '8%',
          right: '8%',
          height: baseHeight * 0.66,
          backgroundColor: '#171717',
          borderRadius: 5,
          overflow: 'hidden',
          boxShadow: 'inset 0 2px 4px rgba(0,0,0,0.5)',
        }}>
          {/* Keys - subtle hint */}
          <div style={{
            position: 'absolute',
            top: '10%',
            left: '5%',
            right: '5%',
            height: '80%',
            background: `repeating-linear-gradient(
              90deg,
              ${COLORS.macbookKey} 0px,
              ${COLORS.macbookKey} 11px,
              transparent 11px,
              transparent 14px
            ),
            repeating-linear-gradient(
              0deg,
              ${COLORS.macbookKey} 0px,
              ${COLORS.macbookKey} 8px,
              transparent 8px,
              transparent 11px
            )`,
            opacity: 0.82,
          }} />

          {/* Function row hint */}
          <div style={{
            position: 'absolute',
            top: '8%',
            left: '5%',
            right: '5%',
            height: '15%',
            background: `repeating-linear-gradient(
              90deg,
              ${COLORS.macbookKeyHighlight} 0px,
              ${COLORS.macbookKeyHighlight} 6px,
              transparent 6px,
              transparent 8px
            )`,
            opacity: 0.55,
          }} />
        </div>

        {/* Trackpad */}
        <div style={{
          position: 'absolute',
          bottom: '12%',
          left: '50%',
          transform: 'translateX(-50%)',
          width: '32%',
          height: '28%',
          backgroundColor: 'rgba(255,255,255,0.03)',
          borderRadius: 6,
          border: '1px solid rgba(255,255,255,0.05)',
        }} />

        {/* Side speaker grilles */}
        <div style={{
          position: 'absolute',
          top: '35%',
          left: '3%',
          width: '5%',
          height: '40%',
          background: `repeating-linear-gradient(
            0deg,
            rgba(0,0,0,0.3) 0px,
            rgba(0,0,0,0.3) 1px,
            transparent 1px,
            transparent 3px
          )`,
          opacity: 0.5,
        }} />
        <div style={{
          position: 'absolute',
          top: '35%',
          right: '3%',
          width: '5%',
          height: '40%',
          background: `repeating-linear-gradient(
            0deg,
            rgba(0,0,0,0.3) 0px,
            rgba(0,0,0,0.3) 1px,
            transparent 1px,
            transparent 3px
          )`,
          opacity: 0.5,
        }} />
      </div>

      {/* Label */}
      <div style={{
        position: 'absolute',
        bottom: -28,
        left: 0,
        right: 0,
        textAlign: 'center',
      }}>
        <span style={{
          color: isActive ? COLORS.cyan : COLORS.textMuted,
          fontSize: 12,
          fontWeight: isActive ? 600 : 500,
          fontFamily: 'system-ui, -apple-system, sans-serif',
          padding: '3px 10px',
          backgroundColor: isActive ? `${COLORS.cyan}15` : 'transparent',
          borderRadius: 4,
        }}>
          MacBook Pro
        </span>
      </div>
    </div>
  );
};

// Enhanced External Monitor Component with better glow effects
const ExternalMonitor: React.FC<{
  x: number;
  y: number;
  width: number;
  height: number;
  label: string;
  isActive?: boolean;
  hasGlow?: boolean;
  glowIntensity?: number;
}> = ({ x, y, width, height, label, isActive = false, hasGlow = false, glowIntensity = 0 }) => {
  // Monitor proportions
  const standWidth = width * MONITOR_GEOMETRY.standWidthRatio;
  const standHeight = height * MONITOR_GEOMETRY.standHeightRatio;
  const baseWidth = width * MONITOR_GEOMETRY.baseWidthRatio;
  const baseHeight = height * MONITOR_GEOMETRY.baseHeightRatio;
  const screenRect = getExternalMonitorScreenRect({ x: 0, y: 0, width, height });

  return (
    <div style={{ position: 'absolute', left: x, top: y, width: width, height: height }}>
      {/* Enhanced Glow effect */}
      {hasGlow && glowIntensity > 0 && (
        <div style={{
          position: 'absolute',
          top: -30,
          left: -30,
          right: -30,
          bottom: -50,
          background: `radial-gradient(ellipse at center, ${COLORS.glowCyan} 0%, ${COLORS.glowGold} 30%, transparent 70%)`,
          opacity: glowIntensity,
          pointerEvents: 'none',
          filter: 'blur(20px)',
        }} />
      )}

      {/* Monitor frame with enhanced styling */}
      <div style={{
        position: 'absolute',
        top: 0,
        left: 0,
        width: width,
        height: height - standHeight - baseHeight,
        background: `linear-gradient(145deg, ${COLORS.macbookSpaceGray} 0%, ${COLORS.macbookDarkGray} 50%, ${COLORS.macbookSpaceGray} 100%)`,
        borderRadius: 12,
        boxShadow: hasGlow && glowIntensity > 0
          ? `0 0 ${60 * glowIntensity}px ${COLORS.cyan}, 0 10px 40px rgba(0,0,0,0.5), inset 0 1px 2px rgba(255,255,255,0.1)`
          : '0 8px 30px rgba(0,0,0,0.4), inset 0 1px 2px rgba(255,255,255,0.1)',
        overflow: 'hidden',
        border: hasGlow && glowIntensity > 0
          ? `2px solid ${COLORS.cyan}`
          : '1px solid rgba(255,255,255,0.1)',
      }}>
        {/* Screen */}
        <div style={{
          position: 'absolute',
          left: screenRect.x,
          top: screenRect.y,
          width: screenRect.width,
          height: screenRect.height,
          backgroundColor: COLORS.monitorBg,
          borderRadius: 6,
          overflow: 'hidden',
          boxShadow: isActive || (hasGlow && glowIntensity > 0)
            ? `inset 0 0 ${80 * (glowIntensity || 0.5)}px rgba(0,0,0,0.3), 0 0 20px ${COLORS.cyanGlow}`
            : 'inset 0 0 40px rgba(0,0,0,0.3)',
        }}>
          {/* Screen reflection */}
          <div style={{
            position: 'absolute',
            top: 0,
            left: 0,
            right: 0,
            height: '45%',
            background: 'linear-gradient(180deg, rgba(255,255,255,0.04) 0%, transparent 100%)',
            pointerEvents: 'none',
          }} />
        </div>

        {/* Brand label */}
        <div style={{
          position: 'absolute',
          bottom: 6,
          left: '50%',
          transform: 'translateX(-50%)',
          fontSize: 9,
          color: 'rgba(255,255,255,0.25)',
          fontFamily: 'system-ui, -apple-system, sans-serif',
          letterSpacing: 1,
          fontWeight: 500,
        }}>
          LG UltraFine
        </div>
      </div>

      {/* Monitor stand neck */}
      <div style={{
        position: 'absolute',
        bottom: baseHeight,
        left: (width - standWidth) / 2,
        width: standWidth,
        height: standHeight,
        background: `linear-gradient(180deg, ${COLORS.macbookDarkGray} 0%, ${COLORS.macbookSpaceGray} 100%)`,
        borderRadius: '3px 3px 0 0',
        boxShadow: '0 -2px 4px rgba(0,0,0,0.2)',
      }} />

      {/* Monitor stand base */}
      <div style={{
        position: 'absolute',
        bottom: 0,
        left: (width - baseWidth) / 2,
        width: baseWidth,
        height: baseHeight,
        background: `linear-gradient(180deg, ${COLORS.macbookSpaceGray} 0%, ${COLORS.macbookDarkGray} 100%)`,
        borderRadius: '6px 6px 0 0',
        boxShadow: '0 4px 15px rgba(0,0,0,0.4)',
      }} />

      {/* Label */}
      <div style={{
        position: 'absolute',
        top: -28,
        left: 0,
        right: 0,
        textAlign: 'center',
      }}>
        <span style={{
          color: hasGlow && glowIntensity > 0 ? COLORS.cyan : COLORS.textMuted,
          fontSize: 13,
          fontWeight: hasGlow && glowIntensity > 0 ? 700 : 500,
          fontFamily: 'system-ui, -apple-system, sans-serif',
          padding: '4px 12px',
          backgroundColor: hasGlow && glowIntensity > 0 ? `${COLORS.cyan}20` : 'transparent',
          borderRadius: 6,
          textShadow: hasGlow && glowIntensity > 0 ? `0 0 10px ${COLORS.cyan}` : 'none',
        }}>
          {label}
        </span>
      </div>
    </div>
  );
};

// Simplified shortcut display
const ShortcutDisplay: React.FC = () => (
  <div style={{
    backgroundColor: COLORS.cyan,
    padding: '12px 24px',
    borderRadius: 10,
    boxShadow: `0 4px 20px ${COLORS.cyan}60`,
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 4,
  }}>
    <span style={{
      color: COLORS.bgDark,
      fontSize: 24,
      fontWeight: 'bold',
      fontFamily: 'monospace',
      letterSpacing: 2,
    }}>⌃M</span>
  </div>
);

// Simple status label
const StatusLabel: React.FC<{
  text: string;
  show: boolean;
}> = ({ text, show }) => {
  if (!show) return null;
  return (
    <div style={{
      position: 'absolute',
      left: '50%',
      top: 50,
      transform: 'translateX(-50%)',
      backgroundColor: 'rgba(47, 183, 201, 0.9)',
      padding: '8px 20px',
      borderRadius: 20,
      zIndex: 100,
    }}>
      <span style={{
        color: '#fff',
        fontSize: 14,
        fontWeight: 600,
      }}>{text}</span>
    </div>
  );
};

// Main Component
export const HeroMultiWindowDemo: React.FC = () => {
  const frame = useCurrentFrame();
  const fps = 60;

  // Animation phases - 3轮演示，展示不同位置的窗口移动
  const roundDuration = 5 * fps; // 每轮5秒
  const totalDuration = 15 * fps; // 总共15秒，3轮

  // 三轮的时间点
  const round1Start = 0;
  const round1MoveStart = 0.5 * fps;
  const round1MoveEnd = 2 * fps;
  const round1HoldEnd = 3 * fps;
  const round1ReturnEnd = 4.5 * fps;
  const round1End = 5 * fps;

  const round2Start = round1End;
  const round2MoveStart = round2Start + 0.5 * fps;
  const round2MoveEnd = round2Start + 2 * fps;
  const round2HoldEnd = round2Start + 3 * fps;
  const round2ReturnEnd = round2Start + 4.5 * fps;
  const round2End = round2Start + 5 * fps;

  const round3Start = round2End;
  const round3MoveStart = round3Start + 0.5 * fps;
  const round3MoveEnd = round3Start + 2 * fps;
  const round3HoldEnd = round3Start + 3 * fps;
  const round3ReturnEnd = round3Start + 4.5 * fps;
  const round3End = round3Start + 5 * fps;

  // External monitor positions
  const extMonitor1 = {
    x: monitorsStartX,
    y: monitorsY,
    width: MONITOR.width,
    height: MONITOR.height,
    label: '外接显示器 1',
  };

  const extMonitor2 = {
    x: monitorsStartX + MONITOR.width + 60,
    y: monitorsY,
    width: MONITOR.width,
    height: MONITOR.height,
    label: '外接显示器 2',
  };

  // MacBook position
  const macbook = {
    x: macbookX,
    y: macbookY,
    width: MACBOOK.width,
    height: MACBOOK.height,
  };

  // Calculate window grid (3x2) for each monitor
  const getWindowGrid = (monitor: Rect) => {
    const screen = getExternalMonitorScreenRect(monitor);
    const gap = 8;
    const cols = 3;
    const rows = 2;
    const cellW = (screen.width - gap * (cols + 1)) / cols;
    const cellH = (screen.height - gap * (rows + 1)) / rows;

    const windows: Rect[] = [];
    for (let row = 0; row < rows; row++) {
      for (let col = 0; col < cols; col++) {
        windows.push({
          x: screen.x + gap + col * (cellW + gap),
          y: screen.y + gap + row * (cellH + gap),
          width: cellW,
          height: cellH,
        });
      }
    }

    return { screen, windows };
  };

  // Generate windows for each monitor
  const { screen: ext1Screen, windows: ext1Windows } = getWindowGrid(extMonitor1);
  const { screen: ext2Screen, windows: ext2Windows } = getWindowGrid(extMonitor2);

  // MacBook screen area
  const macbookScreen = getMacBookScreenRect(macbook);

  // Source windows for each round - 选择不同位置的窗口
  // Round 1: 外接显示器1的第一个窗口（左上）
  // Round 2: 外接显示器1的中间窗口
  // Round 3: 外接显示器2的窗口
  const sourceWindowRound1 = ext1Windows[0];
  const sourceWindowRound2 = ext1Windows[2]; // 中间位置
  const sourceWindowRound3 = ext2Windows[3]; // 外接显示器2的窗口

  // Determine current source window based on frame
  let currentSourceWindow = sourceWindowRound1;
  let currentRound = 1;

  if (frame >= round2Start && frame < round3Start) {
    currentSourceWindow = sourceWindowRound2;
    currentRound = 2;
  } else if (frame >= round3Start) {
    currentSourceWindow = sourceWindowRound3;
    currentRound = 3;
  }

  // Calculate move progress for each round
  let moveProgress = 0;
  let returnProgress = 0;
  let isMoving = false;
  let isReturning = false;

  if (frame >= round1MoveStart && frame < round1MoveEnd) {
    moveProgress = (frame - round1MoveStart) / (round1MoveEnd - round1MoveStart);
    isMoving = true;
  } else if (frame >= round1HoldEnd && frame < round1ReturnEnd) {
    returnProgress = (frame - round1HoldEnd) / (round1ReturnEnd - round1HoldEnd);
    isReturning = true;
  } else if (frame >= round2MoveStart && frame < round2MoveEnd) {
    moveProgress = (frame - round2MoveStart) / (round2MoveEnd - round2MoveStart);
    isMoving = true;
  } else if (frame >= round2HoldEnd && frame < round2ReturnEnd) {
    returnProgress = (frame - round2HoldEnd) / (round2ReturnEnd - round2HoldEnd);
    isReturning = true;
  } else if (frame >= round3MoveStart && frame < round3MoveEnd) {
    moveProgress = (frame - round3MoveStart) / (round3MoveEnd - round3MoveStart);
    isMoving = true;
  } else if (frame >= round3HoldEnd && frame < round3ReturnEnd) {
    returnProgress = (frame - round3HoldEnd) / (round3ReturnEnd - round3HoldEnd);
    isReturning = true;
  }

  // Apply easing
  const easedMoveProgress = isMoving
    ? moveProgress < 0.5 ? 2 * moveProgress * moveProgress : -1 + (4 - 2 * moveProgress) * moveProgress
    : isReturning ? 1 : 0;
  const easedReturnProgress = isReturning
    ? returnProgress < 0.5 ? 2 * returnProgress * returnProgress : -1 + (4 - 2 * returnProgress) * returnProgress
    : 0;

  // Current window position
  let currentWindowPos = currentSourceWindow;
  let isFocused = false;
  let macbookGlowIntensity = 0;

  if (isMoving) {
    // 窗口移动到 MacBook
    currentWindowPos = {
      x: interpolate(easedMoveProgress, [0, 1], [currentSourceWindow.x, macbookScreen.x]),
      y: interpolate(easedMoveProgress, [0, 1], [currentSourceWindow.y, macbookScreen.y]),
      width: interpolate(easedMoveProgress, [0, 1], [currentSourceWindow.width, macbookScreen.width]),
      height: interpolate(easedMoveProgress, [0, 1], [currentSourceWindow.height, macbookScreen.height]),
    };
    isFocused = easedMoveProgress > 0.85;
    macbookGlowIntensity = easedMoveProgress > 0.5 ? (easedMoveProgress - 0.5) * 2 : 0;
  } else if (isReturning) {
    // 窗口返回外接屏
    currentWindowPos = {
      x: interpolate(easedReturnProgress, [0, 1], [macbookScreen.x, currentSourceWindow.x]),
      y: interpolate(easedReturnProgress, [0, 1], [macbookScreen.y, currentSourceWindow.y]),
      width: interpolate(easedReturnProgress, [0, 1], [macbookScreen.width, currentSourceWindow.width]),
      height: interpolate(easedReturnProgress, [0, 1], [macbookScreen.height, currentSourceWindow.height]),
    };
    macbookGlowIntensity = 1 - easedReturnProgress;
  } else if (
    (frame >= round1MoveEnd && frame < round1HoldEnd) ||
    (frame >= round2MoveEnd && frame < round2HoldEnd) ||
    (frame >= round3MoveEnd && frame < round3HoldEnd)
  ) {
    // 聚焦状态保持
    currentWindowPos = macbookScreen;
    isFocused = true;
    macbookGlowIntensity = 1;
  }

  // 当前移动的窗口在副屏上的原始位置
  const movingWindowSourcePos = currentSourceWindow;

  // 其他窗口透明度 - 当窗口移动时降低其他窗口的透明度，突出显示
  const getWindowOpacity = (winIdx: number, monitorIdx: number) => {
    // monitorIdx: 0 = ext1, 1 = ext2
    // 当前移动的窗口是哪一个
    let movingWindowIdx = -1;
    let movingMonitorIdx = -1;

    if (currentRound === 1) {
      movingWindowIdx = 0;
      movingMonitorIdx = 0;
    } else if (currentRound === 2) {
      movingWindowIdx = 2;
      movingMonitorIdx = 0;
    } else if (currentRound === 3) {
      movingWindowIdx = 3;
      movingMonitorIdx = 1;
    }

    // 如果是当前移动的窗口，显示完整
    if (winIdx === movingWindowIdx && monitorIdx === movingMonitorIdx) {
      return 1;
    }

    // 其他窗口在移动过程中降低透明度
    if (isMoving || isReturning) {
      return 0.15;
    }

    // 在聚焦状态时，其他窗口也降低透明度
    if (
      (frame >= round1MoveEnd && frame < round1HoldEnd) ||
      (frame >= round2MoveEnd && frame < round2HoldEnd) ||
      (frame >= round3MoveEnd && frame < round3HoldEnd)
    ) {
      return 0.2;
    }

    return 0.6;
  };

  return (
    <AbsoluteFill style={{
      backgroundColor: COLORS.bgDark,
      fontFamily: 'system-ui, -apple-system, sans-serif',
      width: CANVAS.width,
      height: CANVAS.height,
    }}>
      {/* Background */}
      <div style={{
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        background: `radial-gradient(circle at 50% 30%, ${COLORS.cyan}08 0%, transparent 50%),
                     radial-gradient(circle at 50% 70%, ${COLORS.cyan}05 0%, transparent 50%)`,
      }} />

      {/* Title */}
      <div style={{
        position: 'absolute',
        top: 20,
        left: 0,
        right: 0,
        textAlign: 'center',
        zIndex: 50,
      }}>
        <h1 style={{
          color: COLORS.textLight,
          fontSize: 28,
          fontWeight: 700,
          margin: 0,
          marginBottom: 8,
          textShadow: '0 2px 20px rgba(0,0,0,0.5)',
        }}>
          多屏工作环境，一键窗口流转
        </h1>
        <p style={{
          color: COLORS.textMuted,
          fontSize: 14,
          margin: 0,
        }}>
          从外接显示器 → MacBook 主屏 → 恢复原位
        </p>
      </div>

      {/* External Monitors (Top Row) */}
      <ExternalMonitor {...extMonitor1} isActive={true} hasGlow={isMoving && (currentRound === 1 || currentRound === 2)} glowIntensity={isMoving && (currentRound === 1 || currentRound === 2) ? 0.8 : 0} />
      <ExternalMonitor {...extMonitor2} isActive={true} hasGlow={isMoving && currentRound === 3} glowIntensity={isMoving && currentRound === 3 ? 0.8 : 0} />

      {/* MacBook Pro (Bottom) */}
      <MacBookPro {...macbook} isActive={isMoving || isFocused || isReturning} glowIntensity={macbookGlowIntensity} />

      {/* Windows on External Monitor 1 */}
      {ext1Windows.map((win, idx) => {
        // 跳过当前正在移动的窗口
        if ((currentRound === 1 && idx === 0) || (currentRound === 2 && idx === 2)) return null;
        return (
          <CloudCodeWindow
            key={`ext1-${idx}`}
            {...win}
            opacity={getWindowOpacity(idx, 0)}
            zIndex={1}
          />
        );
      })}

      {/* Windows on External Monitor 2 */}
      {ext2Windows.map((win, idx) => {
        // 跳过当前正在移动的窗口
        if (currentRound === 3 && idx === 3) return null;
        return (
          <CloudCodeWindow
            key={`ext2-${idx}`}
            {...win}
            opacity={getWindowOpacity(idx, 1)}
            zIndex={1}
          />
        );
      })}

      {/* Moving Window (Cloud Code) */}
      <CloudCodeWindow
        {...currentWindowPos}
        isFocused={isFocused}
        isActive={isMoving}
        zIndex={20}
      />

      {/* Shortcut Popups - 出现在当前源窗口位置 */}
      <div style={{
        position: 'absolute',
        left: movingWindowSourcePos.x + movingWindowSourcePos.width / 2,
        top: movingWindowSourcePos.y - 40,
        transform: 'translate(-50%, -50%)',
        opacity: isMoving && easedMoveProgress < 0.3 ? 1 - easedMoveProgress * 2 : 0,
        zIndex: 100,
      }}>
        <ShortcutDisplay />
      </div>
      <div style={{
        position: 'absolute',
        left: macbookScreen.x + macbookScreen.width / 2,
        top: macbookScreen.y - 40,
        transform: 'translate(-50%, -50%)',
        opacity: isReturning && easedReturnProgress < 0.3 ? 1 - easedReturnProgress * 2 : 0,
        zIndex: 100,
      }}>
        <ShortcutDisplay />
      </div>

      {/* Status Labels - 每轮结束时显示 */}
      <StatusLabel text={`Round ${currentRound}: 已聚焦到 MacBook`} show={isFocused && (frame === round1MoveEnd || frame === round2MoveEnd || frame === round3MoveEnd)} />
      <StatusLabel text={`Round ${currentRound}: 已恢复原布局`} show={isReturning && (frame === round1ReturnEnd || frame === round2ReturnEnd || frame === round3ReturnEnd)} />

      {/* Phase indicators - 显示三轮进度 */}
      <div style={{
        position: 'absolute',
        bottom: 12,
        left: '50%',
        transform: 'translateX(-50%)',
        display: 'flex',
        gap: 12,
        zIndex: 50,
      }}>
        {[1, 2, 3].map((round) => {
          const isCurrentRound = currentRound === round;
          const roundStart = (round - 1) * roundDuration;
          const roundEnd = round * roundDuration;
          const progress = Math.min(1, Math.max(0, (frame - roundStart) / roundDuration));

          return (
            <div key={round} style={{
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 6,
              opacity: isCurrentRound ? 1 : 0.4,
            }}>
              <div style={{
                width: 40,
                height: 4,
                backgroundColor: `${COLORS.cyan}30`,
                borderRadius: 2,
                overflow: 'hidden',
              }}>
                <div style={{
                  width: `${progress * 100}%`,
                  height: '100%',
                  backgroundColor: COLORS.cyan,
                  borderRadius: 2,
                  transition: 'width 0.1s linear',
                  boxShadow: isCurrentRound ? `0 0 10px ${COLORS.cyan}` : 'none',
                }} />
              </div>
              <span style={{
                fontSize: 10,
                color: isCurrentRound ? COLORS.cyan : COLORS.textMuted,
                fontWeight: isCurrentRound ? 700 : 500,
                textShadow: isCurrentRound ? `0 0 10px ${COLORS.cyan}` : 'none',
              }}>
                Round {round}
              </span>
            </div>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};
