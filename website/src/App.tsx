import {
  AppstoreOutlined,
  CheckCircleOutlined,
  DesktopOutlined,
  EyeOutlined,
  PlayCircleOutlined,
  ThunderboltOutlined
} from '@ant-design/icons';
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
  Typography
} from 'antd';

const { Header, Content, Footer } = Layout;
const { Title, Paragraph, Text } = Typography;

const pains = [
  '当前工作窗口跑到了副屏，录屏、演示、开会前还要手动拖回主屏。',
  '拖回主屏之后还要自己调尺寸，注意力会从任务本身切出去。',
  '聚焦结束后，很难精确恢复原来的位置和大小。',
  '原生全屏太重，手动摆窗太慢，日常使用缺少一个刚刚好的“临时聚焦”动作。'
];

const capabilities = [
  {
    title: '一键聚焦当前窗口',
    description: '把当前窗口移动到主屏，并铺满可见区域，而不是切到另一个全屏 Space。',
    icon: <ThunderboltOutlined />
  },
  {
    title: '一键恢复原布局',
    description: '临时聚焦完成后，再按一次快捷键就恢复原位置和大小。',
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
  }
];

const scenarios = [
  '录屏、演示、直播前，把当前窗口立即拉回主屏。',
  '写作、编码、分析时进入短时“只看一个窗口”的深度工作状态。',
  '多显示器办公时，降低频繁拖窗和重新摆窗的机械劳动。',
  '临时聚焦结束后，快速回到原来的桌面布局。'
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
};

const demoAssets: DemoItem[] = [
  {
    key: 'focus-to-main-display',
    title: '演示 01：一键拉回主屏并铺满',
    description: '展示从副屏窗口快速进入主屏聚焦态，适合录屏前 3 秒切换。',
    kind: 'GIF',
    expectedPath: '/demos/focus-to-main-display.gif'
  },
  {
    key: 'restore-original-layout',
    title: '演示 02：再次触发恢复原布局',
    description: '展示聚焦结束后窗口回到原位置与尺寸，避免手动摆窗。',
    kind: 'Video',
    expectedPath: '/demos/restore-original-layout.mp4'
  },
  {
    key: 'permissions-diagnostics',
    title: '演示 03：权限和状态诊断',
    description: '展示设置页里的辅助功能权限、登录项和快捷键状态检查。',
    kind: 'Video',
    expectedPath: '/demos/permissions-diagnostics.mp4'
  }
];

const faqs = [
  {
    key: '1',
    label: 'Vibe Focus 解决的核心问题是什么？',
    children:
      '它解决的是多显示器工作流里“临时聚焦某个窗口”这件事太繁琐的问题，让拖窗、缩放、恢复布局这套重复动作变成一次快捷键切换。'
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
      '因为应用需要控制其他 App 的窗口位置和大小，这是 macOS 的受保护能力，所以首次使用必须给 Vibe Focus 辅助功能权限。'
  },
  {
    key: '4',
    label: '哪些人最适合用它？',
    children:
      '经常开会、录屏、做演示，或者日常在双屏/多屏环境下深度工作的人，会最明显感受到收益。'
  }
];

