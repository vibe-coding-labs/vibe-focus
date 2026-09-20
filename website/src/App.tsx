import { useEffect, useRef, useState } from 'react';
import { MonitorFrame } from './components/MonitorFrame';

const RELEASES_URL = 'https://github.com/vibe-coding-labs/vibe-focus/releases';
const REPO_URL = 'https://github.com/vibe-coding-labs/vibe-focus';
const LATEST_VERSION = '0.0.89';
// vite base=/vibe-focus/（GitHub Pages 项目页）：public 资源必须拼 BASE_URL，否则线上 404
const BASE = import.meta.env.BASE_URL;

/* ---------------------------------- 图标（手绘描边风） ---------------------------------- */

type IconProps = { className?: string };

const IconBolt = ({ className }: IconProps) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <path d="M13 2 4.5 13.5H11L10 22l8.5-11.5H13L13 2z" />
  </svg>
);

const IconBubble = ({ className }: IconProps) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <path d="M21 11.5a8.5 8.5 0 0 1-8.5 8.5c-1.5 0-2.9-.4-4.1-1L3 20l1.1-4.2A8.5 8.5 0 1 1 21 11.5z" />
    <path d="M8 10h8M8 13.5h5" />
  </svg>
);

const IconGrid = ({ className }: IconProps) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <rect x="3" y="3" width="8" height="8" rx="1.5" />
    <rect x="13" y="3" width="8" height="8" rx="1.5" />
    <rect x="3" y="13" width="8" height="8" rx="1.5" />
    <rect x="13" y="13" width="8" height="8" rx="1.5" />
  </svg>
);

const IconSessions = ({ className }: IconProps) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <path d="M3 12a9 9 0 1 0 9-9" />
    <path d="M12 7v5l3.5 3.5" />
    <path d="M3 3l4 2-2 4" />
  </svg>
);

const IconMap = ({ className }: IconProps) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <rect x="2.5" y="5" width="14" height="11" rx="1.5" />
    <rect x="15" y="9" width="6.5" height="10" rx="1.5" />
    <circle cx="7" cy="9" r="1.2" />
    <path d="M5.5 13.5h6" />
  </svg>
);

const IconGlobe = ({ className }: IconProps) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <circle cx="12" cy="12" r="9" />
    <path d="M3 12h18" />
    <path d="M12 3a14.5 14.5 0 0 1 0 18 14.5 14.5 0 0 1 0-18z" />
  </svg>
);

const IconShield = ({ className }: IconProps) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <path d="M12 3l7 3v5c0 4.5-3 8.5-7 10-4-1.5-7-5.5-7-10V6l7-3z" />
    <path d="M9.5 11.5l2 2 3.5-4" />
  </svg>
);

const IconGithub = ({ className }: IconProps) => (
  <svg className={className} viewBox="0 0 24 24" fill="currentColor">
    <path d="M12 2C6.48 2 2 6.58 2 12.25c0 4.53 2.87 8.37 6.84 9.73.5.1.68-.22.68-.49 0-.24-.01-.88-.01-1.73-2.78.62-3.37-1.37-3.37-1.37-.45-1.18-1.11-1.5-1.11-1.5-.91-.63.07-.62.07-.62 1 .07 1.53 1.06 1.53 1.06.89 1.57 2.34 1.12 2.91.85.09-.66.35-1.11.63-1.37-2.22-.26-4.56-1.14-4.56-5.07 0-1.12.39-2.03 1.03-2.75-.1-.26-.45-1.3.1-2.7 0 0 .84-.28 2.75 1.05a9.36 9.36 0 0 1 5 0c1.91-1.33 2.75-1.05 2.75-1.05.55 1.4.2 2.44.1 2.7.64.72 1.03 1.63 1.03 2.75 0 3.94-2.34 4.8-4.57 5.06.36.32.68.94.68 1.9 0 1.37-.01 2.47-.01 2.81 0 .27.18.6.69.49A10.26 10.26 0 0 0 22 12.25C22 6.58 17.52 2 12 2z" />
  </svg>
);

