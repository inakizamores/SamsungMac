import Foundation
import Observation
import ServiceManagement
import AppKit

@MainActor
final class Throttler {
    private let interval: TimeInterval
    private var lastFire: Date = .distantPast
    private var pending: Task<Void, Never>?

    init(interval: TimeInterval = 0.1) { self.interval = interval }

    func call(_ op: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = nil
        let elapsed = Date().timeIntervalSince(lastFire)
        if elapsed >= interval {
            lastFire = Date()
            op()
        } else {
            pending = Task {
                try? await Task.sleep(nanoseconds: UInt64((self.interval - elapsed) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.lastFire = Date()
                op()
            }
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("SamsungMac: launch at login failed: \(error.localizedDescription)")
        }
    }
}

/// A TV seen on the network, remembered so the panel can switch between TVs.
/// The optional fields were added later and are learned while talking to
/// the TV, so older saved lists still decode.
struct KnownTV: Codable, Identifiable, Hashable {
    var ip: String
    var name: String
    var model: String
    var mac: String
    /// The MAC the Mac reaches the TV through (Ethernet on a wired TV,
    /// where the reported Wi-Fi MAC won't wake it).
    var lanMAC: String? = nil
    var tokenAuth: Bool? = nil
    var frameTV: Bool? = nil
    /// Whether KEY_HDMI1–4 switch inputs. Recent models ignore them.
    var directInputs: Bool? = nil
    var id: String { Self.id(ip: ip, mac: mac) }

    static func id(ip: String, mac: String) -> String { mac.isEmpty ? ip : mac }
}

/// Runs `op`, giving up after `seconds`.
private func withDeadline<T: Sendable>(_ seconds: Double,
                                       _ op: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await op() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

@MainActor
@Observable
final class TVSystem {
    var reachable = false
    var powerOn = false
    var volume = 0            // 0...100, as the TV reports it
    var muted = false
    /// Sound is going to an external device (ARC/eARC, optical, Bluetooth).
    /// The TV then can't report or set that device's level, only step it
    /// with its volume keys, so the panel shows steppers instead of a slider.
    var externalAudio = false
    var pairState: PairState = .idle
    var apps: [TVApp] = []
    var foregroundApp: TVApp?
    var model = ""
    var lastInput = ""
    var tvs: [KnownTV] = []
    var currentTVID = ""
    var isScanning = false
    var launchAtLogin = LoginItem.isEnabled
    var everConnected = UserDefaults.standard.string(forKey: "tvIP") != nil
    var connectionFailed = false
    /// The TV was on and stopped answering on the network (Wi-Fi dropout,
    /// TV busy). Shown as reconnecting rather than as the TV being off.
    var connectionLost = false

    /// The TV can't report play state, so play/pause alternates locally,
    /// assuming something is playing the first time.
    @ObservationIgnored private var assumePlaying = true
    @ObservationIgnored private let remote = TVRemote()
    @ObservationIgnored private var menuIsOpen = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored private var suppressVolumeUntil: Date = .distantPast
    @ObservationIgnored private var suppressPowerUntil: Date = .distantPast
    @ObservationIgnored private var suppressForegroundUntil: Date = .distantPast
    @ObservationIgnored private var fastPollUntil: Date = .distantPast
    @ObservationIgnored private var pollCount = 0
    @ObservationIgnored private var fetchFailures = 0
    @ObservationIgnored private var lostSince: Date = .distantPast
    @ObservationIgnored private var lastDiscovery: Date = .distantPast
    @ObservationIgnored private var appsLoadedFor = ""
    @ObservationIgnored private var appsLoadedAt: Date = .distantPast
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    @ObservationIgnored private var appsTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundTask: Task<Void, Never>?
    @ObservationIgnored private let volumeThrottler = Throttler(interval: 0.15)

    // Volume-mode evidence. The panel only swaps between slider and
    // steppers on what the TV actually did, and never mid-interaction.
    @ObservationIgnored private var rawVolume: Int?
    @ObservationIgnored private var upnpFailures = 0
    @ObservationIgnored private var lastVolumeInteraction: Date = .distantPast
    @ObservationIgnored private var pendingAudioMode: Bool?
    @ObservationIgnored private var audioSwapTask: Task<Void, Never>?
    @ObservationIgnored private var stepBurst: StepBurst?
    @ObservationIgnored private var writeCheck: Task<Void, Never>?

    /// Volume key presses in quick succession, checked as one against the
    /// level read before the first.
    private struct StepBurst {
        var before: Int?
        var ready = false
        var queued: [Bool] = []
        var net = 0
        var settle: Task<Void, Never>?
    }

    private var knownIP: String? {
        get { UserDefaults.standard.string(forKey: "tvIP") }
        set { UserDefaults.standard.set(newValue, forKey: "tvIP") }
    }

    private var currentTV: KnownTV? { tvs.first { $0.id == currentTVID } }

    /// The name the TV was given in its settings, e.g. "Living Room".
    var tvName: String {
        let n = currentTV?.name ?? ""
        return n.hasPrefix("[TV] ") ? String(n.dropFirst(5)) : n
    }

    /// False once this TV has been seen ignoring the HDMI 1–4 keys; the
    /// panel then offers Next Input and the Source list instead.
    var directInputs: Bool { currentTV?.directInputs != false }

    /// Pairing tokens are per TV.
    private var token: String? {
        get { (UserDefaults.standard.dictionary(forKey: "tvTokens") as? [String: String])?[currentTVID] }
        set {
            var all = UserDefaults.standard.dictionary(forKey: "tvTokens") as? [String: String] ?? [:]
            all[currentTVID] = newValue
            UserDefaults.standard.set(all, forKey: "tvTokens")
        }
    }

    init() {
        remote.onState = { [weak self] in self?.pairState = $0 }
        remote.onToken = { [weak self] in self?.token = $0 }
        // Older firmware still answers the installed-apps request; merge it
        // with what the catalog lookup found.
        remote.onApps = { [weak self] found in
            guard let self else { return }
            var merged = self.apps
            for app in found where !merged.contains(where: { $0.id == app.id }) { merged.append(app) }
            self.setApps(merged)
        }
        if let data = UserDefaults.standard.data(forKey: "knownTVs"),
           let saved = try? JSONDecoder().decode([KnownTV].self, from: data) {
            tvs = saved
        }
        currentTVID = UserDefaults.standard.string(forKey: "currentTV") ?? tvs.first?.id ?? ""
        migrateLegacyToken()
        if let data = UserDefaults.standard.data(forKey: "tvApps.\(currentTVID)"),
           let saved = try? JSONDecoder().decode([TVApp].self, from: data) {
            apps = saved
        }
        restoreState()
        externalAudio = UserDefaults.standard.bool(forKey: "externalAudio.\(currentTVID)")
        // After sleep the socket is dead and the TV may have moved address.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
    }

    /// 1.0.0 builds stored a single token before the TV list existed.
    private func migrateLegacyToken() {
        guard let legacy = UserDefaults.standard.string(forKey: "tvToken") else { return }
        let mac = UserDefaults.standard.string(forKey: "tvMAC") ?? ""
        if let ip = knownIP, tvs.isEmpty {
            tvs = [KnownTV(ip: ip, name: "Samsung TV", model: "", mac: mac)]
            currentTVID = tvs[0].id
            persistTVs()
        }
        if token == nil { token = legacy }
        UserDefaults.standard.removeObject(forKey: "tvToken")
    }

    /// Last-known state, so the panel renders populated instantly instead of
    /// flashing an empty layout while the TV answers.
    private func restoreState() {
        guard let s = UserDefaults.standard.dictionary(forKey: "lastState") else { return }
        powerOn = s["powerOn"] as? Bool ?? false
        volume = s["volume"] as? Int ?? 0
        muted = s["muted"] as? Bool ?? false
        model = s["model"] as? String ?? ""
        lastInput = s["lastInput"] as? String ?? ""
    }

    private func persistState() {
        UserDefaults.standard.set([
            "powerOn": powerOn, "volume": volume, "muted": muted,
            "model": model, "lastInput": lastInput,
        ] as [String: Any], forKey: "lastState")
    }

    private func persistTVs() {
        if let data = try? JSONEncoder().encode(tvs) {
            UserDefaults.standard.set(data, forKey: "knownTVs")
        }
        UserDefaults.standard.set(currentTVID, forKey: "currentTV")
    }

    private func updateCurrentTV(_ change: (inout KnownTV) -> Void) {
        guard let i = tvs.firstIndex(where: { $0.id == currentTVID }) else { return }
        let before = tvs[i]
        change(&tvs[i])
        if tvs[i] != before { persistTVs() }
    }

    private func setApps(_ list: [TVApp]) {
        apps = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: "tvApps.\(currentTVID)")
        }
    }

    // MARK: - Lifecycle

    func menuOpened() {
        menuIsOpen = true
        lastDiscovery = .distantPast
        closeTask?.cancel()
        if knownIP == nil {
            Task { await discover() }
        } else {
            startPolling()
        }
    }

    /// Keeps the socket around briefly so a quick reopen is instant.
    func menuClosed() {
        menuIsOpen = false
        pollTask?.cancel()
        pollTask = nil
        persistState()
        closeTask = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, !self.menuIsOpen else { return }
            self.remote.disconnect()
        }
    }

