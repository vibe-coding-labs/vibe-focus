import {
  useEffect,
  useRef,
  useState,
  useCallback
} from 'react';
import {
  AppstoreOutlined,
  CheckCircleOutlined,
  DesktopOutlined,
  EyeOutlined,
  GithubOutlined,
  PlayCircleOutlined,
  ThunderboltOutlined,
  PauseCircleOutlined,
  FullscreenOutlined,
  FullscreenExitOutlined,
  LoadingOutlined,
  MacCommandOutlined,
  SyncOutlined
} from '@ant-design/icons';
import { MonitorFrame } from './components/MonitorFrame';
import {
  Anchor,
  Button,
  Card,
  Col,
  Collapse,
  Divider,
  Layout,
  Row,
  Space,
  Statistic,
  Steps,
  Tag,
  Typography,
  Tooltip
} from 'antd';

const { Header, Content, Footer } = Layout;
const { Title, Paragraph, Text } = Typography;

const pains = [
  '带鱼屏、曲面屏用户频繁扭头看副屏窗口，长期导致颈椎不适。',
  '使用 Claude Code 编程时，终端在副屏，需要频繁扭头查看 AI 响应结果。',
  '窗口跑到了副屏，录屏、演示前还要手动拖回主屏并调尺寸。',
  '聚焦结束后，很难精确恢复原来的位置和大小。'
];

const capabilities = [
  {
    title: '一键聚焦当前窗口',
    description: '把当前窗口移动到主屏，并铺满可见区域，而不是切到另一个全屏 Space。',
    icon: <ThunderboltOutlined />
  },
  {
    title: '一键恢复原布局',
    description: '临时聚焦完成后，再按一次快捷键就恢复原位置和大小。支持自定义恢复策略：可切回原工作区，也可将窗口拉到当前工作区。',
    icon: <CheckCircleOutlined />
  },
  {
    title: 'Claude Code 自动化',
    description: '深度集成 Claude Code，对话结束时自动聚焦终端到主屏，提交新 Prompt 时自动恢复原位。全程零手动操作。',
    icon: <MacCommandOutlined />
  },
  {
    title: '多终端精确匹配',
    description: '通过 TTY、PPID、会话 ID 等终端上下文精确匹配窗口。多个 Claude Code 实例并行工作也不会错乱。',
    icon: <DesktopOutlined />
  },
  {
    title: '菜单栏常驻，不打断桌面',
    description: '需要时随时可用，不需要时安静待在菜单栏里。Hook 服务器自动启停，无需额外配置。',
    icon: <EyeOutlined />
  },
  {
    title: '权限与状态可诊断',
    description: '设置页可以检查授权、Hook 连接状态、活跃会话和快捷键配置，减少排查成本。',
    icon: <AppstoreOutlined />
  }
];

const scenarios = [
  '使用 Claude Code 编程时，副屏终端自动聚焦到主屏查看响应结果，保护颈椎。',
  '带鱼屏、曲面屏用户，无需频繁扭头即可查看副屏窗口内容，保护颈椎。',
  '录屏、演示、直播前，把当前窗口立即拉回主屏，保持自然视线。',
  '多显示器办公时，一键聚焦和恢复，降低频繁拖窗和重新摆窗的机械劳动。'
];

type DemoMediaKind = 'GIF' | 'Video';

type DemoItem = {
  key: string;
  title: string;
  description: string;
  kind: DemoMediaKind;
  expectedPath: string;
  src?: string;
  poster?: string;
  // 视频配置选项
  playsInline?: boolean;
  controls?: boolean;
  muted?: boolean;
  loop?: boolean;
  autoPlay?: boolean;
};

