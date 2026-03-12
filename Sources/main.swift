import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation

// 全局日志函数
private func log(_ message: String) {
    NSLog("[VibeFocus] %@", message)
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    let logURL = URL(fileURLWithPath: "/tmp/vibefocus.log")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

private extension Notification.Name {
    static let hotKeyConfigurationDidChange = Notification.Name("HotKeyConfigurationDidChange")
}

struct HotKeyConflict: Equatable {
    let configuration: HotKeyConfiguration
    let reason: String
}

struct HotKeyConfiguration: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let userDefaultsKey = "hotKeyConfiguration"
    static let `default` = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    static let knownConflicts: [HotKeyConflict] = [
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)), reason: "与 Spotlight 冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey)), reason: "与 Finder 搜索冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey)), reason: "与应用切换器冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey | shiftKey)), reason: "与反向应用切换冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)), reason: "与退出应用冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey)), reason: "与关闭窗口冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey)), reason: "与最小化窗口冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey)), reason: "与隐藏应用冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | controlKey)), reason: "与许多应用的全屏快捷键冲突")
    ]

    var displayString: String {
        modifierDisplay + Self.displayKey(for: keyCode)
    }

    private var modifierDisplay: String {
        var output = ""
        if modifiers & UInt32(controlKey) != 0 { output += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { output += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { output += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { output += "⌘" }
        return output
    }

    func matches(event: NSEvent) -> Bool {
        UInt32(event.keyCode) == keyCode &&
        event.modifierFlags.intersection(.hotKeyRelevantFlags).carbonHotKeyModifiers == modifiers
    }

    static func from(event: NSEvent) -> HotKeyConfiguration? {
        let modifiers = event.modifierFlags.intersection(.hotKeyRelevantFlags).carbonHotKeyModifiers
        guard modifiers != 0 else {
            return nil
        }

        let keyCode = UInt32(event.keyCode)
        guard displayKey(for: keyCode) != "?" else {
            return nil
        }

        return HotKeyConfiguration(keyCode: keyCode, modifiers: modifiers)
    }

    static func displayKey(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case Int(kVK_ANSI_A): return "A"
        case Int(kVK_ANSI_B): return "B"
        case Int(kVK_ANSI_C): return "C"
        case Int(kVK_ANSI_D): return "D"
        case Int(kVK_ANSI_E): return "E"
        case Int(kVK_ANSI_F): return "F"
        case Int(kVK_ANSI_G): return "G"
        case Int(kVK_ANSI_H): return "H"
        case Int(kVK_ANSI_I): return "I"
        case Int(kVK_ANSI_J): return "J"
        case Int(kVK_ANSI_K): return "K"
        case Int(kVK_ANSI_L): return "L"
        case Int(kVK_ANSI_M): return "M"
        case Int(kVK_ANSI_N): return "N"
        case Int(kVK_ANSI_O): return "O"
        case Int(kVK_ANSI_P): return "P"
        case Int(kVK_ANSI_Q): return "Q"
        case Int(kVK_ANSI_R): return "R"
        case Int(kVK_ANSI_S): return "S"
        case Int(kVK_ANSI_T): return "T"
        case Int(kVK_ANSI_U): return "U"
        case Int(kVK_ANSI_V): return "V"
        case Int(kVK_ANSI_W): return "W"
        case Int(kVK_ANSI_X): return "X"
        case Int(kVK_ANSI_Y): return "Y"
        case Int(kVK_ANSI_Z): return "Z"
        case Int(kVK_ANSI_0): return "0"
        case Int(kVK_ANSI_1): return "1"
        case Int(kVK_ANSI_2): return "2"
        case Int(kVK_ANSI_3): return "3"
        case Int(kVK_ANSI_4): return "4"
        case Int(kVK_ANSI_5): return "5"
        case Int(kVK_ANSI_6): return "6"
        case Int(kVK_ANSI_7): return "7"
        case Int(kVK_ANSI_8): return "8"
        case Int(kVK_ANSI_9): return "9"
        case Int(kVK_Space): return "Space"
        case Int(kVK_Return): return "Return"
        case Int(kVK_Escape): return "Esc"
        case Int(kVK_Delete): return "Delete"
        case Int(kVK_ForwardDelete): return "Fn⌫"
        case Int(kVK_Tab): return "Tab"
        case Int(kVK_LeftArrow): return "←"
        case Int(kVK_RightArrow): return "→"
        case Int(kVK_UpArrow): return "↑"
        case Int(kVK_DownArrow): return "↓"
        case Int(kVK_F1): return "F1"
        case Int(kVK_F2): return "F2"
        case Int(kVK_F3): return "F3"
        case Int(kVK_F4): return "F4"
        case Int(kVK_F5): return "F5"
        case Int(kVK_F6): return "F6"
        case Int(kVK_F7): return "F7"
        case Int(kVK_F8): return "F8"
        case Int(kVK_F9): return "F9"
        case Int(kVK_F10): return "F10"
        case Int(kVK_F11): return "F11"
        case Int(kVK_F12): return "F12"
        default: return "?"
        }
    }
}

private extension NSEvent.ModifierFlags {
    static let hotKeyRelevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var carbonHotKeyModifiers: UInt32 {
        var result: UInt32 = 0
        if contains(.command) { result |= UInt32(cmdKey) }
        if contains(.option) { result |= UInt32(optionKey) }
        if contains(.control) { result |= UInt32(controlKey) }
        if contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

private final class ShortcutRecorderButton: NSButton {
    var displayedShortcut = HotKeyConfiguration.default.displayString {
        didSet { updateAppearance() }
    }
    var onShortcutCaptured: ((HotKeyConfiguration) -> Void)?
    private var isRecording = false {
        didSet { updateAppearance() }
    }

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func beginRecording() {
        isRecording = true
        NSApp.activate(ignoringOtherApps: true)
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        isRecording = false
        return result
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            return
        }

        guard let hotKey = HotKeyConfiguration.from(event: event) else {
            NSSound.beep()
            return
        }

        onShortcutCaptured?(hotKey)
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    private func updateAppearance() {
        title = isRecording ? "按下新的快捷键" : displayedShortcut
    }
}

private struct ShortcutRecorderView: NSViewRepresentable {
    let displayedShortcut: String
    let onShortcutCaptured: (HotKeyConfiguration) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.displayedShortcut = displayedShortcut
        button.onShortcutCaptured = onShortcutCaptured
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.displayedShortcut = displayedShortcut
        nsView.onShortcutCaptured = onShortcutCaptured
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var hotKeyManager: HotKeyManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VibeFocus")
                .font(.title2.weight(.semibold))

            Text("自定义菜单栏快捷键；录制后实时生效，并自动检测常见系统冲突。")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("当前快捷键")
                    Spacer()
                    Text(hotKeyManager.currentHotKey.displayString)
                        .font(.system(.body, design: .monospaced))
                }

                ShortcutRecorderView(displayedShortcut: hotKeyManager.currentHotKey.displayString) { hotKey in
                    hotKeyManager.applyShortcut(hotKey)
                }
                .frame(width: 220)

                HStack(spacing: 12) {
                    Button("恢复默认") {
                        hotKeyManager.resetToDefaultShortcut()
                    }

                    Text("默认：\(HotKeyConfiguration.default.displayString)")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(hotKeyManager.shortcutStatusMessage)
                .foregroundStyle(hotKeyManager.shortcutStatusIsError ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(20)
        .frame(width: 480, height: 260)
    }
}

@MainActor
private final class FocusableSettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let hostingController = NSHostingController(
            rootView: SettingsView()
                .environmentObject(HotKeyManager.shared)
        )

        let window = FocusableSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeFocus 设置"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.contentViewController = hostingController
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.center()
            window.orderFrontRegardless()
            window.makeMain()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - 主程序
@main
struct VibeFocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(HotKeyManager.shared)
        }
    }
}

