import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerDiagnosticPathTests.swift — 诊断文件路径角色隔离 + 全局常量直测。
// 覆盖：进程名派生规则（主应用规范路径/空名回落/其它进程加后缀）、本进程 fatal 与
// snapshot 路径与派生规则同源、VFConstants 关键域（端口/权限/保留期/路径/上限）。

extension RunnerHarness {
    func runDiagnosticPathTests() {
        // MARK: A. 进程名派生（/tmp 全局文件跨二进制污染治理）
        check("diagPath: 主应用使用规范路径",
              diagnosticFilePath(base: "/tmp/x.log", processName: "VibeFocusHotkeys") == "/tmp/x.log")
        check("diagPath: 空进程名回落规范路径",
              diagnosticFilePath(base: "/tmp/x.log", processName: "") == "/tmp/x.log")
        check("diagPath: 其它进程加进程名后缀",
              diagnosticFilePath(base: "/tmp/x.log", processName: "VibeFocusTestRunner")
                  == "/tmp/x.log-VibeFocusTestRunner")

        let processName = ProcessInfo.processInfo.processName
        check("diagPath: 本进程 fatal 路径与派生规则同源",
              diagnosticFatalLogPath()
                  == diagnosticFilePath(base: "/tmp/vibefocus-crash-fatal.log", processName: processName))
        check("diagPath: 本进程 snapshot 路径与派生规则同源",
              diagnosticSnapshotLogPath()
                  == diagnosticFilePath(base: "/tmp/vibefocus-crash-snapshot.log", processName: processName))

        // MARK: B. 全局常量域
        check("const: 默认端口在合法区间",
              VFConstants.defaultHookServerPort >= VFConstants.minValidPort
                  && VFConstants.defaultHookServerPort <= VFConstants.maxValidPort)
        check("const: 端口区间端点",
              VFConstants.minValidPort == 1024 && VFConstants.maxValidPort == 65535)
        check("const: 文件权限位",
              VFConstants.filePermissionReadWrite == 0o644
                  && VFConstants.filePermissionExecutable == 0o755)
        check("const: 完成保留期短于活跃保留期",
              VFConstants.completedRetentionSeconds < VFConstants.activeRetentionSeconds
                  && VFConstants.bindingMaxAgeSeconds > 0)
        check("const: 路径常量形态",
              !VFConstants.configDirName.isEmpty
                  && VFConstants.appLockFilePath.hasPrefix("/tmp/")
                  && VFConstants.claudeSettingsRelativePath.hasSuffix("settings.json"))
        check("const: 缓冲与日志上限为正",
              VFConstants.crashSnapshotBufferSize > 0
                  && VFConstants.maxLogSizeBytes > 0
                  && VFConstants.structuredLogLineLimit > 0)
    }
}
