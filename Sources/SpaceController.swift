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

    private var lastCheckAt: Date?
    private var cachedYabaiPath: String?
    private let checkInterval: TimeInterval = 5

    private init() {}

    var isEnabled: Bool {
        SpacePreferences.integrationEnabled && availability == .available
    }

    func refreshAvailabilityIfNeeded() {
        refreshAvailability(force: false)
    }

    func refreshAvailability(force: Bool) {
        if !force, let lastCheckAt, Date().timeIntervalSince(lastCheckAt) < checkInterval {
            return
        }

        lastCheckAt = Date()
        lastErrorMessage = nil

        guard let yabaiPath = locateYabai() else {
            availability = .notInstalled
            return
        }

        cachedYabaiPath = yabaiPath

        guard let result = runYabai(arguments: ["-m", "query", "--spaces"]) else {
            availability = .unavailable
            lastErrorMessage = "Unable to launch yabai"
            return
        }

        if result.exitCode == 0 {
            availability = .available
            lastErrorMessage = nil
        } else {
            availability = .unavailable
            lastErrorMessage = formatErrorMessage(stdout: result.stdout, stderr: result.stderr)
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
        return false
    }

    private func locateYabai() -> String? {
        if let cachedYabaiPath, !cachedYabaiPath.isEmpty {
            return cachedYabaiPath
        }

        guard let result = runProcess(executable: "/usr/bin/which", arguments: ["yabai"]),
              result.exitCode == 0 else {
            return nil
        }

        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return nil
        }
        return path
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
