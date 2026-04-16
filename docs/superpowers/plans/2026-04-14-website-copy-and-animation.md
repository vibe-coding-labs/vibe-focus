# Website Copy & Animation Optimization Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 更新官网文案和动画演示，反映 VibeFocus 新增的 Claude Code 深度集成、对话结束自动聚焦、提交 Prompt 自动恢复、终端上下文精确匹配等核心能力。

**Architecture:** 修改 `App.tsx` 中的数据数组（pains/capabilities/scenarios/faqs/demoAssets）更新文案，新增 `HookWorkflowAnimation` 组件展示 Claude Code 自动化工作流；修改 `styles.css` 添加步骤循环动画和过渡效果；保持现有 React + Ant Design 技术栈不变。

**Tech Stack:** React 18, TypeScript 5, Ant Design 5, Vite 6, CSS3 Animations

**Risks:**
- CSS 动画在不同浏览器表现可能不一致 -> 缓解：使用标准 `@keyframes` + `animation` 属性
- 新增内容可能使页面过长 -> 缓解：每个 section 控制在 2-3 屏内
- 新 demo 视频资源暂不存在 -> 缓解：使用占位符组件，不依赖实际视频文件

---

### Task 1: Update All Copy — Hero, Capabilities, Scenarios, Demos, FAQ, CTA

**Depends on:** None
**Files:**
- Modify: `website/src/App.tsx:42-47` (pains array)
- Modify: `website/src/App.tsx:49-75` (capabilities array)
- Modify: `website/src/App.tsx:77-82` (scenarios array)
- Modify: `website/src/App.tsx:102-139` (demoAssets array)
- Modify: `website/src/App.tsx:142-179` (faqs array)
- Modify: `website/src/App.tsx:525-546` (hero content)
- Modify: `website/src/App.tsx:559-581` (hero stats)
- Modify: `website/src/App.tsx:730-754` (CTA section)
- Modify: `website/src/App.tsx:781-791` (footer nav + copyright)

- [ ] **Step 1: Update pain points array to include Claude Code context**

文件: `website/src/App.tsx:42-47`

```tsx
const pains = [
  '带鱼屏、曲面屏用户频繁扭头看副屏窗口，长期导致颈椎不适。',
  '使用 Claude Code 编程时，终端在副屏，需要频繁扭头查看 AI 响应结果。',
  '窗口跑到了副屏，录屏、演示前还要手动拖回主屏并调尺寸。',
  '聚焦结束后，很难精确恢复原来的位置和大小。'
];
```

- [ ] **Step 2: Update capabilities array with new Claude Code features**

文件: `website/src/App.tsx:49-75`

```tsx
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
```

- [ ] **Step 3: Update scenarios array to lead with Claude Code use case**

文件: `website/src/App.tsx:77-82`

```tsx
const scenarios = [
  '使用 Claude Code 编程时，副屏终端自动聚焦到主屏查看响应结果，保护颈椎。',
  '带鱼屏、曲面屏用户，无需频繁扭头即可查看副屏窗口内容，保护颈椎。',
  '录屏、演示、直播前，把当前窗口立即拉回主屏，保持自然视线。',
  '多显示器办公时，一键聚焦和恢复，降低频繁拖窗和重新摆窗的机械劳动。'
];
```

- [ ] **Step 4: Add new demo items for Claude Code features**

文件: `website/src/App.tsx:102-139`

在现有 3 个 demo 之后追加 2 个新 demo：

```tsx
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
```

- [ ] **Step 5: Update FAQ with Claude Code related questions**

文件: `website/src/App.tsx:142-179`

```tsx
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
```

- [ ] **Step 6: Update hero tagline and description**

文件: `website/src/App.tsx:525-546`（hero-main Space 内容区块）

```tsx
<Space direction="vertical" size={20} className="hero-main">
  <Tag color="cyan" className="hero-tag">
    保护颈椎 · Claude Code 深度集成
  </Tag>
  <Title className="hero-title">
    <span>告别频繁扭头</span>
    保护颈椎健康
  </Title>
  <Paragraph className="hero-description">
    专为带鱼屏、曲面屏等大屏幕用户设计。Vibe Focus 让你无需频繁扭头看副屏窗口，
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
```

- [ ] **Step 7: Update hero stats**

文件: `website/src/App.tsx:559-581`

```tsx
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
```

- [ ] **Step 8: Update CTA section copy**

文件: `website/src/App.tsx:730-754`

```tsx
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
```

- [ ] **Step 9: Update footer nav and copyright**

文件: `website/src/App.tsx:781-791`

```tsx
<Space size={24} className="footer-nav">
  <a href="#problem">问题</a>
  <a href="#solution">解决方案</a>
  <a href="#claude-code">Claude Code</a>
  <a href="#demo">效果演示</a>
  <a href="#features">功能</a>
  <a href="#faq">FAQ</a>
</Space>
```

```tsx
<Text className="footer-copyright">
  &copy; 2024-2026 Vibe Focus. All rights reserved.
</Text>
```

- [ ] **Step 10: Commit**

Run: `git add website/src/App.tsx && git commit -m "feat(website): update copy to reflect Claude Code integration capabilities"`

---

### Task 2: Add Claude Code Integration Section with Animated Workflow

**Depends on:** None (parallel with Task 1)
**Files:**
- Modify: `website/src/App.tsx` (add HookWorkflowAnimation component + section JSX + nav anchor)
- Modify: `website/src/styles.css` (add animation CSS)

- [ ] **Step 1: Add import for additional Ant Design icons**

文件: `website/src/App.tsx:8-20`（import 区块）

