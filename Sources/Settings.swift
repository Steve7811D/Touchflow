import Foundation

/// User-tunable appearance of the bar.  Every value has a default that matches
/// the 0.2.2 look, so a fresh install is unchanged.
struct FlowSettings {
    var sideCoverSize: Double = 25      // pt, 20…30
    var tiltDegrees: Double = 61.9      // 30…80
    var spacing: Double = 18            // pt, 8…30
    var centerGap: Double = 32          // pt, 0…80 gap around the main cover
    var uniformTilt: Bool = false       // false = inner sleeves lean less
    var edgeFade: Double = 0.88         // 0…2 (above 1 widens the fade band)
    var lyricSpeed: Double = 20         // pt/s, 6…40
    var infoCorner: Double = 6          // pt, 0…14
    var coverCorner: Double = 8         // pt, 0…15 info-panel artwork
    var mainCoverCorner: Double = 0     // pt, 0…15
    var sideCoverCorner: Double = 0     // pt, 0…15
    var lyricsEnabled: Bool = true      // show the synced lyric line
    var keepCoverWithLyrics: Bool = false  // lyric sits right of the artwork
    var autoFitLyricFont: Bool = false  // shrink the font instead of scrolling
    var lyricFade: Double = 16          // pt, 0…40 edge fade while scrolling
    var lyricSize: Double = 15.5        // pt, 3…26 (line height fits the bar)
    var keepAwake: Bool = false         // keep the Touch Bar / display awake
    var evenSpacing: Bool = false       // one spacing for every sleeve
    var flatCovers: Bool = false        // same size, no 3D tilt
    var hideInfoPanel: Bool = false     // covers fill the whole bar
    var equalSideSize: Bool = false     // side sleeves keep one size

    static let sideCoverRange: ClosedRange<Double> = 16...30
    static let tiltRange: ClosedRange<Double> = 0...85
    static let spacingRange: ClosedRange<Double> = 4...48
    static let centerGapRange: ClosedRange<Double> = 0...80
    static let fadeRange: ClosedRange<Double> = 0...2
    static let lyricSpeedRange: ClosedRange<Double> = 4...60
    static let cornerRange: ClosedRange<Double> = 0...24
    static let coverCornerRange: ClosedRange<Double> = 0...15
    static let lyricFadeRange: ClosedRange<Double> = 0...40
    static let lyricSizeRange: ClosedRange<Double> = 3...26
}

final class SettingsStore {
    static let shared = SettingsStore()
    static let changed = Notification.Name("TouchFlowSettingsChanged")

    private static let key = "TouchFlow.settings.v1"

    var values: FlowSettings {
        didSet {
            save()
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    private init() {
        values = Self.load()
    }

    func reset() {
        values = FlowSettings()
    }

    private func save() {
        let dict: [String: Any] = [
            "sideCoverSize": values.sideCoverSize,
            "tiltDegrees": values.tiltDegrees,
            "spacing": values.spacing,
            "centerGap": values.centerGap,
            "uniformTilt": values.uniformTilt,
            "edgeFade": values.edgeFade,
            "lyricSpeed": values.lyricSpeed,
            "infoCorner": values.infoCorner,
            "coverCorner": values.coverCorner,
            "mainCoverCorner": values.mainCoverCorner,
            "sideCoverCorner": values.sideCoverCorner,
            "lyricsEnabled": values.lyricsEnabled,
            "keepCoverWithLyrics": values.keepCoverWithLyrics,
            "autoFitLyricFont": values.autoFitLyricFont,
            "lyricFade": values.lyricFade,
            "lyricSize": values.lyricSize,
            "keepAwake": values.keepAwake,
            "evenSpacing": values.evenSpacing,
            "flatCovers": values.flatCovers,
            "hideInfoPanel": values.hideInfoPanel,
            "equalSideSize": values.equalSideSize
        ]
        UserDefaults.standard.set(dict, forKey: Self.key)
    }

    private static func load() -> FlowSettings {
        var settings = FlowSettings()
        guard let dict = UserDefaults.standard.dictionary(forKey: key) else { return settings }
        if let v = dict["sideCoverSize"] as? Double { settings.sideCoverSize = v }
        if let v = dict["tiltDegrees"] as? Double { settings.tiltDegrees = v }
        if let v = dict["spacing"] as? Double { settings.spacing = v }
        if let v = dict["centerGap"] as? Double { settings.centerGap = v }
        if let v = dict["uniformTilt"] as? Bool { settings.uniformTilt = v }
        if let v = dict["edgeFade"] as? Double { settings.edgeFade = v }
        if let v = dict["lyricSpeed"] as? Double { settings.lyricSpeed = v }
        if let v = dict["infoCorner"] as? Double { settings.infoCorner = v }
        if let v = dict["coverCorner"] as? Double { settings.coverCorner = v }
        if let v = dict["mainCoverCorner"] as? Double { settings.mainCoverCorner = v }
        if let v = dict["sideCoverCorner"] as? Double { settings.sideCoverCorner = v }
        if let v = dict["lyricsEnabled"] as? Bool { settings.lyricsEnabled = v }
        if let v = dict["keepCoverWithLyrics"] as? Bool { settings.keepCoverWithLyrics = v }
        if let v = dict["autoFitLyricFont"] as? Bool { settings.autoFitLyricFont = v }
        if let v = dict["lyricFade"] as? Double { settings.lyricFade = v }
        if let v = dict["lyricSize"] as? Double { settings.lyricSize = v }
        if let v = dict["keepAwake"] as? Bool { settings.keepAwake = v }
        if let v = dict["evenSpacing"] as? Bool { settings.evenSpacing = v }
        if let v = dict["flatCovers"] as? Bool { settings.flatCovers = v }
        if let v = dict["hideInfoPanel"] as? Bool { settings.hideInfoPanel = v }
        if let v = dict["equalSideSize"] as? Bool { settings.equalSideSize = v }
        return settings
    }
}
