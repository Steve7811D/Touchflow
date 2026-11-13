import AppKit

final class HUDWindow: NSWindow {
    var providedTouchBar: NSTouchBar?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func makeTouchBar() -> NSTouchBar? {
        providedTouchBar ?? super.makeTouchBar()
    }
}

final class HUDViewController: NSViewController {
    var providedTouchBar: NSTouchBar?

    override func makeTouchBar() -> NSTouchBar? {
        NSLog("TouchFlow HUDViewController makeTouchBar provided=\(providedTouchBar != nil)")
        return providedTouchBar ?? super.makeTouchBar()
    }
}

final class HUDView: NSView {
    var onClose: (() -> Void)?
    var providedTouchBar: NSTouchBar?

    override var acceptsFirstResponder: Bool { true }

    override func makeTouchBar() -> NSTouchBar? {
        providedTouchBar ?? super.makeTouchBar()
    }

    private let kicker = NSTextField(labelWithString: "TOUCHFLOW")
    private let playlistLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "轻点封面播放 · 左右拖动浏览 · 关闭后回到网易云")
    private let artView = NSImageView()
    private let dot = NSView()
    private let closeButton = NSButton(title: "关闭并返回网易云", target: nil, action: nil)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        kicker.font = NSFont(name: "Avenir Next Condensed", size: 9) ?? NSFont.systemFont(ofSize: 9, weight: .semibold)
        kicker.textColor = NSColor(calibratedWhite: 1, alpha: 0.38)
        kicker.cell?.usesSingleLineMode = true
        addSubview(kicker)

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(calibratedRed: 0.48, green: 0.88, blue: 0.62, alpha: 0.9).cgColor
        dot.layer?.cornerRadius = 3
        addSubview(dot)

        statusLabel.font = NSFont(name: "Avenir Next Condensed", size: 8) ?? NSFont.systemFont(ofSize: 8)
        statusLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.45)
        addSubview(statusLabel)

        artView.wantsLayer = true
        artView.imageScaling = .scaleAxesIndependently
        artView.layer?.cornerRadius = 4
        artView.layer?.masksToBounds = true
        artView.layer?.borderWidth = 0.5
        artView.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.22).cgColor
        addSubview(artView)

        playlistLabel.font = NSFont(name: "Lucida Grande", size: 8.5) ?? NSFont.systemFont(ofSize: 8.5)
        playlistLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.46)
        playlistLabel.lineBreakMode = .byTruncatingTail
        playlistLabel.cell?.usesSingleLineMode = true
        addSubview(playlistLabel)

        titleLabel.font = NSFont(name: "Lucida Grande", size: 18) ?? NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.97, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true
        addSubview(titleLabel)

        artistLabel.font = NSFont(name: "Lucida Grande", size: 11.5) ?? NSFont.systemFont(ofSize: 11.5)
        artistLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.58)
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.cell?.usesSingleLineMode = true
        addSubview(artistLabel)

        hintLabel.font = NSFont(name: "Lucida Grande", size: 8.5) ?? NSFont.systemFont(ofSize: 8.5)
        hintLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.30)
        hintLabel.lineBreakMode = .byTruncatingTail
        addSubview(hintLabel)

        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.bezelStyle = .rounded
        closeButton.font = NSFont(name: "Lucida Grande", size: 10) ?? NSFont.systemFont(ofSize: 10)
        closeButton.contentTintColor = NSColor(calibratedWhite: 1, alpha: 0.78)
        closeButton.bezelColor = NSColor(calibratedWhite: 0.18, alpha: 1)
        addSubview(closeButton)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        // HUDView is flipped.  Visual top edge is square; the bottom has the
        // same 14 pt radius as before.
        let radius: CGFloat = 14
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
        path.curve(to: NSPoint(x: rect.maxX - radius, y: rect.maxY),
                   controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY - radius * 0.45),
                   controlPoint2: NSPoint(x: rect.maxX - radius * 0.45, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
        path.curve(to: NSPoint(x: rect.minX, y: rect.maxY - radius),
                   controlPoint1: NSPoint(x: rect.minX + radius * 0.45, y: rect.maxY),
                   controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - radius * 0.45))
        path.close()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.095, green: 0.105, blue: 0.12, alpha: 1),
            NSColor(calibratedRed: 0.028, green: 0.033, blue: 0.042, alpha: 1)
        ]) {
            gradient.draw(in: bounds, angle: -90)
        }
        NSColor(calibratedWhite: 1, alpha: 0.035).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        kicker.frame = NSRect(x: 20, y: 15, width: 160, height: 13)
        dot.frame = NSRect(x: 20, y: 35, width: 6, height: 6)
        statusLabel.frame = NSRect(x: 31, y: 32, width: 200, height: 12)
        artView.frame = NSRect(x: 20, y: 53, width: 58, height: 58)
        playlistLabel.frame = NSRect(x: 92, y: 52, width: w - 112, height: 12)
        titleLabel.frame = NSRect(x: 90, y: 68, width: w - 112, height: 25)
        artistLabel.frame = NSRect(x: 91, y: 94, width: w - 112, height: 16)
        closeButton.frame = NSRect(x: w - 148, y: 112, width: 128, height: 24)
        hintLabel.frame = NSRect(x: 20, y: 128, width: w - 190, height: 12)
    }

    func setLoading(_ message: String) {
        statusLabel.stringValue = message
        dot.layer?.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.3, alpha: 0.9).cgColor
        playlistLabel.stringValue = "网易云音乐 · 正在读取"
        titleLabel.stringValue = "TouchFlow"
        artistLabel.stringValue = ""
        closeButton.isHidden = false
    }

    func setError(_ message: String) {
        statusLabel.stringValue = "ERROR"
        dot.layer?.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.3, alpha: 0.9).cgColor
        playlistLabel.stringValue = "无法打开 TouchFlow"
        titleLabel.stringValue = message
        artistLabel.stringValue = ""
        closeButton.isHidden = false
    }

    func update(playlist: Playlist, selectedIndex: Int, status: String) {
        dot.layer?.backgroundColor = NSColor(calibratedRed: 0.48, green: 0.88, blue: 0.62, alpha: 0.9).cgColor
        statusLabel.stringValue = status
        playlistLabel.stringValue = "\(playlist.title)  ·  \(playlist.tracks.count) 首"
        closeButton.isHidden = false
        guard selectedIndex >= 0 && selectedIndex < playlist.tracks.count else { return }
        let track = playlist.tracks[selectedIndex]
        titleLabel.stringValue = track.title
        artistLabel.stringValue = track.artist
        artView.image = ImageStore.shared.cached(track)
        ImageStore.shared.image(for: track) { [weak self] image in
            guard let self, let image else { return }
            if self.titleLabel.stringValue == track.title { self.artView.image = image }
        }
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func setTouchBarStatus(_ text: String, active: Bool, visible: Bool) {
        statusLabel.stringValue = text
        if !active {
            dot.layer?.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.35, alpha: 0.9).cgColor
        } else if visible {
            dot.layer?.backgroundColor = NSColor(calibratedRed: 0.48, green: 0.88, blue: 0.62, alpha: 0.9).cgColor
        } else {
            dot.layer?.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.3, alpha: 0.9).cgColor
        }
    }

    @objc private func closePressed() {
        onClose?()
    }
}

final class HUDController {
    let window: HUDWindow
    let view: HUDView
    let controller: HUDViewController
    var onClose: (() -> Void)? {
        didSet { view.onClose = onClose }
    }

    init() {
        let frame = NSRect(x: 0, y: 0, width: 420, height: 150)
        window = HUDWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        view = HUDView(frame: frame)
        controller = HUDViewController()
        controller.view = view
        window.contentViewController = controller
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.center()
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let windowSize = window.frame.size
            let origin = NSPoint(x: vf.maxX - windowSize.width - 24, y: vf.maxY - windowSize.height - 24)
            window.setFrameOrigin(origin)
        }
    }

    func showLoading() {
        view.setLoading("正在连接网易云…")
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func show(playlist: Playlist, selectedIndex: Int) {
        view.update(playlist: playlist, selectedIndex: selectedIndex, status: "TOUCH BAR ACTIVE")
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func select(index: Int) {
        guard let playlist = (NSApp.delegate as? AppDelegate)?.currentPlaylist else { return }
        view.update(playlist: playlist, selectedIndex: index, status: "TOUCH BAR ACTIVE")
    }

    func close() {
        window.orderOut(nil)
    }
}
