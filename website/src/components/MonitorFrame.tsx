import React from 'react';

interface MonitorFrameProps {
  children: React.ReactNode;
  isActive?: boolean;
  brand?: string;
  className?: string;
}

export const MonitorFrame: React.FC<MonitorFrameProps> = ({
  children,
  isActive = false,
  brand = 'LG UltraFine',
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
          borderRadius: '12px',
          padding: '8px',
        }}
      >
        {/* Screen Bezel */}
        <div
          className="monitor-frame-bezel"
          style={{
            position: 'relative',
            background: '#0a0a0a',
            borderRadius: '8px',
            overflow: 'hidden',
            padding: '12px',
            border: '1px solid #1a1a1a',
          }}
        >
          {/* Screen Content */}
          <div
            className="monitor-frame-screen"
            style={{
              position: 'relative',
              aspectRatio: '16 / 9',
              background: '#000',
              borderRadius: '2px',
              overflow: 'hidden',
            }}
          >
            {children}
          </div>

          {/* Brand Label */}
          <div
            className="monitor-frame-brand"
            style={{
              position: 'absolute',
              bottom: '4px',
              left: '50%',
              transform: 'translateX(-50%)',
              fontSize: '9px',
              color: '#555',
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
          background: '#2d2d2d',
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
          background: '#1a1a1a',
          borderRadius: '8px 8px 0 0',
          marginTop: '-2px',
          border: '1px solid #333',
          borderBottom: 'none',
        }}
      />

      {/* Stand Shadow */}
      <div
        className="monitor-frame-stand-shadow"
        style={{
          width: '180px',
          height: '8px',
          background: '#0f0f0f',
          marginTop: '-4px',
          borderRadius: '50%',
        }}
      />
    </div>
  );
};

export default MonitorFrame;
