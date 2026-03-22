import React from 'react';
import {
  AbsoluteFill,
  useCurrentFrame,
  interpolate,
} from 'remotion';

// Custom easing function - cubic-bezier(0.4, 0, 0.2, 1)
const easeInOutCubic = (t: number): number => {
  return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
};

// Color palette from Vibe Focus
const COLORS = {
  bgDark: '#071726',
  cyan: '#2fb7c9',
  cyanLight: '#5bc9d7',
  monitorBg: '#0d2137',
  monitorBorder: '#1a3a52',
  codeBg: '#0a1929',
  codeLine1: '#2fb7c9',
  codeLine2: '#5bc9d7',
  codeLine3: '#8dd4df',
  successGreen: '#52c41a',
  textLight: '#ffffff',
  textMuted: '#8b9dc3',
};

// Code editor window component
const CodeWindow: React.FC<{
  x: number;
  y: number;
  width: number;
  height: number;
  opacity?: number;
  scale?: number;
}> = ({ x, y, width, height, opacity = 1, scale = 1 }) => {
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
        border: `1px solid ${COLORS.monitorBorder}`,
        opacity: opacity,
        transform: `scale(${scale})`,
        transformOrigin: 'center center',
        overflow: 'hidden',
      }}
    >
      {/* Title bar */}
      <div
        style={{
          height: 28,
          backgroundColor: COLORS.monitorBg,
          borderBottom: `1px solid ${COLORS.monitorBorder}`,
          display: 'flex',
          alignItems: 'center',
          paddingLeft: 12,
          gap: 6,
        }}
      >
        <div style={{ width: 10, height: 10, borderRadius: '50%', backgroundColor: '#ff5f56' }} />
        <div style={{ width: 10, height: 10, borderRadius: '50%', backgroundColor: '#ffbd2e' }} />
        <div style={{ width: 10, height: 10, borderRadius: '50%', backgroundColor: '#27ca40' }} />
      </div>
      {/* Code content */}
      <div style={{ padding: 16 }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <div style={{ height: 12, width: '80%', backgroundColor: COLORS.codeLine1, borderRadius: 2, opacity: 0.8 }} />
          <div style={{ height: 12, width: '60%', backgroundColor: COLORS.codeLine2, borderRadius: 2, opacity: 0.7 }} />
          <div style={{ height: 12, width: '70%', backgroundColor: COLORS.codeLine3, borderRadius: 2, opacity: 0.6 }} />
          <div style={{ height: 12, width: '90%', backgroundColor: COLORS.codeLine1, borderRadius: 2, opacity: 0.8 }} />
          <div style={{ height: 12, width: '50%', backgroundColor: COLORS.codeLine2, borderRadius: 2, opacity: 0.7 }} />
        </div>
      </div>
    </div>
  );
};

// Monitor display component
const Monitor: React.FC<{
  x: number;
  y: number;
  width: number;
  height: number;
  label: string;
  isActive?: boolean;
}> = ({ x, y, width, height, label, isActive = false }) => {
  return (
    <div
      style={{
        position: 'absolute',
        left: x,
        top: y,
        width: width,
        height: height,
      }}
    >
      {/* Screen */}
      <div
        style={{
          width: width,
          height: height - 12,
          backgroundColor: COLORS.monitorBg,
          border: `2px solid ${isActive ? COLORS.cyan : COLORS.monitorBorder}`,
          borderRadius: 8,
        }}
      />
      {/* Stand */}
      <div
        style={{
          position: 'absolute',
          bottom: 0,
          left: width / 2 - 20,
          width: 40,
          height: 12,
          backgroundColor: COLORS.monitorBorder,
          borderRadius: '0 0 4px 4px',
        }}
      />
      {/* Label */}
      <div
        style={{
          position: 'absolute',
          top: -24,
          left: 0,
          right: 0,
          textAlign: 'center',
          color: isActive ? COLORS.cyan : COLORS.textMuted,
          fontSize: 12,
          fontFamily: 'system-ui, -apple-system, sans-serif',
        }}
      >
        {label}
      </div>
    </div>
  );
};

// Keyboard shortcut indicator
const ShortcutIndicator: React.FC<{
  x: number;
  y: number;
  visible: boolean;
  progress: number;
}> = ({ x, y, visible, progress }) => {
  if (!visible) return null;

  const opacity = interpolate(progress, [0, 0.2, 0.8, 1], [0, 1, 1, 0]);
  const scale = interpolate(progress, [0, 0.2, 0.8, 1], [0.8, 1, 1, 0.9]);

  return (
    <div
      style={{
        position: 'absolute',
        left: x,
        top: y,
        transform: `translate(-50%, -50%) scale(${scale})`,
        opacity: opacity,
        backgroundColor: COLORS.cyan,
        padding: '12px 24px',
        borderRadius: 8,
        display: 'flex',
        alignItems: 'center',
        gap: 8,
      }}
    >
      <span
        style={{
          color: COLORS.bgDark,
          fontSize: 18,
          fontWeight: 'bold',
          fontFamily: 'monospace',
        }}
      >
        ⌃M
      </span>
    </div>
  );
};

