// BuildCapabilities.swift
// VibeFocus — 构建能力标记自检（装机二进制 ≠ 代码基线的 drift 秒级鉴别）
//
// ## 场景（2026-09-06 部署互踩回归）
// 水波修复已合入 main，但装机二进制被并行会话用旧基线构建覆盖，用户按 ⌃Q 走回旧
// move_then_resize 水波路径——排查花了一小时才发现「跑的不是以为的那份代码」。
// 本文件把「这份二进制里编译进了哪些关键修复」变成：
//   1. 启动时 INFO 恒开的一行（logDiagnostics 内，见 Support+Diagnostics.swift）；
//   2. --diagnose 的一段报告（Doctor）。
// 每个能力对应一个只存在于该修复 log 字面量/键名里的标记串——注释不会编进二进制，
// 标记必须取字符串字面量。检测读自身可执行文件做 Data 级字节搜索（二进制安全）。
//
// ## 语义契约（BuildCapabilitiesTests 镜像锁定）
// - detect 是纯函数：对给定 Data 搜索各标记 needle 的 UTF8 字节序列；
// - 空 Data → 全 false；needle 位于头/中/尾都能命中；
// - summary 输出稳定格式 `name=0/1`（按登记顺序、空格分隔）；
// - missing 只列 false 项；全部命中返回空数组。

import Foundation

enum BuildCapabilities {

    struct Marker {
        let name: String
        let needle: String
    }

    /// 能力 → 标记串。新增关键修复落地时同步在此登记，否则 drift 不自检可见。
    static let all: [Marker] = [
        Marker(name: "ax-resize-channel", needle: "resize channel"),                          // cea8f78 混合写入
        Marker(name: "segment-timing", needle: "segment timing"),                             // af19b2b 段级计时
        Marker(name: "stall-resend", needle: "stallResendCount"),                             // af19b2b 停滞重发
        Marker(name: "toggle-windowless-fallback", needle: "toggle fallback: no toggleable"), // 540d007 无窗口前台兜底
        Marker(name: "grid-space-delivery", needle: "GRID_SPACE_E2E"),                        // fbcaa96 网格 Space 投递
        Marker(name: "sa-verdict-state-machine", needle: "saRecoveryVerdict"),                // 51e5c70 SA 结局状态机
    ]

    /// 纯函数：在 data 上二进制安全搜索各标记。
    static func detect(in data: Data) -> [String: Bool] {
        let bytes = [UInt8](data)
        var result: [String: Bool] = [:]
        for marker in all {
            result[marker.name] = contains(bytes, needle: Array(marker.needle.utf8))
        }
        return result
    }

    /// 读自身可执行文件检测；路径不可得/读失败返回 nil（调用方按无信号处理）。
    static func detectInOwnBinary() -> [String: Bool]? {
        let path = Bundle.main.executableURL?.path ?? CommandLine.arguments.first
        guard let path, let data = FileManager.default.contents(atPath: path) else { return nil }
        return detect(in: data)
    }

    /// 稳定格式摘要：`name=0/1`，按登记顺序、空格分隔。
    static func summary(_ result: [String: Bool]) -> String {
        all.map { "\($0.name)=\(result[$0.name] == true ? 1 : 0)" }.joined(separator: " ")
    }

    /// 期望能力中缺失（非 true）的名字列表，按登记顺序。
    static func missing(_ result: [String: Bool]) -> [String] {
        all.filter { result[$0.name] != true }.map { $0.name }
    }

    private static func contains(_ data: [UInt8], needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= data.count else { return false }
        let lastStart = data.count - needle.count
        var i = 0
        while i <= lastStart {
            if data[i] == needle[0] {
                var j = 1
                while j < needle.count, data[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }
}