const demoAssets: DemoItem[] = [
  {
    key: 'focus-to-main-display',
    title: '演示 01：一键拉回主屏并铺满',
    description: '展示从副屏窗口快速进入主屏聚焦态，适合录屏前 3 秒切换。',
    kind: 'GIF',
    expectedPath: '/vibe-focus/demos/focus-to-main-display.gif',
    src: '/vibe-focus/demos/focus-to-main-display.gif',
    poster: '/vibe-focus/demos/focus-to-main-display-poster.jpg'
  },
  {
    key: 'restore-original-layout',
    title: '演示 02：再次触发恢复原布局',
    description: '展示聚焦结束后窗口回到原位置与尺寸，避免手动摆窗。',
    kind: 'Video',
    expectedPath: '/vibe-focus/demos/restore-original-layout.mp4',
    src: '/vibe-focus/demos/restore-original-layout.mp4',
    poster: '/vibe-focus/demos/restore-original-layout-poster.jpg',
    playsInline: true,
    controls: false,
    muted: true,
    loop: true,
    autoPlay: true
  },
  {
    key: 'permissions-diagnostics',
    title: '演示 03：权限和状态诊断',
    description: '展示设置页里的辅助功能权限、登录项和快捷键状态检查。',
    kind: 'Video',
    expectedPath: '/vibe-focus/demos/permissions-diagnostics.mp4',
    src: '/vibe-focus/demos/permissions-diagnostics.mp4',
    poster: '/vibe-focus/demos/permissions-diagnostics-poster.jpg',
    playsInline: true,
    controls: false,
    muted: true,
    loop: true,
    autoPlay: true
  },
  {
    key: 'claude-code-auto-focus',
    title: '演示 04：Claude Code 对话结束自动聚焦',
    description: '展示 Claude Code 响应完成后，终端窗口自动移到主屏并铺满的效果。',
    kind: 'Video',
    expectedPath: '/vibe-focus/demos/claude-code-auto-focus.mp4'
  },
  {
    key: 'claude-code-auto-restore',
    title: '演示 05：提交 Prompt 自动恢复',
    description: '展示提交新 Prompt 后，窗口自动从主屏恢复到副屏原始位置的效果。',
    kind: 'Video',
    expectedPath: '/vibe-focus/demos/claude-code-auto-restore.mp4'
  }
];

const faqs = [
  {
    key: '1',
    label: 'Vibe Focus 为什么能保护颈椎？',
    children:
      '带鱼屏、曲面屏等 40 英寸以上大屏幕用户，经常需要扭头看副屏窗口。Vibe Focus 让你一键将窗口聚焦到主屏中央，配合 Claude Code 自动化集成，对话结束时自动聚焦，无需频繁转动头部，有效减少颈椎压力。'
  },
  {
    key: '2',
    label: 'Claude Code 集成如何工作？',
    children:
      'Vibe Focus 在本地启动一个 HTTP 服务器，接收 Claude Code 的 Hook 事件。当 Claude 完成响应（Stop 事件）时，自动将终端窗口移到主屏；当用户提交新 Prompt（UserPromptSubmit 事件）时，自动将窗口恢复到原位。整个过程通过 TTY、PPID 等终端上下文精确匹配，无需任何手动操作。'
  },
  {
    key: '3',
    label: '它和 macOS 原生全屏有什么区别？',
    children:
      '原生全屏会切到独立 Space，更重；Vibe Focus 是把窗口铺满主屏可见区域，适合短流程聚焦，不会强行改变你的桌面结构。'
  },
  {
    key: '4',
    label: '为什么需要辅助功能权限？',
    children:
      '因为应用需要控制其他 App 的窗口位置和大小，这是 macOS 的受保护能力，所以首次使用必须给 Vibe Focus 辅助功能权限。如果权限异常，可在设置页复制重置命令并在终端执行。'
  },
  {
    key: '5',
    label: '支持哪些终端和 IDE？',
    children:
      'Terminal.app、iTerm2、Warp、Ghostty、Alacritty、kitty 等终端均已适配。IDE 集成终端方面支持 VS Code 和 Cursor。Claude Code 的 Hook 集成对所有终端有效，自动匹配逻辑会根据终端类型选择最佳策略。'
  },
  {
    key: '6',
    label: '什么是跨工作区支持？',
    children:
      '当系统安装了 yabai 窗口管理器时，Vibe Focus 可以跨 Space（工作区）移动窗口，并提供两种恢复策略：切回原工作区，或把窗口拉到当前工作区。'
  },
  {
    key: '7',
    label: '哪些人最适合用它？',
    children:
      '使用 Claude Code 进行 Vibe Coding 的开发者、经常开会录屏的人、双屏/多屏环境下深度工作的用户，会最明显感受到收益。特别是大屏幕用户，自动聚焦功能可以大幅减少扭头次数。'
  }
];