// MARK: - App Delegate
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var toggleMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundleURL.path)")
        setupMenuBar()
        HotKeyManager.shared.setup()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenuLabels),
            name: .hotKeyConfigurationDidChange,
            object: nil
        )
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "VibeFocus"

        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        toggleMenuItem = toggleItem
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        refreshMenuLabels()
    }

    @objc private func refreshMenuLabels() {
        toggleMenuItem?.title = "Toggle (\(HotKeyManager.shared.currentHotKey.displayString))"
    }

    @objc private func toggle() {
        WindowManager.shared.toggle()
    }

    @objc private func openSettings() {
        DispatchQueue.main.async {
            SettingsWindowController.shared.show()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - HotKey Manager
@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    @Published private(set) var currentHotKey: HotKeyConfiguration
    @Published private(set) var shortcutStatusMessage = "当前快捷键已生效"
    @Published private(set) var shortcutStatusIsError = false

    private let hotkeySignature: OSType = 0x56424648
    private let hotkeyIdentifier: UInt32 = 1
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {
        currentHotKey = Self.loadStoredHotKey()
    }

    func setup() {
        installHandlerIfNeeded()
        registerHotKey()
        installFallbackMonitors()
    }

    private func installFallbackMonitors() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                _ = self?.handleFallbackEvent(event, source: "global")
            }
            log("Installed global fallback monitor")
        }

        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                _ = self?.handleFallbackEvent(event, source: "local")
                return event
            }
            log("Installed local fallback monitor")
        }
    }

    private func handleFallbackEvent(_ event: NSEvent, source: String) -> Bool {
        guard currentHotKey.matches(event: event) else {
            return false
        }

        log("Fallback hotkey \(currentHotKey.displayString) triggered from \(source)")
        WindowManager.shared.toggle()
        return true
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else {
                return OSStatus(eventNotHandledErr)
            }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            return manager.handleHotKeyEvent(eventRef)
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handlerRef
        )

        log("Install hotkey handler status: \(installStatus)")
    }

    private func registerHotKey() {
        if let hotKeyRef {
            let unregisterStatus = UnregisterEventHotKey(hotKeyRef)
            log("Unregister previous hotkey status: \(unregisterStatus)")
            self.hotKeyRef = nil
        }

        let hotKeyID = EventHotKeyID(signature: hotkeySignature, id: hotkeyIdentifier)
        let registerStatus = RegisterEventHotKey(
            currentHotKey.keyCode,
            currentHotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        shortcutStatusMessage = registerStatus == noErr
            ? "当前快捷键：\(currentHotKey.displayString)"
            : "快捷键注册失败：\(currentHotKey.displayString)"
        shortcutStatusIsError = registerStatus != noErr
        log("Register hotkey \(currentHotKey.displayString) status: \(registerStatus)")
    }

    private func handleHotKeyEvent(_ eventRef: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            log("Get hotkey event parameter failed: \(status)")
            return status
        }

        guard hotKeyID.signature == hotkeySignature, hotKeyID.id == hotkeyIdentifier else {
            return noErr
        }

        log("Hotkey \(currentHotKey.displayString) triggered")
        WindowManager.shared.toggle()
        return noErr
    }

    func applyShortcut(_ hotKey: HotKeyConfiguration) {
        if hotKey == currentHotKey {
            shortcutStatusMessage = "快捷键未变化：\(hotKey.displayString)"
            shortcutStatusIsError = false
            return
        }

        if let validationError = validate(hotKey) {
            shortcutStatusMessage = validationError
            shortcutStatusIsError = true
            NSSound.beep()
            return
        }

        let previousHotKey = currentHotKey
        currentHotKey = hotKey
        registerHotKey()

        if shortcutStatusIsError {
            currentHotKey = previousHotKey
            registerHotKey()
            shortcutStatusMessage = "快捷键已恢复为 \(currentHotKey.displayString)"
            shortcutStatusIsError = true
            NSSound.beep()
            return
        }

        saveStoredHotKey(hotKey)
        shortcutStatusMessage = "快捷键已更新：\(hotKey.displayString)"
        shortcutStatusIsError = false
        NotificationCenter.default.post(name: .hotKeyConfigurationDidChange, object: nil)
    }

    func resetToDefaultShortcut() {
        applyShortcut(.default)
    }

    private func validate(_ hotKey: HotKeyConfiguration) -> String? {
        if hotKey.modifiers & (UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)) == 0 {
            return "快捷键至少需要包含 ⌘ / ⌥ / ⌃ 之一"
        }

        if let conflict = HotKeyConfiguration.knownConflicts.first(where: { $0.configuration == hotKey }) {
            return "快捷键冲突：\(conflict.reason)"
        }

        return nil
    }

    private static func loadStoredHotKey() -> HotKeyConfiguration {
        guard let data = UserDefaults.standard.data(forKey: HotKeyConfiguration.userDefaultsKey),
              let hotKey = try? JSONDecoder().decode(HotKeyConfiguration.self, from: data) else {
            return .default
        }
        return hotKey
    }

    private func saveStoredHotKey(_ hotKey: HotKeyConfiguration) {
        guard let data = try? JSONEncoder().encode(hotKey) else {
            return
        }
        UserDefaults.standard.set(data, forKey: HotKeyConfiguration.userDefaultsKey)
    }
}

