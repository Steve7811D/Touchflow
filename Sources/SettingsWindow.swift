import AppKit

/// A labelled slider that reports every change immediately.
final class SliderRow: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let format: (Double) -> String
    private let onChange: (Double) -> Void

    init(title: String, range: ClosedRange<Double>, value: Double,
         format: @escaping (Double) -> String,
         onChange: @escaping (Double) -> Void) {
        self.format = format
        self.onChange = onChange
        super.init(frame: .zero)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.textColor = .labelColor
        valueLabel.stringValue = format(value)

        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.controlSize = .small

        for view in [titleLabel, slider, valueLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 128),

            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 58),

            slider.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            slider.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -10),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func sliderChanged() {
        valueLabel.stringValue = format(slider.doubleValue)
        onChange(slider.doubleValue)
    }

    func setValue(_ value: Double) {
        slider.doubleValue = value
        valueLabel.stringValue = format(value)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var rows: [SliderRow] = []
    private var uniformToggle: NSButton!
    private var evenSpacingToggle: NSButton!
    private var flatCoversToggle: NSButton!
    private var keepAwakeToggle: NSButton!
    private var hideInfoToggle: NSButton!
    private var equalSideToggle: NSButton!
    private var lyricsToggle: NSButton!
    private var keepCoverToggle: NSButton!
    private var autoFitToggle: NSButton!

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 906),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "TouchFlow 设置"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 620)
        window.maxSize = NSSize(width: 760, height: 1200)
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        reloadFromStore()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        scrollToTop()
        // The document height only exists after the first layout pass.
        DispatchQueue.main.async { [weak self] in self?.scrollToTop() }
    }

    /// The document view is flipped, so y = 0 is the first row.  Clamp the
    /// clip view there whenever the panel is shown or resized.
    private func scrollToTop() {
        guard let scroll = window?.contentView as? NSScrollView else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func buildContent() {
        let settings = SettingsStore.shared.values
        rows.removeAll()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The settings stack lives in a scroll view so shrinking the window
        // never hides the lower rows.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = scroll

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document

        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18)
        ])

        // MARK: 封面流
        stack.addArrangedSubview(header("封面流"))
        rows.append(slider("侧封面大小", range: FlowSettings.sideCoverRange,
                           value: settings.sideCoverSize, format: { String(format: "%.0f pt", $0) }) {
            SettingsStore.shared.values.sideCoverSize = $0
        })
        rows.append(slider("倾斜角度", range: FlowSettings.tiltRange,
                           value: settings.tiltDegrees, format: { String(format: "%.0f°", $0) }) {
            SettingsStore.shared.values.tiltDegrees = $0
        })
        rows.append(slider("封面间距", range: FlowSettings.spacingRange,
                           value: settings.spacing, format: { String(format: "%.0f pt", $0) }) {
            SettingsStore.shared.values.spacing = $0
        })
        rows.append(slider("主封面两侧距离", range: FlowSettings.centerGapRange,
                           value: settings.centerGap, format: { String(format: "%.0f pt", $0) }) {
            SettingsStore.shared.values.centerGap = $0
        })
        rows.append(slider("主封面圆角", range: FlowSettings.coverCornerRange,
                           value: settings.mainCoverCorner, format: { String(format: "%.1f pt", $0) }) {
            SettingsStore.shared.values.mainCoverCorner = $0
        })
        rows.append(slider("侧封面圆角", range: FlowSettings.coverCornerRange,
                           value: settings.sideCoverCorner, format: { String(format: "%.1f pt", $0) }) {
            SettingsStore.shared.values.sideCoverCorner = $0
        })
        for row in rows { stack.addArrangedSubview(row) }

        // MARK: 排布
        stack.addArrangedSubview(spacer(12))
        stack.addArrangedSubview(header("排布"))

        uniformToggle = checkbox("所有侧封面使用同一倾斜角", settings.uniformTilt,
                                 action: #selector(toggleUniform(_:)))
        evenSpacingToggle = checkbox("所有封面等距（取消主封面两侧加宽）", settings.evenSpacing,
                                     action: #selector(toggleEvenSpacing(_:)))
        flatCoversToggle = checkbox("所有封面等大平铺（关闭 3D 倾斜）", settings.flatCovers,
                                    action: #selector(toggleFlatCovers(_:)))
        equalSideToggle = checkbox("侧封面等大（不随距离缩小）", settings.equalSideSize,
                                   action: #selector(toggleEqualSide(_:)))
        hideInfoToggle = checkbox("隐藏信息栏与关闭按钮", settings.hideInfoPanel,
                                  action: #selector(toggleHideInfo(_:)))
        for toggle in [uniformToggle, evenSpacingToggle, flatCoversToggle, equalSideToggle, hideInfoToggle] {
            stack.addArrangedSubview(toggle!)
        }

        // MARK: 歌词
        stack.addArrangedSubview(spacer(12))
        stack.addArrangedSubview(header("歌词"))
        rows.append(slider("歌词字号", range: FlowSettings.lyricSizeRange,
                           value: settings.lyricSize, format: { String(format: "%.1f pt", $0) }) {
            SettingsStore.shared.values.lyricSize = $0
        })
        rows.append(slider("歌词两侧渐隐", range: FlowSettings.lyricFadeRange,
                           value: settings.lyricFade, format: { String(format: "%.0f pt", $0) }) {
            SettingsStore.shared.values.lyricFade = $0
        })
        for row in rows.suffix(2) { stack.addArrangedSubview(row) }

        lyricsToggle = checkbox("显示歌词", settings.lyricsEnabled,
                                action: #selector(toggleLyrics(_:)))
        keepCoverToggle = checkbox("歌词模式保留封面（歌词在右侧）", settings.keepCoverWithLyrics,
                                   action: #selector(toggleKeepCover(_:)))
        autoFitToggle = checkbox("歌词自动缩放字体（整句显示）", settings.autoFitLyricFont,
                                 action: #selector(toggleAutoFit(_:)))
        for toggle in [lyricsToggle, keepCoverToggle, autoFitToggle] {
            stack.addArrangedSubview(toggle!)
        }

        // MARK: 外观与文字
        stack.addArrangedSubview(spacer(12))
        stack.addArrangedSubview(header("外观与文字"))
        rows.append(slider("两侧渐隐", range: FlowSettings.fadeRange,
                           value: settings.edgeFade, format: { String(format: "%.0f%%", $0 * 100) }) {
            SettingsStore.shared.values.edgeFade = $0
        })
        rows.append(slider("歌词滚动速度", range: FlowSettings.lyricSpeedRange,
                           value: settings.lyricSpeed, format: { String(format: "%.0f", $0) }) {
            SettingsStore.shared.values.lyricSpeed = $0
        })
        rows.append(slider("信息栏圆角", range: FlowSettings.cornerRange,
                           value: settings.infoCorner, format: { String(format: "%.0f pt", $0) }) {
            SettingsStore.shared.values.infoCorner = $0
        })
        rows.append(slider("信息栏封面圆角", range: FlowSettings.coverCornerRange,
                           value: settings.coverCorner, format: { String(format: "%.0f pt", $0) }) {
            SettingsStore.shared.values.coverCorner = $0
        })
        for row in rows.suffix(4) { stack.addArrangedSubview(row) }

        // MARK: 行为
        stack.addArrangedSubview(spacer(12))
        stack.addArrangedSubview(header("行为"))
        keepAwakeToggle = checkbox("保持 Touch Bar 常亮（打开时阻止屏幕休眠）", settings.keepAwake,
                                   action: #selector(toggleKeepAwake(_:)))
        stack.addArrangedSubview(keepAwakeToggle)

        stack.addArrangedSubview(spacer(14))
        let hint = NSTextField(labelWithString: "改动即时生效并自动保存。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(hint)

        stack.addArrangedSubview(spacer(8))
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetPressed))
        reset.bezelStyle = .rounded
        let done = NSButton(title: "完成", target: self, action: #selector(donePressed))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [reset, NSView(), done])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func slider(_ title: String, range: ClosedRange<Double>, value: Double,
                        format: @escaping (Double) -> String,
                        onChange: @escaping (Double) -> Void) -> SliderRow {
        SliderRow(title: title, range: range, value: value, format: format, onChange: onChange)
    }

    private func checkbox(_ title: String, _ on: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = on ? .on : .off
        button.font = .systemFont(ofSize: 12)
        return button
    }

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func reloadFromStore() {
        let settings = SettingsStore.shared.values
        let values: [Double] = [settings.sideCoverSize, settings.tiltDegrees, settings.spacing,
                                settings.centerGap, settings.mainCoverCorner, settings.sideCoverCorner,
                                settings.lyricSize, settings.lyricFade,
                                settings.edgeFade, settings.lyricSpeed,
                                settings.infoCorner, settings.coverCorner]
        for (row, value) in zip(rows, values) { row.setValue(value) }
        uniformToggle?.state = settings.uniformTilt ? .on : .off
        evenSpacingToggle?.state = settings.evenSpacing ? .on : .off
        flatCoversToggle?.state = settings.flatCovers ? .on : .off
        equalSideToggle?.state = settings.equalSideSize ? .on : .off
        hideInfoToggle?.state = settings.hideInfoPanel ? .on : .off
        lyricsToggle?.state = settings.lyricsEnabled ? .on : .off
        keepCoverToggle?.state = settings.keepCoverWithLyrics ? .on : .off
        autoFitToggle?.state = settings.autoFitLyricFont ? .on : .off
        keepAwakeToggle?.state = settings.keepAwake ? .on : .off
    }

    @objc private func toggleUniform(_ sender: NSButton) {
        SettingsStore.shared.values.uniformTilt = sender.state == .on
    }

    @objc private func toggleLyrics(_ sender: NSButton) {
        SettingsStore.shared.values.lyricsEnabled = sender.state == .on
    }

    @objc private func toggleKeepCover(_ sender: NSButton) {
        SettingsStore.shared.values.keepCoverWithLyrics = sender.state == .on
    }

    @objc private func toggleAutoFit(_ sender: NSButton) {
        SettingsStore.shared.values.autoFitLyricFont = sender.state == .on
    }

    @objc private func toggleEvenSpacing(_ sender: NSButton) {
        SettingsStore.shared.values.evenSpacing = sender.state == .on
    }

    @objc private func toggleFlatCovers(_ sender: NSButton) {
        SettingsStore.shared.values.flatCovers = sender.state == .on
    }

    @objc private func toggleKeepAwake(_ sender: NSButton) {
        SettingsStore.shared.values.keepAwake = sender.state == .on
    }

    @objc private func toggleEqualSide(_ sender: NSButton) {
        SettingsStore.shared.values.equalSideSize = sender.state == .on
    }

    @objc private func toggleHideInfo(_ sender: NSButton) {
        SettingsStore.shared.values.hideInfoPanel = sender.state == .on
    }

    @objc private func resetPressed() {
        SettingsStore.shared.reset()
        reloadFromStore()
    }

    @objc private func donePressed() {
        window?.close()
        // Give the Touch Bar host its key status back, otherwise the bar
        // disappears until the next interaction.
        AppDelegate.shared?.refocusAfterSettings()
    }
}
