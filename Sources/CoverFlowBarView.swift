import AppKit
import QuartzCore
import CoreImage

/// The 30 pt high Touch Bar strip.  Left: cover, title, artist, index.
/// Right: a miniature, draggable Cover Flow fan.
final class CoverFlowBarView: NSView {
    static let designSize = NSSize(width: 974, height: 30)

    var onPlay: ((Int) -> Void)?
    var onSelection: ((Int) -> Void)?
    var onClose: (() -> Void)?
    var onTogglePlay: ((Int) -> Void)?
    var onReturnToCurrent: (() -> Void)?

    private(set) var playlist: Playlist?
    private(set) var selectedIndex = 0
    private(set) var playingIndex: Int?

    /// Type scale for the info column.  Kept in one place so the label fields
    /// and the manual text drawing can never drift apart again.
    private enum BarType {
        static let titleSize: CGFloat = 12.0
        static let artistSize: CGFloat = 8.5
        static let statusSize: CGFloat = 9.0
        static let lyricSize: CGFloat = 15.5

        static func title() -> NSFont {
            NSFont(name: "Lucida Grande", size: titleSize) ?? NSFont.systemFont(ofSize: titleSize, weight: .semibold)
        }
        static func artist() -> NSFont {
            NSFont(name: "Lucida Grande", size: artistSize) ?? NSFont.systemFont(ofSize: artistSize)
        }
        static func status() -> NSFont {
            NSFont.monospacedDigitSystemFont(ofSize: statusSize, weight: .regular)
        }
        static func lyric() -> NSFont {
            NSFont.systemFont(ofSize: lyricSize, weight: .medium)
        }
        static func lyricFont(_ size: CGFloat) -> NSFont {
            NSFont.systemFont(ofSize: size, weight: .medium)
        }
    }

    private let infoWidth: CGFloat = 262
    private var closeWidth: CGFloat { settings.hideInfoPanel ? 0 : 30 }
    private let rightColumnWidth: CGFloat = 60
    private var settings: FlowSettings { SettingsStore.shared.values }
    private var spacing: CGFloat { CGFloat(settings.spacing) }
    private var centerGap: CGFloat { CGFloat(settings.centerGap) }
    private let visibleSlack = 4
    private let artView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let indexLabel = NSTextField(labelWithString: "")
    private let playingDot = NSView()
    private let coverHost = CALayer()
    private let coverMask = CALayer()
    private let fadeLayer = CAGradientLayer()

    private var position: Double = 0
    private var lastLabeledIndex = -1
    private var titleText = ""
    private var artistText = ""
    private var marqueeTimer: Timer?
    private var titleMarqueeOffset: CGFloat = 0
    private var artistMarqueeOffset: CGFloat = 0
    private var titlePauseUntil: CFTimeInterval = 0
    private var artistPauseUntil: CFTimeInterval = 0
    private var marqueeLastTick: CFTimeInterval = 0
    private var isPlaying = false
    private var elapsedSeconds: Double = 0
    private var durationText = "--:--"
    private var selectedTitle = ""
    private var selectedArtist = ""
    private var hasActiveLyric = false
    private var bigLyricMode = false
    private var bigLyricOffset: CGFloat = 0
    private var bigLyricPauseUntil: CFTimeInterval = 0
    private var transientText = ""
    private var transientUntil: CFTimeInterval = 0
    private var transientTimer: Timer?
    private var lyrics: [LyricLine] = []
    private var lyricTrackID: String?
    private var lyricLineIndex = -1
    private var liveLyricText = ""
    private var infoBackdrop: NSImage?
    private var infoBackdropTrackID: String?
    private lazy var ciContext = CIContext(options: nil)
    private var slots: [Slot] = []
    private var timer: Timer?
    private var glide: Glide?
    private var drag: Drag?
    private var flickTimer: Timer?
    private var flickVelocity: Double = 0
    private var flickLast: CFTimeInterval = 0
    private var didLogOnce = false
    private var didLogAfter = false

    private struct Slot {
        let cover: CALayer
        let reflection: CALayer
        var trackID: String?
        var index: Int?
    }
    private struct Glide {
        var target: Double
        var velocity: Double
        var last: CFTimeInterval
        let started: CFTimeInterval
        let stiffness: Double
        let damping: Double
    }
    private struct Drag {
        let startX: CGFloat
        let startPosition: Double
        var lastX: CGFloat
        var lastTime: CFTimeInterval
        var velocity: Double
        var moved: Bool
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        timer?.invalidate()
        marqueeTimer?.invalidate()
        flickTimer?.invalidate()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        allowedTouchTypes = [.direct]

        coverHost.frame = bounds
        coverHost.masksToBounds = false
        coverMask.backgroundColor = NSColor.white.cgColor
        coverHost.mask = coverMask
        layer?.addSublayer(coverHost)

        artView.imageScaling = .scaleAxesIndependently
        artView.wantsLayer = true
        artView.layer?.cornerRadius = CGFloat(settings.coverCorner)
        artView.layer?.masksToBounds = true
        artView.layer?.borderWidth = 0
        artView.layer?.borderColor = NSColor.clear.cgColor
        addSubview(artView)

        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.font = BarType.title()
        titleLabel.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.isHidden = true

        artistLabel.isEditable = false
        artistLabel.isBordered = false
        artistLabel.drawsBackground = false
        artistLabel.isSelectable = false
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.maximumNumberOfLines = 1
        artistLabel.font = BarType.artist()
        artistLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1)
        artistLabel.cell?.usesSingleLineMode = true
        artistLabel.isHidden = true

        indexLabel.isEditable = false
        indexLabel.isBordered = false
        indexLabel.drawsBackground = false
        indexLabel.isSelectable = false
        indexLabel.alignment = .center
        indexLabel.font = BarType.status()
        indexLabel.textColor = NSColor(calibratedWhite: 0.56, alpha: 1)
        addSubview(indexLabel)

