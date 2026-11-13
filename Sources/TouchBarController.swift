import AppKit

final class TouchBarController: NSObject, NSTouchBarDelegate {
    static let closeID = NSTouchBarItem.Identifier("com.touchflow.close")
    static let flowID = NSTouchBarItem.Identifier("com.touchflow.flow")
    static let barWidth: CGFloat = 1000

    weak var appDelegate: AppDelegate?
    private(set) var barView: CoverFlowBarView?
    private var touchBar: NSTouchBar?
    private var closeButton: NSButton?
    private var visibilityTimer: Timer?
    private var lastState: String = ""

    func install(on window: NSWindow, playlist: Playlist) {
        let view: CoverFlowBarView
        if let existing = barView {
            view = existing
        } else {
            view = CoverFlowBarView(frame: NSRect(x: 0, y: 0, width: Self.barWidth, height: 30))
            view.onPlay = { [weak self] index in
                self?.appDelegate?.coverTapped(index: index)
            }
            view.onSelection = { [weak self] index in
                self?.appDelegate?.selectionChanged(index: index)
            }
            view.onClose = { [weak self] in
                self?.appDelegate?.closeCoverFlow()
            }
            view.onTogglePlay = { [weak self] index in
                self?.appDelegate?.statusPlayTapped(index: index)
            }
            view.onReturnToCurrent = { [weak self] in
                self?.appDelegate?.returnToCurrent()
            }
            barView = view
        }
        view.configure(playlist: playlist, playingIndex: playlist.currentIndex)

        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = NSTouchBar.CustomizationIdentifier("com.touchflow.bar")
        // An NSTouchBar with only principalItemIdentifier can end up with an
        // empty defaultItemIdentifiers list, in which case the system never
        // considers it eligible for display.  The flow item must be in the
        // default list; the close item is supplied through the Escape slot.
        bar.defaultItemIdentifiers = [Self.flowID]
        bar.principalItemIdentifier = Self.flowID
        bar.customizationAllowedItemIdentifiers = [Self.flowID]
        bar.customizationRequiredItemIdentifiers = [Self.flowID]
        touchBar = bar
        (window as? HUDWindow)?.providedTouchBar = bar
        (window.contentViewController as? HUDViewController)?.providedTouchBar = bar
        (window.contentView as? HUDView)?.providedTouchBar = bar
        window.touchBar = bar
        NSApp.touchBar = bar
        window.makeFirstResponder(window.contentView)
        startVisibilityMonitor(window: window)
        // Re-attach once the HUD is actually key/main.  NSTouchBar can miss
        // the initial assignment when the agent app is still becoming active.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak window, weak view] in
            guard let self, let window, let bar = self.touchBar else { return }
            window.touchBar = nil
            window.touchBar = bar
            window.makeKey()
            if let view {
                NSLog("TouchFlow TouchBar reattached: bar view frame: \(view.frame), window: \(window.frame), key=\(window.isKeyWindow) main=\(window.isMainWindow), policy=\(NSApp.activationPolicy().rawValue), barVisible=\(bar.isVisible)")
            }
        }
    }

    func uninstall(from window: NSWindow) {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        window.touchBar = nil
        NSApp.touchBar = nil
        touchBar = nil
    }

    func refresh(on window: NSWindow) {
        guard let bar = touchBar else { return }
        window.touchBar = nil
        window.touchBar = bar
        NSApp.touchBar = bar
        window.makeKey()
    }

    private func startVisibilityMonitor(window: NSWindow) {
        visibilityTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self, weak window] _ in
            guard let self, let window, let bar = self.touchBar else { return }
            let active = NSApp.isActive
            let key = window.isKeyWindow
            let visible = bar.isVisible
            let state = "active=\(active) key=\(key) visible=\(visible)"
            if state != self.lastState {
                self.lastState = state
                NSLog("TouchFlow TB state \(state)")
                self.appDelegate?.touchBarStateChanged(active: active, visible: visible)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer
    }

    func setPlaying(index: Int?) {
        barView?.setPlayingIndex(index)
    }

    func setPlayingState(_ playing: Bool) {
        barView?.setPlayingState(playing)
    }

    func setElapsed(_ seconds: Double) {
        barView?.setElapsed(seconds)
    }

    func setLyrics(_ lines: [LyricLine], for trackID: String) {
        barView?.setLyrics(lines, for: trackID)
    }

    func clearLyrics() {
        barView?.clearLyrics()
    }

    func setLiveLyric(_ text: String) {
        barView?.setLiveLyric(text)
    }

    func clearLiveLyric() {
        barView?.clearLiveLyric()
    }

    func select(index: Int) {
        barView?.select(index: index, play: false)
    }

    func showTransient(_ text: String) {
        barView?.showTransient(text)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case Self.closeID:
            NSLog("TouchFlow makeItem close")
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton()
            button.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
            button.isBordered = false
            button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭 TouchFlow")
            button.imagePosition = .imageOnly
            button.contentTintColor = NSColor(calibratedWhite: 0.92, alpha: 1)
            button.target = self
            button.action = #selector(closePressed)
            button.toolTip = "关闭 TouchFlow，回到网易云"
            closeButton = button
            item.view = button
            return item

        case Self.flowID:
            NSLog("TouchFlow makeItem flow")
            let item = NSCustomTouchBarItem(identifier: identifier)
            if barView == nil {
                let view = CoverFlowBarView(frame: NSRect(x: 0, y: 0, width: Self.barWidth, height: 30))
                view.onPlay = { [weak self] index in self?.appDelegate?.coverTapped(index: index) }
                view.onSelection = { [weak self] index in self?.appDelegate?.selectionChanged(index: index) }
                view.onClose = { [weak self] in self?.appDelegate?.closeCoverFlow() }
                view.onTogglePlay = { [weak self] index in self?.appDelegate?.statusPlayTapped(index: index) }
                view.onReturnToCurrent = { [weak self] in self?.appDelegate?.returnToCurrent() }
                barView = view
            }
            if let barView { item.view = barView }
            return item

        default:
            return nil
        }
    }

    @objc private func closePressed() {
        appDelegate?.closeCoverFlow()
    }
}
