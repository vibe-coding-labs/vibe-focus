// Tests/Standalone/SoundPlayGateTests.swift
// Verification: 提示音防打扰门控（节流/免打扰时段/优先级/边界）+ SoundPreferences 向后兼容解码
// Mirrors: Sources/App/SoundPlayGate.swift, Sources/App/SoundManager.swift (SoundPreferences)
// Run: swift Tests/Standalone/SoundPlayGateTests.swift

import Foundation

// MARK: - Mirrored types

enum SoundPlayGateDecision: Equatable {
    case allow
    case throttled(remainingSeconds: Int)
    case quietHours
}

enum SoundPlayGate {
    static func decide(
        now: Date,
        lastPlayedAt: Date?,
        minIntervalSeconds: Int,
        quietEnabled: Bool,
        quietStartHour: Int,
        quietEndHour: Int,
        calendar: Calendar
    ) -> SoundPlayGateDecision {
        if quietEnabled, quietStartHour != quietEndHour,
           isInQuietHours(date: now, startHour: quietStartHour, endHour: quietEndHour, calendar: calendar) {
            return .quietHours
        }
        guard minIntervalSeconds > 0, let lastPlayedAt else {
            return .allow
        }
        let elapsed = now.timeIntervalSince(lastPlayedAt)
        if elapsed < Double(minIntervalSeconds) {
            let remaining = Int((Double(minIntervalSeconds) - elapsed).rounded(.up))
            return .throttled(remainingSeconds: max(remaining, 1))
        }
        return .allow
    }

    private static func isInQuietHours(date: Date, startHour: Int, endHour: Int, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        if startHour > endHour {
            return hour >= startHour || hour < endHour
        }
        return hour >= startHour && hour < endHour
    }
}

struct SoundPreferences: Codable, Equatable {
    var soundType: String
    var customSoundPath: String?
    var volume: Float
    var minPlayIntervalSeconds: Int
    var quietHoursEnabled: Bool
    var quietStartHour: Int
    var quietEndHour: Int

