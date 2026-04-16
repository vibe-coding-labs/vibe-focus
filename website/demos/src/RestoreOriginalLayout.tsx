import React from 'react';
import {
  AbsoluteFill,
  useCurrentFrame,
  interpolate,
  spring,
} from 'remotion';

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
  focusBadge: '#faad14',
};

// Code editor window component
const CodeWindow: React.FC<{
  x: number;
  y: number;
  width: number;
  height: number;
  opacity?: number;
  showFocusBadge?: boolean;
}> = ({ x, y, width, height, opacity = 1, showFocusBadge = false }) => {
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
      <div style={{ padding: 20 }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <div style={{ height: 14, width: '80%', backgroundColor: COLORS.codeLine1, borderRadius: 2, opacity: 0.8 }} />
          <div style={{ height: 14, width: '60%', backgroundColor: COLORS.codeLine2, borderRadius: 2, opacity: 0.7 }} />
          <div style={{ height: 14, width: '75%', backgroundColor: COLORS.codeLine3, borderRadius: 2, opacity: 0.6 }} />
          <div style={{ height: 14, width: '90%', backgroundColor: COLORS.codeLine1, borderRadius: 2, opacity: 0.8 }} />
          <div style={{ height: 14, width: '55%', backgroundColor: COLORS.codeLine2, borderRadius: 2, opacity: 0.7 }} />
          <div style={{ height: 14, width: '70%', backgroundColor: COLORS.codeLine3, borderRadius: 2, opacity: 0.6 }} />
        </div>
      </div>

      {/* Focus mode badge */}
      {showFocusBadge && (
        <div
          style={{
            position: 'absolute',
            top: 40,
            right: 20,
            backgroundColor: COLORS.focusBadge,
            padding: '6px 12px',
            borderRadius: 4,
            display: 'flex',
            alignItems: 'center',
            gap: 6,
          }}
        >
          <div
            style={{
              width: 8,
              height: 8,
              borderRadius: '50%',
              backgroundColor: 'white',
              animation: 'pulse 1.5s ease-in-out infinite',
            }}
          />
          <span
            style={{
              color: '#333',
              fontSize: 12,
              fontWeight: 600,
              fontFamily: 'system-ui, -apple-system, sans-serif',
            }}
          >
            聚焦模式
          </span>
        </div>
      )}
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
        padding: '16px 32px',
        borderRadius: 8,
        display: 'flex',
        alignItems: 'center',
        gap: 8,
      }}
    >
      <span
        style={{
          color: COLORS.bgDark,
          fontSize: 24,
          fontWeight: 'bold',
          fontFamily: 'monospace',
        }}
      >
        ⌃Q
      </span>
    </div>
  );
};

// Checkmark animation component
const CheckmarkAnimation: React.FC<{
  progress: number;
}> = ({ progress }) => {
  const scale = spring({
    frame: progress * 30,
    fps: 60,
    config: {
      mass: 1,
      stiffness: 200,
      damping: 15,
    },
  });

  const opacity = interpolate(progress, [0, 0.3, 0.9, 1], [0, 1, 1, 0]);

  return (
    <div
      style={{
        position: 'absolute',
        left: '50%',
        top: '50%',
        transform: `translate(-50%, -50%) scale(${scale})`,
        opacity: opacity,
      }}
    >
      <div
        style={{
          width: 80,
          height: 80,
          borderRadius: '50%',
          backgroundColor: COLORS.successGreen,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
        }}
      >
        <svg width="40" height="40" viewBox="0 0 24 24" fill="none">
          <path d="M5 12l5 5L20 7" stroke="white" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </div>
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
        top: 80,
        transform: `translateX(-50%) translateY(${translateY}px)`,
        opacity: opacity,
        backgroundColor: COLORS.successGreen,
        padding: '14px 28px',
        borderRadius: 28,
        display: 'flex',
        alignItems: 'center',
        gap: 10,
      }}
    >
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
        <path d="M5 12l5 5L20 7" stroke="white" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      <span
        style={{
          color: 'white',
          fontSize: 16,
          fontWeight: 600,
          fontFamily: 'system-ui, -apple-system, sans-serif',
        }}
      >
        已恢复
      </span>
    </div>
  );
};

