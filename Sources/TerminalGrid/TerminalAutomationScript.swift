import CoreGraphics
import Foundation

// MARK: - 终端自动化 AppleScript 生成器（纯字符串，无 I/O）
/// 坐标注记：AppleScript `bounds` 是 Cocoa 全局坐标 {left, top, right, bottom}；
/// 本仓内部 frame 是 Quartz（Y 向下）。换算走 CoordinateKit.cocoaY(fromQuartzY:)，
/// 本文件只负责把换算好的 cocoaTop 拼进脚本。
/// 命令注入防御：所有插值字符串先过 appleScriptEscaped。
@MainActor
enum TerminalAutomationScript {

    // MARK: - 自动化目标终端身份（B64：方言选择判断收敛的唯一事实源）

    /// 网格自动化为其编写了 AppleScript 方言的终端集合（iTerm2 / Apple Terminal）。
    /// 语义边界：`TerminalRegistry.terminalBundleIDs` 是「终端识别」超集（9 终端，
    /// 回答"这是不是终端"）；本集合只回答"网格自动化有没有为它写方言"——两者刻意不同。
    static let automationBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
    ]

    /// 该 bundle id 是否使用 iTerm2 方言（否则按 Apple Terminal 方言处理）。
    /// 不在支持集内的 id 一律返回 false，调用方应先以 isAutomationSupported 拒绝。
    static func usesITermDialect(_ appBundleID: String) -> Bool {
        appBundleID == "com.googlecode.iterm2"
    }

    static func isAutomationSupported(_ appBundleID: String) -> Bool {
        automationBundleIDs.contains(appBundleID)
    }

    static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Quartz frame → Cocoa {l, t, r, b} 四元组字符串
    static func cocoaBoundsTuple(quartzFrame: CGRect) -> String {
        let cocoaTop = CoordinateKit.cocoaY(fromQuartzY: quartzFrame.maxY)
        let left = Int(quartzFrame.minX.rounded())
        let top = Int(cocoaTop.rounded())
        let right = Int(quartzFrame.maxX.rounded())
        let bottom = Int((cocoaTop + quartzFrame.height).rounded())
        return "{\(left), \(top), \(right), \(bottom)}"
    }

    // MARK: Terminal.app

    /// 新建窗口并摆到指定 bounds，返回新窗口 id（即 CGWindowNumber）。
    /// command 为 nil/空时只开 shell。
    /// 真机实证（2026-09-04）：`do script` 建窗是异步的——Terminal 零窗口时
    /// 紧跟的 `front window` 会报 Invalid index(-1719)，必须轮询等窗口数增加。
    static func terminalCreateWindow(command: String?, quartzFrame: CGRect) -> String {
        let escaped = appleScriptEscaped(command ?? "")
        return """
        tell application id "com.apple.Terminal"
            set priorWindowCount to count of windows
            do script "\(escaped)"
            set waited to 0
            repeat until (count of windows) > priorWindowCount or waited > 100
                delay 0.05
                set waited to waited + 1
            end repeat
            set bounds of front window to \(cocoaBoundsTuple(quartzFrame: quartzFrame))
            return id of front window
        end tell
        """
    }

    /// 全量枚举窗口→tab→tty 映射："windowID|tty" 行。Terminal.app 的 AppleScript
    /// window id == CGWindowNumber（仓库 TerminalContext 链路既有实证）。
    static func terminalEnumerateWindowTTYs() -> String {
        """
        tell application id "com.apple.Terminal"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set output to output & (id of w as string) & "|" & (tty of t) & linefeed
                end repeat
            end repeat
            return output
        end tell
        """
    }

    /// 读回窗口 bounds（{l,t,r,b} 逗号串）——读回值与 Quartz 同为左上原点 Y 向下
    static func terminalGetBounds(windowID: UInt32) -> String {
        """
        tell application id "com.apple.Terminal"
            return bounds of window id \(windowID)
        end tell
        """
    }

    /// 向既有窗口注入命令（自动恢复"活窗口复用"路径——不重建窗口，防重复）
    static func terminalInjectCommand(windowID: UInt32, command: String) -> String {
        """
        tell application id "com.apple.Terminal"
            do script "\(appleScriptEscaped(command))" in window id \(windowID)
        end tell
        """
    }

    static func itermInjectCommand(windowID: String, command: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            tell current session of window id \(windowID) to write text "\(appleScriptEscaped(command))"
        end tell
        """
    }

    static func itermGetBounds(windowID: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            return bounds of window id \(windowID)
        end tell
        """
    }

    /// "872, 578, 1726, 1118" → CGRect(l, t, w, h)（Quartz/左上原点语义）
    static func parseBounds(_ stdout: String) -> CGRect? {
        let parts = stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        return CGRect(
            x: parts[0],
            y: parts[1],
            width: parts[2] - parts[0],
            height: parts[3] - parts[1]
        )
    }

    // MARK: iTerm2

    static func itermCreateWindow(command: String?, quartzFrame: CGRect) -> String {
        let writeText = (command?.isEmpty ?? true)
            ? ""
            : "tell current session of current window to write text \"\(appleScriptEscaped(command!))\"\n"
        return """
        tell application id "com.googlecode.iterm2"
            create window with default profile
            \(writeText)set bounds of current window to \(cocoaBoundsTuple(quartzFrame: quartzFrame))
            return id of current window
        end tell
        """
    }

    // MARK: 通用

    /// POSIX 单引号包裹（内部单引号走 `'\''` 惯用法）
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 恢复某个格子的完整 shell 命令行：cwd → 工作目录、sessionID → `claude --resume`、
    /// 否则启动命令。返回原始 shell 串；AppleScript 层逃逸由脚本构建处统一做
    /// （appleScriptEscaped 只动反斜杠/双引号，不碰 shell 单引号，两层不冲突）。
    static func cellCommand(sessionID: String?, cwd: String?, launchCommand: String?) -> String? {
        var parts: [String] = []
        if let cwd, !cwd.isEmpty {
            parts.append("cd \(shellQuoted(cwd))")
        }
        if let sessionID, !sessionID.isEmpty {
            parts.append("claude --resume \(sessionID)")
        } else if let launchCommand, !launchCommand.isEmpty {
            parts.append(launchCommand)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " && ")
    }

    /// 解析 `terminalEnumerateWindowTTYs` 的 stdout（每行 `windowID|tty`）。
    ///
    /// ## 边界（穷尽锁定于 Runner TerminalGridTTYParsingTests）
    /// - 窗口 id 非 UInt32 的行跳过；缺 `|` 的行跳过；
    /// - tty 缺 `/dev/` 前缀自动补全；首 `|` 之后全部视为 tty（tty 路径含 `|` 不撕列）；
    /// - 空行/纯空白行跳过。
    static func parseWindowTTYMap(_ stdout: String) -> [UInt32: String] {
        var mapping: [UInt32: String] = [:]
        for line in stdout.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let windowID = UInt32(parts[0]) else { continue }
            var tty = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if !tty.hasPrefix("/dev/") {
                tty = "/dev/" + tty
            }
            mapping[windowID] = tty
        }
        return mapping
    }

    // MARK: - 自动化环境守卫与失败明细（纯函数）

    /// 建窗/恢复前的实例环境判定。真机实证（2026-09-11 用户建 2×3 网格失败复盘）：
    /// 并行会话的 GRID E2E 会在 /tmp 拉起同 bundle id 的临时 iTerm2 并与真实终端
    /// 并存/生灭，`tell application id` 按 bundle id 寻址会在实例间随机路由——建窗
    /// AE 被送进垂死的测试副本时 osascript 秒败且 stderr 为空（用户视角=「第 2 个
    /// 窗口创建失败」，且已建窗口会随副本退出消失）。因此唯一安全态 = 恰好一个
    /// 实例、且可执行路径不在临时目录。
    enum AutomationInstanceVerdict: Equatable {
        case clean                          // 单实例且路径可信，放行
        case ephemeralOnly(detail: String)  // 唯一实例是临时副本/路径不可辨
        case ambiguous(detail: String)      // 多实例并存，寻址会漂移
        case notRunning                     // 目标终端没有运行实例
    }

    /// 临时副本路径特征：E2E 脚手架把 iTerm2 拷到 /tmp 直跑；系统临时目录一律不可信
    static func isEphemeralInstancePath(_ path: String) -> Bool {
        path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") || path.hasPrefix("/var/folders/")
    }

    /// 进程 exec 路径是否属于目标终端：basename 与正式安装版可执行文件名一致
    /// （iTerm.app 的可执行名是 iTerm2；副本不论落在哪个目录都会撞上同名 basename）
    static func processPathMatchesCanonicalExec(_ path: String, canonicalExecName: String) -> Bool {
        (path as NSString).lastPathComponent == canonicalExecName
    }

    /// instances = 该 bundleID 当前全部运行实例的（pid, 可执行路径）
    static func automationInstanceVerdict(
        instances: [(pid: pid_t, executablePath: String?)]
    ) -> AutomationInstanceVerdict {
        if instances.isEmpty { return .notRunning }
        if instances.count == 1, let path = instances[0].executablePath,
           !isEphemeralInstancePath(path) {
            return .clean
        }
        let listed = instances.prefix(3)
            .map { "pid \($0.pid)：\($0.executablePath ?? "路径未知")" }
            .joined(separator: "；")
        let listText = instances.count > 3 ? "\(listed)；等共 \(instances.count) 个" : listed
        return instances.count == 1 ? .ephemeralOnly(detail: listText) : .ambiguous(detail: listText)
    }

    /// 守卫拒绝的用户文案；clean → nil（放行）
    static func instanceGuardFailureMessage(
        for verdict: AutomationInstanceVerdict,
        appName: String
    ) -> String? {
        switch verdict {
        case .clean:
            return nil
        case .notRunning:
            return "\(appName) 未运行，无法创建终端窗口"
        case .ephemeralOnly(let detail):
            return "检测到的唯一 \(appName) 实例不是正式安装版（\(detail)），疑似自动化测试的临时副本——窗口建进去会随副本退出而丢失，已中止创建"
        case .ambiguous(let detail):
            return "检测到 \(appName) 有多个实例并存（\(detail)），AppleScript 按 bundle id 寻址会在实例间随机路由，窗口可能建进错误实例——若正在跑自动化测试请等其结束后重试"
        }
    }

    /// 建窗脚本的逐格重试上限：瞬时 AE 故障（终端忙、事件超时、实例切换空窗）
    /// 自愈窗口在亚秒~秒级；两次退避后仍败视为系统性问题，中止并如实上报
    static let maxCellCreateAttempts = 3

    /// 第 failedAttempts 次失败后的退避（线性，封顶 800ms）
    static func cellCreateRetryDelayNanos(failedAttempts: Int) -> UInt64 {
        min(UInt64(failedAttempts) * 400_000_000, 800_000_000)
    }

    /// osascript 结果 → 失败明细（成功 → nil）。stderr 为空的非零退出是真机
    /// 实证过的真实形态（AE 被垂死实例吞掉），必须带着退出码现身，不能落进
    /// 「执行失败或超时」的兜底词里丢失取证线索。
    static func describeScriptFailure(_ result: YabaiClient.YabaiResult?) -> String? {
        guard let result else { return "无法启动 osascript（进程未启动或 30s 超时）" }
        guard result.exitCode != 0 else { return nil }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty
            ? "osascript 异常退出（退出码 \(result.exitCode)，无错误输出）"
            : stderr
    }
}
