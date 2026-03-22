import React from 'react';
import {
  AbsoluteFill,
  useCurrentFrame,
  interpolate,
} from 'remotion';

// Color palette from Vibe Focus
const COLORS = {
  bgDark: '#071726',
  cyan: '#2fb7c9',
  cyanLight: '#5bc9d7',
  cyanDark: '#1a8a99',
  sidebarBg: '#0d2137',
  sidebarBorder: '#1a3a52',
  cardBg: '#0d2137',
  cardBorder: '#1a3a52',
  textLight: '#ffffff',
  textMuted: '#8b9dc3',
  textSecondary: '#6b7c9c',
  successGreen: '#52c41a',
  errorRed: '#ff4d4f',
  warningOrange: '#faad14',
};

// Sidebar component
const Sidebar: React.FC = () => {
  return (
    <div
      style={{
        width: 240,
        height: '100%',
        backgroundColor: COLORS.sidebarBg,
        borderRight: `1px solid ${COLORS.sidebarBorder}`,
        display: 'flex',
        flexDirection: 'column',
        padding: '20px 0',
      }}
    >
      {/* Logo area */}
      <div
        style={{
          padding: '0 20px 24px',
          display: 'flex',
          alignItems: 'center',
          gap: 12,
          borderBottom: `1px solid ${COLORS.sidebarBorder}`,
        }}
      >
        <div
          style={{
            width: 36,
            height: 36,
            borderRadius: 8,
            backgroundColor: COLORS.cyan,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <circle cx="12" cy="12" r="10" stroke="white" strokeWidth="2" />
            <circle cx="12" cy="12" r="4" fill="white" />
          </svg>
        </div>
        <div>
          <div
            style={{
              color: COLORS.textLight,
              fontSize: 16,
              fontWeight: 600,
              fontFamily: 'system-ui, -apple-system, sans-serif',
            }}
          >
            Vibe Focus
          </div>
          <div
            style={{
              color: COLORS.textMuted,
              fontSize: 11,
              fontFamily: 'system-ui, -apple-system, sans-serif',
            }}
          >
            v1.2.0
          </div>
        </div>
      </div>

      {/* Menu items */}
      <div style={{ padding: '16px 12px', display: 'flex', flexDirection: 'column', gap: 4 }}>
        <SidebarItem icon="⚡" label="快捷键" active />
        <SidebarItem icon="🔒" label="权限状态" />
        <SidebarItem icon="🚀" label="开机启动" />
        <SidebarItem icon="🖥️" label="跨工作区" />
        <SidebarItem icon="ℹ️" label="关于" />
      </div>

      {/* Bottom status */}
      <div
        style={{
          marginTop: 'auto',
          padding: '16px 20px',
          borderTop: `1px solid ${COLORS.sidebarBorder}`,
        }}
      >
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 8,
            color: COLORS.successGreen,
            fontSize: 12,
            fontFamily: 'system-ui, -apple-system, sans-serif',
          }}
        >
          <div
            style={{
              width: 8,
              height: 8,
              borderRadius: '50%',
              backgroundColor: COLORS.successGreen,
            }}
          />
          运行正常
        </div>
      </div>
    </div>
  );
};

// Sidebar item component
const SidebarItem: React.FC<{
  icon: string;
  label: string;
  active?: boolean;
}> = ({ icon, label, active = false }) => {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        padding: '10px 12px',
        borderRadius: 6,
        backgroundColor: active ? `${COLORS.cyan}20` : 'transparent',
        color: active ? COLORS.cyan : COLORS.textMuted,
        fontSize: 14,
        fontFamily: 'system-ui, -apple-system, sans-serif',
        cursor: 'pointer',
      }}
    >
      <span style={{ fontSize: 16 }}>{icon}</span>
      <span>{label}</span>
    </div>
  );
};

