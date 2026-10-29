import SwiftUI
import UIKit

/// ClaudeBook's look in one place: Claude's warm orange on cream paper by day, warm charcoal by night.
/// Screens read colors, type, shapes and motion from here instead of hard-coding them, so a new
/// feature picks up the theme by using `Theme.accent`, `Theme.surface`, `Theme.Motion.pop` and friends.
enum Theme {
    // MARK: Colors

    /// Claude's signature orange, for large filled surfaces (buttons, covers, the crab).
    static let claudeOrange = UIColor(hex: "#D97757")
    static let orange = Color(uiColor: claudeOrange)
    /// Orange for text and icons: a touch deeper in light mode so it stays readable on cream.
    static let accent = dynamic(light: "#C15F3C", dark: "#E8916F")
    /// Washed-out orange behind chips, selected rows and badges.
    static let accentSoft = dynamic(light: "#F6E4DA", dark: "#3B2A22")
    /// The app background: Claude's cream, or warm charcoal.
    static let background = dynamic(light: "#FAF9F5", dark: "#1F1E1D")
    /// Cards, fields and pads sitting on the background.
    static let surface = dynamic(light: "#FFFFFF", dark: "#2A2927")
    /// A step up from surface, for wells inside cards and pressed states.
    static let surfaceRaised = dynamic(light: "#F0EEE6", dark: "#353431")
    static let ink = dynamic(light: "#3D3929", dark: "#F4F3EE")
    static let secondaryInk = dynamic(light: "#77736A", dark: "#B4B0A6")
    static let hairline = dynamic(light: "#E6E1D5", dark: "#3E3C38")
    static let danger = dynamic(light: "#B9442E", dark: "#F0846E")
    static let success = dynamic(light: "#4F7F57", dark: "#8CC496")
    /// Behind the pages in the editor: a desk a shade darker than the paper.
    static let desk = uiDynamic(light: "#EFECE3", dark: "#1A1918")

    /// Covers and folders: warm, earthy, all happy next to the orange.
    static let coverPalette: [Color] = [
        Color(uiColor: UIColor(hex: "#D97757")), Color(uiColor: UIColor(hex: "#B5553A")),
        Color(uiColor: UIColor(hex: "#C0965F")), Color(uiColor: UIColor(hex: "#7E9B7B")),
        Color(uiColor: UIColor(hex: "#6E7FA0")), Color(uiColor: UIColor(hex: "#9A6E8E")),
        Color(uiColor: UIColor(hex: "#4E8A86")), Color(uiColor: UIColor(hex: "#C9A13F")),
    ]

    /// Same cover color every launch (String.hashValue changes per launch).
    static func cover(for id: String) -> Color {
        coverPalette[id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % coverPalette.count]
    }

    static func dynamic(light: String, dark: String) -> Color { Color(uiColor: uiDynamic(light: light, dark: dark)) }

    static func uiDynamic(light: String, dark: String) -> UIColor {
        let l = UIColor(hex: light), d = UIColor(hex: dark)
        return UIColor { $0.userInterfaceStyle == .dark ? d : l }
    }

    /// Navigation bars in cream or charcoal with serif titles. Call once at launch, before any bar exists.
    @MainActor
    static func applyUIKitAppearance() {
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = uiDynamic(light: "#FAF9F5", dark: "#1F1E1D")
        bar.shadowColor = uiDynamic(light: "#E6E1D5", dark: "#3E3C38")
        let ink = uiDynamic(light: "#3D3929", dark: "#F4F3EE")
        func serif(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        }
        bar.titleTextAttributes = [.font: serif(18, .semibold), .foregroundColor: ink]
        bar.largeTitleTextAttributes = [.font: serif(34, .semibold), .foregroundColor: ink]
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
    }

    // MARK: Type

    /// Big titles use a serif, like the Claude app.
    static func title(_ style: Font.TextStyle = .largeTitle) -> Font { .system(style, design: .serif, weight: .semibold) }
    /// Friendly UI text: rounded.
    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font { .system(style, design: .rounded, weight: weight) }

    // MARK: Shape

    enum Radius {
        static let card: CGFloat = 18
        static let field: CGFloat = 14
        static let chip: CGFloat = 10
        static let pad: CGFloat = 22
    }

    // MARK: Motion

