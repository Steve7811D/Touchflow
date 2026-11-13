import Foundation

/// Snapshot of what NetEase is *actually playing*: the real play queue plus the
/// exact current track.  Both come from the player state inside the NetEase
/// renderer (the dva/redux store), not from whatever playlist page happens to be
/// open and not from a search re-lookup.  That makes the list complete (all of
/// the queue, including rows a virtualised panel never renders) and the current
/// track exact (matched by song id, so duplicate titles cannot confuse it).
struct LiveQueue {
    let tracks: [Track]
    let sourceID: String
    let sourceTitle: String
    let listVersion: Int
    let listCount: Int
    let currentID: String
    let currentIndex: Int?
    let isPlaying: Bool
}

/// Cheap polling payload: everything needed to notice a track/queue change
/// without shipping the whole queue over the wire again.
struct LiveStatus {
    let listVersion: Int
    let listCount: Int
    let currentID: String
    let currentIndex: Int?
    let isPlaying: Bool
    let playingState: Int
    let sourceID: String
    let sourceTitle: String
    let pagePlaylistID: String
    /// Position in seconds as shown by the client's own progress slider.
    /// It follows seeks immediately, which MediaRemote does not.
    let elapsed: Double?
}

enum NetEaseError: LocalizedError {
    case noControlPort
    case noQueue
    case invalidResponse(String)
    case playback(String)
    case socket(String)

    var errorDescription: String? {
        switch self {
        case .noControlPort:
            return "网易云没有以“控制模式”运行。请在菜单里选择“以控制模式重启网易云”。"
        case .noQueue:
            return "网易云当前没有播放队列（先播放一首歌，或换一个歌单）。"
        case .invalidResponse(let s):
            return "网易云返回了无法识别的数据：\(s)"
        case .playback(let s):
            return "播放失败：\(s)"
        case .socket(let s):
            return "无法连接网易云控制端口：\(s)"
        }
    }
}

final class NetEaseBridge {
    static let controlPort = 9222
    private var client: CDPClient?

    var isAvailable: Bool {
        (try? pageWebSocketURL()) != nil
    }

    deinit {
        client = nil
    }

