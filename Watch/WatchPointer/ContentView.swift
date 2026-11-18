import SwiftUI

/// Double Tap (index finger and thumb tapped twice) is recognised a moment after the fingers meet, so its click is
/// sent as if it happened this many seconds ago; the Mac rewinds the pointer by it, as it does for the jolt of a tap.
/// A guess: raise it if Double Tap clicks land a bit after where you were pointing, lower it if before.
private let doubleTapLead = 0.25

/// The steps of the settings (1 = the default). Few and far apart on purpose, so every tap of − or + is felt.
private let speedLevels = [0.4, 0.6, 0.8, 1, 1.25, 1.5, 2, 2.5, 3]
private let steadyLevels = [0.5, 0.75, 1, 1.5, 2, 3, 4]
private let scrollLevels = [0.1, 0.25, 0.5, 1, 2, 4, 8, 12, 20] // 20× = how fast 1× used to be

/// A remote you use without looking: one big pad, three buttons in fixed places, haptics for feedback.
struct ContentView: View {
    @StateObject private var pointer = Pointer()
    @State private var crown = 0.0
    @FocusState private var crownFocused: Bool
    @State private var clicks = 0
    @State private var centers = 0
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            remote
                .toolbar {
                    if pointer.connected {
                        // Top-left, next to the clock: Speed, Steady and Scroll sliders, and the way to unpair.
                        ToolbarItem(placement: .topBarLeading) {
                            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        }
                    }
                }
                .sheet(isPresented: $showSettings) { SettingsSheet(pointer: pointer) }
        }
    }

    private var remote: some View {
        Group {
            if pointer.connected, pointer.access == .waiting || pointer.access == .declined {
                NeedsApproval(declined: pointer.access == .declined)
                    .transition(.opacity)
            } else if pointer.connected {
                VStack(spacing: 6) {
                    ZStack {
                        ClickPad(paused: pointer.paused, clicks: $clicks, pointer: pointer)
                        // Double Tap clicks without touching the watch: the system presses the screen's primary action
                        // for you. Touches never reach this button (the pad under it takes them); only the gesture does.
                        Button {
                            clicks += 1
                            // b = 1 tells the Mac this click came from the gesture, so it keeps the pointer still after it.
                            pointer.send(.leftClick, 0, 1, at: ProcessInfo.processInfo.systemUptime - doubleTapLead)
                        } label: { Color.clear }
                            .buttonStyle(.plain)
                            .handGestureShortcut(.primaryAction)
                            .allowsHitTesting(false)
                    }
                    .frame(maxHeight: .infinity)
                    HStack(spacing: 6) {
                        PadButton(symbol: "contextualmenu.and.cursorarrow") {
                            clicks += 1
                            // Buttons fire on release; a press lasts about this long, so this is roughly touch-down.
                            pointer.send(.rightClick, at: ProcessInfo.processInfo.systemUptime - 0.12)
                        }
                        PadButton(symbol: "scope") {
                            centers += 1
                            pointer.center()
                        }
                        PadButton(symbol: pointer.paused ? "play.fill" : "pause.fill", tint: pointer.paused ? .orange : .white) {
                            pointer.togglePause()
                        }
                        // Which edge points at the screen: each tap goes 12 → 3 → 6 → 9 → 12, and recentres.
                        EdgeButton(edge: pointer.edge) {
                            centers += 1
                            pointer.cycleEdge()
                        }
                    }
                    .frame(height: 52)
                }
                .padding(.horizontal, 4)
                .transition(.opacity)
            } else if let name = pointer.pairedName {
                WaitingForMac(name: name) { pointer.forget() }
                    .transition(.opacity)
            } else {
                PairList(found: pointer.found) { pointer.pair($0) }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .animation(.smooth(duration: 0.3), value: pointer.connected)
        .animation(.smooth(duration: 0.3), value: pointer.access)
        // The Crown only reaches the focused view, so keep focus here rather than on a button.
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation($crown)
        .onChange(of: crown) { old, new in pointer.scroll(crown: new - old) }
        .onChange(of: showSettings) { crownFocused = true }
        .onAppear { crownFocused = true }
        .onChange(of: pointer.connected) { crownFocused = true }
        .sensoryFeedback(.impact(weight: .light), trigger: clicks)
        .sensoryFeedback(.success, trigger: centers)
        .sensoryFeedback(.selection, trigger: pointer.paused)
        .sensoryFeedback(trigger: pointer.connected) { _, now in now ? .start : .stop }
    }
}

/// Speed, Steady and Scroll, and the way to unpair. For Speed and Steady, 1.0× is exactly what the Mac was started with.
private struct SettingsSheet: View {
    @ObservedObject var pointer: Pointer
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnpair = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                LevelRow(symbol: "speedometer", title: "Speed", value: $pointer.speed, levels: speedLevels)
                LevelRow(symbol: "hand.raised", title: "Steady", value: $pointer.steady, levels: steadyLevels)
                Text("Steady ignores more of a shaking hand, but follows a little slower.")
                    .font(.system(size: 11)).foregroundStyle(Color(white: 0.5))
                LevelRow(symbol: "arrow.up.and.down", title: "Scroll", value: $pointer.scrollSpeed, levels: scrollLevels)
                Text("How fast the Digital Crown scrolls.")
                    .font(.system(size: 11)).foregroundStyle(Color(white: 0.5))
                Button("Reset") { pointer.speed = 1; pointer.steady = 1; pointer.scrollSpeed = 1 }
                Button("Unpair", role: .destructive) { confirmUnpair = true }
            }
        }
        .confirmationDialog("Unpair \(pointer.pairedName ?? "Mac")?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                dismiss()
                // Unpair once the sheet has closed; changing the screen under it made dialogs pop up a second time.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pointer.forget() }
            }
        }
    }
}