    enum Motion {
        /// Things appearing: a quick pop with a little bounce.
        static let pop = Animation.spring(response: 0.34, dampingFraction: 0.68)
        /// Larger moves that should settle without wobbling.
        static let soft = Animation.spring(response: 0.5, dampingFraction: 0.86)
        /// Presses and toggles.
        static let snappy = Animation.spring(response: 0.24, dampingFraction: 0.8)
    }
}

/// Kept so older call sites (and branches written before the theme) still compile; prefer `Theme`.
enum StudyPalette {
    static let teal = Theme.accent
    static let coral = Theme.accent
    static let background = Theme.background
}

/// Typealias-free shim for the old cover palette helper.
enum LibraryTint {
    static func color(for id: String) -> Color { Theme.cover(for: id) }
}

// MARK: - Clawd

/// Clawd, the Claude Code pixel crab, drawn on its 16 x 10 pixel grid so it stays crisp at any size.
/// Animated at a deliberately low frame rate, like a sprite, and still when Reduce Motion is on.
struct ClawdView: View {
    enum Mood { case idle, walking, waving, thinking }

    var mood: Mood = .idle
    /// Width in points; height is 10/16 of it.
    var size: CGFloat = 44
    var tint: Color = Theme.orange
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Canvas { ctx, sz in draw(ctx, sz, t: 0) }
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 10)) { tl in
                    Canvas { ctx, sz in draw(ctx, sz, t: tl.date.timeIntervalSinceReferenceDate) }
                }
            }
        }
        .frame(width: size, height: size * 10 / 16 + size * 0.08)
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: GraphicsContext, _ sz: CGSize, t: Double) {
        let u = sz.width / 16
        let frame = Int(t * 10)
        let shade = Color(uiColor: UIColor(hex: "#B85A3C"))
        let eye = Color(uiColor: UIColor(hex: "#1F1E1D"))
        let blush = Color(uiColor: UIColor(hex: "#F2A08A"))
        // Idle and thinking bob up and down a pixel; walking bobs with each step.
        let bob: Double
        switch mood {
        case .walking: bob = frame % 2 == 0 ? 0 : -0.35
        case .idle, .thinking: bob = sin(t * 2.2) > 0.6 ? -0.3 : 0
        case .waving: bob = 0
        }
        func px(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: Color) {
            ctx.fill(Path(CGRect(x: x * u, y: (y + bob + 0.6) * u, width: w * u, height: h * u)), with: .color(c))
        }
        // Legs first so the body overlaps their tops. Walking lifts alternate pairs.
        for (i, lx) in [3.0, 5, 10, 12].enumerated() {
            let lift = mood == .walking && (i % 2 == frame % 2) ? 0.6 : 0
            px(lx, 7.9 - bob, 1, 2.1 - lift, tint)
        }
        px(2, 0, 12, 8, tint)
        px(2, 7.25, 12, 0.75, shade)
        // Claws: waving raises the right one, thinking taps the left one against the "chin".
        let leftY: Double = mood == .thinking && frame % 6 < 3 ? 3.2 : 4
        let rightY: Double = mood == .waving ? (frame % 4 < 2 ? 1.6 : 2.6) : 4
        px(0, leftY, 2, 2, tint)
        px(0, leftY + 1.5, 2, 0.5, shade)
        px(14, rightY, 2, 2, tint)
        px(14, rightY + 1.5, 2, 0.5, shade)
        // Blink for two frames every few seconds; thinking looks up.
        let blinking = frame % 38 < 2
        let eyeY: Double = mood == .thinking ? 1.4 : 2
        if blinking {
            px(4, eyeY + 1.2, 1, 0.5, eye)
            px(11, eyeY + 1.2, 1, 0.5, eye)
        } else {
            px(4, eyeY, 1, 2, eye)
            px(11, eyeY, 1, 2, eye)
            px(4.12, eyeY + 0.15, 0.4, 0.45, .white)
            px(11.12, eyeY + 0.15, 0.4, 0.45, .white)
        }
        px(3, 4.5, 1.5, 0.75, blush.opacity(0.9))
        px(11.5, 4.5, 1.5, 0.75, blush.opacity(0.9))
    }
}

/// Clawd scuttling back and forth along a strip, for empty states.
struct ClawdStroll: View {
    var size: CGFloat = 54
    var width: CGFloat = 220
    @State private var right = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ClawdView(mood: reduceMotion ? .idle : .walking, size: size)
            .offset(x: reduceMotion ? 0 : (right ? (width - size) / 2 : -(width - size) / 2))
            .frame(width: width)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { right = true }
            }
    }
}

