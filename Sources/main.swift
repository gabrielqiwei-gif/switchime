// SwitchIME — macOS 菜单栏输入法轮换小工具
// 通过公开的 Text Input Sources (TIS) API 切换输入源，不依赖 Fn / 🌐 键，
// 不需要辅助功能权限，也不会被系统 Fn 键的 bug 影响。

import AppKit
import Carbon.HIToolbox

// MARK: - 常量

/// 界面文案统一走 Localizable.strings，跟随系统语言
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

var kAppName: String { L("app.name") }
let kVersion = "1.2"
let kLoginLabel = "com.weiqi.switchime"
let kDefaultHotkey = 0
let kPresetSchemaVersion = 2   // 1.1 起快捷键全部改为 Control 组合

// MARK: - 全局热键（Carbon，无需辅助功能权限）

struct HotkeyPreset {
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32
}

let kHotkeyPresets: [HotkeyPreset] = [
    HotkeyPreset(title: "⌃ `", keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(controlKey)),
    HotkeyPreset(title: "⌃ ⇧ `", keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(controlKey | shiftKey)),
    HotkeyPreset(title: "⌃ ⇧ Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey)),
    HotkeyPreset(title: "⌃ Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey)),
    HotkeyPreset(title: "⌃ 1", keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(controlKey)),
]

final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handlerInstalled = false
    var onTrigger: (() -> Void)?

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x49534B57), id: 1) // 'ISKW'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            hotKeyRef = nil
            NSLog("SwitchIME: 注册热键失败 status=\(status)")
            return false
        }
        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
            guard let event = event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hkID)
            guard err == noErr else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { HotKeyManager.shared.onTrigger?() }
            return noErr
        }

        let err = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handlerRef)
        handlerInstalled = (err == noErr)
    }
}

// MARK: - 开机自启（LaunchAgent）

enum LoginItem {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(kLoginLabel).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func set(_ enabled: Bool) {
        let fm = FileManager.default

        if enabled {
            let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
            let plist: [String: Any] = [
                "Label": kLoginLabel,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
            ]
            guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
            try? fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try data.write(to: plistURL)
            } catch {
                NSLog("SwitchIME: 写入 LaunchAgent 失败 \(error)")
            }
            // 登出/登录时 launchd 会自动加载 ~/Library/LaunchAgents，这里不必 bootstrap（避免立刻多开一个实例）
        } else {
            let uid = getuid()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["bootout", "gui/\(uid)", plistURL.path]
            try? task.run()
            task.waitUntilExit()
            try? fm.removeItem(at: plistURL)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var sources: [InputSourceInfo] = []
    private var current: InputSourceInfo?
    private var lastSeenID: String?
    private var pollTimer: Timer?
    private var cycleAnchor: String?   // 上一次成功切换到的输入法，当前输入法不在列表里时兜底
    private var hotkeyRegistered = false
    private let selfTestMode = CommandLine.arguments.contains("--self-test")

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0 != NSRunningApplication.current }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        menu.delegate = self
        statusItem.menu = menu

        refreshSources()
        updateTitle()

        // 1.1 起快捷键全部换成 Control 组合，旧版的 Option 预设不再沿用
        let defaults = UserDefaults.standard
        if (defaults.object(forKey: "hotkeyPresetSchema") as? Int ?? 0) < kPresetSchemaVersion {
            defaults.set(kDefaultHotkey, forKey: "hotkeyPreset")
            defaults.set(kPresetSchemaVersion, forKey: "hotkeyPresetSchema")
        }

        HotKeyManager.shared.onTrigger = { [weak self] in self?.cycle(direction: 1) }
        applyHotkey(presetIndex: defaults.object(forKey: "hotkeyPreset") as? Int ?? kDefaultHotkey,
                    reportFailure: true)

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.syncCurrentSource() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // 首次运行时重建一次 LaunchAgent，保证路径与当前 App 位置一致
        if LoginItem.isEnabled { LoginItem.set(true) }

        if CommandLine.arguments.contains("--show-menu") { showMenuForScreenshot() }

