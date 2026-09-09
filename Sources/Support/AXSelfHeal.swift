import Foundation

// MARK: - AX 授权竞态自愈（2026-09-09/10 三次实证后立项；同日补用户态闭环）
//
// 现象：同证书重装（install replaced）后 ~1s 内拉起的新进程，约半数概率被 tccd
// 误判为未授权（AXIsProcessTrusted=false），且该误判绑定进程存活期——一整夜不自愈；
// 重启进程即恢复（授权本体从未被吊销：钥匙串证书 DR 前后一致，tccutil 不需要）。
// 并行会话高频重装（23:12 / 23:42 / 00:15 三连）→ 用户热键反复失效。
//
// 策略：启动发现未授权且上一进程不是死于自愈 → 派生一个 detached 看护进程
// （等本进程退出 → tccd 退让 3s → open 产物），随后显式 recordExit 并优雅退出，
// 看护进程拉起全新进程，tccd 对新进程重新评估即恢复。
// 自包含、不依赖 keepalive LaunchAgent——真实用户机器上没有那条链（首版
// giveUpNoKeepalive 的教训：开发者环境自愈了，用户态照样堵死）。
// 防循环：上一进程 exit.reason == ax-selfheal-relaunch 时不再自愈（真未授权
// 场景——用户吊销/首次装机未勾选/更新换签名——一圈即止，落回「打开系统设置」提示）。

enum AXSelfHealDecision: Equatable {
    /// 已授权，正常启动
    case proceedTrusted
    /// 未授权且可自愈：派生看护进程后退出，由它拉起全新进程
    case relaunchSelf
    /// 上一进程已自愈过仍未授权 → 判定真未授权，走人工勾选提示（防循环）
    case giveUpPreviousHealFailed
    /// 非 bundle 安装（裸二进制 dev 运行）：open 产物无从谈起，不自愈
    case giveUpNoBundle
}

enum AXSelfHeal {
    /// 自愈退出的审计 reason（防循环判据 + Doctor 时间线归因）
    static let exitReason = "ax-selfheal-relaunch"

    /// 自愈看护脚本（纯函数，Runner 直测）：等 pid 死亡 → tccd 退让 → open 产物。
    /// 退让时长与 install-keepalive.sh wrapper 的 sleep 3 同源同义。
    static func relaunchScript(pid: Int32, bundlePath: String) -> String {
        "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; sleep 3; open '\(bundlePath)'"
    }

    /// 派生 detached 看护进程。子进程不随父死（macOS 无默认进程组连坐），父进程
    /// 先退出、子进程被 launchd 收养继续执行——真实用户无 keepalive 也成立。
    static func spawnRelaunchWatcher(pid: Int32, bundlePath: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", relaunchScript(pid: pid, bundlePath: bundlePath)]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            return true
        } catch {
            return false
        }
    }

    /// 自愈决策表（纯函数，Runner 直测）。
    static func decide(
        axTrusted: Bool,
        previousExitWasSelfHeal: Bool,
        isBundleInstall: Bool
    ) -> AXSelfHealDecision {
        if axTrusted { return .proceedTrusted }
        // 防循环优先于一切：上轮自愈过仍假 = 真未授权（用户吊销/首次装机未勾选/换签名）
        if previousExitWasSelfHeal { return .giveUpPreviousHealFailed }
        if !isBundleInstall { return .giveUpNoBundle }
        return .relaunchSelf
    }
}

// MARK: - 运行期翻转自愈（true→false 中途被 tccd 翻转的补环）
//
// 启动自愈只覆盖「启动即假」；运行期翻转（09-06 两次实证）由
// WindowManager.hasAccessibilityPermission 的翻转检测挂钩本决策，5s 复核防抖后
// 走同一 detached 看护自拉起。每进程最多一次（runtimeHealAttempted 标记），
// 退出 reason 与启动自愈共用——重启后的新进程按既有防循环规则不再自愈。

enum AXRuntimeHealDecision: Equatable {
    /// true→false 且本进程未自愈过 → 5s 复核仍假则自愈
    case healOnConfirm
    /// true→false 但本进程已自愈过 → 只记账不自愈（防循环）
    case ignoreAlreadyHealed
    /// false→true：授权恢复，无需动作
    case ignoreFalseToTrue
}

extension AXSelfHeal {
    /// 运行期翻转决策表（纯函数，Runner 直测）。仅在检测到翻转时调用。
    static func decideRuntimeFlip(
        nowTrusted: Bool,
        healAlreadyAttempted: Bool
    ) -> AXRuntimeHealDecision {
        if nowTrusted { return .ignoreFalseToTrue }
        return healAlreadyAttempted ? .ignoreAlreadyHealed : .healOnConfirm
    }
}