// 自定义 Hook：视频视口自动播放
function useVideoAutoPlay(videoRef: React.RefObject<HTMLVideoElement>) {
  const [isInViewport, setIsInViewport] = useState(false);
  const [isPlaying, setIsPlaying] = useState(false);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;

    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          setIsInViewport(entry.isIntersecting);
        });
      },
      { threshold: 0.3 }
    );

    observer.observe(video);

    return () => {
      observer.disconnect();
    };
  }, [videoRef]);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;

    if (isInViewport) {
      video.play().catch(() => {
        // 自动播放可能被浏览器阻止，忽略错误
      });
    } else {
      video.pause();
    }
  }, [isInViewport, videoRef]);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;

    const handlePlay = () => setIsPlaying(true);
    const handlePause = () => setIsPlaying(false);

    video.addEventListener('play', handlePlay);
    video.addEventListener('pause', handlePause);

    return () => {
      video.removeEventListener('play', handlePlay);
      video.removeEventListener('pause', handlePause);
    };
  }, [videoRef]);

  return { isInViewport, isPlaying };
}

// 视频播放器组件
interface VideoPlayerProps {
  item: DemoItem;
}

function VideoPlayer({ item }: VideoPlayerProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const { isPlaying } = useVideoAutoPlay(videoRef);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [isLoaded, setIsLoaded] = useState(false);

  const toggleFullscreen = useCallback(async () => {
    const container = containerRef.current;
    if (!container) return;

    try {
      if (!isFullscreen) {
        if (container.requestFullscreen) {
          await container.requestFullscreen();
        }
      } else {
        if (document.exitFullscreen) {
          await document.exitFullscreen();
        }
      }
    } catch (err) {
      console.error('Fullscreen error:', err);
    }
  }, [isFullscreen]);

  const togglePlay = useCallback(() => {
    const video = videoRef.current;
    if (!video) return;

    if (video.paused) {
      video.play();
    } else {
      video.pause();
    }
  }, []);

  useEffect(() => {
    const handleFullscreenChange = () => {
      setIsFullscreen(!!document.fullscreenElement);
    };

    document.addEventListener('fullscreenchange', handleFullscreenChange);
    return () => {
      document.removeEventListener('fullscreenchange', handleFullscreenChange);
    };
  }, []);

  const handleVideoClick = () => {
    toggleFullscreen();
  };

  const handleLoadedData = () => {
    setIsLoaded(true);
  };

  // 视频内容
  const videoContent = (
    <video
      ref={videoRef}
      className="demo-media"
      src={item.src}
      poster={item.poster}
      muted={item.muted !== false}
      loop={item.loop !== false}
      playsInline={item.playsInline !== false}
      controls={isFullscreen || item.controls}
      onClick={handleVideoClick}
      onLoadedData={handleLoadedData}
      preload="metadata"
      style={{
        width: '100%',
        height: '100%',
        objectFit: 'contain',
        display: 'block',
      }}
    >
      <source src={item.src} type="video/mp4" />
    </video>
  );

  return (
    <div
      ref={containerRef}
      className={`video-player-container ${isFullscreen ? 'is-fullscreen' : ''}`}
    >
      {!isLoaded && (
        <div className="video-loading">
          <LoadingOutlined className="video-loading-icon" />
        </div>
      )}

      {/* 全屏模式：直接显示视频 */}
      {isFullscreen ? (
        videoContent
      ) : (
        /* 正常模式：用 MonitorFrame 包裹 */
        <MonitorFrame isActive={isPlaying} brand="Vibe Focus">
          {videoContent}
        </MonitorFrame>
      )}

      {/* 播放/暂停指示器 - 仅在非全屏时显示 */}
      {!isFullscreen && (
        <div className={`video-play-indicator ${isPlaying ? 'is-playing' : 'is-paused'}`}>
          {isPlaying ? (
            <PauseCircleOutlined className="video-indicator-icon" />
          ) : (
            <PlayCircleOutlined className="video-indicator-icon" />
          )}
        </div>
      )}

      {/* 视频控制栏 */}
      <div className="video-controls">
        <Tooltip title={isPlaying ? '暂停' : '播放'}>
          <button
            className="video-control-btn"
            onClick={(e) => {
              e.stopPropagation();
              togglePlay();
            }}
          >
            {isPlaying ? <PauseCircleOutlined /> : <PlayCircleOutlined />}
          </button>
        </Tooltip>
        <Tooltip title={isFullscreen ? '退出全屏' : '全屏'}>
          <button
            className="video-control-btn"
            onClick={(e) => {
              e.stopPropagation();
              toggleFullscreen();
            }}
          >
            {isFullscreen ? <FullscreenExitOutlined /> : <FullscreenOutlined />}
          </button>
        </Tooltip>
      </div>
    </div>
  );
}

