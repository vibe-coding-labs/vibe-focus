import AppKit
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
            PreferencesSync.persistToDisk()
        }
    }

    static var restoreStrategy: SpaceRestoreStrategy {
        get {
            let raw = UserDefaults.standard.string(forKey: restoreStrategyKey) ?? SpaceRestoreStrategy.switchToOriginal.rawValue
            return SpaceRestoreStrategy(rawValue: raw) ?? .switchToOriginal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: restoreStrategyKey)
            PreferencesSync.persistToDisk()
        }
    }
}

struct SpaceContext {
    let sourceSpaceIndex: Int?
    let targetSpaceIndex: Int?
    let sourceDisplayIndex: Int?
    let sourceDisplaySpaceIndex: Int?
}

@MainActor
final class SpaceController: ObservableObject {
    static let shared = SpaceController()

    @Published var availability: SpaceAvailability = .unknown
    @Published var lastErrorMessage: String?
    @Published private(set) var isEnabled: Bool = false
    @Published var canControlSpaces: Bool = false

    private var lastCheckAt: Date?
    var cachedYabaiPath: String?
    var didAttemptScriptingAdditionRecovery = false
    var scriptingAdditionRecoverySucceeded = false
    private let checkInterval: TimeInterval = 20

    private init() {
        // Delay initial check to ensure log function is available
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            log("[SpaceController] Initializing...")
            self?.refreshAvailability(force: true)
        }
    }

    deinit {
        log("[SpaceController] Deinit called")
    }

    func updateEnabledState() {
        let newValue = SpacePreferences.integrationEnabled && availability == .available
        if isEnabled != newValue {
            isEnabled = newValue
            log("[SpaceController] isEnabled changed", fields: ["newValue": String(newValue)])
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
            canControlSpaces = false
            updateEnabledState()
            return
        }

        log("Found yabai at: \(yabaiPath)")
        cachedYabaiPath = yabaiPath

        log("Running yabai query...")
        guard let result = runYabai(arguments: ["-m", "query", "--spaces"]) else {
            log("Failed to run yabai - setting availability to .unavailable")
            availability = .unavailable
            canControlSpaces = false
            lastErrorMessage = "Unable to launch yabai"
            updateEnabledState()
            return
        }

        log("yabai query result: exitCode=\(result.exitCode), stdout=\(result.stdout.prefix(100)), stderr=\(result.stderr)")

        if result.exitCode == 0 {
            log("yabai available - checking scripting-addition status")
            availability = .available
            // yabai 恢复可用，重置 focusSpaceKnownBroken 标记
            WindowManager.shared.focusSpaceKnownBroken = false
            // yabai query --spaces 不需要 scripting-addition，但窗口操作需要
            // 检测 SA 是否已加载：尝试一个需要 SA 的操作
            let saLoaded = checkScriptingAdditionLoaded(yabaiPath: yabaiPath)
            if saLoaded {
                canControlSpaces = true
                lastErrorMessage = nil
                log("yabai available with scripting-addition loaded")
            } else {
                canControlSpaces = false
                lastErrorMessage = "yabai scripting-addition 未加载，跨工作区恢复功能受限。请在设置中加载 scripting-addition。"
                log("yabai available but scripting-addition NOT loaded - auto-attempting recovery")
                // 自动尝试无密码方式加载（不弹管理员权限窗口）
                attemptSilentSARecovery(yabaiPath: yabaiPath)
            }
            updateEnabledState()
        } else {
            log("yabai query failed - setting availability to .unavailable")
            availability = .unavailable
            canControlSpaces = false
            lastErrorMessage = formatErrorMessage(stdout: result.stdout, stderr: result.stderr)
            updateEnabledState()
        }
    }


    func isScriptingAdditionError(_ result: ShellResult) -> Bool {
        let text = "\(result.stdout)\n\(result.stderr)".lowercased()
        return text.contains("scripting-addition")
    }

    func runYabai(
        arguments: [String],
        operation: String? = nil,
        operationID: String? = nil,
        logSuccess: Bool = false
    ) -> ShellResult? {
        let op = operationID ?? "none"
        guard let yabaiPath = locateYabai() else {
            log(
                "[SpaceController] yabai command skipped: executable not found",
                level: .error,
                fields: [
                    "op": op,
                    "operation": operation ?? "unknown",
                    "args": arguments.joined(separator: " ")
                ]
            )
            return nil
        }
        let startedAt = Date()
        guard let result = runProcess(executable: yabaiPath, arguments: arguments) else {
            log(
                "[SpaceController] failed to launch yabai command",
                level: .error,
                fields: [
                    "op": op,
                    "operation": operation ?? "unknown",
                    "args": arguments.joined(separator: " ")
                ]
            )
            return nil
        }

        let durationMs = elapsedMilliseconds(since: startedAt)
        let isSlow = durationMs >= 180

        if result.exitCode != 0 || logSuccess || isSlow {
            let stderr = truncateForLog(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), limit: 220)
            let stdout = truncateForLog(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), limit: 220)
            let level: LogLevel = result.exitCode == 0 ? (isSlow ? .warn : .info) : .warn
            log(
                isSlow && result.exitCode == 0 ? "[SpaceController] yabai command slow" : "[SpaceController] yabai command result",
                level: level,
                fields: [
                    "op": op,
                    "operation": operation ?? "unknown",
                    "exitCode": String(result.exitCode),
                    "durationMs": String(durationMs),
                    "args": arguments.joined(separator: " "),
                    "stderr": stderr.isEmpty ? "-" : stderr,
                    "stdout": stdout.isEmpty ? "-" : stdout
                ]
            )
        }

        return result
    }

    func runYabaiVariants(
        variants: [[String]],
        operation: String,
        operationID: String? = nil
    ) -> (success: Bool, failure: ShellResult?) {
        let op = operationID ?? "none"
        var lastFailure: ShellResult?
        var recoveredOnce = false

        for arguments in variants {
            while true {
                guard let result = runYabai(
                    arguments: arguments,
                    operation: operation,
                    operationID: op,
                    logSuccess: true
                ) else {
                    log(
                        "[SpaceController] operation failed to launch",
                        level: .error,
                        fields: [
                            "op": op,
                            "operation": operation,
                            "args": arguments.joined(separator: " ")
                        ]
                    )
                    break
                }

                if result.exitCode == 0 {
                    return (true, nil)
                }

                lastFailure = result
                let stderr = truncateForLog(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), limit: 220)
                let stdout = truncateForLog(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), limit: 220)
                log(
                    "[SpaceController] operation failed",
                    level: .warn,
                    fields: [
                        "op": op,
                        "operation": operation,
                        "exitCode": String(result.exitCode),
                        "args": arguments.joined(separator: " "),
                        "stderr": stderr.isEmpty ? "-" : stderr,
                        "stdout": stdout.isEmpty ? "-" : stdout
                    ]
                )

                if !recoveredOnce, isScriptingAdditionError(result), attemptScriptingAdditionRecovery(trigger: operation, operationID: op) {
                    recoveredOnce = true
                    log(
                        "[SpaceController] retrying after scripting-addition recovery",
                        fields: [
                            "op": op,
                            "operation": operation
                        ]
                    )
                    continue
                }

                break
            }
        }

        return (false, lastFailure)
    }



    func markOperationError(from result: ShellResult?, fallback: String, operationID: String? = nil) {
        let op = operationID ?? "none"
        if let result {
            if isScriptingAdditionError(result) {
                lastErrorMessage = "yabai scripting-addition 不可用，跨工作区恢复功能受限。请在设置中加载 scripting-addition。"
                canControlSpaces = false
            } else {
                lastErrorMessage = formatErrorMessage(stdout: result.stdout, stderr: result.stderr)
            }
        } else {
            lastErrorMessage = fallback
        }
        log(
            "[SpaceController] operation error",
            level: .error,
            fields: [
                "op": op,
                "fallback": fallback,
                "lastError": lastErrorMessage ?? "nil"
            ]
        )
    }

    func markOperationError(_ message: String, operationID: String? = nil) {
        let op = operationID ?? "none"
        lastErrorMessage = message
        log(
            "[SpaceController] operation error",
            level: .error,
            fields: [
                "op": op,
                "message": message
            ]
        )
    }

    func runProcess(executable: String, arguments: [String]) -> ShellResult? {
        return ShellRunner.run(executable: executable, arguments: arguments)
    }

    func decodeSingleOrFirst<T: Decodable>(_ type: T.Type, from text: String) -> T? {
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

    func decodeArray<T: Decodable>(_ type: T.Type, from text: String) -> [T]? {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([T].self, from: data) {
            return array
        }
        return nil
    }


    func formatErrorMessage(stdout: String, stderr: String) -> String {
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

typealias ShellResult = YabaiClient.YabaiResult

struct YabaiSpaceInfo: Decodable {
    let id: Int?
    let index: Int?
    let display: Int?
    let isVisible: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case index
        case display
        case isVisible = "is-visible"
    }
}

struct YabaiWindowInfo: Decodable {
    let id: Int?
    let pid: Int?
    let app: String?
    let title: String?
    let space: Int?
    let display: Int?
    let frame: Frame?
    let isFloatingRaw: Bool?

    enum CodingKeys: String, CodingKey {
        case id, pid, app, title, space, display, frame
        case isFloatingRaw = "is-floating"
    }

    var isFloating: Bool { isFloatingRaw == true }

    struct Frame: Decodable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: w, height: h)
        }
    }
}

struct YabaiDisplayInfo: Decodable {
    let index: Int?
    let frame: Frame?

    struct Frame: Decodable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }
}
