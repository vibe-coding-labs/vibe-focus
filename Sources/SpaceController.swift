import Combine
import Foundation

enum SpaceAvailability: String {
    case unknown
    case notInstalled
    case unavailable
    case available
}

enum SpaceRestoreStrategy: String, CaseIterable {
    case switchToOriginal
    case pullToCurrent
}

struct SpacePreferences {
    static let integrationEnabledKey = "spaceIntegrationEnabled"
    static let restoreStrategyKey = "spaceRestoreStrategy"

    static var integrationEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: integrationEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: integrationEnabledKey)
        }
    }

    static var restoreStrategy: SpaceRestoreStrategy {
        get {
            let raw = UserDefaults.standard.string(forKey: restoreStrategyKey) ?? SpaceRestoreStrategy.switchToOriginal.rawValue
            return SpaceRestoreStrategy(rawValue: raw) ?? .switchToOriginal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: restoreStrategyKey)
        }
    }
}

struct SpaceContext {
    let sourceSpaceIndex: Int?
    let targetSpaceIndex: Int?
}

@MainActor
final class SpaceController: ObservableObject {
    static let shared = SpaceController()

    @Published private(set) var availability: SpaceAvailability = .unknown
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isEnabled: Bool = false

    private var lastCheckAt: Date?
    private var cachedYabaiPath: String?
    private let checkInterval: TimeInterval = 5