    init(
        soundType: String, customSoundPath: String?, volume: Float,
        minPlayIntervalSeconds: Int = 2, quietHoursEnabled: Bool = false,
        quietStartHour: Int = 22, quietEndHour: Int = 8
    ) {
        self.soundType = soundType
        self.customSoundPath = customSoundPath
        self.volume = volume
        self.minPlayIntervalSeconds = minPlayIntervalSeconds
        self.quietHoursEnabled = quietHoursEnabled
        self.quietStartHour = quietStartHour
        self.quietEndHour = quietEndHour
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.soundType = try container.decode(String.self, forKey: .soundType)
        self.customSoundPath = try container.decodeIfPresent(String.self, forKey: .customSoundPath)
        self.volume = try container.decode(Float.self, forKey: .volume)
        self.minPlayIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .minPlayIntervalSeconds) ?? 2
        self.quietHoursEnabled = try container.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? false
        self.quietStartHour = try container.decodeIfPresent(Int.self, forKey: .quietStartHour) ?? 22
        self.quietEndHour = try container.decodeIfPresent(Int.self, forKey: .quietEndHour) ?? 8
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// 固定时区/日历（UTC，避免测试随设备时区漂移）
var utcCalendar = Calendar(identifier: .gregorian)
utcCalendar.timeZone = TimeZone(identifier: "UTC")!

/// UTC y-m-d h:m:s → Date
func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

print("1. 节流（throttle）")
do {
    let t0 = utcDate(2026, 9, 2, 12, 0, 0)
    check("首次播放（无 lastPlayedAt）→ 放行",
          SoundPlayGate.decide(now: t0, lastPlayedAt: nil, minIntervalSeconds: 2,
                               quietEnabled: false, quietStartHour: 22, quietEndHour: 8,
                               calendar: utcCalendar) == .allow)
    check("间隔 1s < 2s → 节流",
          SoundPlayGate.decide(now: t0.addingTimeInterval(1), lastPlayedAt: t0, minIntervalSeconds: 2,
                               quietEnabled: false, quietStartHour: 22, quietEndHour: 8,
                               calendar: utcCalendar) == .throttled(remainingSeconds: 1))
    check("elapsed 0.8s → 剩余 1.2s 向上取整为 2s",
          SoundPlayGate.decide(now: t0.addingTimeInterval(0.8), lastPlayedAt: t0, minIntervalSeconds: 2,
                               quietEnabled: false, quietStartHour: 22, quietEndHour: 8,
                               calendar: utcCalendar) == .throttled(remainingSeconds: 2))
    check("间隔恰好 2s → 放行（严格小于才拦）",
          SoundPlayGate.decide(now: t0.addingTimeInterval(2), lastPlayedAt: t0, minIntervalSeconds: 2,
                               quietEnabled: false, quietStartHour: 22, quietEndHour: 8,
                               calendar: utcCalendar) == .allow)
    check("间隔 0 配置 → 节流关闭",
          SoundPlayGate.decide(now: t0.addingTimeInterval(0.1), lastPlayedAt: t0, minIntervalSeconds: 0,
                               quietEnabled: false, quietStartHour: 22, quietEndHour: 8,
                               calendar: utcCalendar) == .allow)
}

print("2. 免打扰时段（quiet hours）")
do {
    // 跨午夜窗口 22 → 8
    func at(_ h: Int) -> Date { utcDate(2026, 9, 2, h) }
    func gate(_ h: Int) -> SoundPlayGateDecision {
        SoundPlayGate.decide(now: at(h), lastPlayedAt: nil, minIntervalSeconds: 2,
                             quietEnabled: true, quietStartHour: 22, quietEndHour: 8,
                             calendar: utcCalendar)
    }
    check("23 点（窗口内）→ 静音", gate(23) == .quietHours)
    check("22 点（含起点）→ 静音", gate(22) == .quietHours)
    check("7 点（窗口内）→ 静音", gate(7) == .quietHours)
    check("8 点（不含终点）→ 放行", gate(8) == .allow)
    check("12 点（窗口外）→ 放行", gate(12) == .allow)

    // 同日窗口 9 → 18
    func gateDay(_ h: Int) -> SoundPlayGateDecision {
        SoundPlayGate.decide(now: at(h), lastPlayedAt: nil, minIntervalSeconds: 2,
                             quietEnabled: true, quietStartHour: 9, quietEndHour: 18,
                             calendar: utcCalendar)
    }
    check("同日窗口：9 点 → 静音", gateDay(9) == .quietHours)
    check("同日窗口：17 点 → 静音", gateDay(17) == .quietHours)
    check("同日窗口：18 点 → 放行", gateDay(18) == .allow)

    // 起==止 → 配置无效不启用
    check("起==止 → 视作无效，放行",
          SoundPlayGate.decide(now: at(22), lastPlayedAt: nil, minIntervalSeconds: 2,
                               quietEnabled: true, quietStartHour: 22, quietEndHour: 22,
                               calendar: utcCalendar) == .allow)

    // 开关关闭 → 放行
    check("开关关闭 → 窗口内也放行",
          SoundPlayGate.decide(now: at(23), lastPlayedAt: nil, minIntervalSeconds: 2,
                               quietEnabled: false, quietStartHour: 22, quietEndHour: 8,
                               calendar: utcCalendar) == .allow)

    // 优先级：免打扰硬静音压过节流
    check("免打扰优先于节流（双命中 → quietHours）",
          SoundPlayGate.decide(now: at(23), lastPlayedAt: at(22).addingTimeInterval(3600), minIntervalSeconds: 30,
                               quietEnabled: true, quietStartHour: 22, quietEndHour: 8,
                               calendar: utcCalendar) == .quietHours)
}

print("3. SoundPreferences 向后兼容解码（旧 JSON 缺新字段不重置用户配置）")
do {
    // 模拟轮次 1 之前的持久化 JSON：只有三个旧字段
    let oldJSON = #"{"soundType":"builtinDing","customSoundPath":"\/tmp\/x.wav","volume":0.5}"#
    let data = oldJSON.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(SoundPreferences.self, from: data)
    check("旧字段保留：soundType", decoded.soundType == "builtinDing")
    check("旧字段保留：customSoundPath", decoded.customSoundPath == "/tmp/x.wav")
    check("旧字段保留：volume", decoded.volume == 0.5)
    check("缺省补齐：minPlayIntervalSeconds = 2", decoded.minPlayIntervalSeconds == 2)
    check("缺省补齐：quietHoursEnabled = false", decoded.quietHoursEnabled == false)
    check("缺省补齐：quietStart/EndHour = 22/8", decoded.quietStartHour == 22 && decoded.quietEndHour == 8)

    // 新 JSON 完整 roundtrip
    let fresh = SoundPreferences(soundType: "custom", customSoundPath: nil, volume: 0.9,
                                 minPlayIntervalSeconds: 5, quietHoursEnabled: true,
                                 quietStartHour: 23, quietEndHour: 7)
    let round = try JSONDecoder().decode(SoundPreferences.self, from: JSONEncoder().encode(fresh))
    check("新字段完整 roundtrip", round == fresh)
}

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed == 0 ? 0 : 1)