const IconDownload = ({ className }: IconProps) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <path d="M12 3v12" />
    <path d="M7 11l5 5 5-5" />
    <path d="M4 20h16" />
  </svg>
);

const IconTerminal = ({ className }: IconProps) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <rect x="3" y="4" width="18" height="16" rx="2.5" />
    <path d="M7 9l3 3-3 3" />
    <path d="M12.5 15H17" />
  </svg>
);

const IconApple = ({ className }: IconProps) => (
  <svg className={className} viewBox="0 0 24 24" fill="currentColor">
    <path d="M16.7 12.9c0-2.4 2-3.6 2.1-3.7-1.1-1.7-2.9-1.9-3.5-1.9-1.5-.2-2.9.9-3.7.9-.8 0-1.9-.9-3.2-.86-1.6 0-3.1 1-4 2.4-1.7 3-.4 7.3 1.2 9.7.8 1.2 1.8 2.5 3.1 2.4 1.2-.05 1.7-.8 3.2-.8s1.9.8 3.2.77c1.3 0 2.2-1.2 3-2.4.9-1.4 1.3-2.7 1.3-2.8-.03-.01-2.6-1-2.7-3.9zM14.4 5.2c.7-.8 1.1-2 1-3.2-1 .04-2.2.66-2.9 1.5-.6.7-1.2 1.9-1 3 1.1.1 2.2-.55 2.9-1.3z" />
  </svg>
);

/* ---------------------------------- 数据 ---------------------------------- */

const pains = [
  {
    title: '副屏窗口反复扭头看',
    text: '带鱼屏、曲面屏、双屏用户在编码时频繁扭头看副屏终端，一天下来颈椎先罢工。'
  },
  {
    title: 'AI 响应要人盯着',
    text: 'Claude Code 跑长任务时，你不知道它什么时候完成，只能反复切过去看。'
  },
  {
    title: '录屏演示前手忙脚乱',
    text: '窗口跑在副屏，录屏、开会、直播前要手动拖回主屏、拉尺寸、摆半天。'
  },
  {
    title: '聚焦之后回不去',
    text: '临时聚焦完成后，原始位置和大小很难精确复原，桌面越摆越乱。'
  }
];

const capabilities = [
  {
    icon: <IconBolt />,
    title: '一键聚焦 / 恢复',
    text: '⌃Q 把当前窗口移到主屏并铺满可见区域，再按一次精确回到原位置、原尺寸——不切 Space，不动桌面结构。'
  },
  {
    icon: <IconTerminal />,
    title: 'AI 对话自动聚焦',
    text: 'Claude Code / Codex 完成响应（Stop 事件）时，终端自动拉回主屏——响应好了窗口自己过来，不用盯。'
  },
  {
    icon: <IconBubble />,
    title: '⌃X 输入气泡',
    text: '不切窗口直接下指令：Markdown 实时渲染、↑↓ 翻历史、⌘Y 历史面板、AX 落地验证保证回车必达。'
  },
  {
    icon: <IconGrid />,
    title: '网格布局',
    text: '把散落的窗口一键捕获进网格，多屏逐格铺位；临时拼装的工作台随时可恢复。'
  },
  {
    icon: <IconSessions />,
    title: '会话恢复',
    text: '重启或重连后，多屏 × 多工作区的终端会话窗口布局完整还原，直接接着上次干。'
  },
  {
    icon: <IconMap />,
    title: '屏幕小地图 + 空间角标',
    text: 'Minimap 浮层实时显示每块屏的窗口分布，「屏号-位次」角标让窗口去向一目了然。'
  },
  {
    icon: <IconGlobe />,
    title: 'LAN 远程',
    text: 'SSH 到远程机器跑的 Claude Code 会话，一样触发本机的自动拉窗——远程编码同款体验。'
  },
  {
    icon: <IconShield />,
    title: '权限自愈与诊断',
    text: '辅助功能授权竞态自动检测自愈，Doctor 一键体检授权、Hook 连接与快捷键状态。'
  }
];

