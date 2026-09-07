import AppKit
import Foundation

// SA 恢复的 admin 提权执行半区（2026-09-08 B52 从 SpaceController+Recovery.swift 按域拆出）：
// AppleScript 模板提纯（B41）+ 前台同步执行（NSAppleScript）+ 后台异步执行（osascript 进程）。
// 恢复动作编排见 SpaceController+Recovery.swift；状态机见 SpaceController+SARecoveryState.swift。

@MainActor
extension SpaceController {

    /// admin 提权 AppleScript 模板（纯函数，B41 提纯）：双引号/反斜杠转义防注入 +
    /// `with administrator privileges` 包装。模板决策与 NSAppleScript 执行分离（照 TitleEditor 模式）。
    static func makeAdminShellScript(_ command: String) -> String {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escapedCommand)\" with administrator privileges"
    }

    func executeWithAdminPrivileges(_ command: String, operationID: String? = nil) -> (Bool, String) {
        let op = operationID ?? "none"
        #if PERF_INSTRUMENT
        let adminStart = Date()
        defer {
            log("[SpaceController] executeWithAdminPrivileges finished", level: .debug, fields: [
                "op": op,
                "durationMs": String(elapsedMilliseconds(since: adminStart))
            ])
        }
        #endif
        let appleScript = NSAppleScript(source: Self.makeAdminShellScript(command))

        log(
            "[SpaceController] requesting admin privileges",
            fields: [
                "op": op,
                "command": truncateForLog(command, limit: 120)
            ]
        )

        var errorDict: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorDict)

        if let errorDict {
            let errorMessage = (errorDict[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            let errorNumber = errorDict[NSAppleScript.errorNumber] as? Int ?? -1
            log(
                "[SpaceController] admin privilege execution failed",
                level: .error,
                fields: [
                    "op": op,
                    "command": truncateForLog(command, limit: 120),
                    "errorMessage": errorMessage,
                    "errorNumber": String(errorNumber)
                ]
            )
            return (false, errorMessage)
        }

        let output = result?.stringValue ?? ""
        log(
            "[SpaceController] admin privilege execution succeeded",
            fields: [
                "op": op,
                "command": truncateForLog(command, limit: 120),
                "output": truncateForLog(output, limit: 120)
            ]
        )
        return (true, output)
    }

    /// 后台提权恢复（自动路径的执行半区）：utility 队列跑 osascript
    /// （NSAppleScript 需主线程，进程方式天然线程安全；密码弹框阻塞的是后台线程），
    /// 完成后按 verdict 经主队列收敛状态。
    /// 模板统一走 makeAdminShellScript 唯一事实源（B52 收敛：此前此处内联重写了一遍
    /// 转义+包装，与前台路径构成双份判据，模板一旦演进必漂移——B48 同类教训）。
    /// B52 拆分后由恢复编排（+Recovery.swift）跨文件调用，故为 internal。
    func scheduleBackgroundAdminRecovery(command: String, operationID: String) {
        let script = Self.makeAdminShellScript(command)
        DispatchQueue.global(qos: .utility).async {
            let output: String
            let success: Bool
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                success = process.terminationStatus == 0
                output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            } catch {
                success = false
                output = error.localizedDescription
            }
            DispatchQueue.main.async {
                let verdict = SpaceController.recoveryVerdict(success: success, outputOrError: output)
                self.recordRecoveryState(verdict, op: operationID, output: output)
            }
        }
    }
}
