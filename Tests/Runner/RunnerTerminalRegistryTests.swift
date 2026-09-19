import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTerminalRegistryTests.swift — B214 终端注册表覆盖补强
// 靶：Sources/Support/TerminalRegistry.swift（基线 48%）。
// 名册集合是全项目终端识别的单一事实源，此处逐项锁定成员与判定语义；
// findTerminalPID 走真实 /bin/ps fork 通道（与生产同路径），只断言确定性结局。

extension RunnerHarness {
    func runTerminalRegistryCoverageTests() {
        // A. 名册事实源锁定（防手滑删条目——终端上下文识别全依赖这几张集合）
        do {
            check("termReg A1: terminalBundleIDs 覆盖四主力终端",
                  TerminalRegistry.terminalBundleIDs.isSuperset(of: [
                      "com.apple.Terminal", "com.googlecode.iterm2",
                      "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                  ]))
            check("termReg A2: terminalAppNames 与 bundleIDs 数量一致（9 款）",
                  TerminalRegistry.terminalAppNames.count == 9
                  && TerminalRegistry.terminalBundleIDs.count == 9)
            check("termReg A3: ideBundleIDs/appNames 含 VSCode 与 Cursor",
                  TerminalRegistry.ideBundleIDs.contains("com.microsoft.VSCode")
                  && TerminalRegistry.ideAppNames.contains("Cursor"))
            check("termReg A4: 并集计算属性=两集合之并（bundle 与 name 各自成立）",
                  TerminalRegistry.allTerminalAndIDEBundleIDs
                      == TerminalRegistry.terminalBundleIDs.union(TerminalRegistry.ideBundleIDs)
                  && TerminalRegistry.allTerminalAndIDEAppNames
                      == TerminalRegistry.terminalAppNames.union(TerminalRegistry.ideAppNames))
            check("termReg A5: 终端与 IDE 名册互不相交",
                  TerminalRegistry.terminalBundleIDs.isDisjoint(with: TerminalRegistry.ideBundleIDs)
                  && TerminalRegistry.terminalAppNames.isDisjoint(with: TerminalRegistry.ideAppNames))
        }

        // B. isTerminalBundleID：纯集合判定
        do {
            check("termReg B1: Terminal.app bundleID 命中",
                  TerminalRegistry.isTerminalBundleID("com.apple.Terminal"))
            check("termReg B2: iTerm2 bundleID 命中",
                  TerminalRegistry.isTerminalBundleID("com.googlecode.iterm2"))
            check("termReg B3: IDE bundleID 不算终端",
                  !TerminalRegistry.isTerminalBundleID("com.microsoft.VSCode"))
            check("termReg B4: 未知 bundleID 不命中",
                  !TerminalRegistry.isTerminalBundleID("com.apple.finder"))
        }

        // C. isTerminalOrIDEApp：appName / bundleID 双通道，任一命中即真
        do {
            check("termReg C1: appName 终端命中",
                  TerminalRegistry.isTerminalOrIDEApp(appName: "iTerm2", bundleIdentifier: nil))
            check("termReg C2: appName IDE 命中",
                  TerminalRegistry.isTerminalOrIDEApp(appName: "Cursor", bundleIdentifier: nil))
            check("termReg C3: bundleID 终端命中（appName 未知）",
                  TerminalRegistry.isTerminalOrIDEApp(appName: "Safari", bundleIdentifier: "com.apple.Terminal"))
            check("termReg C4: bundleID IDE 命中",
                  TerminalRegistry.isTerminalOrIDEApp(appName: nil, bundleIdentifier: "com.microsoft.VSCode"))
            check("termReg C5: 双 nil 不命中",
                  !TerminalRegistry.isTerminalOrIDEApp(appName: nil, bundleIdentifier: nil))
            check("termReg C6: 双未知不命中",
                  !TerminalRegistry.isTerminalOrIDEApp(appName: "Finder", bundleIdentifier: "com.apple.finder"))
            check("termReg C7: WezTerm 大小写敏感名册按原名命中",
                  TerminalRegistry.isTerminalOrIDEApp(appName: "WezTerm", bundleIdentifier: nil)
                  && !TerminalRegistry.isTerminalOrIDEApp(appName: "wezterm", bundleIdentifier: nil))
        }

        // D. isTerminalPID：pid 域守卫 + 本进程/launchd 走 ps comm 兜底路径
        do {
            let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
            check("termReg D1: pid<=0 恒 false（0 与负值）",
                  !TerminalRegistry.isTerminalPID(0) && !TerminalRegistry.isTerminalPID(-7))
            // Runner 是无 bundle 的 CLI：NSRunningApplication 查不到 → ps comm 兜底
            // → basename 是 VibeFocusTestRunner，不在终端名册 → false。
            check("termReg D2: 自身 CLI 进程非终端（NSRunningApplication 缺席→comm 兜底不命中）",
                  !TerminalRegistry.isTerminalPID(myPID))
            check("termReg D3: launchd 非终端（comm=/sbin/launchd 不在名册）",
                  !TerminalRegistry.isTerminalPID(1))
        }

        // E. findTerminalPID：真实 ps fork 通道，确定性结局（链上无终端 → nil）
        do {
            // pid 1 的 ppid=0 ≤ 1 → 第一轮即断链。
            check("termReg E1: findTerminalPID(pid 1)=nil（launchd 链顶断链）",
                  TerminalRegistry.findTerminalPID(from: 1) == nil)
            // 负 pid：ps 查询失败 → parentPID nil → 断链（ShellRunner 失败路径）。
            check("termReg E2: findTerminalPID(负 pid)=nil（ps 失败断链）",
                  TerminalRegistry.findTerminalPID(from: -3) == nil)
        }
    }
}