// Card component
const Card: React.FC<{
  title: string;
  children: React.ReactNode;
  style?: React.CSSProperties;
}> = ({ title, children, style = {} }) => {
  return (
    <div
      style={{
        backgroundColor: COLORS.cardBg,
        border: `1px solid ${COLORS.cardBorder}`,
        borderRadius: 8,
        padding: 20,
        marginBottom: 16,
        ...style,
      }}
    >
      <div
        style={{
          color: COLORS.textLight,
          fontSize: 14,
          fontWeight: 600,
          marginBottom: 16,
          fontFamily: 'system-ui, -apple-system, sans-serif',
        }}
      >
        {title}
      </div>
      {children}
    </div>
  );
};

// Status tag component
const StatusTag: React.FC<{
  status: 'authorized' | 'unauthorized' | 'pending';
  label: string;
}> = ({ status, label }) => {
  const colors = {
    authorized: { bg: `${COLORS.successGreen}20`, text: COLORS.successGreen },
    unauthorized: { bg: `${COLORS.errorRed}20`, text: COLORS.errorRed },
    pending: { bg: `${COLORS.warningOrange}20`, text: COLORS.warningOrange },
  };

  const color = colors[status];

  return (
    <div
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 6,
        padding: '4px 10px',
        borderRadius: 4,
        backgroundColor: color.bg,
        color: color.text,
        fontSize: 12,
        fontWeight: 500,
        fontFamily: 'system-ui, -apple-system, sans-serif',
      }}
    >
      <div
        style={{
          width: 6,
          height: 6,
          borderRadius: '50%',
          backgroundColor: color.text,
        }}
      />
      {label}
    </div>
  );
};

// Shortcut display component
const ShortcutDisplay: React.FC<{
  shortcut: string;
}> = ({ shortcut }) => {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: '12px 16px',
        backgroundColor: `${COLORS.cyan}10`,
        border: `1px solid ${COLORS.cyan}30`,
        borderRadius: 6,
      }}
    >
      <span
        style={{
          color: COLORS.textMuted,
          fontSize: 13,
          fontFamily: 'system-ui, -apple-system, sans-serif',
        }}
      >
        聚焦窗口快捷键
      </span>
      <span
        style={{
          color: COLORS.cyan,
          fontSize: 16,
          fontWeight: 600,
          fontFamily: 'monospace',
          padding: '6px 12px',
          backgroundColor: `${COLORS.cyan}15`,
          borderRadius: 4,
        }}
      >
        {shortcut}
      </span>
    </div>
  );
};

// Permission item component
const PermissionItem: React.FC<{
  name: string;
  status: 'authorized' | 'unauthorized' | 'pending';
  description: string;
}> = ({ name, status, description }) => {
  const statusLabels = {
    authorized: '已授权',
    unauthorized: '未授权',
    pending: '待检查',
  };

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'flex-start',
        justifyContent: 'space-between',
        padding: '12px 0',
        borderBottom: `1px solid ${COLORS.sidebarBorder}`,
      }}
    >
      <div>
        <div
          style={{
            color: COLORS.textLight,
            fontSize: 13,
            marginBottom: 4,
            fontFamily: 'system-ui, -apple-system, sans-serif',
          }}
        >
          {name}
        </div>
        <div
          style={{
            color: COLORS.textSecondary,
            fontSize: 11,
            fontFamily: 'system-ui, -apple-system, sans-serif',
          }}
        >
          {description}
        </div>
      </div>
      <StatusTag status={status} label={statusLabels[status]} />
    </div>
  );
};

// Toggle component
const Toggle: React.FC<{
  enabled: boolean;
  label: string;
}> = ({ enabled, label }) => {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
      }}
    >
      <span
        style={{
          color: COLORS.textLight,
          fontSize: 13,
          fontFamily: 'system-ui, -apple-system, sans-serif',
        }}
      >
        {label}
      </span>
      <div
        style={{
          width: 44,
          height: 24,
          borderRadius: 12,
          backgroundColor: enabled ? COLORS.cyan : COLORS.sidebarBorder,
          position: 'relative',
          transition: 'background-color 0.3s',
        }}
      >
        <div
          style={{
            width: 20,
            height: 20,
            borderRadius: '50%',
            backgroundColor: 'white',
            position: 'absolute',
            top: 2,
            left: enabled ? 22 : 2,
            transition: 'left 0.3s',
          }}
        />
      </div>
    </div>
  );
};