const terminals = ['Terminal.app', 'iTerm2', 'Warp', 'Ghostty', 'Alacritty', 'kitty', 'VS Code', 'Cursor'];

const hookSteps = [
  { key: 'start', title: '副屏开始对话', desc: '在副屏终端正常启动 Claude Code，专注写你的需求。' },
  { key: 'focus', title: 'Claude 完成响应', desc: 'Stop 事件触发，Vibe Focus 立即收到通知。' },
  { key: 'review', title: '窗口自动到主屏', desc: '终端被拉回主屏铺满，视线不用离开正前方。' },
  { key: 'stay', title: '继续输入，窗口不动', desc: '提交与语音输入期间窗口保持原地，绝不打断你的节奏。' }
];

const faqs = [
  {
    q: 'Vibe Focus 为什么能保护颈椎？',
    a: '带鱼屏、曲面屏等大屏用户经常需要扭头看副屏窗口。Vibe Focus 把「看副屏」变成「窗口自己来主屏」：一键快捷键，或 Claude Code 完成响应时自动拉回，显著减少扭头次数。'
  },
  {
    q: 'Claude Code / Codex 集成如何工作？',
    a: 'Vibe Focus 在本地启动一个 HTTP 服务器接收 Hook 事件：Claude 完成响应（Stop）时自动把绑定终端拉回主屏；你提交 Prompt 或语音输入期间，窗口保持原地不动。支持本地与 LAN 远程会话，通过 TTY、PPID、会话 ID 精确匹配窗口，多实例并行不串窗。'
  },
  {
    q: '输入气泡是什么？',
    a: '按 ⌃X 唤出的浮动输入框：不切窗口、不打断当前终端，直接输入要发给 Claude Code / Codex 的指令。支持 Markdown 实时渲染（Typora 式）、↑↓ 翻阅历史、⌘Y 打开历史面板回填草稿。回车提交前会通过 AX 落地验证确保粘贴完成后再发送，长文本也不会出现「进了输入框没发送」的情况。'
  },
  {
    q: '它和 macOS 原生全屏有什么区别？',
    a: '原生全屏会切到独立 Space，进出代价大；Vibe Focus 是把窗口铺满主屏可见区域，不改变你的桌面结构，适合短流程聚焦，结束后一键精确恢复。'
  },
  {
    q: '为什么需要辅助功能权限？',
    a: '移动和调整其他 App 的窗口是 macOS 的受保护能力，首次使用必须授予辅助功能权限。如果授权异常，设置页可一键诊断并复制重置命令；Vibe Focus 还内置授权竞态自愈，多数异常无需手动处理。'
  },
  {
    q: '支持哪些终端和 IDE？',
    a: 'Terminal.app、iTerm2、Warp、Ghostty、Alacritty、kitty 均已适配，IDE 集成终端支持 VS Code 与 Cursor。自动匹配逻辑按终端类型选择最佳策略。'
  },
  {
    q: '什么是跨工作区支持？',
    a: '安装 yabai 窗口管理器后，Vibe Focus 可以跨 Space 移动窗口：目标窗口在不可见工作区时先聚焦带切，再执行移动，配合两种恢复策略（切回原工作区 / 拉到当前工作区）。'
  },
  {
    q: '适合谁用？',
    a: '用 Claude Code / Codex 做 Vibe Coding 的开发者、多显示器深度办公用户、经常录屏演示的人收益最直接——尤其是 40 英寸以上带鱼屏、曲面屏用户。'
  }
];

/* ---------------------------------- 动效基建 ---------------------------------- */