    private init() {
        // Delay initial check to ensure log function is available
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            NSLog("[SpaceController] Initializing...")
            self?.refreshAvailability(force: true)
        }
    }

    deinit {
        NSLog("[SpaceController] Deinit called")
    }

    private func updateEnabledState() {
        let newValue = SpacePreferences.integrationEnabled && availability == .available
        if isEnabled != newValue {
            isEnabled = newValue
            NSLog("[SpaceController] isEnabled changed to: \(newValue)")
        }
    }

    func refreshAvailabilityIfNeeded() {
        refreshAvailability(force: false)
    }

    func refreshAvailability(force: Bool) {
        log("refreshAvailability called, force=\(force), lastCheckAt=\(String(describing: lastCheckAt))")

        if !force, let lastCheckAt, Date().timeIntervalSince(lastCheckAt) < checkInterval {
            log("Skipping refresh - within check interval")
            return
        }

        lastCheckAt = Date()
        lastErrorMessage = nil

        log("Looking for yabai...")
        guard let yabaiPath = locateYabai() else {
            log("yabai not found - setting availability to .notInstalled")
            availability = .notInstalled
            updateEnabledState()
            return
        }

        log("Found yabai at: \(yabaiPath)")
        cachedYabaiPath = yabaiPath

        log("Running yabai query...")
        guard let result = runYabai(arguments: ["-m", "query", "--spaces"]) else {
            log("Failed to run yabai - setting availability to .unavailable")
            availability = .unavailable
            lastErrorMessage = "Unable to launch yabai"
            updateEnabledState()
            return
        }

        log("yabai query result: exitCode=\(result.exitCode), stdout=\(result.stdout.prefix(100)), stderr=\(result.stderr)")

        if result.exitCode == 0 {
            log("yabai available - setting availability to .available")
            availability = .available
            lastErrorMessage = nil
            updateEnabledState()
        } else {
            log("yabai query failed - setting availability to .unavailable")
            availability = .unavailable
            lastErrorMessage = formatErrorMessage(stdout: result.stdout, stderr: result.stderr)
            updateEnabledState()
        }
    }

    func captureSpaceContext(windowID: UInt32) -> SpaceContext {
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return SpaceContext(sourceSpaceIndex: nil, targetSpaceIndex: nil)
        }

        let currentSpace = currentSpaceIndex()
        let windowSpace = windowSpaceIndex(windowID: windowID)
        return SpaceContext(
            sourceSpaceIndex: windowSpace ?? currentSpace,
            targetSpaceIndex: currentSpace
        )
    }

    func currentSpaceIndex() -> Int? {
        refreshAvailabilityIfNeeded()
        guard isEnabled, let space = queryFocusedSpace() else {
            return nil
        }
        return space.index
    }

    func windowSpaceIndex(windowID: UInt32) -> Int? {
        refreshAvailabilityIfNeeded()
        guard isEnabled, let window = queryWindow(windowID: windowID) else {
            return nil
        }
        return window.space
    }

    @discardableResult
    func moveWindow(_ windowID: UInt32, toSpaceIndex spaceIndex: Int, focus: Bool) -> Bool {
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return false
        }

        var arguments = ["-m", "window", "\(windowID)", "--space", "\(spaceIndex)"]
        if focus {
            arguments.append("--focus")
        }
        guard let result = runYabai(arguments: arguments) else {
            return false
        }
        if result.exitCode == 0 {
            return true
        }
        availability = .unavailable
        lastErrorMessage = formatErrorMessage(stdout: result.stdout, stderr: result.stderr)
        updateEnabledState()
        return false
    }

    @discardableResult
    func focusSpace(_ spaceIndex: Int) -> Bool {
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return false
        }
        guard let result = runYabai(arguments: ["-m", "space", "--focus", "\(spaceIndex)"]) else {
            return false
        }
        if result.exitCode == 0 {
            return true
        }
        availability = .unavailable
        lastErrorMessage = formatErrorMessage(stdout: result.stdout, stderr: result.stderr)
        updateEnabledState()
        return false
    }

    @discardableResult
    func focusWindow(_ windowID: UInt32) -> Bool {
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return false
        }
        guard let result = runYabai(arguments: ["-m", "window", "\(windowID)", "--focus"]) else {
            return false
        }
        if result.exitCode == 0 {
            return true
        }
        availability = .unavailable
        lastErrorMessage = formatErrorMessage(stdout: result.stdout, stderr: result.stderr)
        updateEnabledState()
        return false
    }

    private func locateYabai() -> String? {
        NSLog("[SpaceController] locateYabai called")

        if let cachedYabaiPath, !cachedYabaiPath.isEmpty {
            log("Using cached yabai path: \(cachedYabaiPath)")
            return cachedYabaiPath
        }

        // First, try common installation paths
        let commonPaths = [
            "/opt/homebrew/bin/yabai",
            "/usr/local/bin/yabai",
            "/usr/bin/yabai",
            "/bin/yabai",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/yabai"),
            (NSHomeDirectory() as NSString).appendingPathComponent("bin/yabai"),
            (NSHomeDirectory() as NSString).appendingPathComponent(".nix-profile/bin/yabai")
        ]

        log("Checking common paths: \(commonPaths)")
        for path in commonPaths {
            let exists = FileManager.default.fileExists(atPath: path)
            log("  Path \(path): exists=\(exists)")
            if exists {
                cachedYabaiPath = path
                NSLog("[SpaceController] Found yabai at: \(path)")
                return path
            }
        }

        // Fallback 1: try to find using user's shell environment
        log("Trying to find yabai via user shell...")
        if let shellPath = getYabaiPathFromUserShell() {
            cachedYabaiPath = shellPath
            NSLog("[SpaceController] Found yabai via shell: \(shellPath)")
            return shellPath
        }

        // Fallback 2: try to find using which via bash -l
        log("Trying to find yabai via bash -l...")
        guard let result = runProcess(executable: "/bin/bash", arguments: ["-l", "-c", "which yabai"]),
              result.exitCode == 0 else {
            log("Failed to find yabai via bash -l")
            NSLog("[SpaceController] yabai not found via bash -l")
            return nil
        }

        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            log("which yabai returned empty path")
            NSLog("[SpaceController] which yabai returned empty path")
            return nil
        }
        cachedYabaiPath = path
        NSLog("[SpaceController] Found yabai via which: \(path)")
        return path
    }

    private func getYabaiPathFromUserShell() -> String? {
        // Get user's default shell
        let shellTask = Process()
        shellTask.launchPath = "/usr/bin/env"
        shellTask.arguments = ["bash", "-l", "-c", "echo $SHELL"]

        let shellPipe = Pipe()
        shellTask.standardOutput = shellPipe
        shellTask.standardError = Pipe()

        do {
            try shellTask.run()
            shellTask.waitUntilExit()

            let shellData = shellPipe.fileHandleForReading.readDataToEndOfFile()
            guard let userShell = String(data: shellData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !userShell.isEmpty else {
                return nil
            }

            // Use user's shell to find yabai
            let whichTask = Process()
            whichTask.launchPath = userShell
            whichTask.arguments = ["-l", "-c", "which yabai"]

            let whichPipe = Pipe()
            whichTask.standardOutput = whichPipe
            whichTask.standardError = Pipe()

            try whichTask.run()
            whichTask.waitUntilExit()

            let pathData = whichPipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: pathData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                return path
            }
        } catch {
            log("Failed to get yabai path from user shell: \(error)")
        }

        return nil
    }

    private func queryFocusedSpace() -> YabaiSpaceInfo? {
        guard let result = runYabai(arguments: ["-m", "query", "--spaces", "--space"]),
              result.exitCode == 0 else {
            return nil
        }
        return decodeSingleOrFirst(YabaiSpaceInfo.self, from: result.stdout)
    }

    private func queryWindow(windowID: UInt32) -> YabaiWindowInfo? {
        guard let result = runYabai(arguments: ["-m", "query", "--windows", "--window", "\(windowID)"]),
              result.exitCode == 0 else {
            return nil
        }
        return decodeSingleOrFirst(YabaiWindowInfo.self, from: result.stdout)
    }

    private func runYabai(arguments: [String]) -> ShellResult? {
        guard let yabaiPath = locateYabai() else {
            return nil
        }
        return runProcess(executable: yabaiPath, arguments: arguments)
    }

    private func runProcess(executable: String, arguments: [String]) -> ShellResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            log("Failed to run \(executable): \(error.localizedDescription)")
            return nil
        }

        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        return ShellResult(
            stdout: String(data: output, encoding: .utf8) ?? "",
            stderr: String(data: errorData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private func decodeSingleOrFirst<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        if let single = try? decoder.decode(T.self, from: data) {
            return single
        }
        if let array = try? decoder.decode([T].self, from: data) {
            return array.first
        }
        return nil
    }

    private func formatErrorMessage(stdout: String, stderr: String) -> String {
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStderr.isEmpty {
            return trimmedStderr
        }
        if !trimmedStdout.isEmpty {
            return trimmedStdout
        }
        return "yabai returned empty error output"
    }
}

struct ShellResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct YabaiSpaceInfo: Decodable {
    let id: Int?
    let index: Int?
    let display: Int?
}

struct YabaiWindowInfo: Decodable {
    let id: Int?
    let pid: Int?
    let app: String?
    let title: String?
    let space: Int?
    let display: Int?
}
