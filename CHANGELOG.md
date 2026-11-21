# Changelog

All notable changes to VibeFocus will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Window switching is now **animation-free** — yabai's `window_animation_duration` is
  forced to `0.0` while VibeFocus runs (`Sources/Support/YabaiAnimationGuard.swift`)
  - yabai has no per-command bypass: `--move` / `--resize` always call
    `window_manager_animate_window`, whose only switch is the global
    `window_animation_duration` config (`message.c` hard-codes `animate: true`). Asserted
    once at launch (previous value logged) and re-asserted, throttled to 30s, before any
    `--move` / `--resize` send in the single yabai choke point
    (`SpaceController.runYabai`) — so a `yabairc` reload cannot bring the animation back.
  - The app never restores the user's value: the whole point is that a focus-switching
    tool should jump, not glide.

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