/** 进视口显现：挂载后观察所有 .reveal 元素，进入视口加 .is-visible */
function useRevealObserver() {
  useEffect(() => {
    const els = Array.from(document.querySelectorAll('.reveal'));
    if (!('IntersectionObserver' in window)) {
      els.forEach((el) => el.classList.add('is-visible'));
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add('is-visible');
            io.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.15, rootMargin: '0px 0px -8% 0px' }
    );
    els.forEach((el) => io.observe(el));
    return () => io.disconnect();
  }, []);
}

/** 导航滚动毛玻璃 */
function useScrolled(threshold = 24) {
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > threshold);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, [threshold]);
  return scrolled;
}

/** 视口内自动播放 */
function useInViewportPlay(ref: React.RefObject<HTMLVideoElement>) {
  const [playing, setPlaying] = useState(false);
  useEffect(() => {
    const video = ref.current;
    if (!video) return;
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            video.play().then(
              () => setPlaying(true),
              () => setPlaying(false)
            );
          } else {
            video.pause();
            setPlaying(false);
          }
        });
      },
      { threshold: 0.3 }
    );
    io.observe(video);
    return () => io.disconnect();
  }, [ref]);
  return playing;
}

/* ---------------------------------- 组件 ---------------------------------- */

function Nav() {
  const scrolled = useScrolled();
  const links = [
    ['#features', '功能'],
    ['#automation', '自动化'],
    ['#demo', '演示'],
    ['#download', '下载'],
    ['#faq', 'FAQ']
  ];
  return (
    <header className={`nav ${scrolled ? 'is-scrolled' : ''}`}>
      <div className="nav-inner">
        <a href="#top" className="nav-brand">
          <img src={`${BASE}logo.svg`} alt="Vibe Focus" className="nav-logo" />
          <span className="nav-brand-text">Vibe Focus</span>
        </a>
        <nav className="nav-links">
          {links.map(([href, label]) => (
            <a key={href} href={href}>{label}</a>
          ))}
        </nav>
        <a className="btn btn-primary btn-sm nav-cta" href="#download">
          <IconDownload className="btn-icon" />
          免费下载
        </a>
        <a
          className="nav-github"
          href={REPO_URL}
          target="_blank"
          rel="noopener noreferrer"
          aria-label="GitHub 仓库"
        >
          <IconGithub />
        </a>
      </div>
    </header>
  );
}

function Hero() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const playing = useInViewportPlay(videoRef);
  return (
    <section className="hero" id="top">
      <div className="hero-blob hero-blob-a" aria-hidden="true" />
      <div className="hero-blob hero-blob-b" aria-hidden="true" />
      <div className="hero-inner">
        <div className="hero-copy">
          <span className="hero-badge reveal">
            <span className="hero-badge-dot" />
            macOS 菜单栏 · Claude Code / Codex 深度集成 · v{LATEST_VERSION}
          </span>
          <h1 className="hero-title reveal" style={{ '--delay': '0.06s' } as React.CSSProperties}>
            窗口自动就位，
            <br />
            编码<em className="grad-text">不再扭头</em>
          </h1>
          <p className="hero-sub reveal" style={{ '--delay': '0.12s' } as React.CSSProperties}>
            一键聚焦 / 恢复窗口布局；AI 对话结束自动拉回主屏；⌃X 输入气泡让你
            不切窗口直接下指令。把「拖窗、摆窗、盯屏」这些机械动作全部交给系统。
          </p>
          <div className="hero-actions reveal" style={{ '--delay': '0.18s' } as React.CSSProperties}>
            <a className="btn btn-primary btn-lg" href="#download">
              <IconDownload className="btn-icon" />
              免费下载 v{LATEST_VERSION}
            </a>
            <a className="btn btn-ghost btn-lg" href="#automation">
              看它如何工作
            </a>
          </div>
          <div className="hero-stats reveal" style={{ '--delay': '0.24s' } as React.CSSProperties}>
            <div className="hero-stat">
              <strong>⌃Q</strong>
              <span>一键聚焦 / 恢复</span>
            </div>
            <div className="hero-stat">
              <strong>⌃X</strong>
              <span>输入气泡直达</span>
            </div>
            <div className="hero-stat">
              <strong>2 大 CLI</strong>
              <span>Claude Code · Codex</span>
            </div>
            <div className="hero-stat">
              <strong>8+</strong>
              <span>终端与 IDE 适配</span>
            </div>
          </div>
        </div>
        <div className="hero-media reveal" style={{ '--delay': '0.15s' } as React.CSSProperties}>
          <div className="hero-media-glow" aria-hidden="true" />
          <MonitorFrame isActive={playing} brand="Vibe Focus">
            <video
              ref={videoRef}
              className="hero-video"
              src="/vibe-focus/demos/hero-loop-preview.mp4?v=10"
              autoPlay
              muted
              loop
              playsInline
              preload="metadata"
            />
          </MonitorFrame>
        </div>
      </div>
      <div className="terminal-strip" aria-hidden="true">
        <div className="terminal-strip-track">
          {[...terminals, ...terminals].map((t, i) => (
            <span key={i} className="terminal-chip">
              <IconTerminal className="terminal-chip-icon" />
              {t}
            </span>
          ))}
        </div>
      </div>
    </section>
  );
}

