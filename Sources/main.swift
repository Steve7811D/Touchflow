import AppKit
import Foundation

let arguments = CommandLine.arguments
let bridge = NetEaseBridge()

func makePlaylist(_ queue: LiveQueue) -> Playlist {
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

if arguments.contains("--probe") {
    do {
        let queue = try bridge.liveQueue()
        print("SOURCE \(queue.sourceTitle) id=\(queue.sourceID)")
        print("TRACKS \(queue.tracks.count) version=\(queue.listVersion)")
        print("CURRENT \(queue.currentID) index=\(queue.currentIndex.map(String.init) ?? "-") playing=\(queue.isPlaying)")
        for t in queue.tracks.prefix(5) {
            print("  \(t.index) \(t.title) — \(t.artist) [\(t.coverURL)]")
        }
        if let last = queue.tracks.last {
            print("  …")
            print("  \(last.index) \(last.title) — \(last.artist)")
        }
        exit(0)
    } catch {
        fputs("PROBE ERROR: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--status") {
    do {
        let status = try bridge.liveStatus()
        print("count=\(status.listCount) version=\(status.listVersion) current=\(status.currentID) index=\(status.currentIndex.map(String.init) ?? "-") playing=\(status.isPlaying) state=\(status.playingState) elapsed=\(status.elapsed.map { String(format: "%.1f", $0) } ?? "-")")
        print("source=\(status.sourceTitle) id=\(status.sourceID) page=\(status.pagePlaylistID)")
        exit(0)
    } catch {
        fputs("STATUS ERROR: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--json") {
    do {
        let queue = try bridge.liveQueue()
        var rows: [[String: Any]] = []
        for t in queue.tracks {
            rows.append(["id": t.id, "title": t.title, "artist": t.artist,
                         "album": t.album, "cover": t.coverURL,
                         "duration": t.duration, "index": t.index])
        }
        let payload: [String: Any] = ["sourceID": queue.sourceID,
                                      "sourceTitle": queue.sourceTitle,
                                      "currentID": queue.currentID,
                                      "currentIndex": queue.currentIndex ?? -1,
                                      "playing": queue.isPlaying,
                                      "count": queue.tracks.count,
                                      "tracks": rows]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8) ?? "{}")
        exit(0)
    } catch {
        fputs("JSON ERROR: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--show-bar") {
    do {
        let queue = try bridge.liveQueue()
        let playlist = makePlaylist(queue)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let view = CoverFlowBarView(frame: NSRect(x: 0, y: 0, width: 974, height: 30))
        view.configure(playlist: playlist, playingIndex: playlist.currentIndex)
        if let lyric = ProcessInfo.processInfo.environment["TF_PREVIEW_LYRIC"],
           let idx = playlist.currentIndex, idx >= 0, idx < playlist.tracks.count {
            view.select(index: idx, play: false)
            view.setPlayingIndex(idx)
            view.setPlayingState(true)
            view.setLyrics([LyricLine(time: 0, text: lyric)], for: playlist.tracks[idx].id)
            view.setElapsed(12)
        }
        let window = NSWindow(contentRect: NSRect(x: 120, y: 200, width: 974, height: 30),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.title = "TouchFlowPreview"
        window.backgroundColor = .black
        window.hasShadow = true
        window.level = .floating
        app.finishLaunching()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { NSApp.terminate(nil) }
        app.run()
    } catch {
        fputs("SHOW ERROR: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--render-bar") {
    let out = arguments.firstIndex(of: "--render-bar").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        ?? "docs/bar-preview.png"
    do {
        let queue = try bridge.liveQueue()
        PreviewRenderer.renderBar(of: makePlaylist(queue), to: out)
        exit(0)
    } catch {
        fputs("RENDER ERROR: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if let i = arguments.firstIndex(of: "--play"), arguments.count > i + 1, let idx = Int(arguments[i + 1]) {
    do {
        let queue = try bridge.liveQueue()
        guard idx >= 0 && idx < queue.tracks.count else { fputs("index out of range\n", stderr); exit(2) }
        let track = queue.tracks[idx]
        print("PLAYING \(idx) \(track.title) — \(track.artist)")
        var ok = try bridge.play(track: track, sourceID: queue.sourceID)
        if !ok {
            print("RETRY via playlist page source=\(queue.sourceTitle)")
            if try bridge.openPlaylist(sourceID: queue.sourceID, title: queue.sourceTitle) {
                Thread.sleep(forTimeInterval: 0.4)
                ok = try bridge.play(track: track, sourceID: queue.sourceID)
            }
        }
        print("ACCEPTED \(ok)")
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.15)
            if let status = try? bridge.liveStatus(), status.currentID == track.id {
                print("NOW \(status.currentID) index=\(status.currentIndex.map(String.init) ?? "-") playing=\(status.isPlaying)")
                exit(0)
            }
        }
        fputs("NOT CONFIRMED\n", stderr)
        exit(3)
    } catch {
        fputs("PLAY ERROR: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
