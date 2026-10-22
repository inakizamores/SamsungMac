import Foundation

/// Tizen app IDs for widely used apps. Newer firmware no longer answers the
/// "installed apps" request over the remote channel, but each app can still
/// be looked up by ID at /api/v2/applications/<id> — which also reports
/// whether it's the one on screen. Unknown IDs just 404, so the list can be
/// generous across regions.
enum AppCatalog {
    static let ids: [String] = [
        "3201907018807",   // Netflix
        "111299001912",    // YouTube
        "3201910019365",   // Prime Video
        "3201901017640",   // Disney+
        "3202301029760",   // HBO Max
        "3201601007230",   // HBO Max (older)
        "3201807016597",   // Apple TV
        "3201908019041",   // Apple Music
        "3201606009684",   // Spotify
        "3202110025305",   // Paramount+
        "3201710014981",   // Paramount+ (older)
        "3201512006963",   // Plex
        "3201707014489",   // YouTube TV
        "3201909019175",   // Crunchyroll
        "3202010022098",   // ViX
        "3201703012065",   // Pluto TV
        "3201804016319",   // Twitch
        "3201911019592",   // Peacock
        "3201601007250",   // Hulu
        "3201807016598",   // Tubi
        "3202203026841",   // Kick
        "3201506003486",   // Deezer
        "3201611010983",   // TIDAL
        "3201907018784",   // Rakuten TV
        "3201711015226",   // DAZN
        "3202010022079",   // Browser
        "3201907018786",   // Samsung TV Plus
        "3201710015037",   // Gallery
    ]

    struct Status {
        let app: TVApp
        let visible: Bool
    }

    /// A lookup either finds the app, hears from the TV that it isn't
    /// installed (404), or gets no answer — which says nothing either way.
    enum Lookup {
        case found(Status)
        case missing
        case noAnswer
    }

    static func lookup(host: String, id: String) async -> Lookup {
        guard let url = URL(string: "http://\(host):8001/api/v2/applications/\(id)") else { return .noAnswer }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return .noAnswer }
        if code == 404 { return .missing }
        guard code == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["name"] as? String else { return .noAnswer }
        return .found(Status(app: TVApp(id: id, name: shortName(name), type: 2),
                             visible: obj["visible"] as? Bool ?? false))
    }

    /// Every catalog app installed on the TV, alphabetically. Looked up a
    /// few at a time, since the TV's web server drops requests under a
    /// burst, and unanswered IDs are asked again one by one. An app already
    /// in `known` stays unless the TV says it's gone, so a busy TV can't
    /// shrink the list.
    static func installed(host: String, known: [TVApp]) async -> [TVApp] {
        var apps: [TVApp] = []
        var unanswered: [String] = []
        for start in stride(from: 0, to: ids.count, by: 4) {
            let chunk = ids[start..<min(start + 4, ids.count)]
            let results = await withTaskGroup(of: (String, Lookup).self) { group in
                for id in chunk { group.addTask { (id, await lookup(host: host, id: id)) } }
                var all: [(String, Lookup)] = []
                for await r in group { all.append(r) }
                return all
            }
            for (id, result) in results {
                switch result {
                case .found(let status): apps.append(status.app)
                case .missing: break
                case .noAnswer: unanswered.append(id)
                }
            }
        }
        for id in unanswered {
            switch await lookup(host: host, id: id) {
            case .found(let status): apps.append(status.app)
            case .missing: break
            case .noAnswer:
                if let app = known.first(where: { $0.id == id }) { apps.append(app) }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The installed app currently on screen, if any.
    static func foreground(host: String, among apps: [TVApp]) async -> TVApp? {
        for start in stride(from: 0, to: apps.count, by: 4) {
            let chunk = apps[start..<min(start + 4, apps.count)]
            let hit = await withTaskGroup(of: TVApp?.self) { group -> TVApp? in
                for app in chunk {
                    group.addTask {
                        if case .found(let status) = await lookup(host: host, id: app.id), status.visible { return app }
                        return nil
                    }
                }
                for await hit in group { if let hit { group.cancelAll(); return hit } }
                return nil
            }
            if let hit { return hit }
        }
        return nil
    }

    /// Opens an app over REST. Unlike the remote channel's launch event, this
    /// works for every installed app and needs no pairing.
    static func launch(host: String, id: String) async -> Bool {
        guard let url = URL(string: "http://\(host):8001/api/v2/applications/\(id)") else { return false }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        req.httpMethod = "POST"
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// "Spotify - Music and Podcasts" → "Spotify"
    private static func shortName(_ name: String) -> String {
        name.components(separatedBy: " - ").first ?? name
    }
}
