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
  MacCommandOutlined
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
  '带鱼屏、曲面屏等大屏幕用户，频繁扭头看副屏窗口，长期导致颈椎不适。',
  '当前工作窗口跑到了副屏，录屏、演示、开会前还要手动拖回主屏。',
  '拖回主屏之后还要自己调尺寸，注意力会从任务本身切出去。',
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
    title: '菜单栏常驻，不打断桌面',
    description: '需要时随时可用，不需要时安静待在菜单栏里。',
    icon: <DesktopOutlined />
  },
  {
    title: '权限与状态可诊断',
    description: '设置页可以检查授权、安装路径、登录项和快捷键配置，减少排查成本。',
    icon: <EyeOutlined />
  },
  {
    title: 'yabai 跨工作区支持',
    description: '检测到 yabai 窗口管理器后，可跨 Space（工作区）移动和恢复窗口。',
    icon: <MacCommandOutlined />
  }
];

const scenarios = [
  '带鱼屏、曲面屏等大屏幕用户，无需频繁扭头即可查看副屏窗口内容，保护颈椎。',
  '录屏、演示、直播前，把当前窗口立即拉回主屏，保持自然视线。',
  '写作、编码、分析时进入短时"只看一个窗口"的深度工作状态。',
  '多显示器办公时，降低频繁拖窗和重新摆窗的机械劳动。'
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
  }
];

const faqs = [
  {
    key: '1',
    label: 'Vibe Focus 为什么能保护颈椎？',
    children:
      '带鱼屏、曲面屏等 40 英寸以上大屏幕用户，经常需要扭头看副屏窗口。Vibe Focus 让你一键将窗口聚焦到主屏中央，无需频繁转动头部，有效减少颈椎压力，特别适合长时间 Vibe Coding 的用户。'
  },
  {
    key: '2',
    label: '它和 macOS 原生全屏有什么区别？',
    children:
      '原生全屏会切到独立 Space，更重；Vibe Focus 是把窗口铺满主屏可见区域，适合短流程聚焦，不会强行改变你的桌面结构。'
  },
  {
    key: '3',
    label: '为什么需要辅助功能权限？',
    children:
      '因为应用需要控制其他 App 的窗口位置和大小，这是 macOS 的受保护能力，所以首次使用必须给 Vibe Focus 辅助功能权限。如果权限异常，可在设置页复制重置命令（tccutil reset Accessibility）并在终端执行。Vibe Focus 在未授权时也会尝试使用 System Events 作为降级方案。'
  },
  {
    key: '4',
    label: '什么是跨工作区支持？',
    children:
      '当系统安装了 yabai 窗口管理器时，Vibe Focus 可以跨 Space（工作区）移动窗口，并提供两种恢复策略：切回原工作区，或把窗口拉到当前工作区。'
  },
  {
    key: '5',
    label: '为什么提示安装位置异常？',
    children:
      'Vibe Focus 会检查安装位置，建议放在 ~/Applications/ 或 /Applications/ 目录。检测到多副本时也会提示，建议只保留一个副本运行。'
  },
  {
    key: '6',
    label: '哪些人最适合用它？',
    children:
      '经常开会、录屏、做演示，或者日常在双屏/多屏环境下深度工作的人，会最明显感受到收益。'
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
                    保护颈椎，专注编码
                  </Tag>
                  <Title className="hero-title">
                    <span>告别频繁扭头</span>
                    保护颈椎健康
                  </Title>
                  <Paragraph className="hero-description">
                    专为带鱼屏、曲面屏等 40 英寸以上大屏幕用户设计。Vibe Focus 让你无需频繁扭头看副屏窗口，
                    一键将窗口聚焦到主屏中央，有效减少颈椎压力，让 Vibe Coding 更持久、更健康。
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
                      <Statistic title="一次快捷键" value="聚焦当前窗口" />
                    </Card>
                  </Col>
                  <Col xs={12} md={6}>
                    <Card className="stat-card">
                      <Statistic title="再次触发" value="恢复原布局" />
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
                description: '默认是 ⌃M（Control+M），也可以在设置页里重新录制。请确保快捷键不与系统快捷键冲突。'
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
                  享受大屏幕的效率，同时保护颈椎健康
                </Title>
                <Paragraph className="cta-description">
                  40 英寸以上的带鱼屏、曲面屏让 Vibe Coding 更高效，但频繁扭头会给颈椎带来压力。
                  Vibe Focus 帮助你减少扭头次数，把窗口带到视线中央，让高效工作与健康颈椎兼得。
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
              <a href="#demo">效果演示</a>
              <a href="#features">功能</a>
              <a href="#faq">FAQ</a>
            </Space>
          </div>
          <Text className="footer-copyright">
            © 2024 Vibe Focus. All rights reserved.
          </Text>
        </div>
      </Footer>
    </Layout>
  );
}