function Pains() {
  return (
    <section className="section" id="problem">
      <div className="section-head reveal">
        <span className="section-kicker">问题</span>
        <h2 className="section-title">多屏工作流里，这些动作每天都在浪费你</h2>
        <p className="section-lead">窗口管理与「盯着 AI」都是低频高打断的机械劳动，累积起来就是持续的颈椎与注意力损耗。</p>
      </div>
      <div className="pain-grid">
        {pains.map((p, i) => (
          <div className="pain-card reveal" key={p.title} style={{ '--delay': `${i * 0.07}s` } as React.CSSProperties}>
            <span className="pain-num">0{i + 1}</span>
            <h3>{p.title}</h3>
            <p>{p.text}</p>
          </div>
        ))}
      </div>
    </section>
  );
}

function Features() {
  return (
    <section className="section section-alt" id="features">
      <div className="section-head reveal">
        <span className="section-kicker">功能</span>
        <h2 className="section-title">从一个快捷键，长成一套窗口自动驾驶系统</h2>
        <p className="section-lead">0.0.x 持续迭代 20+ 个版本：聚焦、气泡、网格、会话恢复、小地图、远程联动，全部为你自动就位。</p>
      </div>
      <div className="feature-grid">
        {capabilities.map((c, i) => (
          <div className="feature-card reveal" key={c.title} style={{ '--delay': `${(i % 4) * 0.06}s` } as React.CSSProperties}>
            <div className="feature-icon">{c.icon}</div>
            <h3>{c.title}</h3>
            <p>{c.text}</p>
          </div>
        ))}
      </div>
    </section>
  );
}