    private func syncJSON(_ url: URL, timeout: TimeInterval = 2) -> Any? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Any?
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { result = try? JSONSerialization.jsonObject(with: data) }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 0.5) == .timedOut {
            task.cancel()
            return nil
        }
        return result
    }

    private func pageWebSocketURL() throws -> URL {
        let url = URL(string: "http://127.0.0.1:\(Self.controlPort)/json/list")!
        guard let list = syncJSON(url) as? [[String: Any]] else {
            throw NetEaseError.noControlPort
        }
        let page = list.first { ($0["type"] as? String) == "page" }
        guard let ws = page?["webSocketDebuggerUrl"] as? String,
              let wsURL = URL(string: ws) else {
            throw NetEaseError.noControlPort
        }
        return wsURL
    }

    private func connect() throws -> CDPClient {
        if let client { return client }
        let ws = try pageWebSocketURL()
        let newClient = CDPClient(webSocketURL: ws)
        client = newClient
        return newClient
    }

    private func evaluate(_ expression: String, timeout: TimeInterval = 12) throws -> Any? {
        let cdp = try connect()
        guard let value = cdp.evaluate(expression, timeout: timeout) else {
            client = nil
            throw NetEaseError.invalidResponse("CDP evaluate returned nothing")
        }
        return value
    }

    private func dictionary(_ expression: String, timeout: TimeInterval = 12) throws -> [String: Any] {
        let value = try evaluate(expression, timeout: timeout)
        guard let dict = value as? [String: Any] else {
            throw NetEaseError.invalidResponse("payload is not an object")
        }
        if let ok = dict["ok"] as? Bool, ok == false {
            let message = dict["error"] as? String ?? "unknown error"
            throw NetEaseError.invalidResponse(message)
        }
        return dict
    }

    // MARK: - Reading

    /// The authoritative play queue + current track.
    func liveQueue() throws -> LiveQueue {
        let dict = try dictionary(Self.liveQueueJS(), timeout: 20)
        guard let rawTracks = dict["tracks"] as? [[String: Any]], !rawTracks.isEmpty else {
            throw NetEaseError.noQueue
        }
        var tracks: [Track] = []
        tracks.reserveCapacity(rawTracks.count)
        for raw in rawTracks {
            guard let id = raw["id"] as? String, !id.isEmpty,
                  let title = raw["title"] as? String, !title.isEmpty else { continue }
            let index = (raw["index"] as? NSNumber)?.intValue ?? tracks.count
            tracks.append(Track(id: id,
                                title: title,
                                artist: raw["artist"] as? String ?? "",
                                album: raw["album"] as? String ?? "",
                                coverURL: raw["cover"] as? String ?? "",
                                duration: (raw["duration"] as? NSNumber)?.doubleValue ?? 0,
                                index: index))
        }
        guard !tracks.isEmpty else { throw NetEaseError.noQueue }
        let currentID = dict["currentID"] as? String ?? ""
        var currentIndex = (dict["currentIndex"] as? NSNumber)?.intValue ?? -1
        if currentIndex < 0 || currentIndex >= tracks.count {
            currentIndex = tracks.firstIndex { $0.id == currentID } ?? -1
        }
        return LiveQueue(tracks: tracks,
                         sourceID: dict["sourceID"] as? String ?? "",
                         sourceTitle: dict["sourceTitle"] as? String ?? "",
                         listVersion: (dict["listVersion"] as? NSNumber)?.intValue ?? 0,
                         listCount: (dict["listCount"] as? NSNumber)?.intValue ?? tracks.count,
                         currentID: currentID,
                         currentIndex: currentIndex >= 0 ? currentIndex : nil,
                         isPlaying: (dict["playing"] as? Bool) ?? false)
    }

    /// Tiny payload used by the 0.4 s poll.
    func liveStatus() throws -> LiveStatus {
        let dict = try dictionary(Self.liveStatusJS(), timeout: 6)
        let currentIndex = (dict["currentIndex"] as? NSNumber)?.intValue ?? -1
        return LiveStatus(listVersion: (dict["listVersion"] as? NSNumber)?.intValue ?? 0,
                          listCount: (dict["listCount"] as? NSNumber)?.intValue ?? 0,
                          currentID: dict["currentID"] as? String ?? "",
                          currentIndex: currentIndex >= 0 ? currentIndex : nil,
                          isPlaying: (dict["playing"] as? Bool) ?? false,
                          playingState: (dict["playingState"] as? NSNumber)?.intValue ?? -1,
                          sourceID: dict["sourceID"] as? String ?? "",
                          sourceTitle: dict["sourceTitle"] as? String ?? "",
                          pagePlaylistID: dict["pagePlaylistID"] as? String ?? "",
                          elapsed: {
                              guard let number = dict["elapsed"] as? NSNumber else { return nil }
                              let value = number.doubleValue
                              return value >= 0 ? value : nil
                          }())
    }

    // MARK: - Playback

    /// Ask NetEase to play a specific queue row.
    ///
    /// NetEase has no local API for "play song id X", so this drives the client
    /// UI, but it does so with ids instead of title guesses: the row is located
    /// through its `s_songId` log payload (or the playlist filter narrowed by
    /// the exact title, then matched by id).  If the exact id is not on the open
    /// page it reports that instead of playing a same-named different version.
    @discardableResult
    func play(track: Track, sourceID: String) throws -> Bool {
        let expression = Self.playJS(id: track.id, title: track.title, sourceID: sourceID)
        let value = try evaluate(expression, timeout: 20)
        guard let dict = value as? [String: Any] else {
            throw NetEaseError.invalidResponse("play payload is not an object")
        }
        // "wrong-page" is an expected outcome (the song is simply not on the
        // open page), not an error: the caller navigates and retries.
        return (dict["ok"] as? Bool) ?? false
    }

    @discardableResult
    func togglePlayPause() throws -> Bool {
        let value = try evaluate(Self.togglePlayPauseJS, timeout: 5)
        guard let dict = value as? [String: Any], (dict["ok"] as? Bool) == true else {
            throw NetEaseError.playback("播放/暂停按钮不可用")
        }
        Thread.sleep(forTimeInterval: 0.2)
        return true
    }

    /// Navigate the NetEase window to the playlist/album the queue came from.
    /// Only used as a recovery step when a tap targets a song that is not on
    /// the currently open page.  "我喜欢的音乐" has a dedicated sidebar entry;
    /// anything else is matched by name in the sidebar (expanding the collapsed
    /// "创建的歌单 / 收藏的歌单" sections first).
    func openPlaylist(sourceID: String, title: String) throws -> Bool {
        guard !sourceID.isEmpty || !title.isEmpty else { return false }
        let expression = Self.openPlaylistJS(sourceID: sourceID, title: title)
        let dict = try dictionary(expression, timeout: 20)
        return (dict["ok"] as? Bool) ?? false
    }

    // MARK: - JavaScript
    //
    // All of these run inside the NetEase renderer.  The renderer is a React +
    // dva app, so the player state is reachable through the root React fiber
    // chain: walk down until a component receives the redux store as a prop.
    // The store object is then cached on `window.__tfStore` for instant access.

    /// Shared store-discovery prelude.  Kept as a plain string so the longer
    /// expressions below stay readable.
    private static let storePrelude = #"""
    var KEY = "__tfStore";
    function isStore(v) {
      return !!(v && typeof v === "object" && typeof v.getState === "function" && typeof v.dispatch === "function");
    }
    function findStore() {
      var cached = window[KEY];
      if (isStore(cached)) {
        try { cached.getState(); return cached; } catch (e) { window[KEY] = null; }
      }
      var rootEl = document.querySelector("#root") || document.body.firstElementChild;
      if (!rootEl) return null;
      var root = null;
      var rk = Object.getOwnPropertyNames(rootEl).filter(function (k) { return k.indexOf("__reactContainer") === 0; })[0];
      if (rk) root = rootEl[rk];
      if (!root) {
        var probe = document.querySelector("[data-testid]") || rootEl;
        var ik = Object.getOwnPropertyNames(probe).filter(function (k) { return k.indexOf("__reactInternalInstance") === 0; })[0];
        var f = ik ? probe[ik] : null;
        while (f && f.return) f = f.return;
        root = f;
      }
      if (!root) return null;
      var stack = [root];
      var seen = 0;
      while (stack.length && seen < 60000) {
        var node = stack.pop();
        if (!node || typeof node !== "object") continue;
        seen++;
        var p = node.memoizedProps;
        if (p && typeof p === "object" && isStore(p.store)) {
          window[KEY] = p.store;
          return p.store;
        }
        if (node.sibling) stack.push(node.sibling);
        if (node.child) stack.push(node.child);
      }
      return null;
    }
    function https(u) { return (u && u.indexOf("http://") === 0) ? "https://" + u.slice(7) : (u || ""); }
    function nameList(a) {
      var out = [];
      if (!a) return "";
      for (var i = 0; i < a.length; i++) { if (a[i] && a[i].name) out.push(a[i].name); }
      return out.join("/");
    }
    function sourceInfo(first, cur) {
      // The queue's source is what the first row points at ("我喜欢的音乐",
      // an album, a radio...).  The *current* track's fromInfo can describe a
      // one-off song played from history, which must not rename the queue.
      var src = (first && first.fromInfo && first.fromInfo.sourceData) || {};
      var href = String((first && first.href) || (cur && cur.href) || "");
      var m = href.match(/playlist\/(\d+)/);
      var curSrc = (cur && cur.fromInfo && cur.fromInfo.sourceData) || {};
      return {
        id: src.id ? String(src.id) : (m ? m[1] : (curSrc.id ? String(curSrc.id) : "")),
        title: (first && first.text) || src.name || curSrc.name || ""
      };
    }
    """#

    private static func wrap(_ body: String) -> String {
        return "(() => {" + storePrelude + body + "})()"
    }

    static func liveQueueJS() -> String {
        return wrap(#"""
        var store = findStore();
        if (!store) return { ok: false, error: "state-store-not-found" };
        var st;
        try { st = store.getState(); } catch (e) { window[KEY] = null; return { ok: false, error: "state-read-failed" }; }
        var pl = st.playingList || {};
        var list = pl.curPlayingList;
        if (!list || typeof list.length !== "number" || list.length === 0) return { ok: false, error: "empty-playing-list" };
        var playing = st.playing || {};
        var cur = playing.curPlaying || null;
        var curTrack = (cur && cur.track) || cur || {};
        var curID = String(curTrack.id || playing.trackId || playing.playId || "");
        var first = list[0] || {};
        var src = sourceInfo(first, cur);
        var tracks = [];
        for (var i = 0; i < list.length; i++) {
          var item = list[i] || {};
          var tr = item.track || item || {};
          var al = tr.album || tr.al || {};
          tracks.push({
            id: String(tr.id || item.id || ""),
            title: tr.name || "",
            artist: nameList(tr.artists || tr.ar || []),
            album: al.name || "",
            cover: https(al.cover || al.picUrl || ""),
            duration: tr.duration || tr.dt || 0,
            index: i
          });
        }
        var currentIndex = -1;
        for (var k = 0; k < tracks.length; k++) { if (tracks[k].id === curID) { currentIndex = k; break; } }
        if (currentIndex < 0 && typeof cur.displayOrder === "number" && cur.displayOrder >= 0 && cur.displayOrder < tracks.length) {
          currentIndex = cur.displayOrder;
        }
        var page = st["page:playlist"] || {};
        var sliderBox = document.querySelector('[aria-label="播放进度调节"]');
        var sliderInput = sliderBox ? sliderBox.querySelector('input[type="range"]') : null;
        var elapsed = sliderInput ? parseFloat(sliderInput.value) : -1;
        if (isNaN(elapsed)) elapsed = -1;
        return {
          ok: true,
          elapsed: elapsed,
          listVersion: typeof pl.updateNumber === "number" ? pl.updateNumber : 0,
          listCount: tracks.length,
          sourceID: src.id,
          sourceTitle: src.title,
          pagePlaylistID: page.id ? String(page.id) : "",
          currentID: curID,
          currentIndex: currentIndex,
          currentName: curTrack.name || "",
          currentArtist: nameList(curTrack.artists || []),
          playing: playing.playingState === 2,
          playingState: typeof playing.playingState === "number" ? playing.playingState : -1,
          tracks: tracks
        };
        """#)
    }

    static func liveStatusJS() -> String {
        return wrap(#"""
        var store = findStore();
        if (!store) return { ok: false, error: "state-store-not-found" };
        var st;
        try { st = store.getState(); } catch (e) { window[KEY] = null; return { ok: false, error: "state-read-failed" }; }
        var pl = st.playingList || {};
        var list = pl.curPlayingList;
        var len = (list && typeof list.length === "number") ? list.length : 0;
        var playing = st.playing || {};
        var cur = playing.curPlaying || null;
        var curTrack = (cur && cur.track) || cur || {};
        var curID = String(curTrack.id || playing.trackId || playing.playId || "");
        var first = (len > 0) ? (list[0] || {}) : {};
        var src = sourceInfo(first, cur);
        var currentIndex = -1;
        if (len > 0) {
          for (var k = 0; k < len; k++) {
            var item = list[k] || {};
            var id = String((item.track || item).id || item.id || "");
            if (id === curID) { currentIndex = k; break; }
          }
          if (currentIndex < 0 && typeof cur.displayOrder === "number" && cur.displayOrder >= 0 && cur.displayOrder < len) {
            currentIndex = cur.displayOrder;
          }
        }
        var page = st["page:playlist"] || {};
        var sliderBox = document.querySelector('[aria-label="播放进度调节"]');
        var sliderInput = sliderBox ? sliderBox.querySelector('input[type="range"]') : null;
        var elapsed = sliderInput ? parseFloat(sliderInput.value) : -1;
        if (isNaN(elapsed)) elapsed = -1;
        return {
          ok: true,
          elapsed: elapsed,
          listVersion: typeof pl.updateNumber === "number" ? pl.updateNumber : 0,
          listCount: len,
          sourceID: src.id,
          sourceTitle: src.title,
          pagePlaylistID: page.id ? String(page.id) : "",
          currentID: curID,
          currentIndex: currentIndex,
          playing: playing.playingState === 2,
          playingState: typeof playing.playingState === "number" ? playing.playingState : -1
        };
        """#)
    }


    static let togglePlayPauseJS = #"""
    (() => {
      const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
      const all = [...document.querySelectorAll('[data-testid="tid_playbar_play_btn"]')];
      const b = all.find(vis) || all[0];
      if (!b) return { ok: false, error: 'playbar button missing' };
      b.click();
      return { ok: true };
    })()
    """#


    /// Play by song id.  Order of attempts:
    ///   1. row already rendered on the open page (matched by `s_songId`)
    ///   2. narrow the open playlist with its own filter box, then match by id
    ///   3. report `wrong-page` so the caller can decide whether to navigate
    static func openPlaylistJS(sourceID: String, title: String) -> String {
        let sid = sourceID.jsLiteral
        let stitle = title.jsLiteral
        return "(() => {" + storePrelude + #"""
        var wantID = \#(sid);
        var wantTitle = \#(stitle);
        return (async () => {
          var sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
          var store = findStore();
          if (!store) return { ok: false, error: "state-store-not-found" };
          var pageID = function () {
            try { var st = store.getState(); return String((st["page:playlist"] || {}).id || ""); } catch (e) { return ""; }
          };
          if (wantID && pageID() === wantID) return { ok: true, via: "already" };
          var clicked = "";
          if (wantTitle.indexOf("喜欢") >= 0) {
            var fav = document.querySelector('[data-testid="tid_navitem_myFavoriteMusic"]');
            if (fav) { fav.click(); clicked = "favorite"; }
          }
          if (!clicked) {
            var inSidebar = function (node) {
              var r = node.getBoundingClientRect();
              return r.width > 0 && r.left < 300;
            };
            var findItem = function () {
              var nodes = [].slice.call(document.querySelectorAll('[class*="PlayListItemContent"]'));
              for (var i = 0; i < nodes.length; i++) {
                var t = (nodes[i].innerText || "").trim();
                if (!t || !inSidebar(nodes[i])) continue;
                if (t === wantTitle) return nodes[i];
              }
              for (var j = 0; j < nodes.length; j++) {
                var t2 = (nodes[j].innerText || "").trim();
                if (!t2 || !inSidebar(nodes[j])) continue;
                if (t2.indexOf(wantTitle) === 0 || wantTitle.indexOf(t2) === 0) return nodes[j];
              }
              return null;
            };
            var item = findItem();
            if (!item) {
              var headers = [].slice.call(document.querySelectorAll('[class*="TitleContainer"]'));
              for (var h = 0; h < headers.length; h++) {
                if ((headers[h].innerText || "").indexOf("歌单") >= 0) { try { headers[h].click(); } catch (e) {} }
              }
              await sleep(500);
              item = findItem();
            }
            if (item) {
              var clickable = item.closest('[class*="Item"]') || item.parentElement || item;
              try { clickable.click(); clicked = "sidebar"; } catch (e) {}
            }
          }
          if (!clicked) return { ok: false, error: "no-sidebar-entry" };
          var ready = false;
          for (var k = 0; k < 30; k++) {
            await sleep(150);
            if (wantID && pageID() === wantID) { ready = true; break; }
          }
          if (!ready) return { ok: false, error: "navigation-timeout" };
          // The page id flips before the track table has rendered.  Clicking a
          // row during that window makes NetEase play a single song instead of
          // the playlist, so wait until rows are actually on screen.
          for (var r = 0; r < 20; r++) {
            await sleep(150);
            var rendered = document.querySelectorAll('[data-testid="tid_scroll_container"] [data-testid="tid_table_viewer_row"]');
            if (rendered.length >= 5) break;
          }
          await sleep(250);
          return { ok: true, via: clicked };
        })();
        """# + "})()"
    }

    static func playJS(id: String, title: String, sourceID: String) -> String {
        let sid = id.jsLiteral
        let stitle = title.jsLiteral
        let ssrc = sourceID.jsLiteral
        return #"""
        (async () => {
          const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
          const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 2 && r.height > 2; };
          const rowID = (row) => {
            try { return JSON.parse(row.getAttribute("data-log") || "{}").params.s_songId || ""; } catch (e) { return ""; }
          };
          const rows = () => [...document.querySelectorAll('[data-testid="tid_table_viewer_row"]')].filter(vis);
          const findRow = (want) => rows().find((r) => rowID(r) === want);
          const clickRow = (row) => {
            const btn = row.querySelector('[data-testid="tid_tableindex_play_btn"]');
            if (btn) { btn.click(); return true; }
            row.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, cancelable: true, view: window }));
            return false;
          };
          const wanted = \#(sid);
          let row = findRow(wanted);
          if (row) { try { clickRow(row); } catch (e) {} return { ok: true, via: "visible" }; }
          const input = document.querySelector('[data-testid="tid_playlist_search_input"]');
          if (!input) return { ok: false, error: "wrong-page", sourceID: \#(ssrc) };
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
          try {
            setter.call(input, \#(stitle));
            input.dispatchEvent(new Event("input", { bubbles: true }));
          } catch (e) {
            return { ok: false, error: "wrong-page", sourceID: \#(ssrc) };
          }
          let match = null;
          for (let i = 0; i < 14; i++) {
            await sleep(120);
            match = findRow(wanted);
            if (match) break;
          }
          if (!match) {
            try {
              setter.call(input, "");
              input.dispatchEvent(new Event("input", { bubbles: true }));
            } catch (e) {}
            return { ok: false, error: "wrong-page", sourceID: \#(ssrc) };
          }
          try { clickRow(match); } catch (e) {}
          // Clear the filter *after* returning; clearing synchronously right
          // after the click re-renders the whole 600+ row table and can stall
          // the renderer for seconds.
          setTimeout(function () {
            try {
              setter.call(input, "");
              input.dispatchEvent(new Event("input", { bubbles: true }));
            } catch (e) {}
          }, 800);
          return { ok: true, via: "filter" };
        })()
        """#
    }
}