在现有 icon imports 中追加 `SyncOutlined`：

```tsx
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
```

- [ ] **Step 2: Add HookWorkflowAnimation component — auto-cycling animated workflow**

在 `website/src/App.tsx` 中，`HeroVideoPlayer` 组件定义之后（约第 486 行后），添加：

```tsx
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
            className={`hook-workflow-step ${index === activeStep ? 'active' : ''} ${index < activeStep || (activeStep === 0 && index === hookWorkflowSteps.length - 1) ? '' : ''}`}
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
```

- [ ] **Step 3: Add Claude Code integration section JSX — 插入到 solution section 之后**

在 `website/src/App.tsx` 中，找到 solution section 的闭合 `</section>` 标签（约第 635 行），在其后插入：

```tsx
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
```

- [ ] **Step 4: Add Claude Code nav anchor to Header**

文件: `website/src/App.tsx` Header Anchor items（约第 503-509 行），在 `solution` 和 `demo` 之间插入：

```tsx
items={[
  { key: 'problem', href: '#problem', title: '问题' },
  { key: 'solution', href: '#solution', title: '解决方案' },
  { key: 'claude-code', href: '#claude-code', title: 'Claude Code' },
  { key: 'demo', href: '#demo', title: '效果演示' },
  { key: 'features', href: '#features', title: '功能' },
  { key: 'scenes', href: '#scenes', title: '场景' },
  { key: 'faq', href: '#faq', title: 'FAQ' }
]}
```

- [ ] **Step 5: Add CSS animation styles for hook workflow**

在 `website/src/styles.css` 文件末尾追加：

```css
/* ===== Claude Code Hook Workflow Animation ===== */
.hook-workflow-container {
  max-width: 720px;
  margin: 0 auto;
  padding: 32px 0;
}

.hook-workflow-track {
  display: flex;
  flex-direction: column;
  gap: 0;
  position: relative;
}

.hook-workflow-step {
  display: flex;
  align-items: center;
  gap: 20px;
  padding: 20px 24px;
  border-radius: 12px;
  transition: all 0.5s cubic-bezier(0.4, 0, 0.2, 1);
  position: relative;
  opacity: 0.45;
  transform: scale(0.97);
}

.hook-workflow-step.active {
  opacity: 1;
  transform: scale(1);
  background: var(--color-card);
  border: 1px solid var(--color-accent);
  box-shadow: 0 0 24px rgba(56, 189, 248, 0.1);
}

.hook-workflow-step-number {
  width: 44px;
  height: 44px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 16px;
  font-weight: 700;
  background: transparent;
  border: 2px solid var(--color-border);
  color: var(--color-text-muted);
  flex-shrink: 0;
  transition: all 0.5s ease;
}

.hook-workflow-step.active .hook-workflow-step-number {
  border-color: var(--color-accent);
  color: var(--color-accent);
  background: rgba(56, 189, 248, 0.1);
  box-shadow: 0 0 12px rgba(56, 189, 248, 0.15);
}

.hook-workflow-step-content {
  flex: 1;
  min-width: 0;
}

.hook-workflow-step-title {
  font-size: 16px;
  font-weight: 600;
  color: var(--color-text);
  margin-bottom: 4px;
  transition: color 0.3s ease;
}

.hook-workflow-step.active .hook-workflow-step-title {
  color: var(--color-accent);
}

.hook-workflow-step-desc {
  font-size: 13px;
  color: var(--color-text-muted);
  line-height: 1.5;
}

.hook-workflow-connector {
  position: absolute;
  left: 45px;
  bottom: -20px;
  display: flex;
  flex-direction: column;
  align-items: center;
  z-index: 1;
}

.hook-workflow-connector-line {
  width: 2px;
  height: 18px;
  background: var(--color-border);
  transition: background 0.5s ease;
}

.hook-workflow-connector.active .hook-workflow-connector-line {
  background: var(--color-accent);
}

.hook-workflow-loop-hint {
  text-align: center;
  margin-top: 32px;
  font-size: 14px;
  color: var(--color-accent);
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
}

.hook-workflow-loop-icon {
  animation: spin-slow 3s linear infinite;
}

@keyframes spin-slow {
  from { transform: rotate(0deg); }
  to { transform: rotate(360deg); }
}

/* Hook Workflow Mobile Responsive */
@media (max-width: 640px) {
  .hook-workflow-step {
    padding: 16px;
    gap: 14px;
  }

  .hook-workflow-step-number {
    width: 36px;
    height: 36px;
    font-size: 14px;
  }

  .hook-workflow-step-title {
    font-size: 14px;
  }

  .hook-workflow-step-desc {
    font-size: 12px;
  }
}
```

- [ ] **Step 6: Commit**

Run: `git add website/src/App.tsx website/src/styles.css && git commit -m "feat(website): add Claude Code integration section with animated workflow"`

---

### Task 3: Build and Verify

**Depends on:** Task 1, Task 2
**Files:**
- Modify: `website/dist/` (build output)

- [ ] **Step 1: Install dependencies and build**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus/website && npm install && npm run build`

Expected:
  - Exit code: 0
  - Output contains: "built in"
  - No TypeScript compilation errors

- [ ] **Step 2: Verify build output**

Run: `ls -la /Users/cc11001100/github/vibe-coding-labs/vibe-focus/website/dist/`

Expected:
  - Directory contains: `index.html`, `assets/`
  - `assets/` contains new `.js` and `.css` files

- [ ] **Step 3: Commit build output**

Run: `git add website/dist/ && git commit -m "build(website): rebuild with updated copy and animations"`
