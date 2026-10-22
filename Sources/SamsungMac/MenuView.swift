import SwiftUI

struct MenuView: View {
    @Environment(TVSystem.self) private var tv
    @Environment(\.isScreenshotting) private var isScreenshotting
    /// Sections whose rows are fading out before the section closes.
    @State private var closing: Set<String> = []
    /// The text field was opened from its button, for TVs that don't say
    /// when their keyboard is up.
    @State private var typing = false
    @FocusState private var fieldFocused: Bool

    private var showField: Bool { typing || tv.keyboardOpen }

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
        .animation(.panel, value: "\(remoteExpanded)\(appsExpanded)\(inputsExpanded)\(tv.pairState == .paired)\(tv.connectionLost)\(showField)")
        .modifier(PanelSizer(enabled: !isScreenshotting) { handleKey($0) })
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
                toggle(title, expanded)
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
                    .opacity(closing.contains(title) ? 0 : 1)
                    .transition(.panelRow)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Opening grows the window and then fades the rows in; closing fades
    /// them out and then shrinks the window, so nothing is drawn while the
    /// edge passes over it.
    private func toggle(_ title: String, _ expanded: Binding<Bool>) {
        guard expanded.wrappedValue else {
            closing.remove(title)
            expanded.wrappedValue = true
            return
        }
        guard !closing.contains(title) else { return }
        withAnimation(.easeIn(duration: 0.09)) { _ = closing.insert(title) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            guard closing.contains(title) else { return }
            expanded.wrappedValue = false
            closing.remove(title)
        }
    }

    // MARK: - Keyboard

    /// Arrow keys, Return, Delete (Back), Space (play/pause), H (Home),
    /// +/− (volume) and M (mute) drive the TV while the panel is open.
    /// Escape still closes the panel. While the text field has focus its
    /// keys go to it instead, and Escape just closes the field.
    private func handleKey(_ event: NSEvent) -> Bool {
        if fieldFocused {
            guard event.keyCode == 53 else { return false }
            closeField()
            return true
        }
        // The field is up but lost focus: typing still goes into it rather
        // than to the remote shortcuts (H would otherwise mean Home).
        if showField, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.keyCode {
            case 53: closeField()
            case 51: tv.typeText(String(tv.typedText.dropLast()))
            case 36, 76: tv.submitText(); typing = false
            default:
                guard let chars = event.characters, !chars.isEmpty,
                      chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                      !(123...126).contains(event.keyCode) else { return false }
                tv.typeText(tv.typedText + chars)
            }
            fieldFocused = true
            return true
        }
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
                iconButton("keyboard", help: "Type on TV") {
                    if showField { closeField() } else { typing = true; fieldFocused = true }
                }
                iconButton("playpause.fill", primary: true, help: "Play / Pause") { tv.playPause() }
            }
            volume
            if showField {
                textField
                    .transition(.panelRow)
            }
        }
        .onChange(of: tv.keyboardOpen) { _, open in
            if open { fieldFocused = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .disabled(!tv.powerOn || tv.connectionLost)
        .opacity(tv.powerOn && !tv.connectionLost ? 1 : 0.4)
    }

    /// Mirrors into the field the TV's on-screen keyboard is editing, so
    /// search boxes can be typed from the Mac. Return runs the search.
    private var textField: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            TextField("Type on TV", text: Binding(get: { tv.typedText }, set: { tv.typeText($0) }))
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit {
                    tv.submitText()
                    typing = false
                }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    }

    private func closeField() {
        typing = false
        fieldFocused = false
        tv.keyboardOpen = false
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

    /// Two columns laid out eagerly. A lazy grid places cells that appear
    /// mid-animation at its origin first, so they flew in from the top.
    private func twoColumns<Item, Cell: View>(_ items: [Item],
                                              @ViewBuilder cell: @escaping (Item) -> Cell) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { i in
                HStack(spacing: 4) {
                    cell(items[i]).frame(maxWidth: .infinity)
                    if i + 1 < items.count {
                        cell(items[i + 1]).frame(maxWidth: .infinity)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
        .padding(.horizontal, -6)
    }

    private var appGrid: some View {
        twoColumns(tv.apps) { app in
            ChoiceRow(symbol: Self.symbol(for: app.name), title: app.name,
                      active: tv.foregroundApp?.id == app.id) { tv.launch(app) }
                .help("Open \(app.name)")
        }
    }

    /// HDMI 1–4 where the TV takes direct input keys. Newer sets ignore
    /// them, so once that's seen the section steps through inputs instead.
    @ViewBuilder
    private var inputGrid: some View {
        if tv.directInputs {
            twoColumns(Array(1...4)) { n in
                ChoiceRow(symbol: "cable.connector", title: "HDMI \(n)",
                          active: tv.foregroundApp == nil && tv.lastInput == "HDMI \(n)") {
                    tv.selectInput(n)
                }
            }
        } else {
            HStack(spacing: 4) {
                ChoiceRow(symbol: "arrow.right.circle", title: "Next Input") { tv.nextInput() }
                    .frame(maxWidth: .infinity)
                ChoiceRow(symbol: "rectangle.on.rectangle", title: "Source List") { tv.press(.source) }
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, -6)
        }
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
