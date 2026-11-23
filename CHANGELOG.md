# Changelog

All notable changes to VibeFocus will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Window switching is now **animation-free** — yabai's `window_animation_duration` is
  forced to `0.0` while VibeFocus runs (`Sources/Support/YabaiAnimationGuard.swift`)
  - yabai has no per-command bypass: the global `window_animation_duration` config is the
    only switch for `window_manager_animate_window` — and that function is reached from far
    more than the two frame primitives: `--move`/`--resize` (window_manager.c:342/359/403),
    the layout re-flow after `--toggle float` (`window_node_flush` → view.c:378, which is
    the **first** step of every toggle — that's the "window slides by itself" the user
    sees), `--toggle windowed-fullscreen` / `--zoom-fullscreen` (:2394/2399), and any
    command that re-flows a view.
  - `YabaiAnimationConfig.requiresAnimationOff(arguments:)` now gates on "is this a write"
    rather than "does it contain --move/--resize", so every write command is covered
    (reads — `query`, `config <key>` without a value, `signal`, bare `space`/`window`
    selectors, `--load-sa` — are skipped; unknown domains default to protected).
  - Asserted at launch (previous value logged) and re-asserted **before every** write in
    the single yabai choke point (`SpaceController.runYabai`), throttled to 30s. Frame
    writes (`--move` / `--resize` / `--toggle float` / `--zoom-fullscreen`) additionally
    re-assert **unconditionally after** the command returns, because those are the events
    users hook `yabai -m config --load-sa` onto — the moment the switch would come back.
  - The app never restores the user's value: the whole point is that a focus-switching
    tool should jump, not glide.

- All decorative UI animation removed — VibeFocus is an efficiency tool, not a showcase
  - Settings tab bar no longer slides its selection pill (`.matchedGeometryEffect` +
    `.spring` removed); hover effects on buttons, minimap tiles and the copy chip are now
    instant instead of 100–150ms ease-outs; the copy-success icon swap is no longer
    animated.
  - The space-index overlay disables CoreAnimation implicit actions
    (`CATransaction.setDisableActions(true)`) around its layer/window writes — a space
    switch that changed the "3-1" → "3-2" label used to fade/scale over ~0.25s because
    CALayer applies implicit animations to `frame`/`backgroundColor` writes.

- Window moves are now **atomic** (single yabai message) — fixes the "multi-step,
  move-then-grow" animation and the visible pause between segments
  - `window --move` and `window --resize` are sent in one `yabai -m` invocation
    (`Sources/Support/WindowFrameCommand.swift`). yabai runs chained commands from one
    message, so there is a single fork, no inter-segment polling, and no second
    independent animation.
  - Root cause: yabai animates **each** write primitive separately when
    `window_animation_duration` is set (`window_manager_animate_window` is called by both
    `window_manager_move_window_relative` and `window_manager_resize_window_relative`).
    Splitting them into two commands therefore produced two sequential proxy animations
    separated by a `waitForPhase` poll (up to 300ms).
  - `FrameWriteExecutor` gains an optional `applyCombined` path: when present, phase 1 is
    one write of the full frame with no inter-segment wait; retries that need both
    dimensions also go out combined. The two-segment path is unchanged when it is absent
    (AX direct-write channel), and `YabaiMoveEnvironment.useCombinedWrite` can force it
    for regression tests.
  - Same treatment applied to the two other raw move+resize pairs: session-restore
    delivery (`SessionRestoreExecutor`) and terminal-grid space delivery
    (`TerminalGridController+SpaceDelivery`).

### Fixed

- Frame writes: back to the one shape that holds up on real hardware
  - **Cross-display moves never go through a bare AX position write.** WindowServer clamps
    such writes back to the source display, so the attempt fails, the executor falls back to
    a yabai move, and the window visibly moves **twice** — reported on-device as "bouncing
    back and forth." The AX position channel has been removed entirely; position always goes
    through yabai (the only channel validated for cross-display), size through AX.
  - **Enlargements keep the historical `move → resize` order.** An earlier attempt tried the
    terminal size first ("clamp is observable, so we can retry") — on-device that meant the
    window grew *once on the source display* (clamped to 1055), then moved, then grew again.
    Observability guarantees the final value, not the absence of intermediate visible states.
  - **Two steps for cross-display + resize is a physical limit, not a defect.** Three
    constraints are mutually exclusive: yabai's `--move` rewrites size from its in-process
    frame cache; iTerm2 snaps to its character grid when position and size change together
    (640 → 664); and a bare AX cross-display position write is clamped back. Size must go
    first and through AX; position can only go through yabai.
  - Earlier attempts at "one step" (single combined yabai message, all-AX position, trying
    the terminal size first, AX resize without read-back) each traded one property for
    another and were reverted after on-device regressions. All that machinery is removed
    rather than left dormant, so nobody re-adopts it by accident.
  - `docs/performance-triage-runbook.md` gains a "why is switching slow / why two steps"
    section splitting the problem into two orthogonal axes — **visible animation** (yabai
    writes size→position→size from its frame cache) and **total duration** (6 yabai forks
    per restore, no longer on the main thread since B191). Mixing them up is what made
    earlier investigations chase the wrong layer.