// MARK: - Claude's spark

/// A hand-cut starburst in the spirit of Claude's mark, for little flourishes and the thinking spinner.
struct SparkShape: Shape {
    var rays = 11

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0..<rays {
            // Slightly uneven ray lengths and angles make it feel drawn rather than generated.
            let wobble = [1.0, 0.86, 0.95, 0.8, 1.0, 0.9, 0.84, 0.97, 0.88, 0.93, 0.82][i % 11]
            let a = Double(i) / Double(rays) * 2 * .pi - .pi / 2 + (i % 2 == 0 ? 0.04 : -0.03)
            let len = r * wobble
            let half = 0.11
            let tip = CGPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len)
            let l = CGPoint(x: c.x + cos(a - half) * r * 0.22, y: c.y + sin(a - half) * r * 0.22)
            let rr = CGPoint(x: c.x + cos(a + half) * r * 0.22, y: c.y + sin(a + half) * r * 0.22)
            p.move(to: c)
            p.addLine(to: l)
            p.addQuadCurve(to: rr, control: CGPoint(x: tip.x + cos(a) * r * 0.05, y: tip.y + sin(a) * r * 0.05))
            p.closeSubpath()
        }
        p.addEllipse(in: CGRect(x: c.x - r * 0.24, y: c.y - r * 0.24, width: r * 0.48, height: r * 0.48))
        return p
    }
}

/// The spark slowly turning and breathing, like Claude thinking. Use in place of a spinner.
struct ClaudeSpinner: View {
    var size: CGFloat = 28
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SparkShape()
            .fill(Theme.orange)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(on ? 360 : 0))
            .scaleEffect(on ? 1.0 : 0.82)
            .animation(reduceMotion ? nil : .linear(duration: 2.4).repeatForever(autoreverses: false), value: on)
            .onAppear { on = true }
            .accessibilityLabel("Loading")
    }
}

// MARK: - Styles

/// Cards squish a little under your finger and spring back.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.965

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.02 : 0)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}

/// Fades and lifts content in once, staggered by index, the first time a screen fills.
struct EntranceModifier: ViewModifier {
    var shown: Bool
    var index: Int

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .scaleEffect(shown ? 1 : 0.97)
            .animation(Theme.Motion.soft.delay(Double(min(index, 10)) * 0.035), value: shown)
    }
}

extension View {
    func entrance(_ shown: Bool, index: Int = 0) -> some View { modifier(EntranceModifier(shown: shown, index: index)) }

    /// A themed card background: surface, soft border, warm shadow.
    func themedCard(radius: CGFloat = Theme.Radius.card, padding: CGFloat = 0) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: Color(uiColor: UIColor(hex: "#5A3A28")).opacity(0.06), radius: 10, y: 4)
    }
}

/// A pulsing dot that says "live".
struct LiveDot: View {
    var live: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if live {
                Circle().fill(Theme.success.opacity(0.35))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.3 : 0.6)
                    .opacity(pulse ? 0 : 1)
            }
            Circle().fill(live ? Theme.success : Theme.secondaryInk).frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true } }
        .accessibilityHidden(true)
    }
}

/// A vertical line through the middle of its rect, for stitched seams.
struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY + 8))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 8))
        return p
    }
}

/// Clawd next to the library title: waves hello, then idles. Tap for another wave.
struct HeaderClawd: View {
    @State private var waving = true

    var body: some View {
        ClawdView(mood: waving ? .waving : .idle, size: 46)
            .contentShape(Rectangle())
            .onTapGesture { wave() }
            .task {
                try? await Task.sleep(for: .seconds(2.4))
                waving = false
            }
    }

    private func wave() {
        waving = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            try? await Task.sleep(for: .seconds(2))
            waving = false
        }
    }
}

/// Empty screens get Clawd pacing about instead of a grey icon.
struct CrabEmptyState<Actions: View>: View {
    var title: String
    var message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            ClawdStroll(size: 64, width: 240)
                .padding(.bottom, 4)
            Text(title).font(Theme.title(.title2)).foregroundStyle(Theme.ink)
            Text(message)
                .font(.subheadline).foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            actions().padding(.top, 4)
        }
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
    }
}
