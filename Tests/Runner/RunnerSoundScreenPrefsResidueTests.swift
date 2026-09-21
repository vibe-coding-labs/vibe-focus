import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSoundScreenPrefsResidueTests.swift — B312 覆盖率扫尾批
//
// 台账 A 态清单最后两个具名残留的清账（豁免台账「ScreenIndexPreferences 待重审」+
// 「SoundManager 残支维持 A」两条 2026-09-21 复审结论的执行批）：
//   ①SoundManager 节流臂/免打扰臂/resolve 失败臂/5s 兜底停止身份校验/
//     loadPreferences 缺数据+坏数据双臂（loadPreferences 按 B248 标准提 internal）；
//   ②ScreenIndexPreferences.enforcePerScreenSpaceIndexingIfNeeded 全局→分屏迁移臂
//     （save() 在 Runner 恒走沙箱文件，生产三源零触碰）。
// 复审后仍留白部分（不属本批）：AppSoundPlayer 真实发声=C4；NSSound(named:)
// 系统音恒在、Bundle Sounds 资源仅装机有=装机态；save() 生产三源写臂与 load()
// 生产三源链=0.0.81 沙箱守卫本体（强提缝须写真实 plist，违反生产禁写红线），
// 归 C7-装机态，随本批入台账。

extension RunnerHarness {

