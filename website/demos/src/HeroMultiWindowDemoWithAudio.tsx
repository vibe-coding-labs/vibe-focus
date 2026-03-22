import React from 'react';
import {
  AbsoluteFill,
  useCurrentFrame,
  interpolate,
  Audio,
  staticFile,
  useVideoConfig,
} from 'remotion';
import { HeroMultiWindowDemo } from './HeroMultiWindowDemo.js';

// Audio segments timing (frames at 60fps)
// Total: 900 frames (15 seconds)
const AUDIO_TIMING = {
  intro: { start: 0, end: 120, file: 'intro.mp3' },      // 0-2s: Intro
  round1: { start: 120, end: 420, file: 'round1.mp3' },  // 2-7s: Round 1
  round2: { start: 420, end: 720, file: 'round2.mp3' },  // 7-12s: Round 2
  round3: { start: 720, end: 900, file: 'round3.mp3' },  // 12-15s: Round 3
};

// Text overlays for each segment
const TEXT_OVERLAYS = [
  {
    startFrame: 30,
    endFrame: 120,
    text: 'Vibe Focus - 多显示器窗口管理',
    subText: '一键聚焦，一键恢复',
    position: 'center',
  },
  {
    startFrame: 150,
    endFrame: 400,
    text: '按下 ⌃M，窗口瞬间移动到主屏',
    subText: '自动铺满可见区域',
    position: 'bottom',
  },
  {
    startFrame: 450,
    endFrame: 700,
    text: '左右副屏，都能快速聚焦',
    subText: '无需手动拖拽调整',
    position: 'bottom',
  },
  {
    startFrame: 750,
    endFrame: 870,
    text: '再次按下 ⌃M，窗口恢复原位',
    subText: '精准回到原来的位置和大小',
    position: 'bottom',
  },
];

// Text Overlay Component
const TextOverlay: React.FC<{
  frame: number;
  text: string;
  subText?: string;
  startFrame: number;
  endFrame: number;
  position: 'center' | 'bottom' | 'top';
}> = ({ frame, text, subText, startFrame, endFrame, position }) => {
  const { fps } = useVideoConfig();

  // Fade in/out animation
  const fadeDuration = 15; // frames
  let opacity = 0;

  if (frame >= startFrame && frame <= endFrame) {
    if (frame < startFrame + fadeDuration) {
      opacity = (frame - startFrame) / fadeDuration;
    } else if (frame > endFrame - fadeDuration) {
      opacity = (endFrame - frame) / fadeDuration;
    } else {
      opacity = 1;
    }
  }

  if (opacity <= 0) return null;

  const getPosition = () => {
    switch (position) {
      case 'top':
        return { top: '15%', left: '50%', transform: 'translateX(-50%)' };
      case 'bottom':
        return { bottom: '18%', left: '50%', transform: 'translateX(-50%)' };
      case 'center':
      default:
        return { top: '45%', left: '50%', transform: 'translate(-50%, -50%)' };
    }
  };

  return (
    <div
      style={{
        position: 'absolute',
        ...getPosition(),
        textAlign: 'center',
        opacity,
        zIndex: 100,
        pointerEvents: 'none',
      }}
    >
      <div
        style={{
          background: 'rgba(0, 0, 0, 0.7)',
          padding: '16px 32px',
          borderRadius: '12px',
          border: '1px solid rgba(0, 212, 255, 0.5)',
          boxShadow: '0 4px 20px rgba(0, 0, 0, 0.5), 0 0 30px rgba(0, 212, 255, 0.2)',
        }}
      >
        <div
          style={{
            color: '#00d4ff',
            fontSize: position === 'center' ? '36px' : '28px',
            fontWeight: 700,
            fontFamily: 'system-ui, -apple-system, sans-serif',
            textShadow: '0 2px 8px rgba(0,0,0,0.8)',
            letterSpacing: '0.5px',
            marginBottom: subText ? '8px' : 0,
          }}
        >
          {text}
        </div>
        {subText && (
          <div
            style={{
              color: '#ffffff',
              fontSize: '20px',
              fontWeight: 500,
              fontFamily: 'system-ui, -apple-system, sans-serif',
              textShadow: '0 1px 4px rgba(0,0,0,0.8)',
            }}
          >
            {subText}
          </div>
        )}
      </div>
    </div>
  );
};

