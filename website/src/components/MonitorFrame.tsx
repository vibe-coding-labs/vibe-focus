import React from 'react';

interface MonitorFrameProps {
  children: React.ReactNode;
  isActive?: boolean;
  brand?: string;
  className?: string;
}

// 显示器外框：暖咖啡色机身（与页面奶油/珊瑚语系同源），播放中机身右下角
// 珊瑚色电源灯呼吸（.monitor-led 动画在 styles.css）。
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
      }}
    >
      {/* Monitor Frame */}
      <div
        className="monitor-frame-container"
        style={{
          position: 'relative',
          background: 'transparent',
          borderRadius: '14px',
          padding: '8px',
          filter: 'drop-shadow(0 26px 44px rgba(64, 54, 43, 0.22))',
        }}
      >
        {/* Screen Bezel — 暖咖啡机身 + 蜜桃细描边 */}
        <div
          className="monitor-frame-bezel"
          style={{
            position: 'relative',
            background: 'linear-gradient(180deg, #2A221A 0%, #211B14 100%)',
            borderRadius: '12px',
            overflow: 'hidden',
            padding: '12px',
            border: '1px solid #3D3225',
            boxShadow: 'inset 0 1px 0 rgba(255, 225, 201, 0.08)',
          }}
        >
          {/* Screen Content — 暖黑屏（视频 letterbox 处不显冷灰） */}
          <div
            className="monitor-frame-screen"
            style={{
              position: 'relative',
              aspectRatio: '16 / 9',
              background: '#14100B',
              borderRadius: '5px',
              overflow: 'hidden',
            }}
          >
            {children}
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
              opacity: isActive ? 1 : 0.8,
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

      {/* Stand Neck */}
      <div
        className="monitor-frame-stand-neck"
        style={{
          width: '80px',
          height: '50px',
          background: 'linear-gradient(180deg, #332920 0%, #2A2119 100%)',
          marginTop: '-2px',
          clipPath: 'polygon(20% 0%, 80% 0%, 100% 100%, 0% 100%)',
        }}
      />

      {/* Stand Base */}
      <div
        className="monitor-frame-stand-base"
        style={{
          width: '160px',
          height: '16px',
          background: '#241D16',
          borderRadius: '8px 8px 0 0',
          marginTop: '-2px',
          border: '1px solid #3D3225',
          borderBottom: 'none',
        }}
      />

      {/* Stand Shadow — 暖色落地影（不再用纯黑椭圆） */}
      <div
        className="monitor-frame-stand-shadow"
        style={{
          width: '190px',
          height: '10px',
          background:
            'radial-gradient(ellipse at center, rgba(64, 54, 43, 0.28), rgba(64, 54, 43, 0) 72%)',
          marginTop: '-5px',
          borderRadius: '50%',
        }}
      />
    </div>
  );
};

export default MonitorFrame;
