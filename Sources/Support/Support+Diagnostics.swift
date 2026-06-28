import AppKit
import ApplicationServices.HIServices
import Foundation

// 诊断日志（尽量详细）
func logDiagnostics(_ context: String) {
    // P-INST-62: logDiagnostics 总耗时（bundle/process/AX 信息收集 + logCodesign fork + logSigningCertificates fork；诊断路径，启动 + 手动触发；归因诊断 fork 累积）。
    let diagStart = Date()
    defer {
        log("[Diagnostics] logDiagnostics finished", level: .debug, fields: [
            "context": context,
            "durationMs": String(elapsedMilliseconds(since: diagStart))
        ])
    }
    let bundle = Bundle.main
    let bundleID = bundle.bundleIdentifier ?? "nil"
    let bundlePath = bundle.bundleURL.path
    let execPath = bundle.executableURL?.path ?? "nil"
    let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "nil"
    let build = (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "nil"
    let lsui = (bundle.infoDictionary?["LSUIElement"] as? Bool) ?? false

    let processInfo = ProcessInfo.processInfo
    let pid = processInfo.processIdentifier
    let uid = getuid()
    let euid = geteuid()
    let ppid = getppid()
    let os = processInfo.operatingSystemVersionString

    let axOptions = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
    let axTrusted = AXIsProcessTrustedWithOptions(axOptions)

    let currentApp = NSRunningApplication.current
    let currentAppName = currentApp.localizedName ?? "nil"
    let currentBundleID = currentApp.bundleIdentifier ?? "nil"
    let currentBundleURL = currentApp.bundleURL?.path ?? "nil"

    let frontApp = NSWorkspace.shared.frontmostApplication
    let frontName = frontApp?.localizedName ?? "nil"
    let frontPID = frontApp?.processIdentifier ?? 0
    let frontBundleID = frontApp?.bundleIdentifier ?? "nil"
    let frontBundleURL = frontApp?.bundleURL?.path ?? "nil"

    log("=== DIAGNOSTICS (\(context)) ===")
    log("Process pid=\(pid) ppid=\(ppid) uid=\(uid) euid=\(euid) os=\(os)")
    log("Bundle id=\(bundleID) version=\(version) build=\(build) lsui=\(lsui)")
    log("Bundle path=\(bundlePath)")
    log("Executable path=\(execPath)")
    log("Current app name=\(currentAppName) bundleID=\(currentBundleID)")
    log("Current app bundleURL=\(currentBundleURL)")
    log("Frontmost app name=\(frontName) pid=\(frontPID) bundleID=\(frontBundleID)")
    log("Frontmost app bundleURL=\(frontBundleURL)")
    log("AX trusted (prompt=false)=\(axTrusted)")

    if execPath != "nil" {
        logCodesign(targetPath: execPath, label: "Executable codesign")
    }
    logCodesign(targetPath: bundlePath, label: "Bundle codesign")
    logSigningCertificates()
    log("=== END DIAGNOSTICS ===")
}

private func logCodesign(targetPath: String, label: String) {
    guard let result = runProcessForDiagnostics(executable: "/usr/bin/codesign", arguments: ["-dv", "--verbose=4", targetPath]) else {
        log("\(label): unable to run codesign")
        return
    }

    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if !stdout.isEmpty {
        log("\(label) stdout: \(stdout)")
    }
    if !stderr.isEmpty {
        log("\(label) stderr: \(stderr)")
    }
    log("\(label) exit=\(result.exitCode)")
}

func runProcessForDiagnostics(executable: String, arguments: [String]) -> (stdout: String, stderr: String, exitCode: Int32)? {
    // P-INST-196: 诊断进程执行耗时（委托 ShellRunner.run fork P-INST-49；findAppBundlePaths mdfind / logSigningCertificates security 等诊断路径调用，≥50ms warn 归因调用点）。
    let rpdStart = Date()
    guard let result = ShellRunner.run(executable: executable, arguments: arguments) else { return nil }
    let durMs = elapsedMilliseconds(since: rpdStart)
    if durMs >= 50 { log("[Diagnostics] runProcessForDiagnostics slow", level: .warn, fields: ["executable": executable, "durationMs": String(durMs)]) }
    return (stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
}

func findAppBundlePaths(bundleIdentifier: String) -> [String] {
    let query = "kMDItemCFBundleIdentifier == \"\(bundleIdentifier)\""
    guard let result = runProcessForDiagnostics(executable: "/usr/bin/mdfind", arguments: [query]),
          result.exitCode == 0 else {
        return []
    }

    let paths = result.stdout
        .split(separator: "\n")
        .map { String($0) }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    return Array(Set(paths)).sorted()
}

private func logSigningCertificates() {
    guard let result = runProcessForDiagnostics(
        executable: "/usr/bin/security",
        arguments: ["find-certificate", "-a", "-c", "VibeFocus Local Code Signing", "-Z"]
    ) else {
        log("Signing certs: unable to run security")
        return
    }

    let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if !stdout.isEmpty {
        log("Signing certs stdout: \(stdout)")
    }
    if !stderr.isEmpty {
        log("Signing certs stderr: \(stderr)")
    }
    log("Signing certs exit=\(result.exitCode)")
}