- （已撤回）曾有一版让位置也走 AX 直接写，号称「跨屏单步」。真机实测该通道被
  WindowServer 钳回源屏、降级后又挪一次 —— 用户看到「来回跳来跳去」。已整体移除，
  详见上方「Frame writes: back to the one shape that holds up on real hardware」。

- Restoring a window to its original frame now lands on the **exact** size — an iTerm2
  window asked to restore to `640×525` no longer comes back `664×525` (24px wide)
  - Root cause: the atomic combined write (above) handed the *size* to yabai. With
    `window_animation_duration = 0`, both `--move` and `--resize` end up in
    `window_manager_set_window_frame()`, which writes `size → position → size` and takes
    the size from yabai's **in-process** window-frame cache. For windows that snap to a
    character grid (iTerm2, ~8px per column) that sequence settles on the snapped value.
    The app writing `kAXSizeAttribute` once gets the exact 640 — same window, same target,
    only the channel differs (`e16de7b` correct, `5e0b288` onward wrong).
  - Fix: `FramePhase1Plan` (new, in `Sources/Support/FrameWriteExecutor.swift`) decides
    phase 1 by channel: **AX size writable → AX resize + yabai move back to back**; AX
    unavailable or proven to swallow writes → yabai combined message (kept, it is still
    the cheapest channel when size has to go through yabai); combined explicitly disabled
    → the historical two-segment path. Size *retries* follow the same rule, so a snapped
    window no longer spins on yabai `--resize` returning 664 forever (`frameOK=false`).
  - The `--move` half can still rewrite the cached width, so after the move the executor
    reads the frame back once (CGWindowList, no fork) and re-issues the AX size write
    **immediately** if it was overwritten — still a single visual jump.
- Window switching is now a **single** visual step — the 300ms stall between "move" and
  "grow" is gone
  - The old AX path polled `waitForPhase` between the resize and the move (25ms tick,
    300ms budget) and measured 300–378ms on restores. The AX write primitive already
    verifies its own result (`resizeViaAX` → `writeSizeWithReadback`), so the poll was
    pure latency once yabai animations were forced to 0.
  - Now the two writes are back to back with only a fixed 25ms beat
    (`WindowSettle.axPhaseSettleMs`) between them to let yabai's frame cache catch up.
    The enlarge order (`move → resize`) still waits for the window to land on the target
    display before writing the AX size — but on a 150ms budget
    (`WindowSettle.axMoveThenResizeWaitBudgetMs`, early-exit), half the old 300ms, which
    preserves the source-screen clamp protection.

- Settings window visual overhaul — unified design system introduced in
  `Sources/Settings/DesignSystem.swift` and applied across all five tabs
  - Brand indigo accent (light/dark adaptive) injected via root `.tint`, replacing
    the mix of system blue and ad-hoc colors
  - Segmented tab bar with sliding selection thumb
  - Section icon chips on every settings card; hairline borders + soft shadows
  - Unified info banners replacing per-section yellow/orange boxes
  - Gradient primary buttons for each tab's core action
  - Screen minimap redrawn as a dot-grid canvas with elevated screen tiles
  - Consistent status colors (success/warning/danger/neutral) and radii tokens

- Major codebase refactoring for maintainability and open-source readiness
  - Split 12 large files (>300 lines) into focused single-responsibility modules
  - Extracted pure decision logic for testability (decideRestore, decideWindowMove, decideWindowResolution)
  - Centralized constants to `VibeFocusConstants.swift`
  - Eliminated all force unwrap patterns in production code
  - Added allowlist validation for AppleScript string interpolation (security hardening)
- Fixed 2 pre-existing test failures in `decideRestoreEligibility`
- All 992 tests now pass with zero failures

### Added

- `CONTRIBUTING.md` — contribution guidelines
- `CHANGELOG.md` — this file
- `docs/superpowers/plans/` — refactoring plan documents

### Security

- Added UUID format validation for iTerm2 session ID interpolation
- Added TTY path allowlist validation for Terminal.app AppleScript interpolation

## [0.1.0] - 2026-03-25

### Added

- One-key window focus: move current window to main screen and maximize
- One-key window restore: return window to original position and size
- Menu bar resident app — no dock icon, no main window
- Customizable global hotkey (default: Ctrl+M)
- Claude Code Hooks integration (SessionStart/SessionEnd auto-binding)
- Multi-display support with Space management via yabai
- Terminal context matching (TTY, PID, iTerm2 session ID)
- LAN hook support for remote machine bindings
- Screen index overlay for window identification
- Login item auto-start support
- Accessibility permission diagnostics
- Sound effects for completion events
- Window state persistence across app restarts