// MARK: - Window Manager
@MainActor
class WindowManager {
    static let shared = WindowManager()

    private let savedStatesKey = "savedWindowStates"
    private var windowElementsByStateID: [String: AXUIElement] = [:]
    private var lastWindowElement: AXUIElement?
    private var lastWindowToken: WindowToken?
    private var lastWindowFrame: CGRect?
    private var lastTargetFrame: CGRect?
    private var savedWindowStates: [SavedWindowState] = []
    private var didPromptForAccessibility = false
    private let frameTolerance: CGFloat = 10
    private let axWindowNumberAttribute = "AXWindowNumber"
    private let axFrameAttribute = "AXFrame"

    private struct WindowToken {
        let stateID: String
        let pid: pid_t
        let bundleIdentifier: String?
        let appName: String?
        let windowNumber: Int?
        let title: String?
    }

    private struct RectPayload: Codable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    private struct SavedWindowState: Codable {
        let id: String
        let pid: Int32
        let bundleIdentifier: String?
        let appName: String?
        let windowNumber: Int?
        let title: String?
        let originalFrame: RectPayload
        let targetFrame: RectPayload
        let savedAt: Date
    }

    private struct ScriptWindowSnapshot: Codable {
        let appName: String
        let title: String?
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        var frame: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    private init() {
        savedWindowStates = loadSavedWindowStates()
        if !savedWindowStates.isEmpty {
            log("Loaded persisted window states from disk: \(savedWindowStates.count)")
        }
    }