// Hero 视频组件
function HeroVideoPlayer() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const { isPlaying } = useVideoAutoPlay(videoRef);
  const [isFullscreen, setIsFullscreen] = useState(false);

  const toggleFullscreen = useCallback(async () => {
    const container = containerRef.current;
    if (!container) return;

    try {
      if (!isFullscreen) {
        if (container.requestFullscreen) {
          await container.requestFullscreen();
        }
      } else {
        if (document.exitFullscreen) {
          await document.exitFullscreen();
        }
      }
    } catch (err) {
      console.error('Fullscreen error:', err);
    }
  }, [isFullscreen]);

  useEffect(() => {
    const handleFullscreenChange = () => {
      setIsFullscreen(!!document.fullscreenElement);
    };

    document.addEventListener('fullscreenchange', handleFullscreenChange);
    return () => {
      document.removeEventListener('fullscreenchange', handleFullscreenChange);
    };
  }, []);

  // 视频内容
  const videoContent = (
    <video
      ref={videoRef}
      className="hero-video-player"
      src="/vibe-focus/demos/hero-loop-preview.mp4?v=9"
      autoPlay
      muted
      loop
      playsInline
      controls={isFullscreen}
      onClick={toggleFullscreen}
      style={{
        width: '100%',
        height: '100%',
        objectFit: 'contain',
        objectPosition: 'center center',
        display: 'block',
      }}
    />
  );

  return (
    <div
      ref={containerRef}
      className={`video-player-container hero-video-wrapper ${isFullscreen ? 'is-fullscreen' : ''}`}
    >
      {/* 全屏模式：直接显示视频 */}
      {isFullscreen ? (
        videoContent
      ) : (
        /* 正常模式：用 MonitorFrame 包裹 */
        <MonitorFrame isActive={isPlaying} brand="Vibe Focus">
          {videoContent}
        </MonitorFrame>
      )}

      {/* 播放/暂停指示器 - 仅在非全屏时显示 */}
      {!isFullscreen && (
        <div className={`video-play-indicator ${isPlaying ? 'is-playing' : 'is-paused'}`}>
          {isPlaying ? (
            <PauseCircleOutlined className="video-indicator-icon" />
          ) : (
            <PlayCircleOutlined className="video-indicator-icon" />
          )}
        </div>
      )}

      {/* 视频控制栏 */}
      <div className="video-controls">
        <Tooltip title={isFullscreen ? '退出全屏' : '全屏'}>
          <button
            className="video-control-btn"
            onClick={(e) => {
              e.stopPropagation();
              toggleFullscreen();
            }}
          >
            {isFullscreen ? <FullscreenExitOutlined /> : <FullscreenOutlined />}
          </button>
        </Tooltip>
      </div>
    </div>
  );
}

