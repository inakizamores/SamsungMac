import Foundation
import Darwin

/// What the TV reports about itself at http://<tv>:8001/api/v2/ — answered
/// both when on and in network standby.
struct TVInfo {
    let name: String
    let modelName: String      // e.g. QN55S85FAFXZX
    let mac: String
    let powerOn: Bool
    /// 2018+ TVs pair over wss://:8002 with a token; 2016–17 models only
    /// speak plain ws://:8001 and never prompt.
    var tokenAuth = true
    /// The Frame's power key goes to Art Mode; a long press turns it off.
    var frameTV = false

    static func fetch(host: String, timeout: TimeInterval = 1.5) async -> TVInfo? {
        guard let url = URL(string: "http://\(host):8001/api/v2/") else { return nil }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let device = obj["device"] as? [String: Any],
              (device["type"] as? String)?.hasPrefix("Samsung") == true else { return nil }
        let name = (device["name"] as? String ?? "Samsung TV")
            .replacingOccurrences(of: "&quot;", with: "\"")
        // Older firmware omits PowerState: answering at all means it's on.
        return TVInfo(name: name,
                      modelName: device["modelName"] as? String ?? "",
                      mac: device["wifiMac"] as? String ?? "",
                      powerOn: (device["PowerState"] as? String ?? "on") == "on",
                      tokenAuth: (device["TokenAuthSupport"] as? String ?? "true") == "true",
                      frameTV: (device["FrameTVSupport"] as? String ?? "false") == "true")
    }

    /// "QN55S85FAFXZX" → "S85F · 55″". Falls back to the TV's own name.
    var displayModel: String {
        let chars = Array(modelName.dropFirst(2))
        let size = String(chars.prefix(while: \.isNumber))
        var rest = chars.dropFirst(size.count)
        var series = String(rest.prefix(while: \.isLetter))
        rest = rest.dropFirst(series.count)
        let digits = String(rest.prefix(while: \.isNumber))
        rest = rest.dropFirst(digits.count)
        guard (2...3).contains(size.count), !series.isEmpty, !digits.isEmpty,
              let suffix = rest.first, suffix.isLetter else { return name }
        series += digits + String(suffix)
        return "\(series) · \(size)″"
    }
}

/// UPnP RenderingControl on port 9197 — the one local interface that can
/// read the TV's volume and mute, not just nudge them.
enum UPnP {
    private static func call(_ host: String, _ action: String, _ args: String) async -> String? {
        guard let url = URL(string: "http://\(host):9197/upnp/control/RenderingControl1") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#\(action)\"",
                     forHTTPHeaderField: "SOAPACTION")
        req.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>\
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
            <u:\(action) xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">\
            <InstanceID>0</InstanceID><Channel>Master</Channel>\(args)</u:\(action)>\
            </s:Body></s:Envelope>
            """.utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func value(_ tag: String, in xml: String?) -> String? {
        guard let xml, let a = xml.range(of: "<\(tag)>"),
              let b = xml.range(of: "</\(tag)>", range: a.upperBound..<xml.endIndex) else { return nil }
        return xml[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func volume(_ host: String) async -> Int? {
        value("CurrentVolume", in: await call(host, "GetVolume", "")).flatMap { Int($0) }
    }

    static func muted(_ host: String) async -> Bool? {
        value("CurrentMute", in: await call(host, "GetMute", "")).map { $0 == "1" }
    }

    @discardableResult
    static func setVolume(_ host: String, _ v: Int) async -> Bool {
        await call(host, "SetVolume", "<DesiredVolume>\(v)</DesiredVolume>") != nil
    }

    @discardableResult
    static func setMute(_ host: String, _ on: Bool) async -> Bool {
        await call(host, "SetMute", "<DesiredMute>\(on ? 1 : 0)</DesiredMute>") != nil
    }
}

/// SSDP sweep for media renderers, confirmed against the Samsung REST API.
enum TVDiscovery {
    /// Every Samsung TV that answers, sorted by name.
    static func discover() async -> [(ip: String, info: TVInfo)] {
        let candidates = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: ssdpSearch(timeout: 1.8))
            }
        }
        return await withTaskGroup(of: (String, TVInfo)?.self) { group in
            for ip in candidates {
                group.addTask { await TVInfo.fetch(host: ip).map { (ip, $0) } }
            }
            var found: [(ip: String, info: TVInfo)] = []
            for await hit in group { if let hit { found.append((ip: hit.0, info: hit.1)) } }
            return found.sorted { $0.info.name < $1.info.name }
        }
    }

    private static func ssdpSearch(timeout: TimeInterval) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")
        // Every Tizen TV answers as a media renderer; the remote-control
        // receiver type also catches sets with DLNA turned off.
        let targets = ["urn:schemas-upnp-org:device:MediaRenderer:1",
                       "urn:samsung.com:device:RemoteControlReceiver:1"]
        for _ in 0..<2 {
            for st in targets {
                let probe = Array(("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n" +
                                   "MAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(st)\r\n\r\n").utf8)
                _ = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, probe, probe.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var found: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
                }
            }
            guard n > 0 else { continue }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sin = from.sin_addr
            if inet_ntop(AF_INET, &sin, &ipBuf, socklen_t(INET_ADDRSTRLEN)) != nil {
                let ip = String(cString: ipBuf)
                if !found.contains(ip) { found.append(ip) }
            }
        }
        return found
    }
}

/// Wakes a TV whose network interface is fully asleep (needs "Power On
/// with Mobile" enabled in the TV's settings).
enum WakeOnLAN {
    /// The MAC the Mac actually reaches the TV through, from the ARP cache.
    /// The REST API only reports the Wi-Fi MAC, which is the wrong one for
    /// a TV on Ethernet.
    static func arpMAC(for ip: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-n", ip]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let r = text.range(of: " at "),
              let mac = text[r.upperBound...].split(separator: " ").first else { return nil }
        // arp drops leading zeros ("38:8c:ef:2b:1b:1a" but "0:1a:…").
        let parts = mac.split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }
        guard parts.count == 6, parts.allSatisfy({ UInt8($0, radix: 16) != nil }) else { return nil }
        return parts.joined(separator: ":").uppercased()
    }

    static func send(mac: String, near host: String) {
        let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += bytes }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        let subnet = host.split(separator: ".").prefix(3).joined(separator: ".") + ".255"
        for target in ["255.255.255.255", subnet] {
            for port: UInt16 in [9, 7] {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr.s_addr = inet_addr(target)
                _ = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, packet, packet.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }
}
