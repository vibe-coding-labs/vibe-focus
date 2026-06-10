# Contributing to VibeFocus

Thank you for your interest in contributing to VibeFocus! This guide will help you get started.

## Development Setup

### Prerequisites

- macOS 13.0 (Ventura) or later
- Xcode 15+ with Swift 5.9+
- [yabai](https://github.com/koekeishiya/yabai) (optional, for Space management features)

### Build & Run

```bash
# Build
swift build

# Run tests
swift test

# Run the app
./run.sh
```

### Install to ~/Applications

```bash
./install.sh
```

See [README.md](README.md) for full installation instructions including code signing setup.

## Project Structure

```
Sources/
├── Hook/           — Claude Code hook integration (server, events, bindings)
├── Overlay/        — Screen index overlay (always-on-top window labeling)
├── Settings/       — SwiftUI settings UI
├── Space/          — macOS Space management via yabai
├── Support/        — Shared utilities (logging, persistence, crash recording)
├── TitleEditor/    — Terminal window title editor
├── Window/         — Window management (finding, moving, toggling, state)
└── AppEntry.swift  — Application entry point
Tests/
├── Standalone/     — Pure logic tests (no macOS framework dependencies)
└── XCTest/         — Integration and mock-based tests
```

## Code Conventions

### File Organization

- **One responsibility per file.** Split large types using Swift `extension` across multiple files.
- Files >300 lines should be considered for extraction.
- Use `+` naming for extension files: `TypeName+Responsibility.swift`.

### Swift Style

- Access control: prefer `internal` over `private` for testability when needed.
- No force unwraps (`!`) except in test code.
- Use `///` documentation comments on all public and important internal APIs.
- Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/).

### Commits

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(scope): add new feature
fix(scope): fix a bug
refactor(scope): restructure code without behavior change
test(scope): add or update tests
docs: update documentation
```

### Testing

- All changes must pass the full test suite: `swift test`
- New features should include corresponding tests
- Pure logic should be extracted to static functions for testability

## Pull Request Process

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes with clear commit messages
4. Ensure `swift build` and `swift test` pass
5. Open a pull request with a description of the changes

## Reporting Issues

- Use GitHub Issues for bug reports and feature requests
- Include macOS version, VibeFocus version, and steps to reproduce
- Check existing issues before opening a new one

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
