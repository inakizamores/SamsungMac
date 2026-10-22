import SwiftUI

struct MenuView: View {
    @Environment(TVSystem.self) private var tv
    @Environment(\.isScreenshotting) private var isScreenshotting
    @State private var contentHeight: CGFloat = 0

    /// Show the populated controls whenever we know the TV — even while it
    /// is still answering — so opening the panel never flashes an empty
    /// layout. The empty state is reserved for first-run and failure.
    private var showControls: Bool {
        tv.everConnected && !tv.connectionFailed
    }

    @AppStorage("remoteExpanded") private var remoteExpanded = true
    @AppStorage("appsExpanded") private var appsExpanded = true
    @AppStorage("inputsExpanded") private var inputsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                pairingNote
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            if showControls {
                divider
                nowPlaying
                Group {
                    divider
                    section("Remote", expanded: $remoteExpanded) { remote }
                    if !tv.apps.isEmpty {
                        divider
                        section("Apps", detail: tv.foregroundApp?.name,
                                expanded: $appsExpanded) { appGrid }
                    }
                    divider
                    section("Inputs", detail: tv.foregroundApp == nil ? tv.lastInput : nil,
                            expanded: $inputsExpanded) { inputGrid }
                }
                .disabled(!tv.powerOn || tv.connectionLost)
                .opacity(tv.powerOn && !tv.connectionLost ? 1 : 0.4)
            } else {
                disconnectedState
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
        }
        .frame(width: 320)
        .animation(.panel, value: "\(remoteExpanded)\(appsExpanded)\(inputsExpanded)\(tv.pairState == .paired)\(tv.connectionLost)")
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .background {
            if !isScreenshotting { KeyCatcher(height: contentHeight) { handleKey($0) } }
        }
        .onAppear { tv.menuOpened() }
        .onDisappear { tv.menuClosed() }
    }

    private var divider: some View {
        Divider().padding(.horizontal, 10)
    }

    /// Collapsible section, headed like SonoMac's Sound section. When it's
    /// closed the header still shows the current choice on the right.
    private func section<Content: View>(_ title: String, detail: String? = nil,
                                        expanded: Binding<Bool>,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(expanded.wrappedValue ? .zero : .degrees(-90))
                    Text(title)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if !expanded.wrappedValue, let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.wrappedValue {
                content()
                    .transition(.panelRow)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Keyboard

    /// Arrow keys, Return, Delete (Back), Space (play/pause), H (Home),
    /// +/− (volume) and M (mute) drive the TV while the panel is open.
    /// Escape still closes the panel.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard tv.powerOn, !tv.connectionLost, showControls,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 126: tv.press(.up)
        case 125: tv.press(.down)
        case 123: tv.press(.left)
        case 124: tv.press(.right)
        case 36, 76: tv.press(.enter)
        case 51: tv.press(.back)
        case 49: tv.playPause()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "h": tv.press(.home)
            case "m": tv.toggleMute()
            case "=", "+": stepVolume(up: true)
            case "-": stepVolume(up: false)
            default: return false
            }
        }
        return true
    }

    private func stepVolume(up: Bool) {
        if tv.externalAudio { tv.stepVolume(up: up) } else { tv.setVolume(tv.volume + (up ? 2 : -2)) }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Text("Samsung")
                .font(.system(.body, weight: .semibold))
            if !tv.model.isEmpty {
                Text(tv.model)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if showControls {
                Button { tv.togglePower() } label: {
                    Image(systemName: "power")
                        .fontWeight(.semibold)
                        .foregroundStyle(tv.powerOn ? AnyShapeStyle(Color.accentColor)
                                                    : AnyShapeStyle(.secondary))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tv.powerOn ? "Turn off" : "Turn on")
            }
            settingsMenu
        }
    }

    /// What's on, with transport and volume — the same card SonoMac draws
    /// for a room.
    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(nowPlayingTitle)
                        .lineLimit(1)
                    if !tv.tvName.isEmpty {
                        Text(tv.tvName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                // Seek and skip keys are left out: apps like Spotify ignore
                // them, so only play/pause is reliable across apps.
                iconButton("playpause.fill", primary: true, help: "Play / Pause") { tv.playPause() }
            }
            volume
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .disabled(!tv.powerOn || tv.connectionLost)
        .opacity(tv.powerOn && !tv.connectionLost ? 1 : 0.4)
    }

    private var nowPlayingTitle: String {
        guard tv.powerOn else { return "Off" }
        if let app = tv.foregroundApp { return app.name }
        return tv.lastInput.isEmpty ? "TV" : tv.lastInput
    }

    /// Slider and steppers share one 22pt capsule and crossfade, so a
    /// change of output never shifts the layout.
    private var volume: some View {
        ZStack {
            if tv.externalAudio {
                VolumeStepper(onStep: { tv.stepVolume(up: $0) }, onMute: { tv.toggleMute() })
                    .transition(.opacity)
            } else {
                CapsuleSlider(
                    value: Binding(
                        get: { Double(tv.volume) },
                        set: { tv.setVolume(Int($0.rounded())) }
                    ),
                    icon: CapsuleSlider.speakerIcon(tv.volume, muted: tv.muted),
                    onIconTap: { tv.toggleMute() }
                )
                .transition(.opacity)
            }
        }
        .frame(height: 22)
        .animation(.easeInOut(duration: 0.3), value: tv.externalAudio)
    }

    private func iconButton(_ symbol: String, primary: Bool = false, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .imageScale(primary ? .medium : .small)
                .foregroundStyle(primary ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 23, height: 21)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Ring in the middle, Back/Home on its left and the TV's own menus on
    /// its right.
    private var remote: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                glyphButton("chevron.backward", "Back") { tv.press(.back) }
                glyphButton("house", "Home") { tv.press(.home) }
            }
            .frame(maxWidth: .infinity)
            DPad { tv.press($0) }
            VStack(spacing: 12) {
                glyphButton("rectangle.on.rectangle", "Source List") { tv.press(.source) }
                glyphButton("gearshape", "TV Settings") { tv.press(.menu) }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 2)
    }

    private func glyphButton(_ symbol: String, _ label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private let twoColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 2)

    private var appGrid: some View {
        LazyVGrid(columns: twoColumns, spacing: 2) {
            ForEach(tv.apps) { app in
                ChoiceRow(symbol: Self.symbol(for: app.name), title: app.name,
                          active: tv.foregroundApp?.id == app.id) { tv.launch(app) }
                    .help("Open \(app.name)")
            }
        }
        .padding(.horizontal, -6)
    }

    /// HDMI 1–4 where the TV takes direct input keys. Newer sets ignore
    /// them, so once that's seen the section steps through inputs instead.
    @ViewBuilder
    private var inputGrid: some View {
        LazyVGrid(columns: twoColumns, spacing: 2) {
            if tv.directInputs {
                ForEach(1...4, id: \.self) { n in
                    ChoiceRow(symbol: "cable.connector", title: "HDMI \(n)",
                              active: tv.foregroundApp == nil && tv.lastInput == "HDMI \(n)") {
                        tv.selectInput(n)
                    }
                }
            } else {
                ChoiceRow(symbol: "arrow.right.circle", title: "Next Input") { tv.nextInput() }
                ChoiceRow(symbol: "rectangle.on.rectangle", title: "Source List") { tv.press(.source) }
            }
        }
        .padding(.horizontal, -6)
    }

    /// Apps have no icons over the network API, so each gets a symbol for
    /// what it is.
    private static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if ["music", "spotify", "deezer", "tidal"].contains(where: n.contains) { return "music.note" }
        if n.contains("browser") || n.contains("internet") { return "globe" }
        if n.contains("gallery") { return "photo" }
        if n.contains("apple tv") { return "appletv" }
        if n.contains("youtube") || n.contains("twitch") || n.contains("kick") { return "play.rectangle" }
        return "play.fill"
    }

    @ViewBuilder
    private var pairingNote: some View {
        if tv.connectionLost {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("TV isn't responding. Reconnecting…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            pairPrompt
        }
    }

    /// The Allow prompt only makes sense while the TV is answering;
    /// otherwise a slow connection would read as a pairing request.
    @ViewBuilder
    private var pairPrompt: some View {
        switch tv.reachable ? tv.pairState : .idle {
        case .awaitingApproval:
            Label("Choose Allow on your TV to pair this Mac.", systemImage: "tv")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .denied:
            HStack {
                Label("Pairing was declined on the TV.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Try Again") { tv.retryPairing() }
                    .controlSize(.small)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var settingsMenu: some View {
        if isScreenshotting {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        } else {
            Menu {
                if tv.tvs.count > 1 {
                    Picker("TV", selection: Binding(
                        get: { tv.currentTVID },
                        set: { tv.selectTV($0) }
                    )) {
                        ForEach(tv.tvs) { t in
                            Text(t.model.isEmpty ? t.name : "\(t.name) — \(t.model)").tag(t.id)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                }
                Toggle("Start at Login", isOn: Binding(
                    get: { tv.launchAtLogin },
                    set: { tv.setLaunchAtLogin($0) }
                ))
                Button("Rescan Network") { tv.rescan() }
                Divider()
                Button("Quit SamsungMac") { tv.quit() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var disconnectedState: some View {
        VStack(spacing: 8) {
            if tv.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Looking for your TV…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "tv")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No Samsung TV found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Scan Again") { tv.rescan() }
                    .controlSize(.small)
            }
        }
    }
}