// Current time indicator
const TimeIndicator: React.FC<{ frame: number }> = ({ frame }) => {
  const { fps } = useVideoConfig();
  const seconds = Math.floor(frame / fps);
  const displayTime = `${seconds}s`;

  return (
    <div
      style={{
        position: 'absolute',
        top: '20px',
        right: '20px',
        background: 'rgba(0, 0, 0, 0.6)',
        padding: '8px 16px',
        borderRadius: '8px',
        color: '#00d4ff',
        fontSize: '14px',
        fontFamily: 'monospace',
        fontWeight: 600,
        zIndex: 100,
        border: '1px solid rgba(0, 212, 255, 0.3)',
      }}
    >
      {displayTime}
    </div>
  );
};

// Progress bar showing rounds
const ProgressBar: React.FC<{ frame: number }> = ({ frame }) => {
  const { fps } = useVideoConfig();
  const totalFrames = 900;
  const progress = (frame / totalFrames) * 100;

  // Determine current round
  let currentRound = 1;
  if (frame >= 300 && frame < 600) currentRound = 2;
  else if (frame >= 600) currentRound = 3;

  return (
    <div
      style={{
        position: 'absolute',
        bottom: '12px',
        left: '50%',
        transform: 'translateX(-50%)',
        width: '300px',
        zIndex: 100,
      }}
    >
      {/* Round indicators */}
      <div
        style={{
          display: 'flex',
          justifyContent: 'center',
          gap: '8px',
          marginBottom: '8px',
        }}
      >
        {[1, 2, 3].map((round) => (
          <div
            key={round}
            style={{
              padding: '4px 12px',
              borderRadius: '4px',
              background: currentRound === round
                ? 'rgba(0, 212, 255, 0.8)'
                : 'rgba(255, 255, 255, 0.2)',
              color: currentRound === round ? '#000' : '#fff',
              fontSize: '12px',
              fontWeight: 600,
              fontFamily: 'system-ui, -apple-system, sans-serif',
            }}
          >
            第 {round} 轮
          </div>
        ))}
      </div>

      {/* Progress bar */}
      <div
        style={{
          height: '4px',
          background: 'rgba(255, 255, 255, 0.2)',
          borderRadius: '2px',
          overflow: 'hidden',
        }}
      >
        <div
          style={{
            height: '100%',
            width: `${progress}%`,
            background: 'linear-gradient(90deg, #00d4ff, #5ce1ff)',
            borderRadius: '2px',
            transition: 'width 0.1s linear',
          }}
        />
      </div>
    </div>
  );
};

// Main Component with Audio and Text
export const HeroMultiWindowDemoWithAudio: React.FC = () => {
  const frame = useCurrentFrame();

  return (
    <AbsoluteFill style={{ backgroundColor: '#0a1929' }}>
      {/* Base animation */}
      <HeroMultiWindowDemo />

      {/* Audio tracks */}
      <Audio
        src={staticFile('audio/intro.mp3')}
        startFrom={0}
        endAt={120}
      />
      <Audio
        src={staticFile('audio/round1.mp3')}
        startFrom={120}
        endAt={420}
      />
      <Audio
        src={staticFile('audio/round2.mp3')}
        startFrom={420}
        endAt={720}
      />
      <Audio
        src={staticFile('audio/round3.mp3')}
        startFrom={720}
        endAt={900}
      />

      {/* Text overlays */}
      {TEXT_OVERLAYS.map((overlay, index) => (
        <TextOverlay
          key={index}
          frame={frame}
          text={overlay.text}
          subText={overlay.subText}
          startFrame={overlay.startFrame}
          endFrame={overlay.endFrame}
          position={overlay.position as 'center' | 'bottom' | 'top'}
        />
      ))}

      {/* Time indicator */}
      <TimeIndicator frame={frame} />

      {/* Progress bar */}
      <ProgressBar frame={frame} />
    </AbsoluteFill>
  );
};

export default HeroMultiWindowDemoWithAudio;
