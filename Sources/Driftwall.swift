// Driftwall.app — a menu-bar app that plays any video you pick as your desktop
// wallpaper, looping forever. Turn it on/off, pause it, or change the video from
// the menu-bar icon.
import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let player = AVQueuePlayer()
    var looper: AVPlayerLooper?
    var windows: [NSWindow] = []
    var asleep = false
    var userPaused = false
    var statusItem: NSStatusItem!
    let defaults = UserDefaults.standard
    let fm = FileManager.default

    // Videos you pick are copied here so the wallpaper keeps working even if the
    // original file is moved or deleted.
    var storeDir: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftwall", isDirectory: true)
    }
    var videoURL: URL? {
        get { defaults.string(forKey: "videoPath").map { URL(fileURLWithPath: $0) } }
        set { defaults.set(newValue?.path, forKey: "videoPath") }
    }
    var videoName: String? {
        get { defaults.string(forKey: "videoName") }
        set { defaults.set(newValue, forKey: "videoName") }
    }
    var isOn: Bool {
        get { defaults.object(forKey: "isOn") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "isOn") }
    }
    var hasVideo: Bool { videoURL.map { fm.fileExists(atPath: $0.path) } ?? false }

    // MARK: launch
    func applicationDidFinishLaunching(_ n: Notification) {
        if Bundle.main.bundlePath.hasPrefix("/Volumes/") {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Move Driftwall to Applications first"
            a.informativeText = "Drag Driftwall into the Applications folder in this window, eject the disk image, then open it from Applications."
            a.runModal()
            NSApp.terminate(nil); return
        }

        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Driftwall"
        drawStatusIcon()
        startIconAnimation()
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                       object: nil, queue: .main) { [weak self] _ in
            guard let s = self, s.isOn, s.looper != nil else { return }
            s.buildWindows() }
        nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                       object: nil, queue: .main) { [weak self] _ in self?.updatePlayback() }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.asleep = true; self?.updatePlayback() }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.asleep = false; self?.updatePlayback() }
        }

        // First run: start at login by default, and reuse the video from the old version.
        if defaults.object(forKey: "didFirstRun") == nil {
            defaults.set(true, forKey: "didFirstRun")
            if #available(macOS 13.0, *) { try? SMAppService.mainApp.register() }
            let old = URL(fileURLWithPath: NSHomeDirectory() + "/Movies/LiveWallpaper/wallpaper.mp4")
            if !hasVideo, fm.fileExists(atPath: old.path) {
                importVideo(old, displayName: "wallpaper.mp4"); return
            }
        }

        if !hasVideo { chooseVideo() }
        else if isOn { turnOn() }
    }

    // MARK: wallpaper on/off
    func turnOn() {
        guard let url = videoURL, hasVideo else { chooseVideo(); return }
        isOn = true
        userPaused = false
        looper?.disableLooping()
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        buildWindows()
    }

    func turnOff() {
        isOn = false
        player.pause()
        looper?.disableLooping(); looper = nil
        player.removeAllItems()
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            w.setFrame(screen.frame, display: false)
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(layer)
            w.contentView = view
            w.orderFront(nil)
            return w
        }
        updatePlayback()
    }

    // Pause when the display sleeps, every screen is covered, or you chose Pause.
    func updatePlayback() {
        guard isOn, looper != nil else { player.pause(); return }
        let visible = windows.contains { $0.occlusionState.contains(.visible) }
        if asleep || userPaused || !visible { player.pause() } else { player.play() }
    }

    // MARK: animated menu-bar icon — the wave drifts slowly while playing
    var wavePhase: CGFloat = 0
    var iconTimer: Timer?
    var lastIconState = ""

    func startIconAnimation() {
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in self?.tickIcon() }
        RunLoop.main.add(t, forMode: .common)
        iconTimer = t
    }

    func tickIcon() {
        let on = isOn && looper != nil
        let playing = on && player.timeControlStatus == .playing
        if playing { wavePhase += 0.08 }   // slow, calm drift
        let state = "\(on)-\(playing)"
        if playing || state != lastIconState { drawStatusIcon() }
        lastIconState = state
    }

    func drawStatusIcon() {
        let on = isOn && looper != nil
        statusItem.button?.image = Self.statusIcon(phase: wavePhase, on: on)
        statusItem.button?.appearsDisabled = !on
    }

    static func statusIcon(phase: CGFloat, on: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            NSColor.black.set()
            // two gentle parallel waves (flat when off)
            let amp: CGFloat = on ? 1.4 : 0
            for base: CGFloat in [5, 11] {
                let path = NSBezierPath()
                path.lineWidth = 1.7
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                var x: CGFloat = 2
                path.move(to: NSPoint(x: x, y: base + amp * sin(x * 0.6 + phase)))
                while x < 18 {
                    x += 0.5
                    path.line(to: NSPoint(x: x, y: base + amp * sin(x * 0.6 + phase)))
                }
                path.stroke()
            }
            return true
        }
        img.isTemplate = true   // adapts to light/dark menu bar automatically
        return img
    }

    // MARK: choosing a video
    @objc func chooseVideo() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose a video for your wallpaper"
        panel.prompt = "Use as Wallpaper"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importVideo(url, displayName: url.lastPathComponent)
    }

    func importVideo(_ src: URL, displayName: String) {
        let dir = storeDir
        let ext = src.pathExtension.isEmpty ? "mp4" : src.pathExtension
        let dest = dir.appendingPathComponent("wallpaper-\(UUID().uuidString).\(ext)")
        let previous = videoURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var final = src
            do {
                try self.fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try self.fm.copyItem(at: src, to: dest)
                final = dest
            } catch { NSLog("Driftwall: couldn't copy video, using original: \(error)") }
            DispatchQueue.main.async {
                self.videoURL = final
                self.videoName = displayName
                self.turnOn()
                if let p = previous, p != final, p.path.hasPrefix(dir.path) {
                    try? self.fm.removeItem(at: p)
                }
            }
        }
    }

    // MARK: menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = hasVideo ? "Wallpaper: \(videoName ?? videoURL?.lastPathComponent ?? "video")"
                             : "No video chosen"
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let running = isOn && looper != nil
        add(menu, running ? "Turn Off Wallpaper" : "Turn On Wallpaper", #selector(toggleOn))
        if running {
            add(menu, userPaused ? "Resume Animation" : "Pause Animation", #selector(togglePause))
        }
        add(menu, "Choose Video…", #selector(chooseVideo))
        menu.addItem(.separator())

        if #available(macOS 13.0, *) {
            let item = add(menu, "Open at Login", #selector(toggleLogin))
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(.separator())
        }
        add(menu, "Quit Driftwall", #selector(quit), key: "q")
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc func toggleOn() { if isOn && looper != nil { turnOff() } else { turnOn() } }
    @objc func togglePause() { userPaused.toggle(); updatePlayback() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(); a.messageText = "Couldn't change the login setting"
            a.informativeText = error.localizedDescription; a.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar icon only, no Dock icon
app.run()
