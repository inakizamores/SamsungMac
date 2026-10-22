import SwiftUI
import AppKit

/// Renders the real UI to PNGs for the README when the app is launched
/// with `--render-screenshots <dir>`. Not reachable in normal use.
@MainActor
enum ScreenshotRenderer {
    static func runIfRequested() {
        guard let i = CommandLine.arguments.firstIndex(of: "--render-screenshots"),
              CommandLine.arguments.count > i + 1 else { return }
        renderAll(to: CommandLine.arguments[i + 1])
        exit(0)
    }

    private static func sampleSystem() -> TVSystem {
        let sys = TVSystem()
        sys.everConnected = true
        sys.connectionFailed = false
        sys.reachable = true
        sys.model = "S85F · 55″"
        sys.powerOn = true
        sys.volume = 24
        sys.muted = false
        sys.pairState = .paired
        sys.externalAudio = false
        sys.lastInput = "HDMI 2"
        sys.tvs = [KnownTV(ip: "", name: "Living Room", model: "S85F · 55″", mac: "sample")]
        sys.currentTVID = "sample"
        sys.apps = ["Apple Music", "Apple TV", "Disney+", "HBO Max", "Netflix", "Prime Video",
                    "Spotify", "YouTube"]
            .enumerated().map { TVApp(id: "app\($0.offset)", name: $0.element, type: 2) }
        sys.foregroundApp = sys.apps.first { $0.name == "Netflix" }
        return sys
    }

    private static func renderAll(to dir: String) {
        let sys = sampleSystem()
        render(MenuView().environment(sys), name: "screenshot-panel", dir: dir)
        sys.externalAudio = true
        render(MenuView().environment(sys), name: "screenshot-arc", dir: dir)
    }

    private static func render<V: View>(_ view: V, name: String, dir: String) {
        let content = view
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(white: 0.13))
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .padding(32)
            .environment(\.colorScheme, .dark)
            .environment(\.isScreenshotting, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed: \(name)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("rendered \(name).png")
    }
}