    func runSoundScreenPrefsResidueTests() {
        let sound = SoundManager.shared
        let savedPrefs = sound.preferences
        defer {
            sound.updateSoundType(savedPrefs.soundType)
            sound.updateVolume(savedPrefs.volume)
            sound.updateMinPlayInterval(savedPrefs.minPlayIntervalSeconds)
            sound.updateQuietHours(enabled: savedPrefs.quietHoursEnabled,
                                   startHour: savedPrefs.quietStartHour,
                                   endHour: savedPrefs.quietEndHour)
            sound.stopPlayback()
        }
        let mockPlayer = MockSoundPlayer()
        sound.soundPlayer = mockPlayer

        // MARK: A. 节流臂——minInterval 内第二次完成音被抑制（只落日志不发声）
        // 注：套件前块（B249）已播过完成音，lastCompletionPlayedAt 有先验值——
        // 先以 interval 0（节流关闭）放行刷新节流基准，对先验状态免疫。
        sound.updateSoundType(.systemDefault)
        sound.updateMinPlayInterval(0)
        sound.playCompletionSound(projectName: nil)
        let playCountAfterFirst = mockPlayer.playCount
        check("soundResidue A1: 节流关闭（0）恒放行", playCountAfterFirst == 1)
        sound.updateMinPlayInterval(300)
        sound.playCompletionSound(projectName: nil)
        check("soundResidue A2: minInterval 内第二次被节流抑制（零新增播放）",
              mockPlayer.playCount == playCountAfterFirst)
        sound.updateMinPlayInterval(0)

        // MARK: B. 免打扰臂——构造恒含当前时刻的静音窗（start=当前小时，end=+1 mod 24，
        // h=23 时 23→0 走跨午夜语义仍命中），硬静音压过节流。
        let h = Calendar.current.component(.hour, from: Date())
        sound.updateQuietHours(enabled: true, startHour: h, endHour: (h + 1) % 24)
        sound.playCompletionSound(projectName: nil)
        check("soundResidue B1: 免打扰窗内完成音静音（零新增播放）",
              mockPlayer.playCount == playCountAfterFirst)
        sound.updateQuietHours(enabled: false,
                               startHour: savedPrefs.quietStartHour,
                               endHour: savedPrefs.quietEndHour)

        // MARK: C. resolve 失败臂——builtin 资源在 Runner 无 Sounds 目录，解析 nil 早退
        sound.updateSoundType(.builtinDing)
        sound.playCompletionSound(projectName: nil)
        check("soundResidue C1: bundled 资源缺失 → resolve 失败早退（零播放）",
              mockPlayer.playCount == playCountAfterFirst)

        // MARK: D. preview 失败臂——试听同走 resolve nil 早退（且不经过防打扰门）
        sound.previewSound(.builtinDing, volume: 0.5)
        check("soundResidue D1: preview 资源缺失 → 失败早退（零播放）",
              mockPlayer.playCount == playCountAfterFirst)

        // MARK: E. 5s 兜底停止身份校验——旧播放的兜底闭包不得掐断新播放
        // （多会话并发完成的真实竞态契约：两次播放用两个自定义文件保证 NSSound 实例身份不同）。
        let soundSource = "/System/Library/Sounds/Purr.aiff"
        if FileManager.default.fileExists(atPath: soundSource) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("vf-b312-sound-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pathA = dir.appendingPathComponent("a.aiff")
            let pathB = dir.appendingPathComponent("b.aiff")
            try? FileManager.default.copyItem(atPath: soundSource, toPath: pathA.path)
            try? FileManager.default.copyItem(atPath: soundSource, toPath: pathB.path)
            defer {
                try? FileManager.default.removeItem(at: dir)
                sound.updateCustomSoundPath(savedPrefs.customSoundPath)
            }

            sound.updateSoundType(.custom)
            // 全新 mock：先吸收性停机——清掉前块（A1）遗留的 currentSound+5s workitem，
            // 以此后的计数为基线（对套件先验播放态免疫）。
            let identityPlayer = MockSoundPlayer()
            sound.soundPlayer = identityPlayer
            sound.stopPlayback()
            let baselineStops = identityPlayer.stopCount
            sound.updateCustomSoundPath(pathA.path)
            sound.playCompletionSound(projectName: nil)
            check("soundResidue E1: 自定义文件播放一（实例 A）", identityPlayer.playCount == 1)
            sound.updateCustomSoundPath(pathB.path)
            sound.playCompletionSound(projectName: nil)
            // 第二次播放入口先同步停掉实例 A（互斥），随后 currentSound=B
            check("soundResidue E2: 互斥入口同步停 A（恰较基线 +1）",
              identityPlayer.stopCount == baselineStops + 1 && identityPlayer.playCount == 2)

            // 泵主 RunLoop 越过两个 5s 兜底拍：A 的兜底闭包身份校验失败（current 已是 B）
            // 不得停 B；B 的兜底闭包正常停机。broken 语义（无身份校验）会多停一次。
            RunLoop.main.run(until: Date().addingTimeInterval(6.5))
            check("soundResidue E3: 兜底拍后 B 恰被自身闭包停机（A 的旧闭包零误伤）",
              identityPlayer.stopCount == baselineStops + 2 && identityPlayer.playCount == 2)
        } else {
            check("soundResidue E0: 系统音源缺失，身份校验场景跳过", true)
        }

        // MARK: F. loadPreferences 缺数据/坏数据双臂（B312 提缝 internal，B248 标准）
        let prefsKey = "soundPreferences"
        let savedData = UserDefaults.standard.data(forKey: prefsKey)
        defer {
            if let savedData {
                UserDefaults.standard.set(savedData, forKey: prefsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: prefsKey)
            }
        }
        // 阳性对照：合法非默认偏好往返（证明下方两臂不是恒返 .default 的假绿）
        var positive = SoundPreferences.default
        positive.volume = 0.42
        UserDefaults.standard.set(try! JSONEncoder().encode(positive), forKey: prefsKey)
        check("soundResidue F1: 合法数据解码往返保真",
              SoundManager.loadPreferences() == positive)
        UserDefaults.standard.set(Data("not-json-garbage".utf8), forKey: prefsKey)
        check("soundResidue F2: 坏 JSON → 告警日志臂 + 回落 .default",
              SoundManager.loadPreferences() == .default)
        UserDefaults.standard.removeObject(forKey: prefsKey)
        check("soundResidue F3: 键缺失 → 缺数据臂 + 回落 .default",
              SoundManager.loadPreferences() == .default)

        // MARK: G. ScreenIndexPreferences 全局→分屏迁移臂（save 恒走沙箱）
        let sandboxFile = ScreenIndexPreferences.sandboxPreferencesURL
        let hadSandbox = FileManager.default.fileExists(atPath: sandboxFile.path)
        let sandboxSnapshot = try? Data(contentsOf: sandboxFile)
        defer {
            if hadSandbox, let sandboxSnapshot {
                try? sandboxSnapshot.write(to: sandboxFile)
            } else {
                try? FileManager.default.removeItem(at: sandboxFile)
            }
        }
        var legacyMode = ScreenIndexPreferences.default
        legacyMode.usePerScreenSpaceIndexing = false
        let migrated = ScreenIndexPreferences.enforcePerScreenSpaceIndexingIfNeeded(legacyMode)
        check("screenResidue G1: 全局模式被迁移为分屏模式",
              migrated.usePerScreenSpaceIndexing)
        let reread = ScreenIndexPreferences.load()
        check("screenResidue G2: 迁移臂内部 save 落沙箱且 load 读回（沙箱往返）",
              reread.usePerScreenSpaceIndexing)
        let unchanged = ScreenIndexPreferences.enforcePerScreenSpaceIndexingIfNeeded(.default)
        check("screenResidue G3: 已是分屏模式 → 守卫臂原样返回",
              unchanged.usePerScreenSpaceIndexing && unchanged.position == .topRight)
    }
}