export default function App() {
  return (
    <Layout className="site-shell">
      <Header className="site-header">
        <div className="brand">
          <img src="/logo.svg" alt="Vibe Focus Logo" className="brand-logo" />
          <div>
            <div className="brand-title">Vibe Focus</div>
            <div className="brand-subtitle">把拖窗动作变成一次按键</div>
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
      </Header>

      <Content className="site-content">
        <section className="hero">
          <div className="hero-bg" />
          <div className="hero-content">
            <Row gutter={[28, 28]} align="middle" className="hero-grid">
              <Col xs={24} lg={14}>
                <Space direction="vertical" size={20} className="hero-main">
                  <Tag color="cyan" className="hero-tag">
                    macOS 菜单栏效率工具
                  </Tag>
                  <Title className="hero-title">
                    把窗口聚焦，做成一个
                    <span>不打断心流</span>
                    的动作
                  </Title>
                  <Paragraph className="hero-description">
                    Vibe Focus 专为多显示器工作流设计：
                    一键把当前窗口移动到主屏并铺满可见区域，再一键恢复原布局。
                    你不用再拖窗、调尺寸、记位置，只需要继续工作。
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

              <Col xs={24} lg={10}>
                <Card className="hero-video-card" bordered={false}>
                  <div className="hero-video-shell">
                    <div className="hero-video-placeholder">
                      <PlayCircleOutlined className="hero-video-icon" />
                      <Text className="hero-video-title">Banner 演示视频占位</Text>
                      <Text className="hero-video-hint">
                        后续替换成自动播放、静音、循环的演示视频
                      </Text>
                      <Text className="hero-video-path">/demos/hero-loop-preview.mp4</Text>
                    </div>
                  </div>
                  <Space size={8}>
                    <Tag color="cyan">Loop Preview</Tag>
                    <Tag>16:9</Tag>
                  </Space>
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
          <Title level={2}>我们解决的问题</Title>
          <Paragraph className="section-lead">
            Vibe Focus 不是通用窗口管理器，而是专门解决“临时把当前窗口拉回主屏并聚焦”这件高频小事。
          </Paragraph>
          <Row gutter={[20, 20]}>
            {pains.map((item) => (
              <Col xs={24} md={12} key={item}>
                <Card className="info-card">
                  <Paragraph>{item}</Paragraph>
                </Card>
              </Col>
            ))}
          </Row>
        </section>

        <section id="solution" className="section section-alt">
          <Title level={2}>Vibe Focus 的解决方式</Title>
          <Paragraph className="section-lead">
            它不试图接管你的整个桌面，而是只优化一个关键时刻：你需要马上聚焦当前窗口的时候。
          </Paragraph>
          <Steps
            responsive
            current={3}
            items={[
              {
                title: '按下快捷键',
                description: '默认是 Ctrl+M，也可以在设置页里重新录制。'
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
          <Title level={2}>效果演示</Title>
          <Paragraph className="section-lead">
            下面预留了 GIF 和 Video 的展示位。把素材放到
            <Text code>website/public/demos</Text>，
            然后在 <Text code>demoAssets</Text> 里填入对应 <Text code>src</Text> 即可上线展示。
          </Paragraph>
          <Row gutter={[20, 20]}>
            {demoAssets.map((item) => (
              <Col xs={24} lg={8} key={item.key}>
                <Card className="demo-card">
                  <div className="demo-media-shell">
                    {item.src ? (
                      item.kind === 'Video' ? (
                        <video
                          className="demo-media"
                          controls
                          muted
                          loop
                          playsInline
                          poster={item.poster}
                        >
                          <source src={item.src} type="video/mp4" />
                        </video>
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
                  <Space direction="vertical" size={8}>
                    <Space size={8}>
                      <Tag color="blue">{item.kind}</Tag>
                      <Tag>{item.key}</Tag>
                    </Space>
                    <Title level={4}>{item.title}</Title>
                    <Paragraph>{item.description}</Paragraph>
                  </Space>
                </Card>
              </Col>
            ))}
          </Row>
        </section>

        <section id="features" className="section">
          <Title level={2}>核心功能</Title>
          <Row gutter={[20, 20]}>
            {capabilities.map((item) => (
              <Col xs={24} md={12} key={item.title}>
                <Card className="feature-card">
                  <Space size={14} align="start">
                    <div className="feature-icon">{item.icon}</div>
                    <div>
                      <Title level={4}>{item.title}</Title>
                      <Paragraph>{item.description}</Paragraph>
                    </div>
                  </Space>
                </Card>
              </Col>
            ))}
          </Row>
        </section>

        <section id="scenes" className="section section-alt">
          <Title level={2}>适用场景</Title>
          <Row gutter={[20, 20]}>
            {scenarios.map((item) => (
              <Col xs={24} md={12} key={item}>
                <Card className="scene-card">
                  <Space align="start">
                    <AppstoreOutlined className="scene-icon" />
                    <Text>{item}</Text>
                  </Space>
                </Card>
              </Col>
            ))}
          </Row>
        </section>

        <section className="section">
          <Card className="cta-card">
            <Row gutter={[24, 24]} align="middle">
              <Col xs={24} lg={15}>
                <Title level={2}>它不是为了“管理所有窗口”，而是为了减少一次次机械操作</Title>
                <Paragraph>
                  如果你已经知道自己要聚焦哪个窗口，Vibe Focus 就会是最快的一步。
                  它帮助你把手从触控板和拖拽动作里解放出来，把注意力还给任务本身。
                </Paragraph>
              </Col>
              <Col xs={24} lg={9}>
                <Space direction="vertical" size={12} style={{ width: '100%' }}>
                  <Button type="primary" size="large" block href="#faq">
                    查看常见问题
                  </Button>
                  <Button size="large" block href="https://github.com/vibe-coding-labs/vibe-focus">
                    查看项目仓库
                  </Button>
                </Space>
              </Col>
            </Row>
          </Card>
        </section>

        <section id="faq" className="section">
          <Title level={2}>常见问题</Title>
          <Collapse items={faqs} className="faq" />
        </section>

        <Divider />
      </Content>

      <Footer className="site-footer">
        <Space direction="vertical" size={6}>
          <Text strong>Vibe Focus</Text>
          <Text type="secondary">
            一款为 macOS 多显示器工作流设计的窗口聚焦工具。
          </Text>
        </Space>
      </Footer>
    </Layout>
  );
}
