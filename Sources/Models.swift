import Foundation
import AppKit

struct Track: Identifiable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let coverURL: String
    let duration: Double
    let index: Int
    var image: NSImage?
}

struct Playlist {
    /// Always "queue": the Flow always shows the real play queue.
    let id: String
    let uid: String
    let title: String
    let coverURL: String
    var tracks: [Track]
    /// NetEase playlist/album/radio the queue came from (from the current
    /// track's `fromInfo.sourceData`), used when playback needs the right page.
    var sourceID: String = ""
    var sourceTitle: String = ""
    /// Exact song id of the track NetEase is playing.  Matching by id instead of
    /// by title is what makes duplicate song names safe.
    var currentID: String = ""
    var currentTitle: String = ""
    var currentArtist: String = ""

    var currentIndex: Int? {
        if !currentID.isEmpty, let i = tracks.firstIndex(where: { $0.id == currentID }) {
            return i
        }
        // Kept only as a safety net for callers that have no id (e.g. previews).
        guard !currentTitle.isEmpty else { return nil }
        let nt = Track.norm(currentTitle)
        let na = Track.norm(currentArtist)
        if let i = tracks.firstIndex(where: { Track.norm($0.title) == nt && (na.isEmpty || Track.norm($0.artist).contains(na) || na.contains(Track.norm($0.artist))) }) {
            return i
        }
        return tracks.firstIndex(where: { Track.norm($0.title) == nt })
    }
}

extension Track {
    static func norm(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "【", with: "[")
            .replacingOccurrences(of: "】", with: "]")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    /// A JavaScript string literal, safely quoted as JSON.
    var jsLiteral: String {
        let data = try? JSONSerialization.data(withJSONObject: [self], options: [])
        guard let data, let s = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(s.dropFirst().dropLast())
    }
}