// Main component
export const RestoreOriginalLayout: React.FC = () => {
  const frame = useCurrentFrame();
  const fps = 60;

  // Animation phases (in seconds)
  // 0-2s: Show focused state on main monitor
  // 2-3s: Show shortcut
  // 3-7s: Window moves back to secondary with spring animation
  // 7-9s: Checkmark and "已恢复" notification
  // 9-10s: Stable dual monitor state

  const phase1End = 2 * fps;
  const phase2End = 3 * fps;
  const phase3End = 7 * fps;
  const phase4End = 9 * fps;
  const phase5End = 10 * fps;

  // Monitor positions
  const mainMonitor = { x: 150, y: 150, width: 540, height: 360 };
  const secondaryMonitor = { x: 800, y: 200, width: 300, height: 225 };

  // Window positions
  const windowFocused = {
    x: mainMonitor.x + 30,
    y: mainMonitor.y + 50,
    width: mainMonitor.width - 60,
    height: mainMonitor.height - 80,
  };

  const windowOriginal = {
    x: secondaryMonitor.x + 30,
    y: secondaryMonitor.y + 50,
    width: secondaryMonitor.width - 60,
    height: secondaryMonitor.height - 80,
  };

  // Spring animation for window movement (phase 3)
  const windowProgress = interpolate(
    frame,
    [phase2End, phase3End],
    [0, 1],
    {
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
    }
  );

  const springValue = spring({
    frame: windowProgress * (phase3End - phase2End),
    fps,
    config: {
      mass: 1,
      stiffness: 100,
      damping: 15,
    },
  });

  const windowX = interpolate(springValue, [0, 1], [windowFocused.x, windowOriginal.x]);
  const windowY = interpolate(springValue, [0, 1], [windowFocused.y, windowOriginal.y]);
  const windowWidth = interpolate(springValue, [0, 1], [windowFocused.width, windowOriginal.width]);
  const windowHeight = interpolate(springValue, [0, 1], [windowFocused.height, windowOriginal.height]);

  // Show window on main in phase 1-2
  const showWindowOnMain = frame < phase2End;
  // Show window animating in phase 3
  const showWindowAnimating = frame >= phase2End && frame < phase3End;
  // Show window on secondary in phase 4-5
  const showWindowOnSecondary = frame >= phase3End;

  // Active monitor
  const mainMonitorActive = frame < phase3End;
  const secondaryMonitorActive = frame >= phase3End;

  // Shortcut indicator
  const shortcutProgress = interpolate(
    frame,
    [phase1End, phase2End],
    [0, 1],
    { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }
  );

  // Success animation progress
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
          top: 40,
          left: 0,
          right: 0,
          textAlign: 'center',
        }}
      >
        <h1
          style={{
            color: COLORS.textLight,
            fontSize: 28,
            fontWeight: 600,
            margin: 0,
            fontFamily: 'system-ui, -apple-system, sans-serif',
          }}
        >
          恢复原布局
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
        isActive={secondaryMonitorActive}
      />

      {/* Window on main monitor (phase 1-2) */}
      {showWindowOnMain && (
        <CodeWindow
          x={windowFocused.x}
          y={windowFocused.y}
          width={windowFocused.width}
          height={windowFocused.height}
          showFocusBadge={true}
        />
      )}

      {/* Animating window (phase 3) */}
      {showWindowAnimating && (
        <CodeWindow
          x={windowX}
          y={windowY}
          width={windowWidth}
          height={windowHeight}
          showFocusBadge={false}
        />
      )}

      {/* Window on secondary monitor (phase 4-5) */}
      {showWindowOnSecondary && (
        <CodeWindow
          x={windowOriginal.x}
          y={windowOriginal.y}
          width={windowOriginal.width}
          height={windowOriginal.height}
          showFocusBadge={false}
        />
      )}

      {/* Shortcut indicator */}
      <ShortcutIndicator
        x={600}
        y={400}
        visible={frame >= phase1End && frame <= phase2End}
        progress={shortcutProgress}
      />

      {/* Success animation */}
      {frame >= phase3End && frame < phase4End && (
        <CheckmarkAnimation progress={successProgress} />
      )}

      {/* Success notification */}
      {frame >= phase3End && <SuccessNotification progress={successProgress} />}
    </AbsoluteFill>
  );
};
