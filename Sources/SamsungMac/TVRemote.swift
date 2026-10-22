import Foundation

/// Remote keys understood by Tizen TVs over the remote-control channel.
enum TVKey: String {
    case up = "KEY_UP", down = "KEY_DOWN", left = "KEY_LEFT", right = "KEY_RIGHT"
    case enter = "KEY_ENTER", back = "KEY_RETURN", home = "KEY_HOME", menu = "KEY_MENU"
    case play = "KEY_PLAY", pause = "KEY_PAUSE"
    case volumeUp = "KEY_VOLUP", volumeDown = "KEY_VOLDOWN", mute = "KEY_MUTE"
    case power = "KEY_POWER", source = "KEY_SOURCE", nextInput = "KEY_HDMI"
    case hdmi1 = "KEY_HDMI1", hdmi2 = "KEY_HDMI2", hdmi3 = "KEY_HDMI3", hdmi4 = "KEY_HDMI4"
}

struct TVApp: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: Int
}

enum PairState: Equatable {
    case idle, connecting, awaitingApproval, paired, denied
}

/// The TV's remote-control WebSocket: wss://<tv>:8002 on 2018+ sets, where
/// the first connection makes the TV ask for permission on screen and once
/// allowed hands back a token that skips the prompt from then on; plain
/// ws://<tv>:8001 on 2016–17 sets, which never ask.
///
/// The socket heals itself: a send that fails, or a connection that never
/// completes, drops it and reconnects with the message still queued.
@MainActor
final class TVRemote {
    var onState: (PairState) -> Void = { _ in }
    var onToken: (String) -> Void = { _ in }
    var onApps: ([TVApp]) -> Void = { _ in }

    private(set) var state: PairState = .idle {
        didSet { if state != oldValue { onState(state) } }
    }

    private struct Queued {
        let text: String
        let at: Date
    }

    private var task: URLSessionWebSocketTask?
    private var pending: [Queued] = []
    private var approvalTimer: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var target: (host: String, token: String?, secure: Bool)?
    private var retries = 0
    private let session = URLSession(configuration: .ephemeral,
                                     delegate: TrustLocalTV(), delegateQueue: nil)

    /// Shown on the TV's permission prompt and its device list.
    private static let clientName = Data("SamsungMac".utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "%3D")

    /// Keys older than this are dropped rather than sent late: a direction
    /// press arriving seconds after the click does more harm than good.
    private static let maxQueueAge: TimeInterval = 4

    var isOpen: Bool { task != nil }

    /// A fresh request to connect, as opposed to an automatic retry.
    func connect(host: String, token: String?, secure: Bool = true) {
        if task == nil { retries = 0 }
        open(host: host, token: token, secure: secure)
    }

    private func open(host: String, token: String?, secure: Bool) {
        target = (host, token, secure)
        guard task == nil else { return }
        let scheme = secure ? "wss" : "ws"
        let port = secure ? 8002 : 8001
        var s = "\(scheme)://\(host):\(port)/api/v2/channels/samsung.remote.control?name=\(Self.clientName)"
        if secure, let token, !token.isEmpty { s += "&token=\(token)" }
        guard let url = URL(string: s) else { return }
        let t = session.webSocketTask(with: url)
        task = t
        state = .connecting
        t.resume()
        receive(t)
        // A paired TV answers within a second or two, so an attempt with a
        // token that's still waiting after a few seconds is stuck: start a
        // fresh one rather than leave clicks queued behind it. Only after a
        // couple of those, or without a token, is the TV taken to be showing
        // its Allow / Deny prompt, which times out after about 30 seconds.
        let hasToken = !(token ?? "").isEmpty || !secure
        let quickRetry = hasToken && retries < 2
        approvalTimer?.cancel()
        approvalTimer = Task {
            let wait: UInt64 = quickRetry ? 4_000_000_000 : hasToken ? 8_000_000_000 : 1_200_000_000
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled, self.task === t, self.state == .connecting else { return }
            if quickRetry {
                self.drop(t, keepQueue: true)
                self.reconnectIfIdle()
                return
            }
            if secure { self.state = .awaitingApproval }
            try? await Task.sleep(nanoseconds: 32_000_000_000)
            guard !Task.isCancelled, self.task === t, self.state != .paired else { return }
            self.drop(t, keepQueue: false)
        }
    }

    func disconnect() {
        approvalTimer?.cancel()
        keepAlive?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        target = nil
        pending = []
        retries = 0
        if state != .denied { state = .idle }
    }

    /// Forget a declined pairing so the next connect prompts again.
    func resetDenied() {
        if state == .denied { state = .idle }
    }

    func send(_ key: TVKey) {
        sendKey(key.rawValue, cmd: "Click")
    }

