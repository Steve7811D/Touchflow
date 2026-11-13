import AppKit
import Carbon
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    private let bridge = NetEaseBridge()
    private var statusItem: NSStatusItem!
    private var refreshItem: NSMenuItem?
    private var controlStatusItem: NSMenuItem!
    private var hud: HUDController!
    private var touchBar: TouchBarController!
    /// 0.4 s poll of the NetEase player state (in-memory, no network).
    private var liveTimer: Timer?
    /// 1 s poll of macOS Now Playing, only used to anchor the progress clock.
    private var nowPlayingTimer: Timer?
    private var liveInFlight = false
    private var nowPlayingInFlight = false
    private var reloadInFlight = false
    private var isBusy = false
    private(set) var isOpen = false
    private var keepAwakeToken: NSObjectProtocol?
    private(set) var currentPlaylist: Playlist?
    private var currentTrackIndex: Int?
    private var listVersion = -1
    private var localIsPlaying = false
    private var elapsedSeconds: Double = 0
    private var elapsedTimer: Timer?
    private var snapshotElapsed: Double = 0
    private var snapshotAt = Date()
    private var lastLyricTime: Double = -1
    private var lastDomElapsedAt = Date.distantPast
    private var lastUserInteraction = Date.distantPast
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        NSApp.isAutomaticCustomizeTouchBarMenuItemEnabled = true
        setupMainMenu()
        setupStatusItem()
        hud = HUDController()
        hud.onClose = { [weak self] in self?.closeCoverFlow() }
        touchBar = TouchBarController()
        touchBar.appDelegate = self
        registerHotKey()
        updateControlStatus()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(settingsChangedOutside),
                                               name: SettingsStore.changed,
                                               object: nil)
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.openCoverFlow(interactive: false)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard isOpen, let window = hud?.window else { return }
        touchBar?.refresh(on: window)
        touchBar?.appDelegate = self
    }

    func applicationDidResignActive(_ notification: Notification) {
        touchBar?.appDelegate = self
    }

    func touchBarStateChanged(active: Bool, visible: Bool) {
        let text: String
        if !active {
            text = "未在前台 · 点此窗口接管 Touch Bar"
        } else {
            text = "TOUCH BAR ACTIVE · 轻点封面播放"
        }
        hud?.view.setTouchBarStatus(text, active: active, visible: visible)
    }

    func applicationWillTerminate(_ notification: Notification) {
        liveTimer?.invalidate()
        nowPlayingTimer?.invalidate()
        stopElapsedTimer()
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    // MARK: - Menu

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let aboutMain = NSMenuItem(title: "关于 TouchFlow", action: #selector(aboutPressed), keyEquivalent: "")
        aboutMain.target = self
        appMenu.addItem(aboutMain)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 TouchFlow", action: #selector(quit), keyEquivalent: "q").target = self
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.stack.fill", accessibilityDescription: "TouchFlow")
            button.image?.isTemplate = true
            button.toolTip = "TouchFlow — 网易云 Touch Bar 播放控制"
        }
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开 TouchFlow", action: #selector(openPressed), keyEquivalent: "c")
        open.keyEquivalentModifierMask = [.control, .option]
        open.target = self
        menu.addItem(open)

        let close = NSMenuItem(title: "关闭 TouchFlow", action: #selector(closeSelectedPressed), keyEquivalent: "w")
        close.target = self
        menu.addItem(close)

        let refresh = NSMenuItem(title: "刷新播放队列", action: #selector(refreshPressed), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        refreshItem = refresh

        let debugLaunch = NSMenuItem(title: "以调试模式启动网易云",
                                     action: #selector(debugLaunchPressed), keyEquivalent: "")
        debugLaunch.target = self
        menu.addItem(debugLaunch)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(settingsPressed), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于 TouchFlow", action: #selector(aboutPressed), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 TouchFlow", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    private func updateControlStatus() {
        let available = bridge.isAvailable
        controlStatusItem?.title = available ? "网易云控制：已连接" : "网易云控制：未连接"
    }

    // MARK: - Opening

    @objc private func openPressed() { openCoverFlow() }
    @objc private func playSelectedPressed() {
        guard isOpen, let bar = touchBar.barView else { return }
        coverTapped(index: bar.selectedIndex)
    }
    @objc private func closeSelectedPressed() {
        if isOpen { closeCoverFlow() }
    }
    @objc private func refreshPressed() {
        refreshPlaylist()
    }

    func refocusAfterSettings() {
        guard isOpen else { return }
        bringHUDToFront()
    }

    @objc private func settingsPressed() {
        SettingsWindowController.shared.present()
    }

    @objc private func aboutPressed() { showAbout() }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshPlaylist() {
        guard isOpen else {
            openCoverFlow()
            return
        }
        guard !isBusy else { return }
        isBusy = true
        let oldPlaylist = currentPlaylist
        let oldSelected = touchBar.barView?.selectedIndex ?? 0
        let oldSelectedID = oldPlaylist.flatMap {
            oldSelected >= 0 && oldSelected < $0.tracks.count ? $0.tracks[oldSelected].id : nil
        }
        hud.view.setStatus("正在读取网易云当前播放队列…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let queue = try self.bridge.liveQueue()
                DispatchQueue.main.async {
                    guard self.isOpen else { self.isBusy = false; return }
                    self.apply(queue: queue, keepSelectionByID: oldSelectedID, transient: "已刷新 · \(queue.tracks.count) 首")
                    self.isBusy = false
                }
            } catch {
                NSLog("TouchFlow refresh error: \(error)")
                DispatchQueue.main.async {
                    if let old = oldPlaylist {
                        self.currentPlaylist = old
                        self.touchBar.showTransient("队列读取失败，已保留当前列表")
                        self.hud.view.setStatus("读取失败，已保留当前列表：\(error.localizedDescription)")
                    } else {
                        self.touchBar.showTransient("刷新失败")
                        self.hud.view.setStatus("刷新失败：\(error.localizedDescription)")
                    }
                    self.isBusy = false
                }
            }
        }
    }

    private func becomeActiveApp() {
        NSApp.setActivationPolicy(.regular)
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func bringHUDToFront() {
        becomeActiveApp()
        hud.window.orderFrontRegardless()
        hud.window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            self.hud.window.orderFrontRegardless()
            self.hud.window.makeKeyAndOrderFront(nil)
        }
    }

    private func becomeMenuBarApp() {
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func settingsChangedOutside() {
        updateKeepAwake()
    }

    /// "Keep the Touch Bar awake": while enabled and the bar is shown, hold a
    /// display-sleep assertion so the bar does not dim with the screen.
    func updateKeepAwake() {
        let wanted = SettingsStore.shared.values.keepAwake && isOpen
        if wanted, keepAwakeToken == nil {
            keepAwakeToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled],
                reason: "TouchFlow keeps the Touch Bar awake")
        } else if !wanted, let token = keepAwakeToken {
            ProcessInfo.processInfo.endActivity(token)
            keepAwakeToken = nil
        }
    }

    func openCoverFlow(forceRefresh: Bool = false, interactive: Bool = true) {
        if isOpen && !forceRefresh {
            bringHUDToFront()
            return
        }
        guard !isBusy else { return }
        guard bridge.isAvailable else {
            promptControlMode()
            return
        }
        isBusy = true
        becomeActiveApp()
        updateControlStatus()
        hud.showLoading()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var lastError: Error?
            for attempt in 0..<8 {
                do {
                    let queue = try self.bridge.liveQueue()
                    DispatchQueue.main.async { self.present(queue: queue) }
                    return
                } catch {
                    lastError = error
                    NSLog("TouchFlow open attempt \(attempt + 1) failed: \(error.localizedDescription)")
                    Thread.sleep(forTimeInterval: 0.6)
                }
            }
            DispatchQueue.main.async {
                if interactive {
                    self.fail(lastError ?? NetEaseError.noQueue)
                } else {
                    self.failQuietly(lastError ?? NetEaseError.noQueue)
                }
            }
        }
    }

    /// Build the Flow playlist from the authoritative live queue.
    private func playlist(from queue: LiveQueue) -> Playlist {
        var playlist = Playlist(id: "queue",
                                uid: "",
                                title: queue.sourceTitle.isEmpty ? "正在播放" : queue.sourceTitle,
                                coverURL: queue.tracks.first?.coverURL ?? "",
                                tracks: queue.tracks)
        playlist.sourceID = queue.sourceID
        playlist.sourceTitle = queue.sourceTitle
        playlist.currentID = queue.currentID
        return playlist
    }

    private func present(queue: LiveQueue) {
        let playlist = playlist(from: queue)
        isBusy = false
        isOpen = true
        updateKeepAwake()
        currentPlaylist = playlist
        listVersion = queue.listVersion
        UserDefaults.standard.set(playlist.id, forKey: "TouchFlow.playlistID")
        currentTrackIndex = playlist.currentIndex
        // Restore the last browsed cover only while the *same* song is still
        // playing.  If the song advanced while Flow was closed, the saved index
        // points at the previous track: opening there would show a neighbouring
        // cover and no lyrics, which reads as "lyrics are broken".
        let savedIndex = UserDefaults.standard.object(forKey: "TouchFlow.lastIndex") as? Int
        let savedTrackID = UserDefaults.standard.string(forKey: "TouchFlow.lastTrackID")
        let validSaved = savedIndex.flatMap { (0..<playlist.tracks.count).contains($0) ? $0 : nil }
        let sameTrack = savedTrackID != nil && savedTrackID == queue.currentID
        let selected = (sameTrack ? validSaved : nil) ?? playlist.currentIndex ?? validSaved ?? 0
        UserDefaults.standard.set(queue.currentID, forKey: "TouchFlow.lastTrackID")
        becomeActiveApp()
        hud.show(playlist: playlist, selectedIndex: selected)
        touchBar.install(on: hud.window, playlist: playlist)
        touchBar.select(index: selected)
        prefetchAround(selected)
        fetchLyrics(for: playlist.currentIndex ?? selected)
        bringHUDToFront()
        lastLyricTime = -1
        localIsPlaying = queue.isPlaying
        elapsedSeconds = 0
        snapshotElapsed = 0
        snapshotAt = Date()
        touchBar.setPlayingState(queue.isPlaying)
        touchBar.setElapsed(0)
        touchBar.clearLiveLyric()
        if queue.isPlaying { startElapsedTimer() } else { stopElapsedTimer() }
        refreshItem?.title = "刷新播放队列 · \(playlist.tracks.count) 首"
        // Deliberately free of song titles / playlist names: the unified log is
        // readable by other tools and often pasted into bug reports.
        NSLog("TouchFlow presented queue tracks=\(queue.tracks.count) current=\(queue.currentIndex.map(String.init) ?? "-") selected=\(selected) saved=\(validSaved.map(String.init) ?? "-") sameTrack=\(sameTrack) playing=\(queue.isPlaying)")
        startLivePolling()
        startNowPlayingPolling()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.refreshNowPlayingAnchor()
        }
    }

    /// Used for opens that the user did not ask for directly (launch flag,
    /// post-restart): report in-place instead of stealing focus with a dialog.
    private func failQuietly(_ error: Error) {
        isBusy = false
        let message = error.localizedDescription
        hud.view.setError(message)
        bringHUDToFront()
        touchBar.showTransient("读取失败：请检查网易云")
        NSLog("TouchFlow quiet open failure: \(message)")
    }

    private func fail(_ error: Error) {
        isBusy = false
        let message = error.localizedDescription
        hud.view.setError(message)
        bringHUDToFront()
        showAlert(title: "无法打开 TouchFlow", message: message, style: .warning)
    }

    func closeCoverFlow() {
        isOpen = false
        updateKeepAwake()
        liveTimer?.invalidate()
        liveTimer = nil
        nowPlayingTimer?.invalidate()
        nowPlayingTimer = nil
        stopElapsedTimer()
        touchBar.uninstall(from: hud.window)
        hud.close()
        NSApp.hide(nil)
        becomeMenuBarApp()
    }

    // MARK: - Live state

    private func startLivePolling() {
        liveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pollLiveState()
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func startNowPlayingPolling() {
        nowPlayingTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshNowPlayingAnchor()
        }
        RunLoop.main.add(timer, forMode: .common)
        nowPlayingTimer = timer
    }

    private func pollLiveState() {
        guard isOpen, currentPlaylist != nil, !liveInFlight else { return }
        liveInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let status = try? self.bridge.liveStatus()
            DispatchQueue.main.async {
                self.liveInFlight = false
                guard self.isOpen, let status else { return }
                self.apply(liveStatus: status)
            }
        }
    }

    private func apply(liveStatus status: LiveStatus) {
        guard let playlist = currentPlaylist else { return }

        if let reported = status.elapsed {
            // The client's own progress slider reflects seeks immediately, but
            // it advances in ~1 s steps.  Snapping our interpolated clock to
            // every step made the seconds (and any lyric sitting on a boundary)
            // visibly jump back and forth, so:
            //   - paused: the value is exact, take it;
            //   - big delta: it is a seek, take it;
            //   - small delta: keep the monotonic interpolated estimate.
            lastDomElapsedAt = Date()
            let estimate = snapshotElapsed + Date().timeIntervalSince(snapshotAt)
            let delta = reported - estimate
            if !status.isPlaying || abs(delta) > 1.5 {
                elapsedSeconds = reported
                snapshotElapsed = reported
                snapshotAt = Date()
                touchBar.setElapsed(reported)
            } else if delta > 0.05 {
                // Reported is slightly ahead: nudge, don't jump.
                snapshotElapsed = estimate + delta * 0.25
                snapshotAt = Date()
            } else {
                // Reported is behind (staircase step): keep the estimate.
                snapshotElapsed = estimate
                snapshotAt = Date()
            }
        }

        localIsPlaying = status.isPlaying
        touchBar.setPlayingState(status.isPlaying)
        if status.isPlaying { startElapsedTimer() } else { stopElapsedTimer() }

        // The queue itself changed (new playlist, songs added/removed): reload.
        if status.listCount != playlist.tracks.count || status.listVersion != listVersion {
            reloadQueue()
            return
        }

        guard let index = status.currentIndex, index < playlist.tracks.count else {
            if currentTrackIndex != nil {
                currentTrackIndex = nil
                touchBar.setPlaying(index: nil)
                touchBar.clearLyrics()
                touchBar.setElapsed(0)
            }
            return
        }

        // A queue slot can be replaced by a different song (NetEase does this
        // when you play a single song from "最近播放"), so the song id — not the
        // row index — is what decides whether the track really changed.
        let idChanged = !status.currentID.isEmpty && status.currentID != playlist.currentID
        if idChanged {
            currentPlaylist?.currentID = status.currentID
        }
        let indexChanged = currentTrackIndex != index
        guard idChanged || indexChanged else { return }

        currentTrackIndex = index
        touchBar.setPlaying(index: index)
        touchBar.clearLiveLyric()
        touchBar.clearLyrics()
        fetchLyrics(for: index)
        prefetchAround(index)
        elapsedSeconds = 0
        snapshotElapsed = 0
        snapshotAt = Date()
        touchBar.setElapsed(0)
        DispatchQueue.main.async { [weak self] in
            self?.refreshNowPlayingAnchor()
        }
        NSLog("TouchFlow track change idx=\(index) id=\(status.currentID)")
        if indexChanged, touchBar.barView?.isInteracting != true {
            touchBar.barView?.scrollTo(index: index)
        }
    }

    /// Reload the whole queue after a playlist/source change.  The old Flow is
    /// kept when the read fails; nothing is cleared or reported as "refresh failed".
    private func reloadQueue() {
        guard !reloadInFlight else { return }
        reloadInFlight = true
        let oldPlaylist = currentPlaylist
        let selected = touchBar.barView?.selectedIndex ?? 0
        let selectedID = oldPlaylist.flatMap {
            selected >= 0 && selected < $0.tracks.count ? $0.tracks[selected].id : nil
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = try? self.bridge.liveQueue()
            DispatchQueue.main.async {
                self.reloadInFlight = false
                guard self.isOpen, let queue = result else {
                    NSLog("TouchFlow queue reload skipped (closed or failed)")
                    return
                }
                NSLog("TouchFlow queue reloaded tracks=\(queue.tracks.count) current=\(queue.currentIndex.map(String.init) ?? "-")")
                self.apply(queue: queue, keepSelectionByID: selectedID, transient: "播放队列已更新 · \(queue.tracks.count) 首")
            }
        }
    }

    private func apply(queue: LiveQueue, keepSelectionByID selectedID: String?, transient: String?) {
        let playlist = playlist(from: queue)
        currentPlaylist = playlist
        listVersion = queue.listVersion
        currentTrackIndex = queue.currentIndex
        let selected = selectedID.flatMap { id in
            playlist.tracks.firstIndex(where: { $0.id == id })
        } ?? min(max(0, queue.currentIndex ?? 0), max(0, playlist.tracks.count - 1))
        touchBar.barView?.configure(playlist: playlist, playingIndex: queue.currentIndex)
        touchBar.select(index: selected)
        touchBar.setPlaying(index: queue.currentIndex)
        touchBar.setPlayingState(queue.isPlaying)
        hud.view.update(playlist: playlist, selectedIndex: selected, status: "TOUCH BAR ACTIVE · 轻点封面播放/暂停")
        prefetchAround(selected)
        fetchLyrics(for: queue.currentIndex ?? selected)
        refreshItem?.title = "刷新播放队列 · \(playlist.tracks.count) 首"
        UserDefaults.standard.set(selected, forKey: "TouchFlow.lastIndex")
        if let transient { touchBar.showTransient(transient) }
    }

    // MARK: - Progress

    private func refreshNowPlayingAnchor() {
        guard isOpen, !nowPlayingInFlight else { return }
        nowPlayingInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = SystemNowPlaying.shared.snapshot()
            DispatchQueue.main.async {
                self.nowPlayingInFlight = false
                guard self.isOpen, let snapshot else { return }
                // While the page reports its own position, it wins: it is the
                // only source that notices a seek right away.
                if Date().timeIntervalSince(self.lastDomElapsedAt) < 3 { return }
                self.snapshotElapsed = max(0, snapshot.elapsed)
                self.snapshotAt = Date()
                self.elapsedSeconds = self.snapshotElapsed
                self.touchBar.setElapsed(self.elapsedSeconds)
            }
        }
    }

    private func startElapsedTimer() {
        guard elapsedTimer == nil else { return }
        // Interpolate from the last MediaRemote snapshot so the clock stays in
        // phase with the real timestamp instead of drifting ahead of the song.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.localIsPlaying else { return }
            let value = self.snapshotElapsed + Date().timeIntervalSince(self.snapshotAt)
            self.elapsedSeconds = max(0, value)
            self.touchBar.setElapsed(self.elapsedSeconds)
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - Playback

    func selectionChanged(index: Int) {
        guard let playlist = currentPlaylist else { return }
        lastUserInteraction = Date()
        hud.view.update(playlist: playlist, selectedIndex: index, status: "TOUCH BAR ACTIVE · 轻点封面播放/暂停")
        UserDefaults.standard.set(index, forKey: "TouchFlow.lastIndex")
    }

    func coverTapped(index: Int) {
        guard let playlist = currentPlaylist, index >= 0, index < playlist.tracks.count else { return }
        lastUserInteraction = Date()
        if currentTrackIndex == index {
            togglePlayback()
        } else {
            play(index: index)
        }
    }

    func togglePlaybackFromUI() {
        togglePlayback()
    }

    func statusPlayTapped(index: Int) {
        lastUserInteraction = Date()
        if currentTrackIndex == index {
            togglePlayback()
        } else {
            play(index: index)
        }
    }

    private func togglePlayback() {
        hud.view.setStatus("正在切换播放/暂停…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var ok = (try? self.bridge.togglePlayPause()) ?? false
            if !ok {
                ok = SystemNowPlaying.shared.togglePlayPause()
            }
            // Read the truth from the player state instead of guessing.
            Thread.sleep(forTimeInterval: 0.35)
            let status = try? self.bridge.liveStatus()
            DispatchQueue.main.async {
                if !ok {
                    self.hud.view.setStatus("播放/暂停失败：网易云没有响应")
                    return
                }
                if let status {
                    self.localIsPlaying = status.isPlaying
                    self.touchBar.setPlayingState(status.isPlaying)
                    if status.isPlaying { self.startElapsedTimer() } else { self.stopElapsedTimer() }
                    self.elapsedSeconds = self.snapshotElapsed
                    self.touchBar.setElapsed(self.elapsedSeconds)
                }
                self.lastUserInteraction = Date()
                self.hud.view.setStatus("TOUCH BAR ACTIVE · 轻点封面播放/暂停")
            }
        }
    }

    func returnToCurrent() {
        guard let playlist = currentPlaylist, !playlist.tracks.isEmpty else { return }
        let index = currentTrackIndex ?? touchBar.barView?.playingIndex ?? 0
        guard index >= 0 && index < playlist.tracks.count else { return }
        touchBar.barView?.scrollTo(index: index)
    }

    func play(index: Int) {
        guard let playlist = currentPlaylist, index >= 0 && index < playlist.tracks.count else { return }
        let track = playlist.tracks[index]
        let sourceID = playlist.sourceID
        let sourceTitle = playlist.sourceTitle
        hud.view.setStatus("正在播放：\(track.title)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                var played = (try? self.bridge.play(track: track, sourceID: sourceID)) ?? false
                if !played {
                    // The open page does not contain that song: go back to the
                    // playlist the queue came from, then retry once.
                    if (try? self.bridge.openPlaylist(sourceID: sourceID, title: sourceTitle)) == true {
                        Thread.sleep(forTimeInterval: 0.4)
                        played = (try? self.bridge.play(track: track, sourceID: sourceID)) ?? false
                    }
                }
                guard played else {
                    throw NSError(domain: "TouchFlow", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "这首歌当前未在网易云打开"])
                }
                // Verify through the player state (exact song id, not a title guess).
                var confirmed = false
                for _ in 0..<20 {
                    Thread.sleep(forTimeInterval: 0.15)
                    if (try? self.bridge.liveStatus())?.currentID == track.id {
                        confirmed = true
                        break
                    }
                }
                guard confirmed else {
                    throw NSError(domain: "TouchFlow", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "网易云没有切到这首歌，请再点一次"])
                }
                DispatchQueue.main.async {
                    self.lastUserInteraction = Date()
                    self.currentPlaylist?.currentID = track.id
                    self.currentTrackIndex = index
                    self.localIsPlaying = true
                    self.elapsedSeconds = 0
                    self.snapshotElapsed = 0
                    self.snapshotAt = Date()
                    self.lastLyricTime = -1
                    self.touchBar.setPlaying(index: index)
                    self.touchBar.setPlayingState(true)
                    self.touchBar.setElapsed(0)
                    self.touchBar.clearLiveLyric()
                    self.startElapsedTimer()
                    self.prefetchAround(index)
                    self.fetchLyrics(for: index)
                    self.hud.view.update(playlist: playlist, selectedIndex: index, status: "TOUCH BAR ACTIVE · 轻点封面播放/暂停")
                }
            } catch {
                DispatchQueue.main.async {
                    self.hud.view.setStatus("播放失败：\(error.localizedDescription)")
                    self.touchBar.showTransient(error.localizedDescription)
                }
            }
        }
    }

    private func fetchLyrics(for index: Int) {
        guard let playlist = currentPlaylist, index >= 0, index < playlist.tracks.count else { return }
        let trackID = playlist.tracks[index].id
        LyricsStore.shared.lyrics(for: trackID) { [weak self] lines in
            DispatchQueue.main.async {
                guard let self, self.isOpen, self.currentTrackIndex == index,
                      let current = self.currentPlaylist,
                      index < current.tracks.count,
                      current.tracks[index].id == trackID else { return }
                NSLog("TouchFlow lyrics loaded id=\(trackID) lines=\(lines.count)")
                self.touchBar.setLyrics(lines, for: trackID)
            }
        }
    }

    private func prefetchAround(_ index: Int) {
        guard let playlist = currentPlaylist, !playlist.tracks.isEmpty else { return }
        let lower = max(0, index - 20)
        let upper = min(playlist.tracks.count - 1, index + 30)
        guard lower <= upper else { return }
        ImageStore.shared.prefetch(Array(playlist.tracks[lower...upper]))
    }

    private func activateNetEase() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.netease.163music")
        if let app = apps.first {
            app.activate(options: [.activateIgnoringOtherApps])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/NeteaseMusic.app"))
        }
    }

    // MARK: - Control mode

    private func promptControlMode() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要以调试模式启动网易云"
        alert.informativeText = "TouchFlow 通过网易云本地的调试端口读取当前播放队列和切换歌曲。为了让控制生效，需要重新启动网易云（会中断当前播放）。\n\n如果不想重启，你也可以先手动打开网易云并保持播放，但 TouchFlow 无法控制选歌。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "重启网易云并继续")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            restartNetEase()
        }
    }

    private func confirmRestartNetEase() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "以调试模式重启网易云？"
        alert.informativeText = "这会退出当前网易云进程，并以调试端口（9222）重新打开。当前播放会中断；歌单和账号会保留。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重启")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            restartNetEase()
        }
    }

    private func restartNetEase() {
        if isOpen { closeCoverFlow() }
        guard !isBusy else { return }
        isBusy = true
        hud.showLoading()
        hud.view.setLoading("正在重启网易云…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.netease.163music") {
                app.terminate()
            }
            Thread.sleep(forTimeInterval: 1.8)
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.netease.163music") where !app.isTerminated {
                app.forceTerminate()
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "-a", "/Applications/NeteaseMusic.app", "--args", "--remote-debugging-port=9222"]
            try? process.run()
            var ready = false
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.5)
                if self.bridge.isAvailable { ready = true; break }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                if ready {
                    self.updateControlStatus()
                    self.openCoverFlow()
                } else {
                    self.fail(NetEaseError.noControlPort)
                }
            }
        }
    }

    @objc private func debugLaunchPressed() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.netease.163music")
        if running.isEmpty {
            launchNetEaseInDebugMode()
        } else {
            confirmRestartNetEase()
        }
    }

    /// Starts NetEase with the DevTools port enabled when it is not running.
    /// (When it is already running, the caller confirms a restart instead.)
    private func launchNetEaseInDebugMode() {
        guard FileManager.default.fileExists(atPath: "/Applications/NeteaseMusic.app") else {
            showAlert(title: "没有找到网易云音乐",
                      message: "请先把网易云音乐安装到 /Applications。", style: .warning)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-a", "/Applications/NeteaseMusic.app",
                             "--args", "--remote-debugging-port=9222"]
        do {
            try process.run()
        } catch {
            showAlert(title: "无法启动网易云", message: error.localizedDescription, style: .warning)
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            DispatchQueue.main.async {
                self?.updateControlStatus()
                if self?.isOpen == true {
                    self?.hud.view.setStatus("网易云已以调试模式启动")
                }
            }
        }
    }

    private func showAbout() {
        NSLog("TouchFlow about shown")
        NSApp.activate(ignoringOtherApps: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        let alert = NSAlert()
        alert.messageText = "TouchFlow"
        alert.informativeText = "版本 \(version)\nDesigned by Niko"
        if let path = Bundle.main.path(forResource: "TouchFlow", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            alert.icon = icon
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - Global hotkey

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { AppDelegate.shared?.openCoverFlow() }
            return noErr
        }, 1, &eventType, nil, &hotKeyHandler)

        var hotKeyID = EventHotKeyID(signature: OSType(0x54464C57), id: 1)
        let modifiers = UInt32(controlKey) | UInt32(optionKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_C), modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