/// A setting with a handful of steps: the value in large type and − / + buttons (the Crown works on it too once focused).
private struct LevelRow: View {
    let symbol: String
    let title: String
    @Binding var value: Double
    let levels: [Double]

    /// The step nearest the stored value, so a value saved by an older build still lands somewhere sensible.
    private var index: Binding<Int> {
        Binding(
            get: { levels.indices.min { abs(levels[$0] - value) < abs(levels[$1] - value) } ?? 0 },
            set: { value = levels[min(max($0, 0), levels.count - 1)] }
        )
    }

    var body: some View {
        Stepper(value: index, in: 0...(levels.count - 1)) {
            VStack(alignment: .leading, spacing: 0) {
                Label(title, systemImage: symbol).font(.system(size: 13))
                Text(String(format: "%g×", levels[index.wrappedValue]))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
            }
        }
    }
}

/// Not paired yet: every Mac running the receiver nearby, each with a Pair button.
private struct PairList: View {
    let found: [FoundMac]
    let pair: (FoundMac) -> Void

    var body: some View {
        if found.isEmpty {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(found) { mac in
                        Button { pair(mac) } label: {
                            HStack(spacing: 8) {
                                Text(mac.name)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("Pair")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(.white, in: Capsule())
                            }
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(minHeight: 52)
                            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

/// Paired, but that Mac isn't connected right now (receiver closed or out of range). Connects by itself when it's back.
private struct WaitingForMac: View {
    let name: String
    let forget: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "laptopcomputer")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse)
            Text(name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(white: 0.6))
                .lineLimit(1)
            Spacer()
            Button(action: forget) {
                Text("Forget")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressStyle())
        }
        .padding(.horizontal, 4)
    }
}

/// Connected, but the Mac hasn't let this watch control it (yet): its owner is asked first.
/// To ask again after a refusal, unpair (top-left) and pair again, or reopen the app.
private struct NeedsApproval: View {
    let declined: Bool

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: declined ? "hand.raised.fill" : "laptopcomputer")
                .font(.system(size: 34))
                .foregroundStyle(declined ? Color.orange : Color(white: 0.5))
                .symbolEffect(.pulse, isActive: !declined)
            Text(declined ? "Declined on your Mac" : "Approve on your Mac")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(white: 0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

/// Tap = click. Hold = grab (mouse down); point to move; let go to drop.
private struct ClickPad: View {
    let paused: Bool
    @Binding var clicks: Int
    let pointer: Pointer

    @State private var pressing = false
    @State private var dragging = false
    @State private var holdTimer: Timer?
    @State private var touchDown: TimeInterval = 0

    private var fill: Color {
        if dragging { return .white }
        if paused { return Color.orange.opacity(0.25) }
        return Color(white: pressing ? 0.28 : 0.16)
    }

    private var symbol: String { dragging ? "hand.raised.fill" : paused ? "pause.fill" : "cursorarrow.click" }

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(fill)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(dragging ? .black : paused ? .orange : Color(white: 0.55))
                    .contentTransition(.symbolEffect(.replace))
            }
            .scaleEffect(pressing && !dragging ? 0.98 : 1)
            .animation(.smooth(duration: 0.15), value: pressing)
            .animation(.smooth(duration: 0.2), value: dragging)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressing else { return }
                        pressing = true
                        touchDown = ProcessInfo.processInfo.systemUptime // same clock as the motion samples
                        holdTimer = Timer.scheduledTimer(withTimeInterval: holdToDrag, repeats: false) { _ in
                            dragging = true
                            pointer.send(.drag, 1, at: touchDown)
                        }
                    }
                    .onEnded { _ in
                        holdTimer?.invalidate()
                        pressing = false
                        if dragging {
                            dragging = false
                            pointer.send(.drag, 0, at: ProcessInfo.processInfo.systemUptime - 0.05) // just before the lift
                        } else {
                            clicks += 1
                            pointer.send(.leftClick, at: touchDown)
                        }
                    }
            )
            .sensoryFeedback(trigger: dragging) { _, now in .impact(weight: now ? .heavy : .light) }
    }
}

private struct PadButton: View {
    let symbol: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.16))
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                }
        }
        .buttonStyle(PressStyle())
    }
}

/// Shows which edge points at the screen and switches it 12 → 3 → 6 → 9 → 12.
private struct EdgeButton: View {
    let edge: PointerEdge
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.16))
                .overlay { EdgeIcon(edge: edge) }
        }
        .buttonStyle(PressStyle())
    }
}

/// The watch seen from the front, its hour in the middle and the pointing edge lit: 12 = top, 3 = right, 6 = bottom, 9 = left.
private struct EdgeIcon: View {
    let edge: PointerEdge

    var body: some View {
        let vertical = edge == .three || edge == .nine // the lit edge runs up and down
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(white: 0.5), lineWidth: 2)
                .frame(width: 24, height: 28)
            Text("\(edge.rawValue)")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
            Capsule()
                .fill(Color.green)
                .frame(width: vertical ? 3 : 14, height: vertical ? 14 : 3)
                .offset(x: edge == .three ? 12 : edge == .nine ? -12 : 0,
                        y: edge == .six ? 14 : edge == .twelve ? -14 : 0)
        }
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
    }
}