    /// Holds a key down, for the long-press actions some keys have (the
    /// Frame's power key turns it off instead of going to Art Mode).
    func hold(_ key: TVKey, seconds: Double) {
        sendKey(key.rawValue, cmd: "Press")
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self.sendKey(key.rawValue, cmd: "Release")
        }
    }

    private func sendKey(_ code: String, cmd: String) {
        sendJSON(["method": "ms.remote.control",
                  "params": ["Cmd": cmd, "DataOfCmd": code,
                             "Option": "false", "TypeOfRemote": "SendRemoteKey"]])
    }

    func requestApps() {
        sendJSON(["method": "ms.channel.emit",
                  "params": ["event": "ed.installedApp.get", "to": "host"]])
    }

    func launch(_ app: TVApp) {
        // app_type 2 = web app (deep link), 4 = native Tizen app.
        sendJSON(["method": "ms.channel.emit",
                  "params": ["event": "ed.apps.launch", "to": "host",
                             "data": ["appId": app.id,
                                      "action_type": app.type == 2 ? "DEEP_LINK" : "NATIVE_LAUNCH"]]])
    }

    /// Sends now when paired; otherwise queues so a click made while the
    /// connection is still coming up isn't lost, and reconnects if needed.
    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        if state == .paired, let task {
            transmit(text, on: task)
        } else {
            pending.append(Queued(text: text, at: Date()))
            if pending.count > 20 { pending.removeFirst() }
            reconnectIfIdle()
        }
    }

    private func transmit(_ text: String, on t: URLSessionWebSocketTask) {
        t.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, self.task === t else { return }
                // A socket that died quietly (Mac asleep, TV restarted its
                // server): put the message back and connect again.
                self.pending.insert(Queued(text: text, at: Date()), at: 0)
                self.drop(t, keepQueue: true)
                self.reconnectIfIdle()
            }
        }
    }

    private func reconnectIfIdle() {
        guard task == nil, state != .denied, let target, retries < 3 else { return }
        retries += 1
        open(host: target.host, token: target.token, secure: target.secure)
    }

    /// The TV can stop answering without closing the socket (its network
    /// stack drops idle peers, Wi-Fi hiccups), and a send into a dead
    /// socket doesn't fail for a long time. A ping every few seconds finds
    /// that out quickly, and the socket is replaced before the next click.
    private func startKeepAlive(_ t: URLSessionWebSocketTask) {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled, let self, self.task === t else { return }
                let alive = await Self.ping(t, timeout: 3)
                guard !Task.isCancelled, self.task === t else { return }
                if !alive {
                    self.drop(t, keepQueue: true)
                    self.retries = 0
                    self.reconnectIfIdle()
                    return
                }
            }
        }
    }

    private static func ping(_ t: URLSessionWebSocketTask, timeout: Double) async -> Bool {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var c: CheckedContinuation<Bool, Never>?
            init(_ c: CheckedContinuation<Bool, Never>) { self.c = c }
            func resume(_ v: Bool) {
                lock.lock(); let k = c; c = nil; lock.unlock()
                k?.resume(returning: v)
            }
        }
        return await withCheckedContinuation { c in
            let once = Once(c)
            t.sendPing { error in once.resume(error == nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(false) }
        }
    }

    private func drop(_ t: URLSessionWebSocketTask, keepQueue: Bool) {
        guard task === t else { return }
        keepAlive?.cancel()
        approvalTimer?.cancel()
        t.cancel(with: .goingAway, reason: nil)
        task = nil
        if !keepQueue { pending = [] }
        if state != .denied { state = .idle }
    }

    private func flushQueue() {
        guard let task else { return }
        let fresh = pending.filter { Date().timeIntervalSince($0.at) < Self.maxQueueAge }
        pending = []
        for q in fresh { transmit(q.text, on: task) }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                do {
                    let msg = try await t.receive()
                    guard let self, self.task === t else { return }
                    switch msg {
                    case .string(let s): self.handle(s)
                    case .data(let d): self.handle(String(decoding: d, as: UTF8.self))
                    @unknown default: break
                    }
                } catch {
                    guard let self, self.task === t else { return }
                    // Closed under us: reconnect right away while the
                    // panel wants the TV, so the next click doesn't wait.
                    self.drop(t, keepQueue: true)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self.reconnectIfIdle()
                    return
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let event = obj["event"] as? String else { return }
        let data = obj["data"] as? [String: Any]
        switch event {
        case "ms.channel.connect":
            approvalTimer?.cancel()
            if let token = (data?["token"] as? String) ?? (data?["token"] as? Int).map(String.init) {
                onToken(token)
                target?.token = token
            }
            retries = 0
            state = .paired
            if let task { startKeepAlive(task) }
            flushQueue()
            requestApps()
        case "ms.channel.unauthorized":
            approvalTimer?.cancel()
            state = .denied
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            pending = []
        case "ms.channel.timeOut":
            // The TV gave up waiting on its prompt, or is busy; try later.
            if let task { drop(task, keepQueue: false) }
        case "ed.installedApp.get":
            guard let list = data?["data"] as? [[String: Any]] else { return }
            let apps = list.compactMap { a -> TVApp? in
                guard let id = a["appId"] as? String, let name = a["name"] as? String else { return nil }
                let type = (a["app_type"] as? Int) ?? Int(a["app_type"] as? String ?? "") ?? 2
                return TVApp(id: id, name: name, type: type)
            }
            if !apps.isEmpty {
                onApps(apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
            }
        default:
            break
        }
    }
}

/// The TV serves a self-signed certificate; this session only ever talks to
/// the TV's own address on the local network.
private final class TrustLocalTV: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