        if selfTestMode {
            NSLog("SwitchIME: self-test starting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.runSelfTest() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        HotKeyManager.shared.unregister()
    }

    // MARK: 输入法状态

    private func refreshSources() {
        sources = TIS.enabledSources()
    }

    private func syncCurrentSource() {
        guard let now = TIS.current() else { return }
        if now.id != lastSeenID {
            lastSeenID = now.id
            cycleAnchor = now.id
            refreshSources()      // 用户可能刚增删了输入法，标签要跟着更新
            current = now
            updateTitle()
        }
    }

    private func updateTitle() {
        guard let cur = current ?? TIS.current() else {
            statusItem.button?.title = "?"
            return
        }
        current = cur
        // 列表里的标签做过重名消解，优先用它
        let label = sources.first(where: { $0.id == cur.id })?.label ?? cur.label
        statusItem.button?.title = label
        statusItem.button?.toolTip = L("status.tooltip", cur.name)
    }

    /// 按 id 切换。输入源可能在菜单打开后被删除，所以每次都重新解析，
    /// 失败也只是返回错误码，不会崩溃。
    private func switchTo(_ id: String) {
        let status = TIS.select(id: id)
        guard status == noErr else {
            NSLog("SwitchIME: TISSelectInputSource 失败 status=\(status) target=\(id)")
            refreshSources()                 // 列表可能已经变了，立刻重新读一次
            if IsSecureEventInputEnabled() { showSecureInputWarning() }
            return
        }
        // 以系统实际生效的结果为准（输入法可能把模式做了归一化）
        if let now = TIS.current() {
            lastSeenID = now.id
            cycleAnchor = now.id
            current = now
        }
        updateTitle()
    }

    /// 按系统输入法菜单里的顺序轮换到下一个 / 上一个，到底后回到第一个
    private func cycle(direction: Int) {
        refreshSources()      // 每次按键都重新读列表：新增/删除输入法立刻生效
        guard !sources.isEmpty else { return }

        let nowID = TIS.current()?.id ?? lastSeenID
        let ids = sources.map { $0.id }
        guard let index = Cycler.nextIndex(current: nowID, anchor: cycleAnchor,
                                           ids: ids, direction: direction) else { return }
        switchTo(ids[index])
    }

    private func showSecureInputWarning() {
        let alert = NSAlert()
        alert.messageText = L("alert.secure.title")
        alert.informativeText = L("alert.secure.body")
        alert.addButton(withTitle: L("alert.ok"))
        alert.runModal()
    }

    // MARK: 热键设置

    private var hotkeyIndex: Int {
        UserDefaults.standard.object(forKey: "hotkeyPreset") as? Int ?? kDefaultHotkey
    }

    private func applyHotkey(presetIndex: Int, reportFailure: Bool) {
        let index = (0..<kHotkeyPresets.count).contains(presetIndex) ? presetIndex : kDefaultHotkey
        let preset = kHotkeyPresets[index]
        UserDefaults.standard.set(index, forKey: "hotkeyPreset")

        let ok = HotKeyManager.shared.register(keyCode: preset.keyCode, modifiers: preset.modifiers)
        hotkeyRegistered = ok
        if !ok && reportFailure && !selfTestMode {
            let alert = NSAlert()
            alert.messageText = L("alert.hotkey.title", preset.title)
            alert.informativeText = L("alert.hotkey.body")
            alert.addButton(withTitle: L("alert.ok"))
            alert.runModal()
        }
    }


    // MARK: 截图辅助（--show-menu，仅开发时用来拍 README 图）

    /// 把菜单弹出来停留 5 秒，方便外部用 screencapture 抓图
    private func showMenuForScreenshot() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            self.refreshSources()
            self.syncCurrentSource()
            self.rebuildMenu()

            // 菜单跟踪期间主队列不跑，必须用 Timer + .common 模式才能取消
            let closer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
                self?.menu.cancelTracking()
            }
            RunLoop.main.add(closer, forMode: .common)