// Content area component
const ContentArea: React.FC<{
  scrollY: number;
}> = ({ scrollY }) => {
  return (
    <div
      style={{
        flex: 1,
        padding: 24,
        overflow: 'hidden',
      }}
    >
      <div
        style={{
          transform: `translateY(${-scrollY}px)`,
          transition: 'transform 0.1s',
        }}
      >
        {/* Shortcut Card */}
        <Card title="快捷键设置">
          <ShortcutDisplay shortcut="⌃M" />
          <div
            style={{
              marginTop: 12,
              color: COLORS.textSecondary,
              fontSize: 12,
              fontFamily: 'system-ui, -apple-system, sans-serif',
            }}
          >
            按下快捷键后，当前窗口将移动到主屏并铺满可见区域
          </div>
        </Card>

        {/* Permissions Card */}
        <Card title="权限状态">
          <PermissionItem
            name="辅助功能权限"
            status="authorized"
            description="用于控制其他应用窗口的位置和大小"
          />
          <PermissionItem
            name="屏幕录制权限"
            status="authorized"
            description="用于检测显示器布局和窗口信息"
          />
          <PermissionItem
            name="自动化权限"
            status="unauthorized"
            description="用于执行系统级窗口操作"
          />
        </Card>

        {/* Startup Card */}
        <Card title="开机启动">
          <Toggle enabled={true} label="登录时自动启动 Vibe Focus" />
          <div
            style={{
              marginTop: 12,
              color: COLORS.textSecondary,
              fontSize: 12,
              fontFamily: 'system-ui, -apple-system, sans-serif',
            }}
          >
            应用将在系统启动后自动运行，无需手动打开
          </div>
        </Card>

        {/* Workspace Card */}
        <Card title="跨工作区">
          <Toggle enabled={false} label="允许跨工作区移动窗口" />
          <div
            style={{
              marginTop: 12,
              color: COLORS.textSecondary,
              fontSize: 12,
              fontFamily: 'system-ui, -apple-system, sans-serif',
            }}
          >
            启用后，窗口可以在不同 Space 之间移动
          </div>
        </Card>

        {/* About Card */}
        <Card title="关于">
          <div
            style={{
              display: 'flex',
              flexDirection: 'column',
              gap: 8,
            }}
          >
            <div
              style={{
                display: 'flex',
                justifyContent: 'space-between',
              }}
            >
              <span style={{ color: COLORS.textMuted, fontSize: 13 }}>版本</span>
              <span style={{ color: COLORS.textLight, fontSize: 13 }}>v1.2.0</span>
            </div>
            <div
              style={{
                display: 'flex',
                justifyContent: 'space-between',
              }}
            >
              <span style={{ color: COLORS.textMuted, fontSize: 13 }}>构建日期</span>
              <span style={{ color: COLORS.textLight, fontSize: 13 }}>2024-03-15</span>
            </div>
            <div
              style={{
                display: 'flex',
                justifyContent: 'space-between',
              }}
            >
              <span style={{ color: COLORS.textMuted, fontSize: 13 }}>开发者</span>
              <span style={{ color: COLORS.cyan, fontSize: 13 }}>Vibe Coding Labs</span>
            </div>
          </div>
        </Card>
      </div>
    </div>
  );
};

