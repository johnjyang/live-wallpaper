import AppKit
import AVFoundation
import Darwin

final class VideoView: NSView {
    let video = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        video.videoGravity = .resizeAspectFill
        layer?.addSublayer(video)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
    }
}

final class VideoSession {
    let id: String
    let player = AVQueuePlayer()
    let looper: AVPlayerLooper
    let rate: Float = 1
    var playing = false
    var onLoop: (() -> Void)?
    private var loopObservation: NSKeyValueObservation?
    init(id: String, url: URL) {
        self.id = id
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        loopObservation = looper.observe(\.loopCount, options: [.new]) { [weak self] _, change in
            guard (change.newValue ?? 0) > 0 else { return }
            DispatchQueue.main.async { self?.onLoop?() }
        }
    }
    func setPlaying(_ value: Bool) {
        guard playing != value else { return }
        playing = value
        if value { player.playImmediately(atRate: rate) } else { player.pause() }
    }
    deinit { loopObservation?.invalidate(); player.pause(); looper.disableLooping(); player.removeAllItems() }
}

final class Surface {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let displayUUID: String
    let window: NSWindow
    let view: VideoView
    var session: VideoSession?
    var wantsPlayback = false
    var coverage = 0.0
    var reason = "No aerial selected"
    var shuffleChoice: ShuffleChoice?
    var onReady: (() -> Void)?
    private var readyObservation: NSKeyValueObservation?
    init(screen: NSScreen) {
        self.screen = screen
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        displayUUID = CGDisplayCreateUUIDFromDisplayID(displayID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
        view = VideoView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.animationBehavior = .none
        window.setFrame(screen.frame, display: true)
    }
    func attach(_ session: VideoSession?) {
        guard self.session !== session else { return }
        self.session = session
        wantsPlayback = false
        readyObservation?.invalidate()
        readyObservation = view.video.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.onReady?() }
        }
        view.video.player = session?.player
        if session == nil { window.orderOut(nil) }
    }
    func close() { readyObservation?.invalidate(); window.orderOut(nil); view.video.player = nil; session = nil; window.close() }
}

