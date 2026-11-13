import Foundation

/// A deliberately small, synchronous CDP client for the CEF page owned by
/// NetEaseMusic.  It only needs Runtime.evaluate; keeping it blocking makes the
/// AppKit side much easier to reason about.
final class CDPClient {
    private final class Pending {
        let semaphore = DispatchSemaphore(value: 0)
        var response: [String: Any]?
        var error: Error?
    }

    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var closed = false

    init(webSocketURL: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
        task = session.webSocketTask(with: webSocketURL)
        task.resume()
        receiveLoop()
    }

    deinit {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.handle(data)
                case .string(let string):
                    if let data = string.data(using: .utf8) { self.handle(data) }
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure:
                self.failAll()
            }
        }
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int else { return }
        lock.lock()
        let p = pending.removeValue(forKey: id)
        lock.unlock()
        p?.response = object
        p?.semaphore.signal()
    }

    private func failAll() {
        lock.lock()
        closed = true
        let all = pending
        pending.removeAll()
        lock.unlock()
        for (_, p) in all {
            p.error = NSError(domain: "TouchFlow.CDP", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "CEF debugging connection closed"])
            p.semaphore.signal()
        }
    }

    func evaluate(_ expression: String, timeout: TimeInterval = 12) -> Any? {
        let params: [String: Any] = [
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true,
            "userGesture": true
        ]
        guard let response = send(method: "Runtime.evaluate", params: params, timeout: timeout) else {
            return nil
        }
        if let result = response["result"] as? [String: Any] {
            if let exception = result["exceptionDetails"] as? [String: Any] {
                let text = exception["text"] as? String ?? "JavaScript exception"
                let detail = (exception["exception"] as? [String: Any])?["description"] as? String ?? ""
                NSLog("TouchFlow CDP JS exception: \(text) \(detail)")
                return nil
            }
            if let inner = result["result"] as? [String: Any] {
                return inner["value"]
            }
        }
        return nil
    }

    private func send(method: String, params: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        lock.lock()
        if closed {
            lock.unlock()
            return nil
        }
        nextID += 1
        let id = nextID
        let p = Pending()
        pending[id] = p
        lock.unlock()

        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let string = String(data: data, encoding: .utf8) else { return nil }
        task.send(.string(string)) { [weak self] error in
            guard let self, let error else { return }
            self.lock.lock()
            if let p = self.pending.removeValue(forKey: id) {
                p.error = error
                p.semaphore.signal()
            }
            self.lock.unlock()
        }

        if p.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            pending.removeValue(forKey: id)
            lock.unlock()
            return nil
        }
        return p.response
    }
}