    func toggle() {
        if shouldRestoreCurrentWindow() {
            restore()
        } else {
            moveToMainScreen()
        }
    }

    private func moveToMainScreen() {
        log("=== MOVE TO MAIN SCREEN ===")
        let axTrusted = hasAccessibilityPermission()
        log("AX trusted = \(axTrusted)")

        if !axTrusted {
            moveToMainScreenViaSystemEvents()
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            log("No frontmost app")
            return
        }

        guard let windowAX = focusedWindow(for: frontApp.processIdentifier) else {
            log("Cannot get focused window")
            return
        }

        let windowNumber = windowNumber(for: windowAX)
        if windowNumber == nil {
            log("Window number unavailable; will use direct AX reference fallback")
        }
        let windowTitle = title(of: windowAX)
        let bundleIdentifier = frontApp.bundleIdentifier
        let appName = frontApp.localizedName

        guard let currentFrame = frame(of: windowAX) else {
            log("Cannot get current frame")
            return
        }

        guard isAttributeSettable(windowAX, attribute: kAXPositionAttribute) else {
            log("Window position is not settable")
            return
        }

        guard isAttributeSettable(windowAX, attribute: kAXSizeAttribute) else {
            log("Window size is not settable")
            return
        }

        guard let mainScreen = getMainScreen() else {
            log("Cannot get main screen")
            return
        }

        let targetFrame = axFrame(forVisibleFrameOf: mainScreen)
        log("Current window: pid=\(frontApp.processIdentifier), number=\(String(describing: windowNumber)), title=\(windowTitle ?? "nil"), frame=\(currentFrame)")
        log("Target screen visible frame: \(mainScreen.visibleFrame)")
        log("Target AX frame: \(targetFrame)")

        AXUIElementPerformAction(windowAX, kAXRaiseAction as CFString)

        guard apply(frame: targetFrame, to: windowAX) else {
            log("❌ MOVE FAILED")
            return
        }

        guard let appliedFrame = frame(of: windowAX) else {
            log("❌ MOVE FAILED: cannot read back frame")
            return
        }

        log("Applied frame: \(appliedFrame)")

        guard framesMatch(appliedFrame, targetFrame) else {
            log("❌ MOVE FAILED: verification mismatch")
            return
        }

        let savedState = SavedWindowState(
            id: UUID().uuidString,
            pid: frontApp.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowNumber: windowNumber,
            title: windowTitle,
            originalFrame: RectPayload(currentFrame),
            targetFrame: RectPayload(targetFrame),
            savedAt: Date()
        )

        let persistedState = saveWindowState(savedState, window: windowAX)
        hydrateMemory(from: persistedState, window: windowAX)
        log("✅ MOVED AND MAXIMIZED ON TARGET SCREEN")
    }