final class DirectoryWatch {
    private let source: DispatchSourceFileSystemObject
    init?(_ url: URL, changed: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler(handler: changed)
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }
    deinit { source.cancel() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private final class ShuffleState {
        var bag = ShuffleBag()
        var changedAt = Date()
        var advance = false
    }
    private let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveWallpaper")
    private let wallpaper = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper")
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var surfaces: [Surface] = []
    private var sessions: [String: VideoSession] = [:]
    private var watches: [DirectoryWatch] = []
    private var refreshWork: DispatchWorkItem?
    private var visibilityTimer: Timer?
    private var statusTimer: Timer?
    private var locked = false
    private var sleeping = false
    private var inactive = false
    private var screenSaver = false
    private var previousRects: [CGRect] = []
    private var previousBounds: [CGRect] = []
    private var started = Date()
    private var metadataQueries = 0
    private var sourceRefreshes = 0
    private var lastMetadataMS = 0.0
    private var logHandle: FileHandle?
    private var names: [String: String] = [:]
    private var catalog = AerialCatalog([:])
    private var shuffles: [ShuffleChoice: ShuffleState] = [:]
    private var shuffleTimer: Timer?
    private var shuffleDeadline: Date?
    private var mode: PlaybackMode {
        get { PlaybackMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .visible }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch should not leave two independent decoders running.
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.local.LiveWallpaper")
        let myLaunch = NSRunningApplication.current.launchDate ?? Date()
        if peers.contains(where: { $0.processIdentifier != getpid() && ($0.launchDate ?? Date()) < myLaunch }) {
            NSApp.terminate(nil); return
        }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let log = support.appendingPathComponent("events.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        logHandle = try? FileHandle(forWritingTo: log); _ = try? logHandle?.seekToEnd()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "Live Wallpaper")
        statusItem.button?.toolTip = "Live Wallpaper — follows Apple’s wallpaper selection"
        buildMenu()
        for path in ["Store", "aerials/videos", "aerials/manifest"] {
            if let watch = DirectoryWatch(wallpaper.appendingPathComponent(path), changed: { [weak self] in self?.scheduleRefresh() }) { watches.append(watch) }
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                  NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                  NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(self, selector: #selector(workspaceChanged(_:)), name: n, object: nil)
        }
        // Pause during lock/screen saver without changing their normal behavior.
        for n in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "com.apple.screensaver.didstart", "com.apple.screensaver.didstop"] {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(distributedChanged(_:)), name: NSNotification.Name(n), object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(control(_:)), name: .init("com.local.LiveWallpaper.control"), object: nil)
        // Diagnostic snapshot is tiny and infrequent. No video frames are copied.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.writeStatus() }
        statusTimer?.tolerance = 3
        screensChanged()
        logEvent("Started in \(mode.rawValue) mode")
    }

    @objc private func screensChanged() {
        for s in surfaces { s.close() }
        surfaces = NSScreen.screens.map(Surface.init)
        for surface in surfaces { surface.onReady = { [weak self] in self?.updateVisibility(); self?.writeStatus() } }
        previousBounds = []
        refresh()
    }

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func currentSpaces() -> [String: String] {
        let config = UserDefaults(suiteName: "com.apple.spaces")?.dictionary(forKey: "SpacesDisplayConfiguration")
        let management = config?["Management Data"] as? [String: Any]
        let monitors = management?["Monitors"] as? [[String: Any]] ?? []
        var result: [String: String] = [:]
        for m in monitors {
            if let display = m["Display Identifier"] as? String, let space = (m["Current Space"] as? [String: Any])?["uuid"] as? String { result[display] = space }
        }
        return result
    }

    private func refresh() {
        sourceRefreshes += 1
        guard let data = try? Data(contentsOf: wallpaper.appendingPathComponent("Store/Index.plist")),
              let store = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            // Atomic replacements can briefly race a read. Keep the last valid scene.
            return
        }
        let manifestURL = wallpaper.appendingPathComponent("aerials/manifest/entries.json")
        if let data = try? Data(contentsOf: manifestURL), let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           manifest["assets"] is [[String: Any]] {
            catalog = AerialCatalog(manifest)
            names = Dictionary(catalog.assets.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
        let spaces = currentSpaces()
        var used: Set<String> = []
        var usedShuffles: Set<ShuffleChoice> = []
        var resolvedShuffles: [ShuffleChoice: String] = [:]
        for surface in surfaces {
            let space = spaces[surface.displayUUID] ?? spaces["Main"]
            let selection = WallpaperStore.selection(in: store, display: surface.displayUUID, space: space, categoryIDs: catalog.categoryIDs)
            surface.shuffleChoice = nil
            let id: String
            let url: URL
            switch selection {
            case .aerial(let assetID):
                id = assetID
                url = wallpaper.appendingPathComponent("aerials/videos/\(id).mov")
            case .shuffle(let choice):
                surface.shuffleChoice = choice
                usedShuffles.insert(choice)
                if let resolved = resolvedShuffles[choice] { id = resolved }
                else {
                    let state = shuffles[choice] ?? ShuffleState()
                    shuffles[choice] = state
                    let candidates = catalog.candidates(for: choice) { assetID in
                        FileManager.default.fileExists(atPath: self.wallpaper.appendingPathComponent("aerials/videos/\(assetID).mov").path)
                    }
                    let now = Date()
                    let due = choice.cadence.deadline(after: state.changedAt).map { now >= $0 } ?? false
                    let advance = state.advance || due
                    let previous = state.bag.current
                    guard let selected = state.bag.select(from: candidates, advance: advance) else {
                        surface.attach(nil); surface.reason = "No downloaded videos in selected shuffle collection"; continue
                    }
                    state.advance = false
                    if advance || previous != selected { state.changedAt = now }
                    id = selected
                    resolvedShuffles[choice] = selected
                }
                url = wallpaper.appendingPathComponent("aerials/videos/\(id).mov")
            case .systemDefault:
                guard let bundled = BundledDefault.video() else {
                    surface.attach(nil)
                    surface.reason = "System default has no unambiguous bundled video"
                    continue
                }
                id = "system-default"
                url = bundled
                names[id] = "\(url.deletingPathExtension().lastPathComponent) (system default)"
            case .other, .unavailable:
                surface.attach(nil)
                surface.reason = selection == .other ? "Apple still/dynamic wallpaper — normal macOS behavior" : "Unsupported aerial selection or shuffle interval"
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                surface.attach(nil); surface.reason = "Waiting for \(names[id] ?? id) to finish downloading"; continue
            }
            let session = sessions[id] ?? VideoSession(id: id, url: url)
            session.onLoop = { [weak self, weak session] in
                guard let self, let session, self.sessions[id] === session else { return }
                self.advanceShuffles(finishedID: id)
            }
            sessions[id] = session; used.insert(id)
            if surface.session !== session { logEvent("\(surface.screen.localizedName): selected \(names[id] ?? id)") }
            surface.attach(session)
            surface.reason = names[id] ?? id
        }
        sessions = sessions.filter { used.contains($0.key) }
        shuffles = shuffles.filter { usedShuffles.contains($0.key) }
        updateVisibility(force: true)
        configureTimer()
        buildMenu()
        writeStatus()
    }

    private func advanceShuffles(finishedID: String? = nil) {
        let choices = Set(surfaces.compactMap { surface -> ShuffleChoice? in
            guard let choice = surface.shuffleChoice else { return nil }
            if let finishedID {
                guard choice.cadence == .continuously, surface.session?.id == finishedID, surface.wantsPlayback else { return nil }
            }
            return choice
        })
        guard !choices.isEmpty else { return }
        for choice in choices { shuffles[choice]?.advance = true }
        refresh()
    }

    private func configureShuffleTimer() {
        let active = Set(surfaces.filter(\.wantsPlayback).compactMap(\.shuffleChoice))
        let deadline = active.compactMap { choice in shuffles[choice].flatMap { choice.cadence.deadline(after: $0.changedAt) } }.min()
        guard deadline != shuffleDeadline else { return }
        shuffleTimer?.invalidate(); shuffleTimer = nil; shuffleDeadline = deadline
        if let deadline {
            let timer = Timer(fire: max(deadline, Date().addingTimeInterval(0.1)), interval: 0, repeats: false) { [weak self] _ in
                self?.shuffleDeadline = nil; self?.shuffleTimer = nil; self?.refresh()
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            shuffleTimer = timer
        }
    }

    private var suspended: Bool { locked || sleeping || inactive || screenSaver }

    private func configureTimer() {
        let needed = mode == .visible && !suspended && !sessions.isEmpty
        if !needed { visibilityTimer?.invalidate(); visibilityTimer = nil }
        else if visibilityTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateVisibility() }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            visibilityTimer = timer
        }
    }

    private func updateVisibility(force: Bool = false) {
        if mode == .visible && !suspended && !sessions.isEmpty {
            let start = ProcessInfo.processInfo.systemUptime
            // Only geometry/layer/alpha/PID are read; no screenshots, titles or app names.
            let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            metadataQueries += 1
            let rects: [CGRect] = rows.compactMap { row in
                guard (row[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                      let level = row[kCGWindowLayer as String] as? Int, level >= 0, level < Int(CGWindowLevelForKey(.dockWindow)),
                      (row[kCGWindowAlpha as String] as? Double ?? 1) >= 0.95,
                      let bounds = row[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
                return rect
            }
            let bounds = surfaces.map { CGDisplayBounds($0.displayID) }
            if force || rects != previousRects || bounds != previousBounds {
                for (i, surface) in surfaces.enumerated() { surface.coverage = Visibility.coveredFraction(of: bounds[i], by: rects) }
                previousRects = rects; previousBounds = bounds
            }
            lastMetadataMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        for surface in surfaces {
            surface.wantsPlayback = surface.session != nil && Visibility.shouldPlay(mode: mode, suspended: suspended, coverage: surface.coverage, wasPlaying: surface.wantsPlayback)
            if surface.session != nil && surface.view.video.isReadyForDisplay && mode != .paused && !suspended {
                if !surface.window.isVisible { surface.window.orderBack(nil) }
            } else { surface.window.orderOut(nil) }
        }
        for (id, session) in sessions {
            let play = surfaces.contains { $0.session === session && $0.wantsPlayback }
            if play != session.playing { logEvent("\(names[id] ?? id): \(play ? "playing" : "paused")") }
            session.setPlaying(play)
        }
        configureShuffleTimer()
    }

    @objc private func workspaceChanged(_ n: Notification) {
        switch n.name {
        case NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification: sleeping = true
        case NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification: sleeping = false
        case NSWorkspace.sessionDidResignActiveNotification: inactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: inactive = false
        case NSWorkspace.activeSpaceDidChangeNotification: scheduleRefresh()
        default: break
        }
        updateVisibility(force: true); configureTimer(); writeStatus()
    }

    @objc private func distributedChanged(_ n: Notification) {
        switch n.name.rawValue {
        case "com.apple.screenIsLocked": locked = true
        case "com.apple.screenIsUnlocked": locked = false
        case "com.apple.screensaver.didstart": screenSaver = true
        case "com.apple.screensaver.didstop": screenSaver = false
        default: break
        }
        updateVisibility(force: true); configureTimer(); writeStatus()
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "Follows Apple’s Wallpaper Selection", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading); menu.addItem(.separator())
        for mode in PlaybackMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(changeMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue; item.target = self; item.state = self.mode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let next = NSMenuItem(title: "Next Shuffle Video", action: #selector(nextShuffle), keyEquivalent: "")
        next.target = self; next.isEnabled = !shuffles.isEmpty; menu.addItem(next)
        for (title, action) in [("Open Wallpaper Settings…", #selector(openSettings)), ("Show Status…", #selector(showStatus)), ("Quit Live Wallpaper", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
    }
    @objc private func changeMode(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let mode = PlaybackMode(rawValue: raw) else { return }
        self.mode = mode; buildMenu(); updateVisibility(force: true); configureTimer(); writeStatus()
        logEvent("Mode: \(mode.rawValue)")
    }
    @objc private func openSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!) }
    @objc private func showStatus() { writeStatus(); NSWorkspace.shared.open(support.appendingPathComponent("status.json")) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func nextShuffle() { advanceShuffles() }
    @objc private func control(_ notification: Notification) {
        if let raw = notification.userInfo?["mode"] as? String, let value = PlaybackMode(rawValue: raw) {
            mode = value; buildMenu(); updateVisibility(force: true); configureTimer()
            logEvent("Mode: \(value.rawValue)")
        }
        if notification.userInfo?["quit"] as? Bool == true { NSApp.terminate(nil) }
        if notification.userInfo?["next"] as? Bool == true { advanceShuffles() }
        writeStatus()
    }

    private func writeStatus() {
        let screens: [[String: Any]] = surfaces.map { s in
            let seconds = s.session?.player.currentTime().seconds ?? 0
            return ["display": s.screen.localizedName, "displayUUID": s.displayUUID, "assetID": s.session?.id ?? "", "scene": s.reason,
             "coverage": s.coverage, "wantsPlayback": s.wantsPlayback, "windowVisible": s.window.isVisible,
             "playerRate": s.session?.player.rate ?? 0, "mediaTime": seconds.isFinite ? seconds : 0,
             "playerStatus": s.session?.player.status.rawValue ?? -1, "playerError": s.session?.player.error?.localizedDescription ?? "",
             "layerReady": s.view.video.isReadyForDisplay, "windowID": s.window.windowNumber,
             "shuffleCollection": s.shuffleChoice?.collectionID ?? "", "shuffleCadence": s.shuffleChoice?.cadence.rawValue ?? "",
             "loopCount": s.session?.looper.loopCount ?? 0]
        }
        let status: [String: Any] = ["pid": getpid(), "mode": mode.rawValue, "suspended": suspended, "uptime": Date().timeIntervalSince(started),
            "players": sessions.count, "playingPlayers": sessions.values.filter(\.playing).count, "metadataQueries": metadataQueries,
            "sourceRefreshes": sourceRefreshes, "lastMetadataMS": lastMetadataMS, "visibilityTimerActive": visibilityTimer != nil, "screens": screens]
        if let data = StatusJSON.data(status) {
            try? data.write(to: support.appendingPathComponent("status.json"), options: .atomic)
        }
    }
    private func logEvent(_ text: String) {
        try? logHandle?.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8))
    }
    func applicationWillTerminate(_ notification: Notification) {
        visibilityTimer?.invalidate(); statusTimer?.invalidate(); shuffleTimer?.invalidate()
        for s in surfaces { s.close() }
        sessions.removeAll(); logEvent("Stopped"); try? logHandle?.close()
    }
}

#if !PLAYBACK_TEST
@main enum LiveWallpaper {
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1 {
            var info: [String: Any] = [:]
            if args[1] == "--mode", args.count == 3, PlaybackMode(rawValue: args[2]) != nil { info["mode"] = args[2] }
            else if args[1] == "--quit" { info["quit"] = true }
            else if args[1] == "--next" { info["next"] = true }
            else if args[1] != "--refresh-status" {
                print("Usage: LiveWallpaper [--mode visible|always|paused | --next | --refresh-status | --quit]"); exit(2)
            }
            DistributedNotificationCenter.default().postNotificationName(.init("com.local.LiveWallpaper.control"), object: nil, userInfo: info, deliverImmediately: true)
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
#endif
