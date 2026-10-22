import SwiftUI

/// Set while rendering README screenshots — AppKit-backed views
/// (scroll catchers, menus) can't render offscreen.
private struct ScreenshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isScreenshotting: Bool {
        get { self[ScreenshotModeKey.self] }
        set { self[ScreenshotModeKey.self] = newValue }
    }
}

/// Control-Center-style volume slider: capsule track, white fill,
/// glyph riding inside the leading cap. Tap the glyph to mute,
/// drag or click anywhere to set the level.
struct CapsuleSlider: View {
    @Binding var value: Double            // 0...100
    var height: CGFloat = 22
    var icon: String? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onIconTap: (() -> Void)? = nil

    @State private var isDragging = false
    @State private var startedOnIcon = false
    @State private var moved = false
    @State private var scrollAccum: CGFloat = 0
    @State private var inScrollSession = false
    @State private var scrollEndTask: Task<Void, Never>?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isScreenshotting) private var isScreenshotting

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let frac = CGFloat(min(max(value / 100, 0), 1))
            let fillWidth = height + frac * (width - height)

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.white)
                    .frame(width: fillWidth)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                if let icon {
                    // Pinned to a fixed leading inset rather than centred: the
                    // wave variants are wider than the bare speaker, and
                    // centring them would slide the cone left as volume rises.
                    Image(systemName: icon)
                        .font(.system(size: height * 0.5, weight: .medium))
                        .foregroundStyle(.black)
                        .frame(width: height, height: height, alignment: .leading)
                        .offset(x: height * 0.23)
                }
            }
            .contentShape(Rectangle())
            // Scroll steps and receiver pushes glide to the new level;
            // finger drags track 1:1 with no animation lag.
            .animation(isDragging ? nil : .smooth(duration: 0.25), value: value)
            .background {
                if !isScreenshotting {
                    ScrollCatcher { dx in handleScroll(dx) }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isDragging {
                            isDragging = true
                            moved = false
                            startedOnIcon = icon != nil && onIconTap != nil
                                && g.startLocation.x < height
                            onEditingChanged(true)
                        }
                        if abs(g.translation.width) > 2 || abs(g.translation.height) > 2 {
                            moved = true
                        }
                        if !startedOnIcon || moved {
                            let f = min(max((g.location.x - height / 2) / (width - height), 0), 1)
                            value = Double(f) * 100
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                        if startedOnIcon && !moved { onIconTap?() }
                        startedOnIcon = false
                    }
            )
        }
        .frame(height: height)
    }

    /// Relative, heavily damped scroll: ~12 points of finger travel per
    /// volume unit, so a swipe nudges the level and can never jump it.
    /// A burst of scrolling counts as one editing session (ends after
    /// 0.5s of stillness) so drag-start snapshots happen once per swipe.
    private func handleScroll(_ dx: CGFloat) {
        guard isEnabled else { return }
        scrollAccum += dx
        let damp: CGFloat = 12
        let steps = Int(scrollAccum / damp)
        guard steps != 0 else { return }
        scrollAccum -= CGFloat(steps) * damp
        if !inScrollSession {
            inScrollSession = true
            onEditingChanged(true)
        }
        value = min(100, max(0, value + Double(steps)))
        scrollEndTask?.cancel()
        scrollEndTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            inScrollSession = false
            onEditingChanged(false)
        }
    }
}

extension CapsuleSlider {
    /// Control-Center-style speaker glyph for a level: a bare speaker at
    /// silence, waves filling in as the level climbs.
    static func speakerIcon(_ volume: Int, muted: Bool = false) -> String {
        if muted { return "speaker.slash.fill" }
        switch volume {
        case ..<1:  return "speaker.fill"
        case ..<34: return "speaker.wave.1.fill"
        case ..<67: return "speaker.wave.2.fill"
        default:    return "speaker.wave.3.fill"
        }
    }
}

/// Invisible, click-through view that reports horizontal scroll deltas
/// occurring over its bounds. Clicks and drags pass straight through.
private struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else {
                        return event
                    }
                    let p = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(p) else { return event }
                    let dx = event.hasPreciseScrollingDeltas
                        ? event.scrollingDeltaX
                        : event.scrollingDeltaX * 6
                    self.onScroll?(dx)
                    return nil
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
