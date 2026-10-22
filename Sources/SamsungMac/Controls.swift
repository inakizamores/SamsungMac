import SwiftUI
import AppKit

/// Navigation ring: four press-lit quadrants around a central OK, drawn
/// in the same faint fills as the rest of the panel so it reads as part
/// of the material rather than a slab on top of it.
struct DPad: View {
    var size: CGFloat = 112
    var onKey: (TVKey) -> Void

    private let innerRatio: CGFloat = 0.46

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.06))
            ForEach(Direction.allCases, id: \.self) { d in
                Button { onKey(d.key) } label: { EmptyView() }
                    .buttonStyle(SegmentStyle(direction: d, size: size, innerRatio: innerRatio))
                    .accessibilityLabel(d.label)
            }
            Button { onKey(.enter) } label: {
                Text("OK")
                    .font(.system(.subheadline, weight: .semibold))
            }
            .buttonStyle(CenterStyle(diameter: size * innerRatio - 6))
            .accessibilityLabel("OK")
        }
        .frame(width: size, height: size)
    }

    enum Direction: CaseIterable {
        case up, right, down, left

        var key: TVKey {
            switch self {
            case .up: .up
            case .right: .right
            case .down: .down
            case .left: .left
            }
        }

        var label: String {
            switch self {
            case .up: "Up"
            case .right: "Right"
            case .down: "Down"
            case .left: "Left"
            }
        }

        /// SwiftUI angles run clockwise from +x.
        var angle: Double {
            switch self {
            case .right: 0
            case .down: 90
            case .left: 180
            case .up: 270
            }
        }

        var symbol: String {
            switch self {
            case .up: "chevron.up"
            case .right: "chevron.right"
            case .down: "chevron.down"
            case .left: "chevron.left"
            }
        }
    }

    private struct SegmentStyle: ButtonStyle {
        let direction: Direction
        let size: CGFloat
        let innerRatio: CGFloat

        func makeBody(configuration: Configuration) -> some View {
            let shape = RingSegment(center: direction.angle, innerRatio: innerRatio)
            let r = size / 2 * (1 + innerRatio) / 2
            let rad = direction.angle * .pi / 180
            ZStack {
                shape.fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0))
                Image(systemName: direction.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(configuration.isPressed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .offset(x: cos(rad) * r, y: sin(rad) * r)
            }
            .frame(width: size, height: size)
            .contentShape(shape)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }

    private struct CenterStyle: ButtonStyle {
        let diameter: CGFloat

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(.primary)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07)))
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// A quarter of an annulus centred on `center` degrees.
private struct RingSegment: Shape {
    var center: Double
    var innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: .degrees(center - 45),
                 endAngle: .degrees(center + 45), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: .degrees(center + 45),
                 endAngle: .degrees(center - 45), clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// Control-Center-style choice row: an icon in a circle that fills with
/// the accent colour when it's the current choice, a label beside it, and
/// the menu highlight on hover.
struct ChoiceRow: View {
    var symbol: String
    var title: String
    var active = false
    var action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(active ? AnyShapeStyle(Color.accentColor)
                                                     : AnyShapeStyle(.quaternary)))
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Volume for TVs sending sound to an external device: the level can't be
/// read, so it's the slider's capsule with step buttons instead of a fill
/// that would show a stale number.
struct VolumeStepper: View {
    var onStep: (Bool) -> Void
    var onMute: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onMute) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22, alignment: .leading)
                    .offset(x: 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Mute")
            Text("External speaker")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            Spacer(minLength: 4)
            stepButton("minus", "Volume Down") { onStep(false) }
            stepButton("plus", "Volume Up") { onStep(true) }
        }
        .frame(height: 22)
        .background(Capsule().fill(.quaternary))
    }

    private func stepButton(_ symbol: String, _ label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 34, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
        .help(label)
        .accessibilityLabel(label)
    }

    private struct PressFade: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0)))
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// Invisible view that hands key presses in its window to `onKey` while
/// the panel is open. A local event monitor rather than a focusable SwiftUI
/// view: focusable views draw their own key-view background in the panel.
/// Returning true swallows the event.
///
/// It also keeps the panel's window the height of its content. The menu
/// bar window sizes itself once when it opens and doesn't follow later
/// changes, leaving the content as an inset box in a taller window.
struct KeyCatcher: NSViewRepresentable {
    var height: CGFloat
    var onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onKey = onKey
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onKey = onKey
        nsView.fit(height: height)
    }

    final class CatcherView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Grows or shrinks the window downward, keeping its top under the
        /// menu bar.
        func fit(height: CGFloat) {
            guard let w = window, height > 0 else { return }
            let f = w.frame
            guard abs(f.height - height) > 0.5 else { return }
            w.setFrame(NSRect(x: f.minX, y: f.maxY - height, width: f.width, height: height),
                       display: true)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, event.window === self.window else { return event }
                    return self.onKey?(event) == true ? nil : event
                }
            } else if window == nil, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}
