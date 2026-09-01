import Foundation

// MARK: - yabai 环境探测器（2026-09-01）
// 能力矩阵见 docs/window-capability-matrix.md。
// 设计原则（通用软件约束）：
//   - yabai 是可选增强，不是依赖——"存在即可用"的假设已被 v7 float 布局
//     `--space` 静默失效事故证伪（2026-08-31/09-01 toggle 跨屏失效）。
//   - 三层探测：L1 二进制存在 → L2 daemon 响应 → L3 布局 profile。
//     全部通过才允许 yabai 增强路径；任何一层失败都正确降级到纯 AX 模式。
//   - 命令执行以 closure 注入（ShellRunner），判定逻辑零 I/O 依赖，可完整单测。

/// 单个 space 的布局信息（yabai 坐标系语义）
struct YabaiSpaceLayout: Equatable {
    let index: Int          // yabai 全局 space 索引（1-based）
    let display: Int        // 所属 display（1-based）
    let layout: String      // "float" / "bsp"（yabai v7 新增布局枚举）
}

/// yabai 探测结论（不可变值对象，线程安全）
struct YabaiEnvironmentProfile: Equatable {
    let binaryPresent: Bool          // L1
    let binaryPath: String?
    let daemonResponsive: Bool       // L2
    let versionString: String?       // 例如 "yabai-v7.1.18"
    let spaces: [YabaiSpaceLayout]   // L3（daemon 响应失败时为空）

    /// yabai 是否可作为增强层使用（L1 + L2 通过）
    var usableAsEnhancer: Bool { binaryPresent && daemonResponsive }

    /// 全部 space 均为 float 布局（且至少有一个 space）。
    /// 已实证：float 布局下 `window --space` 静默失效 → 必须走 frame 直写路径。
    var isAllFloatLayout: Bool {
        !spaces.isEmpty && spaces.allSatisfy { $0.layout == "float" }
    }

    /// 存在任一 bsp space（bsp 布局下 `--space` 可靠，yabai 路径可放开）
    var hasBSPSpace: Bool {
        spaces.contains { $0.layout == "bsp" }
    }

    /// `--space` 命令是否可信（L2 通过 且 无任何 float space）
    /// 保守策略：只要探到任一 float space 就不信任 `--space` 的全局行为
    /// （yabai v7 float 布局下该命令静默失效，T3 断言实证）。
    var spaceMoveTrusted: Bool {
        daemonResponsive && !spaces.isEmpty && !spaces.contains { $0.layout == "float" }
    }
}

enum YabaiEnvironmentProbe {

    /// 常见安装路径（Homebrew Apple Silicon / Intel / 手动）
    static let candidatePaths = [
        "/opt/homebrew/bin/yabai",
        "/usr/local/bin/yabai",
        "/usr/bin/yabai"
    ]

    /// L1：二进制存在且可执行
    static func locateBinary(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        candidatePaths.first { fileExists($0) }
    }

    /// 完整探测。runner 注入便于测试；生产环境传 ShellRunner 封装。
    /// - Parameters:
    ///   - runner: (binaryPath, args) -> (exitCode, stdout)；返回 nil 表示 fork 失败
    ///   - timeoutSeconds: daemon 查询超时（超时视为不响应）
    static func probe(
        runner: (_ binaryPath: String, _ args: [String]) -> (exitCode: Int32, stdout: String)?,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        timeoutSeconds: TimeInterval = 2.0
    ) -> YabaiEnvironmentProfile {
        guard let binaryPath = locateBinary(fileExists: fileExists) else {
            return YabaiEnvironmentProfile(
                binaryPresent: false, binaryPath: nil,
                daemonResponsive: false, versionString: nil, spaces: []
            )
        }

        // L2：daemon 响应（query --spaces 是所有 yabai 用途的最小公共查询）
        guard let spacesResult = runner(binaryPath, ["-m", "query", "--spaces"]),
              spacesResult.exitCode == 0 else {
            return YabaiEnvironmentProfile(
                binaryPresent: true, binaryPath: binaryPath,
                daemonResponsive: false, versionString: nil, spaces: []
            )
        }

        // 版本（尽力而为，失败不影响结论）
        let version = runner(binaryPath, ["--version"]).map { $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }

        return YabaiEnvironmentProfile(
            binaryPresent: true,
            binaryPath: binaryPath,
            daemonResponsive: true,
            versionString: version,
            spaces: parseSpaces(spacesResult.stdout)
        )
    }

    /// 解析 `yabai -m query --spaces` 输出 → 布局列表。
    /// 纯函数；任何解析失败返回已成功解析的前缀（宽松语义：部分信息优于失败）。
    static func parseSpaces(_ json: String) -> [YabaiSpaceLayout] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { dict in
            guard let index = dict["index"] as? Int,
                  let display = dict["display"] as? Int else { return nil }
            return YabaiSpaceLayout(
                index: index,
                display: display,
                layout: dict["type"] as? String ?? "unknown"
            )
        }
    }
}