// Success notification
const SuccessNotification: React.FC<{
  progress: number;
}> = ({ progress }) => {
  const opacity = interpolate(progress, [0, 0.3, 0.7, 1], [0, 1, 1, 0]);
  const translateY = interpolate(progress, [0, 0.3], [20, 0]);

  return (
    <div
      style={{
        position: 'absolute',
        left: '50%',
        top: 60,
        transform: `translateX(-50%) translateY(${translateY}px)`,
        opacity: opacity,
        backgroundColor: COLORS.successGreen,
        padding: '12px 24px',
        borderRadius: 24,
        display: 'flex',
        alignItems: 'center',
        gap: 8,
      }}
    >
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
        <path d="M5 12l5 5L20 7" stroke="white" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      <span
        style={{
          color: 'white',
          fontSize: 14,
          fontWeight: 600,
          fontFamily: 'system-ui, -apple-system, sans-serif',
        }}
      >
        已聚焦
      </span>
    </div>
  );
};

// Main component
export const FocusToMainDisplay: React.FC = () => {
  const frame = useCurrentFrame();
  const fps = 30;

  // Animation phases (in seconds)
  // 0-1s: Show dual monitors with window on secondary
  // 1-2s: Show shortcut
  // 2-5s: Window moves from secondary to primary and fills
  // 5-6s: Success notification

  const phase1End = 1 * fps;
  const phase2End = 2 * fps;
  const phase3End = 5 * fps;
  const phase4End = 6 * fps;

  // Monitor positions
  const mainMonitor = { x: 100, y: 120, width: 360, height: 240 };
  const secondaryMonitor = { x: 500, y: 160, width: 200, height: 150 };

  // Window animation
  const windowStart = {
    x: secondaryMonitor.x + 20,
    y: secondaryMonitor.y + 40,
    width: 160,
    height: 100,
  };

  const windowEnd = {
    x: mainMonitor.x + 20,
    y: mainMonitor.y + 40,
    width: mainMonitor.width - 40,
    height: mainMonitor.height - 60,
  };

  // Window position interpolation
  const rawProgress = interpolate(
    frame,
    [phase2End, phase3End],
    [0, 1],
    {
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
    }
  );
  const windowProgress = easeInOutCubic(rawProgress);

  const windowX = interpolate(windowProgress, [0, 1], [windowStart.x, windowEnd.x]);
  const windowY = interpolate(windowProgress, [0, 1], [windowStart.y, windowEnd.y]);
  const windowWidth = interpolate(windowProgress, [0, 1], [windowStart.width, windowEnd.width]);
  const windowHeight = interpolate(windowProgress, [0, 1], [windowStart.height, windowEnd.height]);

  // Show window on secondary in phase 1, then animate in phase 3
  const showWindowOnSecondary = frame < phase2End;
  const showWindowAnimating = frame >= phase2End && frame < phase3End;
  const showWindowOnMain = frame >= phase3End;

  // Main monitor active state
  const mainMonitorActive = frame >= phase2End;

  // Shortcut indicator progress
  const shortcutProgress = interpolate(
    frame,
    [phase1End, phase2End],
    [0, 1],
    { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }
  );

  // Success notification progress
  const successProgress = interpolate(
    frame,
    [phase3End, phase4End],
    [0, 1],
    { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }
  );

  return (
    <AbsoluteFill
      style={{
        backgroundColor: COLORS.bgDark,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      {/* Title */}
      <div
        style={{
          position: 'absolute',
          top: 32,
          left: 0,
          right: 0,
          textAlign: 'center',
        }}
      >
        <h1
          style={{
            color: COLORS.textLight,
            fontSize: 24,
            fontWeight: 600,
            margin: 0,
            fontFamily: 'system-ui, -apple-system, sans-serif',
          }}
        >
          一键聚焦到主屏
        </h1>
      </div>

      {/* Monitors */}
      <Monitor
        x={mainMonitor.x}
        y={mainMonitor.y}
        width={mainMonitor.width}
        height={mainMonitor.height}
        label="主显示器"
        isActive={mainMonitorActive}
      />

      <Monitor
        x={secondaryMonitor.x}
        y={secondaryMonitor.y}
        width={secondaryMonitor.width}
        height={secondaryMonitor.height}
        label="副显示器"
        isActive={!mainMonitorActive}
      />

      {/* Window on secondary monitor (phase 1) */}
      {showWindowOnSecondary && (
        <CodeWindow
          x={windowStart.x}
          y={windowStart.y}
          width={windowStart.width}
          height={windowStart.height}
        />
      )}

      {/* Animating window (phase 3) */}
      {showWindowAnimating && (
        <CodeWindow
          x={windowX}
          y={windowY}
          width={windowWidth}
          height={windowHeight}
        />
      )}

      {/* Window on main monitor (phase 4) */}
      {showWindowOnMain && (
        <CodeWindow
          x={windowEnd.x}
          y={windowEnd.y}
          width={windowEnd.width}
          height={windowEnd.height}
        />
      )}

      {/* Shortcut indicator */}
      <ShortcutIndicator
        x={400}
        y={300}
        visible={frame >= phase1End && frame <= phase2End}
        progress={shortcutProgress}
      />

      {/* Success notification */}
      {frame >= phase3End && <SuccessNotification progress={successProgress} />}
    </AbsoluteFill>
  );
};
