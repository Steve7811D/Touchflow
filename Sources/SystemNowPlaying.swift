import Foundation

struct NowPlayingSnapshot {
    let title: String
    let artist: String
    let isPlaying: Bool
    let elapsed: Double
    let duration: Double
}

/// Reads macOS Now Playing through the vendored MediaRemoteMini adapter.
/// The adapter exposes the timestamp of the now-playing info, which lets us
/// compute the real playback position even when NetEase reports elapsedTime=0.
final class SystemNowPlaying {
    static let shared = SystemNowPlaying()

    private let lock = NSLock()

    private var adapterScriptURL: URL? {
        candidates("scripts/read-nowplaying.pl").first
    }

    private var adapterDylibURL: URL? {
        candidates("build/mediaremote-mini/MediaRemoteMini.dylib").first
    }

    private func candidates(_ suffix: String) -> [URL] {
        let fm = FileManager.default
        let macos = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS")
        let vendor = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("vendor/mediaremote-mini")
        return [macos.appendingPathComponent(suffix), vendor.appendingPathComponent(suffix)]
            .filter { fm.fileExists(atPath: $0.path) }
    }

    func snapshot() -> NowPlayingSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        if let script = adapterScriptURL, let dylib = adapterDylibURL,
           let data = run("/usr/bin/perl", [script.path, dylib.path]),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = object["title"] as? String, !title.isEmpty {
            let artist = object["artist"] as? String ?? ""
            let rate = (object["playbackRate"] as? NSNumber)?.doubleValue ?? 0
            let duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0
            var elapsed = (object["elapsedTime"] as? NSNumber)?.doubleValue ?? 0
            if rate > 0.01, let stamp = object["timestamp"] as? String,
               let date = Self.parseTimestamp(stamp) {
                elapsed += max(0, Date().timeIntervalSince(date))
            }
            if duration > 0 { elapsed = min(elapsed, duration) }
            return NowPlayingSnapshot(title: title, artist: artist,
                                      isPlaying: rate > 0.01,
                                      elapsed: max(0, elapsed),
                                      duration: duration)
        }
        return nil
    }

    /// Sends MediaRemote's "toggle play/pause" command.  Unlike *reading* the
    /// now-playing info, this works from an ad-hoc signed binary, so it can be
    /// called in-process instead of spawning a helper.
    @discardableResult
    func togglePlayPause() -> Bool {
        guard let url = CFURLCreateWithFileSystemPath(
                kCFAllocatorDefault,
                "/System/Library/PrivateFrameworks/MediaRemote.framework" as CFString,
                .cfurlposixPathStyle,
                true),
              let bundle = CFBundleCreate(kCFAllocatorDefault, url),
              let pointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString)
        else { return false }

        // MRMediaRemoteCommandTogglePlayPause == 2
        typealias SendCommandFn = @convention(c) (Int32, UnsafeMutableRawPointer?) -> UInt8
        let sendCommand = unsafeBitCast(pointer, to: SendCommandFn.self)
        return sendCommand(2, nil) != 0
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private func run(_ executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }
}