            self.menu.popUp(positioning: nil,
                            at: NSPoint(x: 0, y: button.bounds.height + 6),
                            in: button)
            NSApp.terminate(nil)
        }
    }

    // MARK: 自检（--self-test，仅供构建后验证使用）

    private func runSelfTest() {
        var lines: [String] = []
        func log(_ s: String) { lines.append(s) }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.45)) }

        log("=== SwitchIME self-test v\(kVersion) ===")
        if let btn = statusItem.button, let win = btn.window {
            let f = win.frame
            let screen = NSScreen.main?.frame ?? .zero
            let visible = NSScreen.main?.visibleFrame ?? .zero
            let inMenuBar = f.maxY >= screen.maxY - 60 && f.minX >= 0 && f.maxY > visible.maxY
            log("statusItem: created, title=\(btn.title), frame=\(f), screen=\(screen), 在菜单栏内=\(inMenuBar)")
        } else {
            log("statusItem: FAILED (no button/window)")
        }
        log("activationPolicy: \(NSApp.activationPolicy() == .accessory ? "accessory (无 Dock 图标)" : "其他")")

        let startID = TIS.current()?.id
        log("hotkey \(kHotkeyPresets[hotkeyIndex].title) registered: \(hotkeyRegistered)")
        refreshSources()
        log("sources(\(sources.count)): " + sources.map { "\($0.label)=\($0.name)[\($0.id)]" }.joined(separator: " | "))
        log("current: \(startID ?? "nil")")

        var seq: [String] = []
        for _ in 0..<sources.count {
            cycle(direction: 1); settle()
            seq.append(TIS.current()?.id ?? "nil")
        }
        let names = seq.map { id in sources.first(where: { $0.id == id })?.name ?? id }
        log("顺序轮换 \(sources.count) 次: " + names.joined(separator: " -> "))
        log("转一圈回到起点: \(seq.last == startID ? "OK" : "FAIL")")

        var chain: [String?] = [startID]
        chain.append(contentsOf: seq.map { Optional($0) })
        var allChanged = true
        for i in 1..<chain.count where chain[i] == chain[i - 1] { allChanged = false }
        log("每一步都换成新输入法: \(allChanged ? "OK" : "FAIL")")

        cycle(direction: -1); settle()
        let backID = TIS.current()?.id
        log("逆序一步 -> \(sources.first(where: { $0.id == backID })?.name ?? "nil") : \(backID != startID ? "OK changed" : "FAIL unchanged")")

        if let startID = startID {
            _ = TIS.select(id: startID); settle()
            log("restored -> \(TIS.current()?.id ?? "nil") : \(TIS.current()?.id == startID ? "OK" : "FAIL")")
        }

        rebuildMenu()
        log("menu(\(menu.items.count)): " + menu.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: " / "))
        log("loginItem enabled: \(LoginItem.isEnabled)")

        let ok = lines.contains { $0.contains("FAIL") } == false
        log(ok ? "RESULT: PASS" : "RESULT: FAIL")

        let args = CommandLine.arguments
        var targets = ["/tmp/switchime-selftest.log"]
        if let i = args.firstIndex(of: "--log"), i + 1 < args.count { targets.insert(args[i + 1], at: 0) }
        let text = lines.joined(separator: "\n") + "\n"
        for path in targets {
            do { try text.write(toFile: path, atomically: true, encoding: .utf8) }
            catch { NSLog("SwitchIME: 写日志失败 \(path): \(error)") }
        }
        NSLog("SwitchIME: self-test done, terminating")
        exit(0)
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshSources()
        syncCurrentSource()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let curID = current?.id ?? TIS.current()?.id
        let curName = sources.first(where: { $0.id == curID })?.name ?? current?.name ?? L("menu.unknown")
        let header = NSMenuItem(title: L("menu.current", curName), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        let hotkeyTitle = kHotkeyPresets[hotkeyIndex].title
        let nextItem = NSMenuItem(title: L("menu.next"), action: #selector(nextAction), keyEquivalent: "")
        nextItem.target = self
        nextItem.toolTip = L("menu.next.tip", hotkeyTitle)
        menu.addItem(nextItem)

        let prevItem = NSMenuItem(title: L("menu.prev"), action: #selector(prevAction), keyEquivalent: "")
        prevItem.target = self
        menu.addItem(prevItem)

        menu.addItem(.separator())

        let listHeader = NSMenuItem(title: L("menu.all"), action: nil, keyEquivalent: "")
        listHeader.isEnabled = false
        menu.addItem(listHeader)

        for src in sources {
            let item = NSMenuItem(title: src.name, action: #selector(selectSourceAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = src.id
            item.state = (src.id == curID) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // 快捷键子菜单
        let hotkeyMenu = NSMenu()
        for (i, preset) in kHotkeyPresets.enumerated() {
            let item = NSMenuItem(title: preset.title, action: #selector(selectHotkeyAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = (i == hotkeyIndex) ? .on : .off
            hotkeyMenu.addItem(item)
        }
        let hotkeyParent = NSMenuItem(title: L("menu.hotkey"), action: nil, keyEquivalent: "")
        hotkeyParent.submenu = hotkeyMenu
        menu.addItem(hotkeyParent)

        let loginItem = NSMenuItem(title: L("menu.login"), action: #selector(toggleLoginItemAction), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: L("menu.about", kAppName), action: #selector(showAboutAction), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: 动作

    @objc private func nextAction() { cycle(direction: 1) }

    @objc private func prevAction() { cycle(direction: -1) }

    @objc private func selectSourceAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        refreshSources()
        if sources.contains(where: { $0.id == id }) { switchTo(id) }
    }

    @objc private func selectHotkeyAction(_ sender: NSMenuItem) {
        applyHotkey(presetIndex: sender.tag, reportFailure: true)
    }

    @objc private func toggleLoginItemAction() {
        LoginItem.set(!LoginItem.isEnabled)
    }

    @objc private func showAboutAction() {
        let alert = NSAlert()
        alert.messageText = "\(kAppName) \(kVersion)"
        alert.informativeText = L("about.body", kHotkeyPresets[hotkeyIndex].title)
        alert.addButton(withTitle: L("alert.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