function Automation() {
  const [active, setActive] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setActive((p) => (p + 1) % hookSteps.length), 2600);
    return () => clearInterval(t);
  }, []);

  return (
    <section className="section" id="automation">
      <div className="section-head reveal">
        <span className="section-kicker">自动化</span>
        <h2 className="section-title">Claude Code / Codex 完成响应，窗口自己过来</h2>
        <p className="section-lead">
          Hook 事件驱动，全程零手动：<strong>Stop</strong> 拉回主屏看结果，提交与语音输入期间窗口纹丝不动。
        </p>
      </div>

      <div className="flow reveal" data-step={active}>
        <div className="flow-stage" aria-hidden="true">
          <div className="flow-screen flow-screen-secondary">
            <span className="flow-screen-label">副屏</span>
            <div className="flow-window flow-window-code">
              <span className="flow-window-dots"><i /><i /><i /></span>
              <span className="flow-window-title">claude</span>
              <div className="flow-window-lines"><i /><i /><i className="short" /></div>
            </div>
          </div>
          <div className="flow-screen flow-screen-primary">
            <span className="flow-screen-label">主屏</span>
            <div className="flow-window flow-window-main">
              <span className="flow-window-dots"><i /><i /><i /></span>
              <span className="flow-window-title">claude — 响应完成</span>
              <div className="flow-window-lines"><i /><i /><i /><i className="short" /></div>
            </div>
            <div className="flow-bubble">
              <span className="flow-bubble-caret" />
              ⏎ 已自动提交 · 窗口不动
            </div>
          </div>
          <svg className="flow-arrow" viewBox="0 0 120 60" aria-hidden="true">
            <path d="M4 44 C 40 8, 78 8, 114 36" />
            <polygon className="flow-arrow-head" points="114,36 103,30 106,41" />
          </svg>
        </div>

        <div className="flow-steps">
          {hookSteps.map((s, i) => (
            <button
              key={s.key}
              type="button"
              className={`flow-step ${i === active ? 'is-active' : ''} ${i < active ? 'is-done' : ''}`}
              onClick={() => setActive(i)}
            >
              <span className="flow-step-index">{i + 1}</span>
              <span className="flow-step-body">
                <strong>{s.title}</strong>
                <span>{s.desc}</span>
              </span>
            </button>
          ))}
        </div>
        <p className="flow-hint reveal">
          <IconBolt className="flow-hint-icon" />
          点击任意步骤查看窗口行为 · 实际由 Hook 事件实时触发
        </p>
      </div>

      <div className="auto-cards">
        <div className="auto-card reveal">
          <h4>Stop → 拉回主屏</h4>
          <p>Claude 完成响应或会话结束时，绑定的终端窗口自动移动到主屏并铺满——多实例按会话精确绑定，不串窗。</p>
        </div>
        <div className="auto-card reveal" style={{ '--delay': '0.07s' } as React.CSSProperties}>
          <h4>输入期间绝不搬窗</h4>
          <p>你提交 Prompt、语音输入时窗口保持原地——自动化从不与你的手抢窗口，聚焦多久由你决定。</p>
        </div>
        <div className="auto-card reveal" style={{ '--delay': '0.14s' } as React.CSSProperties}>
          <h4>本地与远程同款</h4>
          <p>SSH 到局域网机器跑的 Claude Code / Codex 会话同样生效，转发器自动把 Hook 事件送回本机。</p>
        </div>
      </div>
    </section>
  );
}

function DemoVideo({ src }: { src: string }) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const playing = useInViewportPlay(videoRef);
  return (
    <MonitorFrame isActive={playing} brand="Vibe Focus">
      <video
        ref={videoRef}
        className="demo-video"
        src={src}
        muted
        loop
        playsInline
        preload="metadata"
      />
    </MonitorFrame>
  );
}

function Demos() {
  return (
    <section className="section section-alt" id="demo">
      <div className="section-head reveal">
        <span className="section-kicker">演示</span>
        <h2 className="section-title">实际运行效果</h2>
        <p className="section-lead">聚焦、恢复与权限诊断的真实录屏，进入视口自动播放。</p>
      </div>
      <div className="demo-grid">
        <div className="demo-card reveal">
          <div className="demo-media">
            <img src="/vibe-focus/demos/focus-to-main-display.gif" alt="一键拉回主屏并铺满" loading="lazy" />
          </div>
          <h3>一键拉回主屏并铺满</h3>
          <p>从副屏窗口到主屏聚焦态，一次按键完成。</p>
        </div>
        <div className="demo-card reveal" style={{ '--delay': '0.07s' } as React.CSSProperties}>
          <div className="demo-media">
            <DemoVideo src="/vibe-focus/demos/restore-original-layout.mp4" />
          </div>
          <h3>再次触发，恢复原布局</h3>
          <p>窗口回到原位置与尺寸，桌面回到你摆好的样子。</p>
        </div>
        <div className="demo-card reveal" style={{ '--delay': '0.14s' } as React.CSSProperties}>
          <div className="demo-media">
            <DemoVideo src="/vibe-focus/demos/permissions-diagnostics.mp4" />
          </div>
          <h3>权限与状态诊断</h3>
          <p>辅助功能授权、登录项、快捷键状态一站检查。</p>
        </div>
      </div>
    </section>
  );
}

