import React from 'react';

interface MonitorFrameProps {
  children: React.ReactNode;
  isActive?: boolean;
  brand?: string;
  className?: string;
}

// 显示器整机（写实向）：
// - 只有边框是深色（暖咖啡），屏面为亮色奶油——视频以「深色终端窗口」形式
//   嵌在亮色屏面上，带轻微投影，像显示器正显示一个 app 窗口
// - 支架一体：颈部上端插进面板后方（无拼接缝），胶囊脚与颈部同色相连，
//   落地影贴住脚底——整机一个物理对象，不是三块散件
// - 播放中边框右下角珊瑚色电源灯呼吸（.monitor-led 动画在 styles.css）
export const MonitorFrame: React.FC<MonitorFrameProps> = ({
  children,
  isActive = false,
  brand = 'Vibe Focus',
  className = '',
}) => {
  return (
    <div
      className={`monitor-frame ${isActive ? 'active' : ''} ${className}`}
      style={{
        position: 'relative',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        width: '100%',
      }}
    >
      {/* Panel（zIndex 1，颈部上端藏在其后方） */}
      <div
        className="monitor-frame-container"
        style={{
          position: 'relative',
          zIndex: 1,
          width: '100%',
          borderRadius: '16px',
          padding: '9px',
          filter: 'drop-shadow(0 22px 38px rgba(64, 54, 43, 0.20))',
        }}
      >
        {/* 边框：暖咖啡深色 */}
        <div
          style={{
            position: 'relative',
            background: 'linear-gradient(180deg, #2A221A 0%, #211B14 100%)',
            borderRadius: '13px',
            padding: '11px 11px 24px',
            border: '1px solid #3D3225',
            boxShadow: 'inset 0 1px 0 rgba(255, 225, 201, 0.08)',
          }}
        >
          {/* 亮色屏面：奶油渐变 + 内凹感 */}
          <div
            style={{
              borderRadius: '6px',
              background: 'linear-gradient(180deg, #FAF6EC 0%, #EFE7D8 100%)',
              padding: '3.2%',
              boxShadow: 'inset 0 1px 3px rgba(64, 54, 43, 0.16)',
            }}
          >
            {/* 屏上内容窗：视频作为深色窗口嵌在亮屏上 */}
            <div
              style={{
                aspectRatio: '16 / 9',
                borderRadius: '4px',
                overflow: 'hidden',
                background: '#14100B',
                boxShadow: '0 3px 14px rgba(30, 24, 17, 0.28)',
              }}
            >
              {children}
            </div>
          </div>

          {/* Power LED — 播放中珊瑚呼吸，待机暖棕 */}
          <span
            className="monitor-led"
            style={{
              position: 'absolute',
              right: '11px',
              bottom: '9px',
              width: '6px',
              height: '6px',
              borderRadius: '50%',
              background: isActive ? '#FF8266' : '#4A3B2E',
              boxShadow: isActive ? '0 0 9px rgba(255, 130, 102, 0.85)' : 'none',
              transition: 'background 0.35s ease, box-shadow 0.35s ease',
            }}
          />

          {/* Brand Label */}
          <div
            className="monitor-frame-brand"
            style={{
              position: 'absolute',
              bottom: '5px',
              left: '50%',
              transform: 'translateX(-50%)',
              fontSize: '9px',
              color: '#8A7B68',
              fontFamily: 'system-ui, -apple-system, sans-serif',
              letterSpacing: '0.5px',
            }}
          >
            {brand}
          </div>
        </div>
      </div>

      {/* 支架颈部：上端插进面板后方（marginTop 负值 + zIndex 0），无拼接缝 */}
      <div
        style={{
          position: 'relative',
          zIndex: 0,
          width: '92px',
          height: '46px',
          marginTop: '-6px',
          background: 'linear-gradient(180deg, #2A2119 0%, #241D16 100%)',
          borderRadius: '0 0 8px 8px',
        }}
      />

      {/* 胶囊脚：与颈部同色相连，顶部一线暖高光 */}
      <div
        style={{
          position: 'relative',
          zIndex: 0,
          width: '208px',
          height: '13px',
          marginTop: '-2px',
          borderRadius: '999px',
          background: 'linear-gradient(180deg, #332920 0%, #241D16 100%)',
          boxShadow: 'inset 0 1px 0 rgba(255, 225, 201, 0.10)',
        }}
      />

      {/* 落地影：贴住脚底 */}
      <div
        style={{
          width: '236px',
          height: '12px',
          marginTop: '-4px',
          borderRadius: '50%',
          background:
            'radial-gradient(ellipse at center, rgba(64, 54, 43, 0.26), rgba(64, 54, 43, 0) 72%)',
        }}
      />
    </div>
  );
};

export default MonitorFrame;
