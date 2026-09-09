import Foundation

// MARK: - AX 授权竞态自愈（2026-09-09/10 三次实证后立项）
//
// 现象：同证书重装（install replaced）后 ~1s 内拉起的新进程，约半数概率被 tccd
// 误判为未授权（AXIsProcessTrusted=false），且该误判绑定进程存活期——一整夜不自愈；
// 重启进程即恢复（授权本体从未被吊销：钥匙串证书 DR 前后一致，tccutil 不需要）。
// 并行会话高频重装（23:12 / 23:42 / 00:15 三连）→ 用户热键反复失效。
//
// 策略：启动发现未授权且上一进程不是死于自愈 → 显式 recordExit 后优雅退出，
// 交给 keepalive 链（LaunchAgent + wrapper）拉起全新进程，tccd 对新进程重新评估
// 即恢复。一圈最多一次：上一进程 exit.reason == ax-selfheal-relaunch 时不再自愈
// （真未授权场景防无限循环），落回既有「请到系统设置勾选」提示路径。
// 无 keepalive 链时退出后无人拉起，同样不自愈。

enum AXSelfHealDecision: Equatable {
    /// 已授权，正常启动
    case proceedTrusted
    /// 未授权且可自愈：记录审计后退出，keepalive 链拉起全新进程
    case relaunchViaKeepalive
    /// 上一进程已自愈过仍未授权 → 判定真未授权，走人工勾选提示（防循环）
    case giveUpPreviousHealFailed
    /// 无 keepalive 链，退出后无人拉起：不冒险自动重启
    case giveUpNoKeepalive
}

enum AXSelfHeal {
    /// 自愈退出的审计 reason（防循环判据 + Doctor 时间线归因）
    static let exitReason = "ax-selfheal-relaunch"

    /// keepalive wrapper 安装位（scripts/install-keepalive.sh 生成物）。
    /// 存在即视为有拉起链（LaunchAgent KeepAlive=true 会重启 wrapper）。
    static var wrapperPath: String {
        NSString(string: "~/Library/Application Support/VibeFocus/keepalive-wrapper.sh")
            .expandingTildeInPath
    }

    /// 自愈决策表（纯函数，Runner 直测）。
    static func decide(
        axTrusted: Bool,
        previousExitWasSelfHeal: Bool,
        keepaliveAvailable: Bool
    ) -> AXSelfHealDecision {
        if axTrusted { return .proceedTrusted }
        // 防循环优先于一切：上轮自愈过仍假 = 真未授权（用户吊销/首次装机未勾选）
        if previousExitWasSelfHeal { return .giveUpPreviousHealFailed }
        if !keepaliveAvailable { return .giveUpNoKeepalive }
        return .relaunchViaKeepalive
    }
}