function Download() {
  return (
    <section className="section" id="download">
      <div className="section-head reveal">
        <span className="section-kicker">下载</span>
        <h2 className="section-title">一分钟装好，马上少扭头</h2>
        <p className="section-lead">免费开源，从 GitHub Releases 下载最新构建，或用源码一行命令安装。</p>
      </div>
      <div className="download-card reveal">
        <div className="download-main">
          <div className="download-version">
            <span className="download-version-pill">
              <IconApple className="download-apple" />
              v{LATEST_VERSION} · Apple Silicon
            </span>
            <span className="download-version-note">菜单栏常驻 · 安装即用</span>
          </div>
          <div className="download-actions">
            <a className="btn btn-primary btn-lg" href={RELEASES_URL} target="_blank" rel="noopener noreferrer">
              <IconDownload className="btn-icon" />
              从 GitHub Releases 下载
            </a>
            <a className="btn btn-ghost" href={`${REPO_URL}#readme`} target="_blank" rel="noopener noreferrer">
              安装文档
            </a>
          </div>
        </div>
        <div className="download-steps">
          <div className="download-step">
            <span className="download-step-num">1</span>
            <div>
              <strong>下载解压</strong>
              <span>从 Releases 下载 <code>VibeFocus-{LATEST_VERSION}-macos.zip</code> 并解压。</span>
            </div>
          </div>
          <div className="download-step">
            <span className="download-step-num">2</span>
            <div>
              <strong>拖入「应用程序」</strong>
              <span>首次启动若被 Gatekeeper 拦截，右键 → 打开 一次即可。</span>
            </div>
          </div>
          <div className="download-step">
            <span className="download-step-num">3</span>
            <div>
              <strong>授予辅助功能权限</strong>
              <span>设置 → 隐私与安全性 → 辅助功能，勾选 VibeFocus；遇到异常用设置页 Doctor 一键诊断。</span>
            </div>
          </div>
        </div>
        <div className="download-source">
          <span>偏好源码安装？</span>
          <code>git clone {REPO_URL}.git &amp;&amp; cd vibe-focus &amp;&amp; ./install.sh</code>
        </div>
      </div>
    </section>
  );
}

function Faq() {
  return (
    <section className="section section-alt" id="faq">
      <div className="section-head reveal">
        <span className="section-kicker">FAQ</span>
        <h2 className="section-title">常见问题</h2>
      </div>
      <div className="faq-list reveal">
        {faqs.map((f) => (
          <details key={f.q} className="faq-item">
            <summary>
              {f.q}
              <span className="faq-chevron" aria-hidden="true" />
            </summary>
            <p>{f.a}</p>
          </details>
        ))}
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer className="footer">
      <div className="footer-inner">
        <div className="footer-brand">
          <img src={`${BASE}logo.svg`} alt="Vibe Focus" className="footer-logo" />
          <div>
            <strong>Vibe Focus</strong>
            <span>为多显示器 Vibe Coding 而生的窗口自动驾驶系统</span>
          </div>
        </div>
        <nav className="footer-links">
          <a href="#features">功能</a>
          <a href="#automation">自动化</a>
          <a href="#demo">演示</a>
          <a href="#download">下载</a>
          <a href={REPO_URL} target="_blank" rel="noopener noreferrer">GitHub</a>
        </nav>
        <span className="footer-copy">© 2024-2026 Vibe Focus · Open Source</span>
      </div>
    </footer>
  );
}

export default function App() {
  useRevealObserver();
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <Pains />
        <Features />
        <Automation />
        <Demos />
        <Download />
        <Faq />
      </main>
      <Footer />
    </>
  );
}
