import Foundation

struct LyricLine {
    let time: Double
    let text: String
}

final class LyricsStore {
    static let shared = LyricsStore()

    private var cache: [String: [LyricLine]] = [:]
    private var inFlight: [String: [([LyricLine]) -> Void]] = [:]
    private let lock = NSLock()

    private init() {}

    func lyrics(for trackID: String, completion: @escaping ([LyricLine]) -> Void) {
        lock.lock()
        if let lines = cache[trackID] {
            lock.unlock()
            DispatchQueue.main.async { completion(lines) }
            return
        }
        if inFlight[trackID] != nil {
            inFlight[trackID]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[trackID] = [completion]
        lock.unlock()

        guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(trackID)&lv=1&kv=1&tv=-1") else {
            finish(trackID: trackID, lines: [])
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            var lines: [LyricLine] = []
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let lrc = object["lrc"] as? [String: Any],
               let text = lrc["lyric"] as? String {
                lines = Self.parse(text)
            }
            self.finish(trackID: trackID, lines: lines)
        }.resume()
    }

    private func finish(trackID: String, lines: [LyricLine]) {
        lock.lock()
        let callbacks = inFlight.removeValue(forKey: trackID) ?? []
        cache[trackID] = lines
        lock.unlock()
        DispatchQueue.main.async {
            for cb in callbacks { cb(lines) }
        }
    }

    private static func parse(_ lrc: String) -> [LyricLine] {
        let pattern = #"^\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [LyricLine] = []
        let credits = ["作词", "作曲", "编曲", "制作人", "制作", "和声", "吉他", "贝斯", "鼓", "录音", "混音", "母带", "监制", "词", "曲"]
        for raw in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            let minute = Int((line as NSString).substring(with: match.range(at: 1))) ?? 0
            let second = Int((line as NSString).substring(with: match.range(at: 2))) ?? 0
            var fraction = 0.0
            if match.range(at: 3).location != NSNotFound {
                let millis = (line as NSString).substring(with: match.range(at: 3))
                fraction = (Double(millis) ?? 0) / pow(10.0, Double(millis.count))
            }
            let body = (line as NSString).substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            if credits.contains(where: { body.hasPrefix($0) }) { continue }
            result.append(LyricLine(time: Double(minute * 60 + second) + fraction, text: body))
        }
        result.sort { $0.time < $1.time }
        return result
    }
}