    private func handleWake() {
        remote.disconnect()
        fetchFailures = 0
        lastDiscovery = .distantPast
        if menuIsOpen { startPolling() }
    }

    func rescan() {
        appsLoadedFor = ""
        Task { await discover() }
    }

    /// A declined prompt, or a token the TV has since forgotten: start over
    /// without one so the TV asks again.
    func retryPairing() {
        remote.disconnect()
        remote.resetDenied()
        token = nil
        ensureRemote()
    }

    func selectTV(_ id: String) {
        guard id != currentTVID, let tv = tvs.first(where: { $0.id == id }) else { return }
        remote.disconnect()
        remote.resetDenied()
        currentTVID = id
        knownIP = tv.ip
        model = tv.model
        foregroundApp = nil
        lastInput = ""
        rawVolume = nil
        upnpFailures = 0
        fetchFailures = 0
        pendingAudioMode = nil
        externalAudio = UserDefaults.standard.bool(forKey: "externalAudio.\(id)")
        appsLoadedFor = ""
        apps = (UserDefaults.standard.data(forKey: "tvApps.\(id)"))
            .flatMap { try? JSONDecoder().decode([TVApp].self, from: $0) } ?? []
        persistTVs()
        if menuIsOpen { startPolling() }
    }

    private func discover() async {
        guard !isScanning else { return }
        isScanning = true
        connectionFailed = false
        lastDiscovery = Date()
        defer { isScanning = false }
        let found = await TVDiscovery.discover()
        guard !found.isEmpty else {
            if menuIsOpen && knownIP == nil { connectionFailed = true }
            return
        }
        for hit in found {
            let id = KnownTV.id(ip: hit.ip, mac: hit.info.mac)
            if let i = tvs.firstIndex(where: { $0.id == id }) {
                tvs[i].ip = hit.ip
                tvs[i].name = hit.info.name
                tvs[i].model = hit.info.displayModel
            } else {
                tvs.append(KnownTV(ip: hit.ip, name: hit.info.name, model: hit.info.displayModel,
                                   mac: hit.info.mac, tokenAuth: hit.info.tokenAuth,
                                   frameTV: hit.info.frameTV))
            }
        }
        // Stay on the current TV (at its possibly new address) when it's
        // still around; otherwise take the first one found.
        let pick = found.first { KnownTV.id(ip: $0.ip, mac: $0.info.mac) == currentTVID } ?? found[0]
        let pickID = KnownTV.id(ip: pick.ip, mac: pick.info.mac)
        if pickID != currentTVID || pick.ip != knownIP { remote.disconnect() }
        if pickID != currentTVID {
            externalAudio = UserDefaults.standard.bool(forKey: "externalAudio.\(pickID)")
            rawVolume = nil
        }
        currentTVID = pickID
        knownIP = pick.ip
        model = pick.info.displayModel
        fetchFailures = 0
        persistTVs()
        everConnected = true
        if menuIsOpen { startPolling() }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollCount = 0
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                let fast = Date() < fastPollUntil
                try? await Task.sleep(nanoseconds: fast ? 1_000_000_000 : 2_500_000_000)
            }
        }
    }

    /// One status pass. It only waits on the TV's quick info request;
    /// everything slower (the app list, which app is on screen, volume)
    /// runs beside it, at most one of each at a time. A TV whose app
    /// service is sluggish can then never hold up noticing that it's back,
    /// or leave the panel stuck until it's reopened.
    private func refresh() async {
        guard let ip = knownIP else { return }
        let fetched = await withDeadline(2) { await TVInfo.fetch(host: ip) }
        guard knownIP == ip else { return }
        guard let info = fetched else {
            // A missed answer or two is usually the TV being busy, not
            // gone: look again sooner, and only call it lost after a few.
            fetchFailures += 1
            fastPollUntil = max(fastPollUntil, Date().addingTimeInterval(10))
            guard fetchFailures >= 3 else { return }
            if reachable {
                lostSince = Date()
                fastPollUntil = Date().addingTimeInterval(45)
            }
            reachable = false
            // A TV that was just on and went quiet is most often a network
            // dropout and comes back by itself; only a long silence (or old
            // firmware that goes silent in standby) means it's off.
            let dropout = powerOn && Date().timeIntervalSince(lostSince) < 45
            connectionLost = dropout
            if !dropout, Date() >= suppressPowerUntil {
                powerOn = false
                foregroundApp = nil
            }
            // The TV may have a new DHCP address. Look again now and then
            // while it stays away, without scanning back to back.
            if menuIsOpen, Date().timeIntervalSince(lastDiscovery) > 20 {
                Task { await discover() }
            }
            return
        }
        fetchFailures = 0
        connectionLost = false
        reachable = true
        connectionFailed = false
        everConnected = true
        model = info.displayModel
        updateCurrentTV {
            $0.name = info.name
            $0.model = info.displayModel
            if !info.mac.isEmpty { $0.mac = info.mac }
            $0.tokenAuth = info.tokenAuth
            $0.frameTV = info.frameTV
        }
        if currentTV?.lanMAC == nil { learnLanMAC(ip) }
        if Date() >= suppressPowerUntil { powerOn = info.powerOn }
        guard powerOn else { foregroundApp = nil; return }
        ensureRemote()
        let tvID = currentTVID
        // The installed list rarely changes; refreshing it costs ~30
        // requests, which a busy TV's web server doesn't take well.
        if appsTask == nil, appsLoadedFor != tvID || Date().timeIntervalSince(appsLoadedAt) > 600 {
            appsLoadedFor = tvID
            appsLoadedAt = Date()
            let known = apps
            appsTask = Task {
                let found = await AppCatalog.installed(host: ip, known: known)
                if !found.isEmpty, self.currentTVID == tvID { self.setApps(found) }
                self.appsTask = nil
            }
        }
        if volumeTask == nil {
            volumeTask = Task {
                await self.refreshVolume(ip)
                self.volumeTask = nil
            }
        }
        pollCount += 1
        if foregroundTask == nil {
            let full = pollCount % 4 == 1
            foregroundTask = Task {
                await self.checkForeground(ip, full: full)
                self.foregroundTask = nil
            }
        }
    }

    /// Which app is on screen. A full scan costs one request per installed
    /// app, so it runs every few polls; in between only the app believed to
    /// be on screen is asked about, so leaving it for Home shows within a
    /// poll. Skipped right after a launch or input change while the TV is
    /// still switching.
    private func checkForeground(_ ip: String, full: Bool) async {
        guard Date() >= suppressForegroundUntil else { return }
        var current: TVApp?
        if !full, let shown = foregroundApp {
            if case .found(let status) = await AppCatalog.lookup(host: ip, id: shown.id), status.visible {
                return
            }
            // It's gone; something else may have taken its place.
        }
        current = await AppCatalog.foreground(host: ip, among: apps)
        guard Date() >= suppressForegroundUntil else { return }
        // An app closed on its own: whatever input is showing now isn't
        // necessarily the one picked here earlier.
        if current == nil, foregroundApp != nil { lastInput = "" }
        foregroundApp = current
    }

    /// Keys that can leave or open an app get a quick follow-up look.
    private func recheckForeground() {
        guard let ip = knownIP else { return }
        recheckTask?.cancel()
        recheckTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await checkForeground(ip, full: true)
        }
    }

    /// The ARP cache only has the TV once the Mac has talked to it, so
    /// this runs after a successful answer.
    private func learnLanMAC(_ ip: String) {
        let id = currentTVID
        Task.detached {
            guard let mac = WakeOnLAN.arpMAC(for: ip) else { return }
            await MainActor.run {
                guard let i = self.tvs.firstIndex(where: { $0.id == id }) else { return }
                self.tvs[i].lanMAC = mac
                self.persistTVs()
            }
        }
    }

    private func ensureRemote() {
        guard let ip = knownIP, !remote.isOpen, pairState != .denied else { return }
        remote.connect(host: ip, token: token, secure: currentTV?.tokenAuth ?? true)
    }

    // MARK: - Volume

    /// The TV's own level is read every poll, in either mode, so there is
    /// always a fresh reading to judge the next key press against.
    private func refreshVolume(_ ip: String) async {
        guard Date() >= suppressVolumeUntil, stepBurst == nil else { return }
        // With sound on an external device the TV answers a volume query by
        // asking that device over HDMI-CEC, and a soundbar playing something
        // else (a Sonos on Spotify) takes that as the TV claiming it and
        // switches to TV audio. The level is frozen in that mode anyway, so
        // the TV isn't asked at all; pressing the volume keys, which do go
        // to the device, is what reveals a switch back to the TV speakers.
        if externalAudio { return }
        guard let v = await UPnP.volume(ip) else {
            // No volume service at all: keys are the only way to change it.
            upnpFailures += 1
            if upnpFailures >= 3 { proposeAudio(external: true) }
            return
        }
        upnpFailures = 0
        // The level moved without us: someone used the TV's remote, and it
        // moved, so the TV's speakers are playing.
        if let prev = rawVolume, prev != v, Date().timeIntervalSince(lastVolumeInteraction) > 3 {
            proposeAudio(external: false)
        }
        rawVolume = v
        if !externalAudio {
            volume = v
            if let m = await UPnP.muted(ip) { muted = m }
        }
    }

    func setVolume(_ v: Int) {
        guard let ip = knownIP else { return }
        let clamped = max(0, min(100, v))
        volume = clamped
        lastVolumeInteraction = Date()
        suppressVolumeUntil = Date().addingTimeInterval(1.5)
        volumeThrottler.call { [weak self] in
            Task { await self?.writeVolume(ip, clamped) }
        }
    }

    /// Once a drag settles, the level is read back: a TV sending sound to
    /// an external device ignores the write.
    private func writeVolume(_ ip: String, _ v: Int) async {
        let ok = await UPnP.setVolume(ip, v)
        writeCheck?.cancel()
        guard ok else { return }
        writeCheck = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let readBack = await UPnP.volume(ip) else { return }
            rawVolume = readBack
            if abs(readBack - self.volume) <= 1 {
                proposeAudio(external: false)
            } else {
                proposeAudio(external: true)
            }
        }
    }

    /// Volume keys reach any output: the TV's speakers, or an external
    /// device over HDMI-CEC. The level is read just before the first press
    /// of a burst and again once the burst settles; if the TV's own level
    /// didn't follow the keys, sound is going elsewhere.
    func stepVolume(up: Bool) {
        lastVolumeInteraction = Date()
        // On an external device the keys are all there is; reading the TV's
        // level to check would reach the device over HDMI-CEC (see
        // refreshVolume).
        guard let ip = knownIP, !externalAudio else { press(up ? .volumeUp : .volumeDown); return }
        if stepBurst == nil {
            stepBurst = StepBurst()
            Task {
                // A slow TV mustn't hold the key back; without a reading
                // the burst just counts as no evidence.
                let before = await withDeadline(0.35) { await UPnP.volume(ip) }
                stepBurst?.before = before
                stepBurst?.ready = true
                flushVolumeKeys(ip)
            }
        }
        stepBurst?.queued.append(up)
        flushVolumeKeys(ip)
    }

    private func flushVolumeKeys(_ ip: String) {
        guard var burst = stepBurst, burst.ready, !burst.queued.isEmpty else { return }
        for up in burst.queued {
            press(up ? .volumeUp : .volumeDown)
            burst.net += up ? 1 : -1
        }
        burst.queued = []
        burst.settle?.cancel()
        burst.settle = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await finishVolumeBurst(ip)
        }
        stepBurst = burst
    }

    private func finishVolumeBurst(_ ip: String) async {
        guard let burst = stepBurst else { return }
        let after = await UPnP.volume(ip)
        stepBurst = nil
        guard let before = burst.before, let after else { return }
        rawVolume = after
        if after != before {
            if !externalAudio { volume = after }
            proposeAudio(external: false)
        } else if (burst.net > 0 && before < 100) || (burst.net < 0 && before > 0) {
            proposeAudio(external: true)
        }
    }

    /// Records which output the evidence points to. The swap waits until
    /// the volume control has been left alone for a moment, so the control
    /// never changes shape under the pointer.
    private func proposeAudio(external: Bool) {
        guard external != externalAudio else {
            pendingAudioMode = nil
            audioSwapTask?.cancel()
            return
        }
        pendingAudioMode = external
        audioSwapTask?.cancel()
        audioSwapTask = Task {
            while true {
                let wait = lastVolumeInteraction.addingTimeInterval(2).timeIntervalSinceNow
                guard wait > 0 else { break }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, let mode = pendingAudioMode else { return }
            pendingAudioMode = nil
            if !mode, let raw = rawVolume { volume = raw }
            setExternalAudio(mode)
        }
    }

    private func setExternalAudio(_ on: Bool) {
        externalAudio = on
        UserDefaults.standard.set(on, forKey: "externalAudio.\(currentTVID)")
    }

    func toggleMute() {
        guard !externalAudio, let ip = knownIP else {
            press(.mute)
            return
        }
        muted.toggle()
        lastVolumeInteraction = Date()
        suppressVolumeUntil = Date().addingTimeInterval(1.5)
        let wanted = muted
        Task {
            if await !UPnP.setMute(ip, wanted) { press(.mute) }
        }
    }

    // MARK: - Actions

    func press(_ key: TVKey) {
        ensureRemote()
        remote.send(key)
        if [.home, .back, .enter, .source].contains(key) { recheckForeground() }
    }

    func playPause() {
        press(assumePlaying ? .pause : .play)
        assumePlaying.toggle()
    }

    /// HDMI 1–4 keys work on older sets and are ignored by newer ones. If
    /// an app was on screen and still is a few seconds later, the key did
    /// nothing: the TV is marked and the panel switches to Next Input.
    func selectInput(_ n: Int) {
        let keys: [TVKey] = [.hdmi1, .hdmi2, .hdmi3, .hdmi4]
        guard (1...keys.count).contains(n) else { return }
        let wasOn = foregroundApp
        lastInput = "HDMI \(n)"
        foregroundApp = nil
        suppressForegroundUntil = Date().addingTimeInterval(6)
        press(keys[n - 1])
        guard let ip = knownIP, let wasOn else { return }
        let tvID = currentTVID
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard currentTVID == tvID else { return }
            switch await AppCatalog.lookup(host: ip, id: wasOn.id) {
            case .found(let status) where status.visible:
                updateCurrentTV { $0.directInputs = false }
                lastInput = ""
                foregroundApp = wasOn
            case .found, .missing:
                updateCurrentTV { $0.directInputs = true }
            case .noAnswer:
                break
            }
        }
    }

    /// Steps to the next connected input, for TVs without direct HDMI keys.
    func nextInput() {
        lastInput = ""
        foregroundApp = nil
        suppressForegroundUntil = Date().addingTimeInterval(6)
        press(.nextInput)
    }

    func launch(_ app: TVApp) {
        guard let ip = knownIP else { return }
        foregroundApp = app
        assumePlaying = true
        suppressForegroundUntil = Date().addingTimeInterval(6)
        Task {
            if await !AppCatalog.launch(host: ip, id: app.id) {
                ensureRemote()
                remote.launch(app)
            }
        }
    }

    /// Off is the power key (held on the Frame, whose short press only
    /// toggles Art Mode). On depends on how deeply the TV sleeps: in network
    /// standby it still answers and takes the power key; fully asleep it
    /// needs a Wake-on-LAN packet.
    func togglePower() {
        guard let ip = knownIP else { return }
        suppressPowerUntil = Date().addingTimeInterval(10)
        fastPollUntil = Date().addingTimeInterval(15)
        if powerOn {
            powerOn = false
            foregroundApp = nil
            ensureRemote()
            if currentTV?.frameTV == true {
                remote.hold(.power, seconds: 3)
            } else {
                remote.send(.power)
            }
            return
        }
        powerOn = true
        let macs = Set([currentTV?.mac, currentTV?.lanMAC].compactMap { $0 }.filter { !$0.isEmpty })
        let wake = {
            for i in 0..<3 {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(i) * 400_000_000)
                    for mac in macs { WakeOnLAN.send(mac: mac, near: ip) }
                }
            }
        }
        if reachable {
            // Waking a TV in standby and then pressing power would turn it
            // straight back off, so the packet only follows a key that
            // didn't take.
            press(.power)
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if let info = await TVInfo.fetch(host: ip), info.powerOn { return }
                wake()
            }
        } else {
            wake()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        LoginItem.set(on)
        launchAtLogin = LoginItem.isEnabled
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