// Main component
export const PermissionsDiagnostics: React.FC = () => {
  const frame = useCurrentFrame();
  const fps = 30;

  // Animation phases (in seconds)
  // 0-2s: Initial view (show top cards)
  // 2-4s: Focus on shortcut card
  // 4-6s: Scroll to permissions card
  // 6-8s: Scroll to startup card
  // 8-10s: Scroll to workspace card
  // 10-12s: Scroll back to top

  const phase1End = 2 * fps;    // 0-2s
  const phase2End = 4 * fps;    // 2-4s
  const phase3End = 6 * fps;    // 4-6s
  const phase4End = 8 * fps;    // 6-8s
  const phase5End = 10 * fps;   // 8-10s
  const phase6End = 12 * fps;   // 10-12s

  // Scroll positions
  const scrollPositions = {
    initial: 0,
    shortcut: 0,
    permissions: 180,
    startup: 380,
    workspace: 540,
    backToTop: 0,
  };

  // Calculate scroll Y
  let scrollY = 0;

  if (frame < phase2End) {
    scrollY = scrollPositions.initial;
  } else if (frame < phase3End) {
    // Scroll to permissions
    scrollY = interpolate(
      frame,
      [phase2End, phase3End],
      [scrollPositions.shortcut, scrollPositions.permissions],
      { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }
    );
  } else if (frame < phase4End) {
    // Scroll to startup
    scrollY = interpolate(
      frame,
      [phase3End, phase4End],
      [scrollPositions.permissions, scrollPositions.startup],
      { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }
    );
  } else if (frame < phase5End) {
    // Scroll to workspace
    scrollY = interpolate(
      frame,
      [phase4End, phase5End],
      [scrollPositions.startup, scrollPositions.workspace],
      { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }
    );
  } else {
    // Scroll back to top
    scrollY = interpolate(
      frame,
      [phase5End, phase6End],
      [scrollPositions.workspace, scrollPositions.backToTop],
      { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }
    );
  }

  // Highlight effect for current card
  const getCardOpacity = (cardName: string) => {
    const currentPhase = Math.floor(frame / (2 * fps));
    const cardPhases: Record<string, number> = {
      shortcut: 1,
      permissions: 2,
      startup: 3,
      workspace: 4,
    };

    if (cardPhases[cardName] === currentPhase) {
      return 1;
    }
    return 0.7;
  };

  return (
    <AbsoluteFill
      style={{
        backgroundColor: COLORS.bgDark,
        display: 'flex',
        fontFamily: 'system-ui, -apple-system, sans-serif',
      }}
    >
      {/* Window frame */}
      <div
        style={{
          display: 'flex',
          width: '100%',
          height: '100%',
          borderRadius: 12,
          overflow: 'hidden',
          border: `1px solid ${COLORS.sidebarBorder}`,
        }}
      >
        {/* Title bar */}
        <div
          style={{
            position: 'absolute',
            top: 0,
            left: 0,
            right: 0,
            height: 36,
            backgroundColor: COLORS.sidebarBg,
            borderBottom: `1px solid ${COLORS.sidebarBorder}`,
            display: 'flex',
            alignItems: 'center',
            paddingLeft: 16,
            gap: 8,
            zIndex: 10,
          }}
        >
          <div style={{ width: 12, height: 12, borderRadius: '50%', backgroundColor: '#ff5f56' }} />
          <div style={{ width: 12, height: 12, borderRadius: '50%', backgroundColor: '#ffbd2e' }} />
          <div style={{ width: 12, height: 12, borderRadius: '50%', backgroundColor: '#27ca40' }} />
          <span
            style={{
              marginLeft: 12,
              color: COLORS.textMuted,
              fontSize: 13,
            }}
          >
            Vibe Focus - 设置
          </span>
        </div>

        {/* Content */}
        <div
          style={{
            display: 'flex',
            width: '100%',
            height: '100%',
            paddingTop: 36,
          }}
        >
          <Sidebar />
          <ContentArea scrollY={scrollY} />
        </div>
      </div>

      {/* Phase indicator */}
      <div
        style={{
          position: 'absolute',
          bottom: 20,
          right: 20,
          display: 'flex',
          gap: 6,
        }}
      >
        {[0, 1, 2, 3, 4, 5].map((i) => {
          const currentPhase = Math.floor(frame / (2 * fps));
          const isActive = i === currentPhase;
          return (
            <div
              key={i}
              style={{
                width: 8,
                height: 8,
                borderRadius: '50%',
                backgroundColor: isActive ? COLORS.cyan : `${COLORS.cyan}40`,
                transition: 'background-color 0.3s',
              }}
            />
          );
        })}
      </div>
    </AbsoluteFill>
  );
};