        playingDot.wantsLayer = true
        playingDot.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.85).cgColor
        playingDot.layer?.cornerRadius = 1.5
        playingDot.isHidden = true
        addSubview(playingDot)

        applyFadeColors()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(settingsChanged),
                                               name: SettingsStore.changed,
                                               object: nil)
        fadeLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fadeLayer.endPoint = CGPoint(x: 1, y: 0.5)
        fadeLayer.zPosition = 5000
        fadeLayer.isHidden = ProcessInfo.processInfo.environment["TF_NOFADE"] == "1"
        coverHost.addSublayer(fadeLayer)

        for _ in 0..<160 {
            let cover = CALayer()
            cover.contentsGravity = .resizeAspectFill
            cover.masksToBounds = true
            cover.cornerRadius = 1.5
            cover.contentsScale = 2
            cover.borderWidth = 1
            cover.borderColor = NSColor(calibratedWhite: 0.88, alpha: 0.55).cgColor
            cover.minificationFilter = .trilinear
            coverHost.addSublayer(cover)

            let reflection = CALayer()
            reflection.contentsGravity = .resizeAspectFill
            reflection.masksToBounds = true
            reflection.cornerRadius = 1.5
            reflection.contentsScale = 2
            reflection.opacity = 0.18
            reflection.transform = CATransform3DMakeScale(1, -1, 1)
            reflection.isHidden = true
            coverHost.addSublayer(reflection)

            slots.append(Slot(cover: cover, reflection: reflection, trackID: nil, index: nil))
        }
    }

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 700, height: 30) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The cover art and index label are display-only; route every hit to
        // the bar itself so the left/right info split and close button work
        // even when the finger lands on a subview.
        bounds.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        let infoW = infoWidthForCurrentWidth
        let leftW = closeWidth + infoW
        coverHost.frame = bounds
        coverMask.frame = CGRect(x: leftW, y: 0, width: max(0, bounds.width - leftW), height: bounds.height)
        fadeLayer.frame = CGRect(x: leftW, y: 0, width: max(0, bounds.width - leftW), height: bounds.height)

        let hidePanel = settings.hideInfoPanel
        artView.isHidden = hidePanel
        indexLabel.isHidden = hidePanel
        artView.frame = NSRect(x: closeWidth + 3, y: 0, width: 30, height: 30)
        artView.layer?.cornerRadius = CGFloat(settings.coverCorner)
        artView.layer?.borderWidth = 0
        indexLabel.frame = NSRect(x: rightColumnX, y: 14.5, width: rightColumnWidth, height: 13)
        playingDot.isHidden = true
        updateCoverLayers(force: true)
        updateMarqueeTimer()
        needsDisplay = true
    }

    // MARK: - Public

    func configure(playlist: Playlist, playingIndex: Int?) {
        self.playlist = playlist
        self.playingIndex = playingIndex
        if let playingIndex, playingIndex >= 0, playingIndex < playlist.tracks.count {
            position = Double(playingIndex)
        } else {
            position = min(position, Double(max(0, playlist.tracks.count - 1)))
        }
        lastLabeledIndex = -1
        layoutSubtreeIfNeeded()
        updateLabelsIfNeeded()
        updateCoverLayers(force: true)
        needsDisplay = true
    }

    func setPlayingIndex(_ index: Int?) {
        guard playingIndex != index else { return }
        if playingIndex != index {
            lyrics = []
            lyricTrackID = nil
            lyricLineIndex = -1
            liveLyricText = ""
        }
        playingIndex = index
        updateLabelsIfNeeded(force: true)
        refreshDisplayText(force: true)
    }

    func setLiveLyric(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != liveLyricText else { return }
        liveLyricText = trimmed
        if let playingIndex, playingIndex == selectedIndex {
            refreshDisplayText(force: true)
        }
    }

    func clearLiveLyric() {
        guard !liveLyricText.isEmpty else { return }
        liveLyricText = ""
        if let playingIndex, playingIndex == selectedIndex {
            refreshDisplayText(force: true)
        }
    }

    func setLyrics(_ lines: [LyricLine], for trackID: String) {
        guard let playlist, let playingIndex,
              playingIndex >= 0, playingIndex < playlist.tracks.count,
              playlist.tracks[playingIndex].id == trackID else { return }
        lyrics = lines
        lyricTrackID = trackID
        lyricLineIndex = -1
        refreshDisplayText(force: true)
    }

    func clearLyrics() {
        lyrics = []
        lyricTrackID = nil
        lyricLineIndex = -1
        refreshDisplayText(force: true)
    }

    private func lyricIndex(at seconds: Double) -> Int {
        guard !lyrics.isEmpty else { return -1 }
        if seconds <= lyrics[0].time { return 0 }
        var found = 0
        for (i, line) in lyrics.enumerated() {
            if line.time <= seconds { found = i } else { break }
        }
        return found
    }

    private func refreshDisplayText(force: Bool = false) {
        var newTitle = selectedTitle
        var newArtist = selectedArtist
        var activeLyric = false
        if settings.lyricsEnabled, let playingIndex, playingIndex == selectedIndex {
            if !liveLyricText.isEmpty {
                newTitle = liveLyricText
                newArtist = ""
                activeLyric = true
            } else if !lyrics.isEmpty {
                let idx = lyricIndex(at: elapsedSeconds)
                if idx >= 0 && idx < lyrics.count {
                    newTitle = lyrics[idx].text
                    newArtist = ""
                    lyricLineIndex = idx
                    activeLyric = true
                }
            }
        }
        hasActiveLyric = activeLyric
        if force || newTitle != titleText || newArtist != artistText {
            titleText = newTitle
            artistText = newArtist
            resetMarquee()
        }
        updateBigLyricMode()
        needsDisplay = true
    }

    private func updateBigLyricMode() {
        let isCurrent = playingIndex == selectedIndex
        let started = isPlaying || elapsedSeconds > 0.2
        let newMode = isCurrent && hasActiveLyric && started && !titleText.isEmpty && !settings.hideInfoPanel
        if bigLyricMode != newMode {
            bigLyricMode = newMode
            bigLyricOffset = 0
            bigLyricPauseUntil = CACurrentMediaTime() + 0.3
            updateMarqueeTimer()
            needsDisplay = true
        }
        artView.isHidden = settings.hideInfoPanel
            || (bigLyricMode && !settings.keepCoverWithLyrics)
            || !transientText.isEmpty
    }

    private var bigLyricArea: NSRect {
        var minX = closeWidth + 8
        if bigLyricMode && settings.keepCoverWithLyrics {
            minX = artView.frame.maxX + 6
        }
        let maxX = max(minX + 10, rightColumnX - 8)
        return NSRect(x: minX, y: 0, width: maxX - minX, height: bounds.height)
    }

    private var bigLyricFont: NSFont {
        BarType.lyricFont(CGFloat(settings.lyricSize))
    }

    var isInteracting: Bool { drag != nil || glide != nil || flickTimer != nil }

    func scrollTo(index: Int) {
        guard let playlist, !playlist.tracks.isEmpty else { return }
        let target = max(0, min(playlist.tracks.count - 1, index))
        glide = nil
        timer?.invalidate(); timer = nil
        flickTimer?.invalidate(); flickTimer = nil
        flickVelocity = 0
        animate(to: Double(target), initialVelocity: 0)
    }

    func select(index: Int, play: Bool) {
        guard let playlist, !playlist.tracks.isEmpty else { return }
        let target = max(0, min(playlist.tracks.count - 1, index))
        glide = nil
        timer?.invalidate(); timer = nil
        flickTimer?.invalidate(); flickTimer = nil
        flickVelocity = 0
        position = Double(target)
        selectedIndex = target
        updateLabelsIfNeeded(force: true)
        updateCoverLayers(force: true)
        if play { onPlay?(target) }
    }

    func reloadVisibleImages() {
        updateCoverLayers(force: true)
    }

    func snapshot() -> NSImage {
        let rep = bitmapImageRepForCachingDisplay(in: bounds)
        guard let rep else { return NSImage(size: bounds.size) }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func applyFadeColors() {
        let strength = CGFloat(settings.edgeFade)
        let alpha = min(1, strength)
        // Above 100% the fade cannot get darker, so it widens instead:
        // 88% still fades over 12% of each side, 200% over ~23%.
        let extra = max(0, strength - 1)
        let width = 0.08 + 0.045 * min(1, strength) + 0.10 * extra
        fadeLayer.locations = [0.0, width, 1.0 - width, 1.0].map { NSNumber(value: Double($0)) }
        fadeLayer.colors = [
            NSColor(calibratedWhite: 0, alpha: alpha).cgColor,
            NSColor(calibratedWhite: 0, alpha: 0).cgColor,
            NSColor(calibratedWhite: 0, alpha: 0).cgColor,
            NSColor(calibratedWhite: 0, alpha: alpha).cgColor
        ]
    }

    @objc private func settingsChanged() {
        applyFadeColors()
        artView.layer?.cornerRadius = CGFloat(settings.coverCorner)
        // The info panel width feeds the cover host frame and its mask, so a
        // layout pass is required — otherwise hiding the panel leaves the old
        // mask in place and the left part of the bar stays empty.
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateCoverLayers(force: true)
        refreshDisplayText(force: true)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let infoW = infoWidthForCurrentWidth
        let leftW = closeWidth + infoW
        let infoRect = NSRect(x: closeWidth, y: 0, width: infoW, height: bounds.height)

        NSColor(calibratedWhite: 0.018, alpha: 1).setFill()
        rect.fill()

        if settings.hideInfoPanel {
            // Covers fill the whole bar: nothing else is drawn here.
            return
        }

        // Frosted information panel.  It is a blurred version of the
        // selected album art under a dark glass tint; text is drawn above it.
        let radius = CGFloat(settings.infoCorner)
        let glassPath = NSBezierPath(roundedRect: infoRect, xRadius: radius, yRadius: radius)

        if let backdrop = infoBackdrop {
            NSGraphicsContext.saveGraphicsState()
            glassPath.addClip()
            backdrop.draw(in: infoRect, from: .zero, operation: .sourceOver, fraction: 0.9)
            NSColor(calibratedWhite: 0.006, alpha: 0.66).setFill()
            infoRect.fill()
            let blend = NSGradient(colors: [
                NSColor(calibratedWhite: 0.02, alpha: 0),
                NSColor(calibratedWhite: 0.02, alpha: 0.96)
            ])
            blend?.draw(in: NSRect(x: leftW - 30, y: 0, width: 30, height: bounds.height), angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSGraphicsContext.saveGraphicsState()
            glassPath.addClip()
            NSColor(calibratedWhite: 0.025, alpha: 0.9).setFill()
            infoRect.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Round close button, no white outline/glow.
        let closeCircle = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 26, height: 26))
        NSColor(calibratedWhite: 0.185, alpha: 0.98).setFill()
        closeCircle.fill()
        NSColor(calibratedWhite: 0.94, alpha: 0.92).setStroke()
        let closePath = NSBezierPath()
        closePath.lineWidth = 1.35
        closePath.lineCapStyle = .round
        closePath.move(to: NSPoint(x: 11.0, y: 11.0))
        closePath.line(to: NSPoint(x: 19.0, y: 19.0))
        closePath.move(to: NSPoint(x: 19.0, y: 11.0))
        closePath.line(to: NSPoint(x: 11.0, y: 19.0))
        closePath.stroke()

        if !transientText.isEmpty && CACurrentMediaTime() < transientUntil {
            drawTransient(infoRect: infoRect)
        } else if bigLyricMode {
            drawBigLyric(infoRect: infoRect)
        } else {
            let titleFont = BarType.title()
            let artistFont = BarType.artist()
            drawMarquee(titleText, font: titleFont,
                        color: NSColor(calibratedWhite: 0.97, alpha: 1),
                        x: textLeft, y: 14.6, width: textMaxWidth,
                        offset: titleMarqueeOffset)
            drawMarquee(artistText, font: artistFont,
                        color: NSColor(calibratedWhite: 0.72, alpha: 1),
                        x: textLeft, y: 1.8, width: textMaxWidth,
                        offset: artistMarqueeOffset)
        }

        drawPlaybackIndicator()
    }

    private func drawTransient(infoRect: NSRect) {
        let area = bigLyricArea
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1)
        ]
        let size = (transientText as NSString).size(withAttributes: attrs)
        let rect = NSRect(x: area.midX - min(size.width, area.width) / 2,
                          y: (bounds.height - size.height) / 2 + 0.4,
                          width: min(size.width, area.width),
                          height: size.height)
        (transientText as NSString).draw(in: rect, withAttributes: attrs)
    }

    /// Largest lyric font (down to 9 pt) that still fits the whole line.
    private func fittedLyricFont(_ text: String, width: CGFloat) -> NSFont {
        var size = CGFloat(settings.lyricSize)
        while size > 3 {
            let candidate = BarType.lyricFont(size)
            let w = (text as NSString).size(withAttributes: [.font: candidate]).width
            if w <= width { return candidate }
            size -= 0.5
        }
        return BarType.lyricFont(3)
    }

    private func drawBigLyric(infoRect: NSRect) {
        let area = bigLyricArea
        let font = settings.autoFitLyricFont ? fittedLyricFont(titleText, width: area.width) : bigLyricFont
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.97, alpha: 1)
        ]
        let textSize = (titleText as NSString).size(withAttributes: attrs)
        if settings.autoFitLyricFont || textSize.width <= area.width {
            let rect = NSRect(x: area.midX - textSize.width / 2,
                              y: (bounds.height - textSize.height) / 2 + 0.4,
                              width: textSize.width,
                              height: textSize.height)
            (titleText as NSString).draw(in: rect, withAttributes: attrs)
        } else {
            // Repeat "lyric + spaces" so the line loops seamlessly instead of
            // scrolling away once and resetting.
            let unit = titleText + "    "
            let unitAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(calibratedWhite: 0.97, alpha: 1)
            ]
            let unitW = (unit as NSString).size(withAttributes: unitAttrs).width
            guard unitW > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
            let o = bigLyricOffset.truncatingRemainder(dividingBy: unitW)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: area.minX, y: 0, width: area.width, height: bounds.height))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            let y = (bounds.height - textSize.height) / 2 + 0.4
            for i in 0..<3 {
                (unit as NSString).draw(at: NSPoint(x: area.minX - o + CGFloat(i) * unitW, y: y),
                                         withAttributes: unitAttrs)
            }
            // Fade the scrolling line into the edges; width is user adjustable.
            let fadeW = min(CGFloat(settings.lyricFade), area.width / 2)
            if fadeW > 0.5 {
                ctx.setBlendMode(.destinationOut)
                let leftFade = NSGradient(colors: [
                    NSColor(calibratedWhite: 0, alpha: 1),
                    NSColor(calibratedWhite: 0, alpha: 0)
                ])
                leftFade?.draw(in: NSRect(x: area.minX, y: 0, width: fadeW, height: bounds.height), angle: 0)
                let rightFade = NSGradient(colors: [
                    NSColor(calibratedWhite: 0, alpha: 0),
                    NSColor(calibratedWhite: 0, alpha: 1)
                ])
                rightFade?.draw(in: NSRect(x: area.maxX - fadeW, y: 0, width: fadeW, height: bounds.height), angle: 0)
                ctx.setBlendMode(.normal)
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    private func drawPlaybackIndicator() {
        let font = BarType.status()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1)
        ]
        let selectedIsCurrent = playingIndex == selectedIndex
        let timeText = selectedIsCurrent ? timeString(elapsedSeconds) : durationText
        let durationWidth = (timeText as NSString).size(withAttributes: attrs).width
        let iconWidth: CGFloat = 6
        let gap: CGFloat = 5
        let total = iconWidth + gap + durationWidth
        let startX = rightColumnX + (rightColumnWidth - total) / 2
        // Align the glyph with the digits, not with the line box.  Measured on
        // the rendered 9 pt status text: its ink spans rowBottom+3.5 … +9.5,
        // i.e. its optical centre is 6.5 pt above the row bottom.
        let rowBottom: CGFloat = 2.0
        let iconHeight: CGFloat = 7.0
        let textCenterY = rowBottom + 6.5
        let iconBottom = textCenterY - iconHeight / 2

        let selectedIsPlaying = isPlaying && selectedIsCurrent
        NSColor(calibratedWhite: 0.78, alpha: 0.95).setFill()
        if selectedIsPlaying {
            NSRect(x: startX, y: iconBottom, width: 2.2, height: iconHeight).fill()
            NSRect(x: startX + 3.8, y: iconBottom, width: 2.2, height: iconHeight).fill()
        } else {
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: startX, y: iconBottom))
            triangle.line(to: NSPoint(x: startX, y: iconBottom + iconHeight))
            triangle.line(to: NSPoint(x: startX + iconWidth, y: iconBottom + iconHeight / 2))
            triangle.close()
            triangle.fill()
        }
        (timeText as NSString).draw(at: NSPoint(x: startX + iconWidth + gap, y: rowBottom),
                                    withAttributes: attrs)
    }

    // MARK: - Layout of the fan

    private func updateCoverLayers(force: Bool = false) {
        guard let playlist, !playlist.tracks.isEmpty else {
            for slot in slots {
                slot.cover.isHidden = true
                slot.reflection.isHidden = true
            }
            return
        }
        let infoW = infoWidthForCurrentWidth
        let leftW = closeWidth + infoW
        let flowW = max(1, bounds.width - leftW)
        // Hiding the info panel frees the left part for covers but must not
        // move the main sleeve: keep the fan centred on the normal layout.
        let anchorLeft = 30 + (infoW == 0 ? infoWidthBase : infoW)
        let centerX = settings.hideInfoPanel
            ? anchorLeft + (bounds.width - anchorLeft) / 2
            : leftW + flowW / 2
        let count = playlist.tracks.count
        // How many indices are needed to reach either edge of the bar; with the
        // info panel hidden the fan sits right of centre, so a symmetric
        // flowW/2 window would leave the left edge empty.
        let limit = Int(max(centerX, bounds.width - centerX) / max(1, spacing)) + visibleSlack
        // position can drift past either end while the user overdrags, so the
        // floored index must be clamped before it indexes into the queue.
        let base = min(max(0, Int(floor(position.isFinite ? position : 0))), max(0, count - 1))
        var used = 0
        var visibleIDs = Set<String>()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Walk outwards from the centred sleeve so a tight spacing never
        // exhausts the slot pool on one side (which used to push the main
        // cover off-centre).
        var order: [Int] = [base]
        order.reserveCapacity(limit * 2 + 1)
        for offset in 1...max(1, limit) {
            if base + offset < count { order.append(base + offset) }
            if base - offset >= 0 { order.append(base - offset) }
        }
        for index in order {
            let d = Double(index) - position
            let ad = abs(d)
            if ad > Double(limit) { continue }
            guard index >= 0, index < count else { continue }
            let track = playlist.tracks[index]
            visibleIDs.insert(track.id)
            guard used < slots.count else { break }
            var slot = slots[used]
            used += 1

            let distance = abs(d)
            let direction: CGFloat = d < 0 ? -1 : 1
            // The sleeves beside the main one normally sit further away; the
            // "even spacing" option drops that extra gap.
            let xOffset: CGFloat
            if settings.evenSpacing {
                xOffset = CGFloat(d) * spacing
            } else {
                xOffset = distance <= 1
                    ? CGFloat(d) * centerGap
                    : direction * (centerGap + CGFloat(distance - 1) * spacing)
            }
            let x = centerX + xOffset
            let isCenter = index == selectedIndex
            // The three central sleeves get a wider gap.  The sleeves right
            // beside the selected one are turned further (about 60°) than the
            // outer fan.
            let tilt = CGFloat(settings.tiltDegrees * .pi / 180)
            let slope: CGFloat = settings.uniformTilt ? 1.0 : 0.833
            let magnitude = settings.flatCovers ? 0 : min(tilt, CGFloat(abs(d)) * tilt * slope)
            let angle = d < 0 ? magnitude : -magnitude
            let y = 15.0
            // Size follows the distance from the centre continuously, so a
            // side sleeve grows into the main sleeve while it slides in.
            let t = min(1.0, CGFloat(abs(d)))
            let eased = t * t * (3 - 2 * t)
            let side = CGFloat(settings.sideCoverSize)
            let sleeve: CGFloat
            if settings.flatCovers {
                sleeve = 30.0
            } else if settings.equalSideSize {
                // Constant side size; only the very centre grows to the main size.
                let blend = min(1, max(0, (0.5 - CGFloat(abs(d))) / 0.5))
                sleeve = side + (30.0 - side) * blend
            } else {
                sleeve = 30.0 - (30.0 - side) * eased
            }

            var transform = CATransform3DIdentity
            transform.m34 = -1.0 / 180.0
            transform = CATransform3DRotate(transform, angle, 0, 1, 0)

            let cover = slot.cover
            cover.isHidden = false
            slot.index = index
            cover.bounds = CGRect(x: 0, y: 0, width: sleeve, height: sleeve)
            // Radius is user controlled; the centred sleeve uses the main
            // value, the others the side value, blended while it slides in.
            let mainRadius = CGFloat(settings.mainCoverCorner)
            let sideRadius = CGFloat(settings.sideCoverCorner)
            cover.cornerRadius = sideRadius + (mainRadius - sideRadius) * (1 - eased)
            cover.position = CGPoint(x: x, y: y)
            let flat = ProcessInfo.processInfo.environment["TF_FLAT"] == "1"
            cover.transform = flat ? CATransform3DIdentity : transform
            cover.zPosition = flat ? CGFloat(index + 1) : (1000 - CGFloat(ad) * 10 + (isCenter ? 100 : 0))
            // Dim by screen distance, not by index distance: with a tight
            // spacing the index-based falloff made covers a few pixels away
            // look half transparent.
            let edgeT = min(1, abs(x - centerX) / max(1, flowW / 2))
            cover.opacity = Float(1.0 - 0.25 * edgeT)
            cover.borderWidth = isCenter ? 0.6 : 0
            cover.borderColor = isCenter
                ? NSColor(calibratedWhite: 1, alpha: 0.92).cgColor
                : NSColor.clear.cgColor

            if ProcessInfo.processInfo.environment["TF_RED"] == "1" {
                cover.backgroundColor = NSColor.red.cgColor
                cover.contents = nil
                cover.borderWidth = 0
            } else if slot.trackID != track.id {
                slot.trackID = track.id
                if let cached = ImageStore.shared.cached(track) {
                    cover.contents = cached.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    cover.backgroundColor = NSColor.clear.cgColor
                } else {
                    // No placeholder: a placeholder would be stretched into a
                    // blurred sleeve before the real artwork arrives.
                    cover.contents = nil
                    cover.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1).cgColor
                    ImageStore.shared.image(for: track) { [weak self, weak cover] image in
                        guard let self, let cover, let image,
                              let current = self.slots.first(where: { $0.cover === cover }),
                              current.trackID == track.id else { return }
                        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        cover.contents = cg
                        cover.backgroundColor = NSColor.clear.cgColor
                        CATransaction.commit()
                    }
                }
            }

            slots[used - 1] = slot
        }

        for i in used..<slots.count {
            slots[i].cover.isHidden = true
            slots[i].reflection.isHidden = true
            slots[i].trackID = nil
            slots[i].index = nil
        }
        CATransaction.commit()
        if !didLogAfter {
            didLogAfter = true
            print("AFTER used=\(used) pos=\(position) centerX=\(centerX)")
            for k in 0..<min(6, used) {
                print("LAYER \(k) pos=\(slots[k].cover.position) hidden=\(slots[k].cover.isHidden) op=\(slots[k].cover.opacity) z=\(slots[k].cover.zPosition)")
            }
        }
        _ = visibleIDs
        _ = force
    }

    private func updateLabelsIfNeeded(force: Bool = false) {
        guard let playlist, !playlist.tracks.isEmpty else { return }
        let idx = max(0, min(playlist.tracks.count - 1, Int(round(position))))
        selectedIndex = idx
        guard force || idx != lastLabeledIndex else { return }
        lastLabeledIndex = idx
        let track = playlist.tracks[idx]
        selectedTitle = track.title
        selectedArtist = track.artist
        refreshDisplayText(force: true)
        indexLabel.stringValue = "\(idx + 1) / \(playlist.tracks.count)"
        playingDot.isHidden = true
        let seconds = Int(round(track.duration > 10000 ? track.duration / 1000.0 : track.duration))
        durationText = seconds > 0 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : "--:--"
        artView.image = ImageStore.shared.cached(track)
        ImageStore.shared.image(for: track) { [weak self] image in
            guard let self, let image, self.selectedIndex == idx else { return }
            self.artView.image = image
        }
        refreshInfoBackdrop(for: track, index: idx)
        onSelection?(idx)
        needsDisplay = true
    }

    func showTransient(_ text: String) {
        transientText = text
        transientUntil = CACurrentMediaTime() + 1.8
        transientTimer?.invalidate()
        let timer = Timer(timeInterval: 1.8, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.transientText = ""
            self.transientUntil = 0
            self.transientTimer = nil
            self.updateBigLyricMode()
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        transientTimer = timer
        artView.isHidden = true
        needsDisplay = true
    }

    func setPlayingState(_ playing: Bool) {
        isPlaying = playing
        updateBigLyricMode()
        needsDisplay = true
    }

    func setElapsed(_ seconds: Double) {
        elapsedSeconds = max(0, seconds)
        if let playingIndex, playingIndex == selectedIndex, !lyrics.isEmpty {
            refreshDisplayText()
        }
        updateBigLyricMode()
        needsDisplay = true
    }

    private func timeString(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func refreshInfoBackdrop(for track: Track, index: Int) {
        infoBackdropTrackID = track.id
        if let cached = ImageStore.shared.cached(track) {
            setBackdrop(from: cached, trackID: track.id, index: index)
        } else {
            infoBackdrop = nil
            needsDisplay = true
            ImageStore.shared.image(for: track) { [weak self] image in
                guard let self, let image, self.selectedIndex == index,
                      self.infoBackdropTrackID == track.id else { return }
                self.setBackdrop(from: image, trackID: track.id, index: index)
            }
        }
    }

    private func setBackdrop(from image: NSImage, trackID: String, index: Int) {
        guard infoBackdropTrackID == trackID, selectedIndex == index,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let ci = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(22.0, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: ci.extent),
              let blurred = ciContext.createCGImage(output, from: ci.extent) else { return }
        // Crop a long strip from the cover at the information bar's aspect
        // ratio; scale that strip, never the square sleeve.
        let sourceW = CGFloat(cg.width), sourceH = CGFloat(cg.height)
        let targetAspect = max(0.1, infoWidth / 30.0)
        let cropH = min(sourceH, sourceW / targetAspect)
        let cropRect = CGRect(x: 0, y: (sourceH - cropH) / 2, width: sourceW, height: cropH)
        guard let strip = cg.cropping(to: cropRect) else { return }
        let stripCI = CIImage(cgImage: strip)
        filter.setValue(stripCI, forKey: kCIInputImageKey)
        guard let stripOutput = filter.outputImage?.cropped(to: stripCI.extent),
              let stripBlurred = ciContext.createCGImage(stripOutput, from: stripCI.extent) else { return }
        infoBackdrop = NSImage(cgImage: stripBlurred, size: NSSize(width: infoWidth, height: 30))
        needsDisplay = true
    }

    // MARK: - Animation

    private var now: CFTimeInterval { CACurrentMediaTime() }

    private func animate(to target: Double, duration: Double? = nil,
                         initialVelocity: Double = 0,
                         stiffness: Double = 26.0, damping: Double = 11.0) {
        guard let playlist, !playlist.tracks.isEmpty else { return }
        _ = duration
        let clamped = max(0, min(Double(playlist.tracks.count - 1), target))
        if abs(clamped - position) < 0.0005 && abs(initialVelocity) < 0.01 {
            position = clamped
            updateLabelsIfNeeded()
            updateCoverLayers()
            return
        }
        glide = Glide(target: clamped, velocity: initialVelocity,
                      last: now, started: now,
                      stiffness: stiffness, damping: damping)
        if timer == nil {
            timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    @objc private func tick() {
        guard var g = glide, let playlist else {
            timer?.invalidate(); timer = nil; return
        }
        let t = now
        let dt = min(0.04, max(0.001, t - g.last))
        g.last = t

        // Critically damped spring.  It leaves rest slowly, accelerates, then
        // has a long exponential landing — the same natural glide as the
        // inertial flick, not a hard ease ending.
        let displacement = g.target - position
        g.velocity += displacement * g.stiffness * dt
        g.velocity *= exp(-g.damping * dt)
        position += g.velocity * dt

        let settled = abs(g.target - position) < 0.002 && abs(g.velocity) < 0.02
        if settled || t - g.started > 4.0 {
            position = g.target
            glide = nil
            timer?.invalidate(); timer = nil
        } else {
            glide = g
        }
        updateLabelsIfNeeded()
        updateCoverLayers()
    }

    // MARK: - Input

    override func touchesBegan(with event: NSEvent) {
        guard let touch = event.touches(matching: .began, in: self).first as? NSTouch else { return }
        beginDrag(at: touch.location(in: self))
    }

    override func touchesMoved(with event: NSEvent) {
        guard let touch = event.touches(matching: .moved, in: self).first as? NSTouch else { return }
        moveDrag(to: touch.location(in: self).x)
    }

    override func touchesEnded(with event: NSEvent) {
        guard let touch = event.touches(matching: .ended, in: self).first as? NSTouch else {
            endDrag()
            return
        }
        endDrag(at: touch.location(in: self).x)
    }

    override func touchesCancelled(with event: NSEvent) {
        drag = nil
    }

    override func mouseDown(with event: NSEvent) {
        beginDrag(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        moveDrag(to: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        endDrag(at: convert(event.locationInWindow, from: nil).x)
    }

    private func beginDrag(at point: CGPoint) {
        let x = point.x
        if x < closeWidth {
            onClose?()
            drag = nil
            return
        }
        if statusHitRect.contains(point) {
            onTogglePlay?(selectedIndex)
            drag = nil
            return
        }
        if !bigLyricMode && artHitRect.contains(point) {
            // The left cover is the selected track's cover: tapping it starts
            // that track (or toggles it when it is already playing).
            onTogglePlay?(selectedIndex)
            drag = nil
            return
        }
        if x < closeWidth + infoWidthForCurrentWidth {
            onReturnToCurrent?()
            drag = nil
            return
        }
        guard let playlist, x >= closeWidth + infoWidthForCurrentWidth, !playlist.tracks.isEmpty else { return }
        glide = nil
        timer?.invalidate(); timer = nil
        flickTimer?.invalidate(); flickTimer = nil
        flickVelocity = 0
        let now = CACurrentMediaTime()
        drag = Drag(startX: x, startPosition: position, lastX: x, lastTime: now,
                    velocity: 0, moved: false)
    }

    private func moveDrag(to x: CGFloat) {
        guard var drag, let playlist else { return }
        let dx = x - drag.startX
        let now = CACurrentMediaTime()
        let dt = max(0.001, now - drag.lastTime)
        let stepX = x - drag.lastX
        if abs(dx) + abs(stepX) > 0.4 { drag.moved = true }
        drag.velocity = -Double(stepX) / Double(spacing) / dt
        drag.lastX = x
        drag.lastTime = now
        self.drag = drag
        var p = drag.startPosition - Double(dx) / Double(spacing)
        // A one-track list has no destination; still allow a visible
        // overdrag so the spring-back is perceptible.
        let edgeResistance = playlist.tracks.count == 1 ? 0.5 : 0.28
        if p < 0 { p *= edgeResistance }
        if p > Double(playlist.tracks.count - 1) {
            p = Double(playlist.tracks.count - 1)
                + (p - Double(playlist.tracks.count - 1)) * edgeResistance
        }
        position = p
        updateLabelsIfNeeded()
        updateCoverLayers()
    }

    private func endDrag(at x: CGFloat? = nil) {
        guard let drag, let playlist else { return }
        self.drag = nil
        let endX = x ?? drag.lastX
        if drag.moved {
            let maxIndex = Double(playlist.tracks.count - 1)
            let target = Double(max(0, min(playlist.tracks.count - 1, Int(round(position)))))
            // At the ends (including a one-track list), the position is
            // outside the valid range. Animate the spring from that overdrag
            // position; the flick loop would clamp to 0 first and swallow the
            // rebound.
            if position < 0 || position > maxIndex {
                // Strong, quick edge rebound; the general glide spring is
                // intentionally long and would feel sluggish here.
                animate(to: target, initialVelocity: 0,
                        stiffness: 220.0, damping: 26.0)
            } else {
                let age = CACurrentMediaTime() - drag.lastTime
                if age < 0.12, abs(drag.velocity) > 1.0 {
                    startFlick(velocity: drag.velocity)
                } else {
                    animate(to: target)
                }
            }
        } else {
            let idx = indexAt(x: endX)
            position = Double(idx)
            updateLabelsIfNeeded(force: true)
            updateCoverLayers(force: true)
            animateTap(on: idx) { [weak self] in
                self?.onPlay?(idx)
            }
        }
    }

    private func animateTap(on index: Int, completion: @escaping () -> Void) {
        guard let slot = slots.first(where: { $0.index == index && !$0.cover.isHidden }) else {
            completion()
            return
        }
        let baseTransform = slot.cover.transform
        let basePosition = slot.cover.position
        let pressedTransform = CATransform3DScale(baseTransform, 0.84, 0.84, 1)
        let pressedPosition = CGPoint(x: basePosition.x, y: basePosition.y - 1.5)

        let transform = CAKeyframeAnimation(keyPath: "transform")
        transform.values = [NSValue(caTransform3D: baseTransform),
                            NSValue(caTransform3D: pressedTransform),
                            NSValue(caTransform3D: baseTransform)]
        transform.keyTimes = [0, 0.36, 1]

        let position = CAKeyframeAnimation(keyPath: "position")
        position.values = [NSValue(point: basePosition),
                           NSValue(point: pressedPosition),
                           NSValue(point: basePosition)]
        position.keyTimes = [0, 0.36, 1]

        let group = CAAnimationGroup()
        group.animations = [transform, position]
        group.duration = 0.26
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = true
        slot.cover.add(group, forKey: "tapPress")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            completion()
        }
    }

    private func startFlick(velocity: Double) {
        guard let playlist, !playlist.tracks.isEmpty else { return }
        glide = nil
        timer?.invalidate(); timer = nil
        flickVelocity = velocity
        flickLast = CACurrentMediaTime()
        flickTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickFlick()
        }
        RunLoop.main.add(t, forMode: .common)
        flickTimer = t
    }

    private func tickFlick() {
        guard let playlist, !playlist.tracks.isEmpty else {
            flickTimer?.invalidate(); flickTimer = nil
            return
        }
        let now = CACurrentMediaTime()
        let dt = min(0.05, max(0.001, now - flickLast))
        flickLast = now
        position += flickVelocity * dt
        let maxIndex = Double(playlist.tracks.count - 1)
        if position < 0 { position = 0; flickVelocity = 0 }
        if position > maxIndex { position = maxIndex; flickVelocity = 0 }
        flickVelocity *= exp(-2.2 * dt)
        updateLabelsIfNeeded()
        updateCoverLayers()
        if abs(flickVelocity) < 0.28 {
            flickTimer?.invalidate(); flickTimer = nil
            animate(to: Double(max(0, min(playlist.tracks.count - 1, Int(round(position))))),
                    initialVelocity: flickVelocity)
        }
    }

    private func indexAt(x: CGFloat) -> Int {
        guard let playlist, !playlist.tracks.isEmpty else { return 0 }
        let leftW = closeWidth + infoWidthForCurrentWidth
        let flowW = max(1, bounds.width - leftW)
        let center = leftW + flowW / 2
        let dx = x - center
        let adx = abs(dx)
        let rawDistance: Double
        if adx <= centerGap {
            rawDistance = Double(dx / centerGap)
        } else {
            let sign: Double = dx < 0 ? -1 : 1
            rawDistance = sign * (1.0 + Double(adx - centerGap) / Double(spacing))
        }
        let raw = position + rawDistance
        return max(0, min(playlist.tracks.count - 1, Int(round(raw))))
    }

    private var infoWidthForCurrentWidth: CGFloat {
        if settings.hideInfoPanel { return 0 }
        return infoWidthBase
    }

    private var infoWidthBase: CGFloat {
        min(infoWidth, max(176, bounds.width * 0.34))
    }

    private var rightColumnX: CGFloat {
        closeWidth + infoWidthForCurrentWidth - rightColumnWidth - 4
    }

    private var textLeft: CGFloat { closeWidth + 38 }

    private var textMaxWidth: CGFloat {
        max(40, rightColumnX - textLeft - 6)
    }

    private var toggleRect: NSRect {
        NSRect(x: rightColumnX, y: 0.5, width: rightColumnWidth, height: 13.5)
    }

    private var statusHitRect: NSRect {
        NSRect(x: rightColumnX - 2, y: 0, width: rightColumnWidth + 4, height: bounds.height)
    }

    private var artHitRect: NSRect {
        NSRect(x: closeWidth + 1, y: 0, width: 36, height: bounds.height)
    }

    private func resetMarquee() {
        titleMarqueeOffset = 0
        artistMarqueeOffset = 0
        let now = CACurrentMediaTime()
        titlePauseUntil = now + 3.0
        artistPauseUntil = now + 3.0
        bigLyricOffset = 0
        bigLyricPauseUntil = now + 0.3
        marqueeLastTick = now
        updateMarqueeTimer()
    }

    private func updateMarqueeTimer() {
        if bigLyricMode {
            let textW = (titleText as NSString).size(withAttributes: [.font: bigLyricFont]).width
            if textW > bigLyricArea.width {
                if marqueeTimer == nil {
                    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                        self?.tickMarquee()
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    marqueeTimer = timer
                    marqueeLastTick = CACurrentMediaTime()
                }
            } else {
                marqueeTimer?.invalidate()
                marqueeTimer = nil
                bigLyricOffset = 0
            }
            return
        }
        let titleFont = BarType.title()
        let artistFont = BarType.artist()
        let maxW = textMaxWidth
        let titleW = (titleText as NSString).size(withAttributes: [.font: titleFont]).width
        let artistW = (artistText as NSString).size(withAttributes: [.font: artistFont]).width
        let needed = titleW > maxW || artistW > maxW
        if needed {
            if marqueeTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    self?.tickMarquee()
                }
                RunLoop.main.add(timer, forMode: .common)
                marqueeTimer = timer
                marqueeLastTick = CACurrentMediaTime()
            }
        } else {
            marqueeTimer?.invalidate()
            marqueeTimer = nil
            titleMarqueeOffset = 0
            artistMarqueeOffset = 0
        }
    }

    private func tickMarquee() {
        let now = CACurrentMediaTime()
        let dt = min(0.08, max(0, now - marqueeLastTick))
        marqueeLastTick = now
        if bigLyricMode {
            let unit = titleText + "    "
            let unitW = (unit as NSString).size(withAttributes: [.font: bigLyricFont]).width
            let width = bigLyricArea.width
            guard unitW > width else { return }
            guard now >= bigLyricPauseUntil else { return }
            bigLyricOffset += CGFloat(settings.lyricSpeed) * CGFloat(dt)
            if bigLyricOffset >= unitW { bigLyricOffset = 0 }
            needsDisplay = true
            return
        }
        let titleFont = BarType.title()
        let artistFont = BarType.artist()
        let maxW = textMaxWidth
        let titleW = (titleText as NSString).size(withAttributes: [.font: titleFont]).width
        let artistW = (artistText as NSString).size(withAttributes: [.font: artistFont]).width
        let speed: CGFloat = 12.0
        let gap: CGFloat = 14.0
        var changed = false
        if titleW > maxW, now >= titlePauseUntil {
            titleMarqueeOffset += speed * CGFloat(dt)
            let span = titleW + gap
            if titleMarqueeOffset >= span {
                titleMarqueeOffset = 0
                titlePauseUntil = now + 3.0
            }
            changed = true
        }
        if artistW > maxW, now >= artistPauseUntil {
            artistMarqueeOffset += speed * CGFloat(dt)
            let span = artistW + gap
            if artistMarqueeOffset >= span {
                artistMarqueeOffset = 0
                artistPauseUntil = now + 3.0
            }
            changed = true
        }
        if changed { needsDisplay = true }
    }

    private func drawMarquee(_ text: String, font: NSFont, color: NSColor,
                             x: CGFloat, y: CGFloat, width: CGFloat, offset: CGFloat) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let ns = text as NSString
        let textWidth = ns.size(withAttributes: attrs).width
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x, y: 0, width: width, height: bounds.height))
        if textWidth <= width {
            ns.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        } else {
            let gap: CGFloat = 14
            let span = textWidth + gap
            let o = offset.truncatingRemainder(dividingBy: span)
            // One copy only; no second copy is stitched in from the right.
            // Fade the text alpha in an isolated transparency layer so the
            // gradient never paints a dark band over the background or the
            // neighbouring sleeves.
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ns.draw(at: NSPoint(x: x - o, y: y), withAttributes: attrs)
            ctx.setBlendMode(.destinationOut)
            let rightFade = NSGradient(colors: [
                NSColor(calibratedWhite: 0, alpha: 0),
                NSColor(calibratedWhite: 0, alpha: 0.98)
            ])
            rightFade?.draw(in: NSRect(x: x + width - 28, y: 0, width: 28, height: bounds.height), angle: 0)
            if offset > 0.5 {
                let leftFade = NSGradient(colors: [
                    NSColor(calibratedWhite: 0, alpha: 0.88),
                    NSColor(calibratedWhite: 0, alpha: 0)
                ])
                leftFade?.draw(in: NSRect(x: x, y: 0, width: 18, height: bounds.height), angle: 0)
            }
            ctx.setBlendMode(.normal)
            ctx.endTransparencyLayer()
        }
        ctx.restoreGState()
    }

    private func fitted(_ text: String, font: NSFont, width: CGFloat) -> String {
        guard !text.isEmpty else { return "" }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attrs).width <= width { return text }
        var value = text
        while !value.isEmpty {
            value.removeLast()
            let candidate = value + "…"
            if (candidate as NSString).size(withAttributes: attrs).width <= width {
                return candidate
            }
        }
        return "…"
    }
}
