import AppKit
import Foundation

final class ImageStore {
    static let shared = ImageStore()

    private var cache: [String: NSImage] = [:]
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]
    private var failed: Set<String> = []
    private let lock = NSLock()

    private init() {}

    /// Returns only a fully downloaded image.  Never returns a placeholder:
    /// a blurred placeholder followed by the real sleeve was the source of
    /// the visible "flash and blur" when dragging the fan.
    func cached(_ track: Track) -> NSImage? {
        lock.lock()
        let image = cache[track.id]
        lock.unlock()
        return image
    }

    func image(for track: Track, completion: @escaping (NSImage?) -> Void) {
        lock.lock()
        if let image = cache[track.id] {
            lock.unlock()
            DispatchQueue.main.async { completion(image) }
            return
        }
        if failed.contains(track.id) {
            lock.unlock()
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if inFlight[track.id] != nil {
            inFlight[track.id]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[track.id] = [completion]
        lock.unlock()

        guard var components = URLComponents(string: track.coverURL), !track.coverURL.isEmpty else {
            finish(trackID: track.id, image: nil)
            return
        }
        components.query = (components.query.map { $0 + "&" } ?? "") + "param=320y320"
        guard let url = components.url else {
            finish(trackID: track.id, image: nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("TouchFlow/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            let image: NSImage?
            if let data, let http = response as? HTTPURLResponse, http.statusCode == 200 {
                image = NSImage(data: data)
            } else {
                image = nil
            }
            self.finish(trackID: track.id, image: image)
        }.resume()
    }

    func prefetch(_ tracks: [Track]) {
        for track in tracks {
            image(for: track) { _ in }
        }
    }

    private func finish(trackID: String, image: NSImage?) {
        lock.lock()
        let callbacks = inFlight.removeValue(forKey: trackID) ?? []
        if let image {
            cache[trackID] = image
        } else {
            failed.insert(trackID)
        }
        lock.unlock()
        DispatchQueue.main.async {
            for cb in callbacks { cb(image) }
        }
    }
}