// Claude Code 自动化工作流步骤
const hookWorkflowSteps = [
  {
    key: 'start',
    title: '在副屏启动对话',
    description: '在副屏终端中启动 Claude Code 对话，正常编码。'
  },
  {
    key: 'auto-focus',
    title: '对话结束自动聚焦',
    description: 'Claude 完成响应后，终端窗口自动移到主屏并铺满。'
  },
  {
    key: 'review',
    title: '在主屏查看结果',
    description: '无需扭头，在主屏直接查看 Claude 的响应内容。'
  },
  {
    key: 'auto-restore',
    title: '提交 Prompt 自动恢复',
    description: '提交新 Prompt 后，窗口自动回到副屏原始位置。'
  }
];

// 自动循环工作流展示组件
function HookWorkflowAnimation() {
  const [activeStep, setActiveStep] = useState(0);

  useEffect(() => {
    const timer = setInterval(() => {
      setActiveStep((prev) => (prev + 1) % hookWorkflowSteps.length);
    }, 3000);
    return () => clearInterval(timer);
  }, []);

  return (
    <div className="hook-workflow-container">
      <div className="hook-workflow-track">
        {hookWorkflowSteps.map((step, index) => (
          <div
            key={step.key}
            className={`hook-workflow-step ${index === activeStep ? 'active' : ''}`}
          >
            <div className="hook-workflow-step-number">
              {index + 1}
            </div>
            <div className="hook-workflow-step-content">
              <div className="hook-workflow-step-title">{step.title}</div>
              <div className="hook-workflow-step-desc">{step.description}</div>
            </div>
            {index < hookWorkflowSteps.length - 1 && (
              <div className={`hook-workflow-connector ${index < activeStep ? 'active' : ''}`}>
                <div className="hook-workflow-connector-line" />
              </div>
            )}
          </div>
        ))}
      </div>
      <div className="hook-workflow-loop-hint">
        <SyncOutlined className="hook-workflow-loop-icon" />
        <span>全程自动循环，无需手动操作</span>
      </div>
    </div>
  );
}