    private func restore() {
        log("=== RESTORE ===")

        if !hasAccessibilityPermission() {
            restoreViaSystemEvents()
            return
        }

        if lastWindowToken == nil || lastWindowFrame == nil || lastTargetFrame == nil {
            if shouldRestoreCurrentWindow() == false {
                log("No saved window to restore")
                return
            }
        }

        guard let token = lastWindowToken, let frame = lastWindowFrame else {
            log("No active window state to restore")
            return
        }

        guard let window = restoreWindow(using: token) else {
            log("Window not found")
            return
        }

        guard isAttributeSettable(window, attribute: kAXPositionAttribute) else {
            log("Window position is not settable")
            return
        }

        guard isAttributeSettable(window, attribute: kAXSizeAttribute) else {
            log("Window size is not settable")
            return
        }

        log("Restoring to: \(frame)")

        guard apply(frame: frame, to: window) else {
            log("❌ RESTORE FAILED")
            return
        }

        guard let restoredFrame = self.frame(of: window) else {
            log("❌ RESTORE FAILED: cannot read back frame")
            return
        }

        log("Restored frame: \(restoredFrame)")

        guard framesMatch(restoredFrame, frame) else {
            log("❌ RESTORE FAILED: verification mismatch")
            return
        }

        resetActiveWindowContext(removeState: true)
        log("✅ RESTORED")
    }

