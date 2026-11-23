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

- Window switching is now verifiably single-step, and the log says so
  - The all-AX path no longer sleeps 25ms between the resize and the move. That beat was
    copied from the `axPrecise` arm, where it is genuinely needed (the move goes through
    yabai, whose in-process frame cache must catch up). In the all-AX arm the move is also
    an AX write — nothing reads yabai's cache — so the two writes now go back to back.
  - `segment timing` gains `phase1WriteSteps`: **1** means the user saw a single jump,
    **2** means it fell back to two (an AX position write that the system clamped, which
    also logs a warning). The plan field says what *should* happen; this field says what
    *did*. Runner locks both arms (L3″ = 1, L7′ = 2 on fallback) so the honesty cannot
    regress.
  - `docs/performance-triage-runbook.md` gains a "why is switching slow / why two steps"
    section splitting the problem into two orthogonal axes — **visible animation** (yabai
    writes size→position→size from its frame cache; fix = keep position out of yabai) and
    **total duration** (6 yabai forks per restore, no longer on the main thread since
    B191). Mixing them up is what made earlier investigations chase the wrong layer.

- Window switching between displays is now a **single** visual step in **both directions**
  - Moving a window to the main screen (secondary → main, enlarge) and restoring it
    (main → secondary, shrink) used to be two writes even after the precision fix: the
    yabai `--move` half rewrites the size from its **in-process frame cache**
    (`window_manager.c:342` → `set_window_frame` writes size → position → size), so an
    exact size had to be re-applied afterwards — i.e. "shrink, then jump" was still two
    visible states.
  - New `.axFull` phase-1 plan (`Sources/Support/FrameWriteExecutor.swift`): when the
    window's `AXPosition` is settable too, **both** position and size are written through
    AX directly — two AX calls back to back (~30ms each), no yabai fork, no intermediate
    visible state.
  - Not gambling on hardware: every AX position write is read back; if the origin did not
    land (WindowServer clamp / swallowed write) the executor falls back to the yabai move
    **immediately**, marks the position channel unreliable (never retried), and re-applies
    the AX size the yabai move just overwrote.
  - Write order is unchanged (`resize→move` when shrinking/restoring, `move→resize` when
    enlarging) because WindowServer's per-write visible-area constraint still applies; the
    enlarge order keeps a landing check (150ms budget, first-read fast path) so the AX size
    write cannot be clamped by the source display (1079→1055 regression).
  - Why a bare AX cross-display position write is safe here: the historical "AX position
    gets clamped" lesson was about **tiled** windows fighting yabai's re-tile. Every call
    site (restore / move_to_main / stuck) floats the window first; the AX-direct channel's
    on-device probe (2026-09-29) measured 39ms landing for a floating window across
    displays with no clamp.

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