export default function App() {
  return (
    <Layout className="site-shell">
      <Header className="site-header">
        <div className="brand">
          <img src="/logo.svg" alt="Vibe Focus Logo" className="brand-logo" />
          <div>
            <div className="brand-title">Vibe Focus</div>
            <div className="brand-subtitle">保护颈椎，专注编码</div>
          </div>
        </div>
        <Anchor
          className="header-anchor"
          direction="horizontal"
          items={[
            { key: 'problem', href: '#problem', title: '问题' },
            { key: 'solution', href: '#solution', title: '解决方案' },
            { key: 'claude-code', href: '#claude-code', title: 'Claude Code' },
            { key: 'demo', href: '#demo', title: '效果演示' },
            { key: 'features', href: '#features', title: '功能' },
            { key: 'scenes', href: '#scenes', title: '场景' },
            { key: 'faq', href: '#faq', title: 'FAQ' }
          ]}
        />
        <a
          href="https://github.com/vibe-coding-labs/vibe-focus"
          target="_blank"
          rel="noopener noreferrer"
          className="github-link"
        >
          <GithubOutlined />
        </a>
      </Header>

      <Content className="site-content">
        <section className="hero">
          <div className="hero-bg" />
          <div className="hero-content">
            <Row gutter={[28, 28]} align="middle" className="hero-grid">
              <Col xs={24} lg={9}>
                <Space direction="vertical" size={20} className="hero-main">
                  <Tag color="cyan" className="hero-tag">
                    保护颈椎 · Claude Code 深度集成
                  </Tag>
                  <Title className="hero-title">
                    <span>告别频繁扭头</span>
                    保护颈椎健康
                  </Title>
                  <Paragraph className="hero-description">
                    专为带鱼屏、曲面屏等 40 英寸以上大屏幕用户设计。Vibe Focus 让你无需频繁扭头看副屏窗口，
                    一键将窗口聚焦到主屏中央。现已深度集成 Claude Code，
                    对话结束时自动聚焦，提交新 Prompt 时自动恢复，全程零手动操作。
                  </Paragraph>
                  <Space wrap size={16}>
                    <Button type="primary" size="large" href="#solution">
                      了解它如何工作
                    </Button>
                    <Button size="large" href="#demo">
                      先看效果演示
                    </Button>
                  </Space>
                </Space>
              </Col>

              <Col xs={24} lg={15}>
                <Card className="hero-video-card" bordered={false}>
                  <div className="hero-video-shell">
                    <HeroVideoPlayer />
                  </div>
                </Card>
              </Col>

              <Col span={24}>
                <Row gutter={[16, 16]} className="hero-stats">
                  <Col xs={12} md={6}>
                    <Card className="stat-card">
                      <Statistic title="快捷键" value="聚焦 / 恢复" />
                    </Card>
                  </Col>
                  <Col xs={12} md={6}>
                    <Card className="stat-card">
                      <Statistic title="Claude Code" value="自动化集成" />
                    </Card>
                  </Col>
                  <Col xs={12} md={6}>
                    <Card className="stat-card">
                      <Statistic title="适配环境" value="多显示器办公" />
                    </Card>
                  </Col>
                  <Col xs={12} md={6}>
                    <Card className="stat-card">
                      <Statistic title="运行方式" value="菜单栏常驻" />
                    </Card>
                  </Col>
                </Row>
              </Col>
            </Row>
          </div>
        </section>

        <section id="problem" className="section">
          <div className="section-header">
            <Title level={2}>大屏幕用户的颈椎困扰</Title>
            <Paragraph className="section-lead">
              40 英寸以上的带鱼屏、曲面屏在 Vibe Coding 时提供了更大的视野，但也带来了频繁扭头的问题。Vibe Focus 专门解决这一健康隐患。
            </Paragraph>
          </div>
          <Row gutter={[24, 24]}>
            {pains.map((item, index) => (
              <Col xs={24} md={12} key={index}>
                <Card className="info-card" bordered={false}>
                  <div className="info-card-number">0{index + 1}</div>
                  <Paragraph className="info-card-text">{item}</Paragraph>
                </Card>
              </Col>
            ))}
          </Row>
        </section>

        <section id="solution" className="section section-alt">
          <div className="section-header">
            <Title level={2}>保护颈椎，从减少扭头开始</Title>
            <Paragraph className="section-lead">
              它不只优化窗口管理，更重要的是保护你的颈椎健康。通过减少频繁扭头，让你在享受大屏幕带来的效率提升的同时，远离颈椎问题。
            </Paragraph>
          </div>
          <Steps
            responsive
            current={3}
            className="solution-steps"
            items={[
              {
                title: '按下快捷键',
                description: '默认是 ⌃Q（Control+Q），也可以在设置页里重新录制。请确保快捷键不与系统快捷键冲突。'
              },
              {
                title: '移动并铺满主屏',
                description: '把当前窗口送到主屏的可见区域，而不是切系统全屏。'
              },
              {
                title: '继续完成任务',
                description: '录屏、演示、深度工作，都不需要再手动拖窗。'
              },
              {
                title: '再次按键恢复',
                description: '结束聚焦后，窗口回到原位置与大小。'
              }
            ]}
          />
        </section>

        <section id="claude-code" className="section">
          <div className="section-header">
            <Title level={2}>Claude Code 深度集成</Title>
            <Paragraph className="section-lead">
              与 Claude Code 无缝集成，对话结束时自动聚焦终端窗口到主屏，提交新 Prompt 时自动恢复原位。全程零手动操作，让你专注于编码本身。
            </Paragraph>
          </div>
          <HookWorkflowAnimation />
          <Row gutter={[24, 24]} style={{ marginTop: 48 }}>
            <Col xs={24} md={8}>
              <Card className="feature-card" bordered={false}>
                <div className="feature-card-content">
                  <div className="feature-icon-wrapper">
                    <ThunderboltOutlined />
                  </div>
                  <div className="feature-text">
                    <Title level={4}>对话结束自动聚焦</Title>
                    <Paragraph>Claude 完成响应后，终端窗口自动移到主屏。Stop 和 SessionEnd 事件均可触发。</Paragraph>
                  </div>
                </div>
              </Card>
            </Col>
            <Col xs={24} md={8}>
              <Card className="feature-card" bordered={false}>
                <div className="feature-card-content">
                  <div className="feature-icon-wrapper">
                    <CheckCircleOutlined />
                  </div>
                  <div className="feature-text">
                    <Title level={4}>提交 Prompt 自动恢复</Title>
                    <Paragraph>提交新 Prompt 时，窗口自动回到副屏原始位置和大小。精确保存窗口状态，恢复零误差。</Paragraph>
                  </div>
                </div>
              </Card>
            </Col>
            <Col xs={24} md={8}>
              <Card className="feature-card" bordered={false}>
                <div className="feature-card-content">
                  <div className="feature-icon-wrapper">
                    <MacCommandOutlined />
                  </div>
                  <div className="feature-text">
                    <Title level={4}>多终端精确匹配</Title>
                    <Paragraph>通过 TTY、PPID、会话 ID 精确匹配窗口，多 Claude Code 实例并行也不会错乱。</Paragraph>
                  </div>
                </div>
              </Card>
            </Col>
          </Row>
        </section>

        <section id="demo" className="section">
          <div className="section-header">
            <Title level={2}>效果演示</Title>
            <Paragraph className="section-lead">
              以下演示展示了 Vibe Focus 的核心功能，使用 Remotion 生成。
              <br />
              每个演示都展示了多显示器工作流中的实际应用场景。
            </Paragraph>
          </div>
          <Row gutter={[24, 32]}>
            {demoAssets.map((item) => (
              <Col xs={24} md={12} lg={8} key={item.key}>
                <Card className="demo-card" bordered={false}>
                  <div className="demo-media-shell">
                    {item.src ? (
                      item.kind === 'Video' ? (
                        <VideoPlayer item={item} />
                      ) : (
                        <img className="demo-media" src={item.src} alt={item.title} />
                      )
                    ) : (
                      <div className="demo-placeholder">
                        <PlayCircleOutlined className="demo-placeholder-icon" />
                        <Text className="demo-placeholder-title">{item.kind} 占位区</Text>
                        <Text className="demo-placeholder-path">{item.expectedPath}</Text>
                      </div>
                    )}
                  </div>
                  <div className="demo-card-content">
                    <Space size={8} className="demo-card-tags">
                      <Tag color="cyan">{item.kind}</Tag>
                      <Tag color="blue">演示 0{item.key.split('-').pop()?.slice(0, 2) || '1'}</Tag>
                    </Space>
                    <Title level={4} className="demo-card-title">{item.title}</Title>
                    <Paragraph className="demo-card-description">
                      {item.description}
                    </Paragraph>
                  </div>
                </Card>
              </Col>
            ))}
          </Row>
        </section>

        <section id="features" className="section">
          <div className="section-header">
            <Title level={2}>核心功能</Title>
            <Paragraph className="section-lead">
              五大核心能力，覆盖多显示器工作流中的关键场景
            </Paragraph>
          </div>
          <Row gutter={[24, 24]}>
            {capabilities.map((item, index) => (
              <Col xs={24} md={12} key={item.title}>
                <Card className="feature-card" bordered={false}>
                  <div className="feature-card-content">
                    <div className="feature-icon-wrapper">
                      {item.icon}
                    </div>
                    <div className="feature-text">
                      <Title level={4}>{item.title}</Title>
                      <Paragraph>{item.description}</Paragraph>
                    </div>
                  </div>
                </Card>
              </Col>
            ))}
          </Row>
        </section>

        <section id="scenes" className="section section-alt">
          <div className="section-header">
            <Title level={2}>适合谁用</Title>
            <Paragraph className="section-lead">
              如果你在使用带鱼屏、曲面屏等 40 英寸以上大屏幕，这些场景会让你感受到 Vibe Focus 的价值
            </Paragraph>
          </div>
          <Row gutter={[24, 24]}>
            {scenarios.map((item, index) => (
              <Col xs={24} md={12} key={index}>
                <Card className="scene-card" bordered={false}>
                  <div className="scene-card-content">
                    <div className="scene-icon-wrapper">
                      <AppstoreOutlined />
                    </div>
                    <Text className="scene-text">{item}</Text>
                  </div>
                </Card>
              </Col>
            ))}
          </Row>
        </section>

        <section className="section section-cta">
          <Card className="cta-card" bordered={false}>
            <Row gutter={[48, 32]} align="middle">
              <Col xs={24} lg={16}>
                <Title level={2} className="cta-title">
                  大屏编码，健康颈椎，Vibe Coding 更持久
                </Title>
                <Paragraph className="cta-description">
                  一键聚焦 + Claude Code 自动化集成，让你在带鱼屏、曲屏等大屏幕上高效编码的同时，
                  大幅减少扭头次数。无论是手动快捷键还是全自动 Hook，Vibe Focus 都能帮你把窗口带到视线中央。
                </Paragraph>
              </Col>
              <Col xs={24} lg={8}>
                <Space direction="vertical" size={16} style={{ width: '100%' }}>
                  <Button type="primary" size="large" block href="#faq" className="cta-button-primary">
                    查看常见问题
                  </Button>
                  <Button size="large" block href="https://github.com/vibe-coding-labs/vibe-focus" className="cta-button-secondary">
                    查看项目仓库
                  </Button>
                </Space>
              </Col>
            </Row>
          </Card>
        </section>

        <section id="faq" className="section">
          <div className="section-header">
            <Title level={2}>常见问题</Title>
            <Paragraph className="section-lead">
              关于 Vibe Focus 的使用疑问，在这里找到答案
            </Paragraph>
          </div>
          <Collapse items={faqs} className="faq" bordered={false} />
        </section>

        <Divider />
      </Content>

      <Footer className="site-footer">
        <div className="footer-content">
          <div className="footer-brand">
            <img src="/logo.svg" alt="Vibe Focus" className="footer-logo" />
            <div>
              <Text strong className="footer-title">Vibe Focus</Text>
              <Text className="footer-subtitle">
                为带鱼屏、曲面屏等大屏幕用户设计的颈椎保护工具
              </Text>
            </div>
          </div>
          <div className="footer-links">
            <Space size={24} className="footer-nav">
              <a href="#problem">问题</a>
              <a href="#solution">解决方案</a>
              <a href="#claude-code">Claude Code</a>
              <a href="#demo">效果演示</a>
              <a href="#features">功能</a>
              <a href="#faq">FAQ</a>
            </Space>
          </div>
          <Text className="footer-copyright">
            &copy; 2024-2026 Vibe Focus. All rights reserved.
          </Text>
        </div>
      </Footer>
    </Layout>
  );
}