    private func getMainScreen() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if let value = screen.deviceDescription[key] as? NSNumber,
               CGDirectDisplayID(value.uint32Value) == mainDisplayID {
                return screen
            }
        }
        return NSScreen.screens.first ?? NSScreen.main
    }

    private func hasAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func notifyAccessibilityPermissionRequired() {
        guard !didPromptForAccessibility else {
            return
        }

        didPromptForAccessibility = true
        NSSound.beep()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func shouldRestoreCurrentWindow() -> Bool {
        if !hasAccessibilityPermission() {
            return shouldRestoreCurrentWindowViaSystemEvents()
        }

        guard !savedWindowStates.isEmpty,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              let focusedWindow = focusedWindow(for: frontApp.processIdentifier),
              let currentFrame = frame(of: focusedWindow) else {
            return false
        }

        guard let matchedState = matchingSavedState(
            for: frontApp,
            window: focusedWindow,
            currentFrame: currentFrame
        ) else {
            return false
        }

        hydrateMemory(from: matchedState, window: focusedWindow)
        log("Detected moved window state for current AX window: \(matchedState.id)")
        return true
    }

    private func focusedWindow(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard status == .success, let windowRef else {
            return nil
        }
        return (windowRef as! AXUIElement)
    }

    private func restoreWindow(using token: WindowToken) -> AXUIElement? {
        if let lastWindowElement, frame(of: lastWindowElement) != nil {
            log("Restoring using saved AX window reference")
            return lastWindowElement
        }

        if let savedWindow = windowElementsByStateID[token.stateID], frame(of: savedWindow) != nil {
            log("Restoring using cached window reference for state \(token.stateID)")
            return savedWindow
        }

        for app in candidateApplications(for: token) {
            if let window = restoreWindow(in: app, using: token) {
                return window
            }
        }

        if let focused = focusedWindow(for: token.pid) {
            log("Restoring using focused window fallback")
            return focused
        }

        return nil
    }

    private func matchingSavedState(
        for app: NSRunningApplication,
        window: AXUIElement,
        currentFrame: CGRect
    ) -> SavedWindowState? {
        let currentWindowNumber = windowNumber(for: window)
        let currentTitle = title(of: window)

        for state in savedWindowStates.reversed() {
            if let cachedWindow = windowElementsByStateID[state.id],
               CFEqual(cachedWindow, window),
               framesMatch(currentFrame, state.targetFrame.cgRect) {
                return state
            }
        }

        return savedWindowStates.reversed().first { state in
            framesMatch(currentFrame, state.targetFrame.cgRect) &&
            stateMatchesIdentity(
                state,
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                appName: app.localizedName,
                windowNumber: currentWindowNumber,
                title: currentTitle
            )
        }
    }

    private func matchingSavedState(
        for app: NSRunningApplication,
        snapshot: ScriptWindowSnapshot
    ) -> SavedWindowState? {
        return savedWindowStates.reversed().first { state in
            framesMatch(snapshot.frame, state.targetFrame.cgRect) &&
            stateMatchesIdentity(
                state,
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                appName: app.localizedName ?? snapshot.appName,
                windowNumber: nil,
                title: snapshot.title
            )
        }
    }

    private func stateMatchesIdentity(
        _ state: SavedWindowState,
        pid: pid_t,
        bundleIdentifier: String?,
        appName: String?,
        windowNumber: Int?,
        title: String?
    ) -> Bool {
        if let stateBundle = state.bundleIdentifier,
           let bundleIdentifier,
           stateBundle != bundleIdentifier {
            return false
        }

        if let stateAppName = state.appName,
           let appName,
           state.bundleIdentifier == nil,
           stateAppName != appName {
            return false
        }

        if let stateWindowNumber = state.windowNumber,
           let windowNumber {
            return stateWindowNumber == windowNumber
        }

        if let stateTitle = normalizedTitle(state.title),
           let title = normalizedTitle(title) {
            return stateTitle == title
        }

        return state.pid == pid
    }

    private func candidateApplications(for token: WindowToken) -> [NSRunningApplication] {
        var applications: [NSRunningApplication] = []

        func appendIfNeeded(_ app: NSRunningApplication?) {
            guard let app else { return }
            if !applications.contains(where: { $0.processIdentifier == app.processIdentifier }) {
                applications.append(app)
            }
        }

        appendIfNeeded(NSRunningApplication(processIdentifier: token.pid))

        if let bundleIdentifier = token.bundleIdentifier {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
                appendIfNeeded(app)
            }
        }

        if let appName = token.appName {
            for app in NSWorkspace.shared.runningApplications where app.localizedName == appName {
                appendIfNeeded(app)
            }
        }

        appendIfNeeded(NSWorkspace.shared.frontmostApplication)
        return applications
    }

    private func moveToMainScreenViaSystemEvents() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            log("No frontmost app for System Events fallback")
            return
        }

        guard let snapshot = systemEventsSnapshot(forPID: frontApp.processIdentifier) else {
            log("System Events fallback could not read front window")
            notifyAccessibilityPermissionRequired()
            return
        }

        guard let mainScreen = getMainScreen() else {
            log("Cannot get main screen for System Events fallback")
            return
        }

        let targetFrame = axFrame(forVisibleFrameOf: mainScreen)
        let bundleIdentifier = frontApp.bundleIdentifier
        let appName = frontApp.localizedName ?? snapshot.appName
        let savedState = SavedWindowState(
            id: UUID().uuidString,
            pid: frontApp.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowNumber: nil,
            title: snapshot.title,
            originalFrame: RectPayload(snapshot.frame),
            targetFrame: RectPayload(targetFrame),
            savedAt: Date()
        )

        log("System Events snapshot frame: \(snapshot.frame)")
        log("System Events target frame: \(targetFrame)")

        guard systemEventsApply(frame: targetFrame, toPID: frontApp.processIdentifier) else {
            log("System Events fallback failed to move window")
            return
        }

        let persistedState = saveWindowState(savedState)
        hydrateMemory(from: persistedState, window: nil)
        log("✅ MOVED WITH SYSTEM EVENTS FALLBACK")
    }

    private func restoreViaSystemEvents() {
        if lastWindowToken == nil || lastWindowFrame == nil || lastTargetFrame == nil {
            if shouldRestoreCurrentWindowViaSystemEvents() == false {
                log("No saved window to restore via System Events")
                return
            }
        }

        guard let token = lastWindowToken, let frame = lastWindowFrame else {
            log("No active window state to restore via System Events")
            return
        }

        for app in candidateApplications(for: token) {
            guard let snapshot = systemEventsSnapshot(forPID: app.processIdentifier) else {
                continue
            }

            if let targetFrame = lastTargetFrame, framesMatch(snapshot.frame, targetFrame) {
                log("Restoring with System Events using target frame match")
                guard systemEventsApply(frame: frame, toPID: app.processIdentifier) else {
                    log("System Events fallback failed to restore window")
                    return
                }

                resetActiveWindowContext(removeState: true)
                log("✅ RESTORED WITH SYSTEM EVENTS FALLBACK")
                return
            }
        }

        log("System Events fallback could not find moved window to restore")
    }

    private func shouldRestoreCurrentWindowViaSystemEvents() -> Bool {
        guard !savedWindowStates.isEmpty,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              let snapshot = systemEventsSnapshot(forPID: frontApp.processIdentifier) else {
            return false
        }

        guard let matchedState = matchingSavedState(
            for: frontApp,
            snapshot: snapshot
        ) else {
            return false
        }

        hydrateMemory(from: matchedState, window: nil)
        log("Detected moved window state via System Events: \(matchedState.id)")
        return true
    }

    private func restoreWindow(in app: NSRunningApplication, using token: WindowToken) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        let windowsStatus = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard windowsStatus == .success, let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        if let windowNumber = token.windowNumber {
            for window in windows where self.windowNumber(for: window) == windowNumber {
                log("Restoring using window number match")
                return window
            }
        }

        if let targetFrame = lastTargetFrame {
            for window in windows {
                if let currentFrame = frame(of: window), framesMatch(currentFrame, targetFrame) {
                    if let title = token.title {
                        let currentTitle = self.title(of: window)
                        if currentTitle == title {
                            log("Restoring using target frame + title match")
                            return window
                        }
                    } else {
                        log("Restoring using target frame match")
                        return window
                    }
                }
            }
        }

        if let title = token.title {
            for window in windows where self.title(of: window) == title {
                log("Restoring using title match")
                return window
            }
        }

        return nil
    }

    private func systemEventsSnapshot(forPID pid: pid_t) -> ScriptWindowSnapshot? {
        let script = """
        const se = Application('System Events');
        const pid = \(pid);
        const proc = se.applicationProcesses.whose({ unixId: pid })[0];
        if (!proc) throw new Error('NO_PROCESS');
        const win = proc.windows[0];
        if (!win) throw new Error('NO_WINDOW');
        JSON.stringify({
          appName: proc.name(),
          title: (() => { try { return win.name(); } catch (_) { return ""; } })(),
          x: win.position()[0],
          y: win.position()[1],
          width: win.size()[0],
          height: win.size()[1]
        });
        """

        guard let output = runJXAScript(script),
              let data = output.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(ScriptWindowSnapshot.self, from: data) else {
            return nil
        }

        return snapshot
    }

    private func systemEventsApply(frame targetFrame: CGRect, toPID pid: pid_t) -> Bool {
        let script = """
        const se = Application('System Events');
        const pid = \(pid);
        const proc = se.applicationProcesses.whose({ unixId: pid })[0];
        if (!proc) throw new Error('NO_PROCESS');
        const win = proc.windows[0];
        if (!win) throw new Error('NO_WINDOW');
        win.position = [\(Int(targetFrame.origin.x.rounded())), \(Int(targetFrame.origin.y.rounded()))];
        win.size = [\(Int(targetFrame.width.rounded())), \(Int(targetFrame.height.rounded()))];
        JSON.stringify({
          appName: proc.name(),
          title: (() => { try { return win.name(); } catch (_) { return ""; } })(),
          x: win.position()[0],
          y: win.position()[1],
          width: win.size()[0],
          height: win.size()[1]
        });
        """

        guard let output = runJXAScript(script),
              let data = output.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(ScriptWindowSnapshot.self, from: data) else {
            return false
        }

        return framesMatch(snapshot.frame, targetFrame)
    }

    private func runJXAScript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            log("Failed to launch osascript: \(error.localizedDescription)")
            return nil
        }

        if let data = script.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        try? inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errorText = String(data: errorData, encoding: .utf8) ?? "unknown error"
            log("osascript failed: \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
            return nil
        }

        return String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func windowNumber(for window: AXUIElement) -> Int? {
        var numberRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, axWindowNumberAttribute as CFString, &numberRef)
        guard status == .success, let number = numberRef as? NSNumber else {
            return nil
        }
        return number.intValue
    }

    private func title(of window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        guard status == .success else {
            return nil
        }
        return titleRef as? String
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var frameRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, axFrameAttribute as CFString, &frameRef)
        guard status == .success, let frameRef else {
            return nil
        }

        let axValue = frameRef as! AXValue
        var frame = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &frame) else {
            return nil
        }
        return frame
    }

    private func isAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        if status != .success {
            log("Settable check failed for \(attribute): \(status.rawValue)")
            return false
        }
        return settable.boolValue
    }

    private func apply(frame targetFrame: CGRect, to window: AXUIElement) -> Bool {
        for attempt in 1...6 {
            var targetSize = CGSize(width: targetFrame.width, height: targetFrame.height)
            guard let sizeValue = AXValueCreate(.cgSize, &targetSize) else {
                return false
            }

            let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            log("Set size result [attempt \(attempt)]: \(sizeResult.rawValue)")
            guard sizeResult == .success else {
                return false
            }

            var targetOrigin = CGPoint(x: targetFrame.origin.x, y: targetFrame.origin.y)
            guard let originValue = AXValueCreate(.cgPoint, &targetOrigin) else {
                return false
            }

            let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
            log("Set position result [attempt \(attempt)]: \(positionResult.rawValue)")
            guard positionResult == .success else {
                return false
            }

            usleep(80_000)

            if let appliedFrame = frame(of: window) {
                log("Applied frame after attempt \(attempt): \(appliedFrame)")
                if framesMatch(appliedFrame, targetFrame) {
                    return true
                }
            }
        }

        return false
    }

    private func axFrame(forVisibleFrameOf screen: NSScreen) -> CGRect {
        let visibleFrame = screen.visibleFrame
        let zeroScreenMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CGRect(
            x: visibleFrame.origin.x,
            y: zeroScreenMaxY - visibleFrame.maxY,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= frameTolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= frameTolerance &&
        abs(lhs.width - rhs.width) <= frameTolerance &&
        abs(lhs.height - rhs.height) <= frameTolerance
    }

    @discardableResult
    private func saveWindowState(_ state: SavedWindowState, window: AXUIElement? = nil) -> SavedWindowState {
        savedWindowStates.removeAll { existing in
            shouldReplaceSavedState(existing, with: state, currentWindow: window)
        }
        savedWindowStates.append(state)
        savedWindowStates.sort { $0.savedAt < $1.savedAt }

        if let window {
            windowElementsByStateID[state.id] = window
        }

        persistSavedWindowStates()
        log("Persisted window states to UserDefaults: \(savedWindowStates.count)")
        return state
    }

    private func loadSavedWindowStates() -> [SavedWindowState] {
        guard let data = UserDefaults.standard.data(forKey: savedStatesKey),
              let states = try? JSONDecoder().decode([SavedWindowState].self, from: data) else {
            return []
        }
        return states
    }

    private func persistSavedWindowStates() {
        guard let data = try? JSONEncoder().encode(savedWindowStates) else {
            log("Failed to encode saved window states")
            return
        }
        UserDefaults.standard.set(data, forKey: savedStatesKey)
    }

    private func clearSavedWindowState(id: String?) {
        guard let id else { return }
        savedWindowStates.removeAll { $0.id == id }
        windowElementsByStateID.removeValue(forKey: id)
        persistSavedWindowStates()
        log("Cleared persisted window state: \(id)")
    }

    private func resetActiveWindowContext(removeState: Bool) {
        let activeStateID = lastWindowToken?.stateID
        lastWindowElement = nil
        lastWindowToken = nil
        lastWindowFrame = nil
        lastTargetFrame = nil
        if removeState {
            clearSavedWindowState(id: activeStateID)
        }
    }

    private func hydrateMemory(from state: SavedWindowState, window: AXUIElement?) {
        lastWindowElement = window ?? windowElementsByStateID[state.id]
        lastWindowToken = WindowToken(
            stateID: state.id,
            pid: state.pid,
            bundleIdentifier: state.bundleIdentifier,
            appName: state.appName,
            windowNumber: state.windowNumber,
            title: state.title
        )
        lastWindowFrame = state.originalFrame.cgRect
        lastTargetFrame = state.targetFrame.cgRect
    }

    private func shouldReplaceSavedState(
        _ existing: SavedWindowState,
        with incoming: SavedWindowState,
        currentWindow: AXUIElement?
    ) -> Bool {
        if existing.id == incoming.id {
            return true
        }

        if let currentWindow,
           let cachedWindow = windowElementsByStateID[existing.id],
           CFEqual(cachedWindow, currentWindow) {
            return true
        }

        if let existingBundle = existing.bundleIdentifier,
           let incomingBundle = incoming.bundleIdentifier,
           existingBundle != incomingBundle {
            return false
        }

        if let existingNumber = existing.windowNumber,
           let incomingNumber = incoming.windowNumber {
            return existingNumber == incomingNumber
        }

        if let existingTitle = normalizedTitle(existing.title),
           let incomingTitle = normalizedTitle(incoming.title),
           existingTitle == incomingTitle {
            if existing.bundleIdentifier == incoming.bundleIdentifier || existing.appName == incoming.appName {
                return framesMatch(existing.originalFrame.cgRect, incoming.originalFrame.cgRect) ||
                    framesMatch(existing.targetFrame.cgRect, incoming.targetFrame.cgRect)
            }
        }

        return false
    }

    private func normalizedTitle(_ title: String?) -> String? {
        guard let title else {
            return nil
        }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
