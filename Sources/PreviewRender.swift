import AppKit
import Foundation

enum PreviewRenderer {
    static func renderBar(of playlist: Playlist, to path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let view = CoverFlowBarView(frame: NSRect(x: 0, y: 0, width: 974, height: 30))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 974, height: 30),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()

        view.configure(playlist: playlist, playingIndex: playlist.currentIndex)
        if let raw = ProcessInfo.processInfo.environment["TF_PREVIEW_INDEX"], let idx = Int(raw) {
            view.select(index: idx, play: false)
        }
        if let lyric = ProcessInfo.processInfo.environment["TF_PREVIEW_LYRIC"],
           let idxRaw = ProcessInfo.processInfo.environment["TF_PREVIEW_INDEX"],
           let idx = Int(idxRaw), idx >= 0, idx < playlist.tracks.count {
            view.setPlayingIndex(idx)
            view.setPlayingState(true)
            view.setLyrics([LyricLine(time: 0, text: lyric)], for: playlist.tracks[idx].id)
            view.setElapsed(12)
        }
        view.layoutSubtreeIfNeeded()
        view.reloadVisibleImages()

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        }
        view.displayIfNeeded()

        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        guard let rep else { fputs("no bitmap rep\n", stderr); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fputs("no png data\n", stderr); return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("WROTE \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        } catch {
            fputs("write failed: \(error)\n", stderr)
        }
        window.orderOut(nil)
    }
}
