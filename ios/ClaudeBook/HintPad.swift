import SwiftUI
import UIKit

/// A hint on the page is only a small chip with its label. Tapping it pops up a `HintPad` with the
/// text, which wraps inside the pad, so a long hint can never run off the page. Shared by the tiled
/// layer that draws the chip and the controller that places the tap target and the pad.
enum HintChip {
    static func height(_ item: ClaudeItem) -> CGFloat { CGFloat(item.size ?? 32) + 6 }

    static func font(_ item: ClaudeItem) -> UIFont { rounded(height(item) * 0.42, .semibold) }

    /// The chip in page units, measured from the label (never the hint text).
    static func frame(_ item: ClaudeItem) -> CGRect? {
        guard let x = item.x, let y = item.y else { return nil }
        let h = height(item)
        let label = (item.label ?? "Hint") as NSString
        let w = label.size(withAttributes: [.font: font(item)]).width
        return CGRect(x: x, y: y, width: ceil(h * 0.3 + h * 0.5 + h * 0.2 + w + h * 0.4), height: h)
    }

    static func draw(_ item: ClaudeItem, color: UIColor, dark: Bool, in ctx: CGContext) {
        guard let chip = frame(item) else { return }
        let opened = item.revealed == true
        let h = chip.height
        let pill = UIBezierPath(roundedRect: chip, cornerRadius: h / 2).cgPath
        ctx.saveGState()
        ctx.addPath(pill)
        ctx.setFillColor(color.withAlphaComponent(opened ? (dark ? 0.14 : 0.05) : (dark ? 0.28 : 0.12)).cgColor)
        ctx.fillPath()
        ctx.addPath(pill)
        ctx.setStrokeColor(color.withAlphaComponent(opened ? 0.6 : 1).cgColor)
        ctx.setLineWidth(1.5)
        // Opened hints stay tappable but look quieter, so you can tell which ones you've peeked at.
        if opened { ctx.setLineDash(phase: 0, lengths: [5, 4]) }
        ctx.strokePath()
        ctx.restoreGState()

        let ink = opened ? color.withAlphaComponent(dark ? 0.9 : 0.75) : color
        UIGraphicsPushContext(ctx)
        let iconBox = CGRect(x: chip.minX + h * 0.3, y: chip.midY - h * 0.25, width: h * 0.5, height: h * 0.5)
        let config = UIImage.SymbolConfiguration(pointSize: h * 0.5, weight: .semibold)
        if let icon = UIImage(systemName: opened ? "lightbulb" : "lightbulb.fill", withConfiguration: config)?
            .withTintColor(ink, renderingMode: .alwaysOriginal) {
            let s = icon.size
            let fit = min(iconBox.width / max(s.width, 1), iconBox.height / max(s.height, 1))
            icon.draw(in: CGRect(x: iconBox.midX - s.width * fit / 2, y: iconBox.midY - s.height * fit / 2,
                                 width: s.width * fit, height: s.height * fit))
        }
        let labelFont = font(item)
        ((item.label ?? "Hint") as NSString).draw(at: CGPoint(x: iconBox.maxX + h * 0.2, y: chip.midY - labelFont.lineHeight / 2),
                                                  withAttributes: [.font: labelFont, .foregroundColor: ink])
        UIGraphicsPopContext()
    }

    static func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
    }
}

/// The little pad a hint opens into: Clawd, the label, the text, and a close button.
struct HintPad: View {
    var label: String
    var text: String?
    var tint: Color
    /// The text's measured height at the pad's width; taller than `maxText` scrolls inside the pad.
    var textHeight: CGFloat
    var onClose: () -> Void

    static let maxText: CGFloat = 230
    static let padding: CGFloat = 16
    static let textFont = HintChip.rounded(18, .regular)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ClawdView(mood: .idle, size: 30)
                Text(label.uppercased())
                    .font(.caption.weight(.bold)).tracking(0.8)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(width: 30, height: 30)
                        .background(Theme.surfaceRaised, in: Circle())
                }
                .buttonStyle(PressableStyle(scale: 0.9))
                .accessibilityLabel("Hide hint")
                .accessibilityIdentifier("hint.close")
            }
            if let text {
                if textHeight > Self.maxText {
                    ScrollView { textView(text) }.frame(height: Self.maxText)
                } else {
                    textView(text)
                }
            } else {
                HStack(spacing: 10) {
                    ClaudeSpinner(size: 18)
                    Text("Opening hint…").font(.subheadline).foregroundStyle(Theme.secondaryInk)
                }
            }
        }
        .padding(Self.padding)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.pad, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.pad, style: .continuous).strokeBorder(tint.opacity(0.4), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hint.pad")
    }

    private func textView(_ text: String) -> some View {
        Text(text)
            .font(Font(Self.textFont))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier("hint.text")
    }

    /// Height of `text` laid out at `width`, in the pad's font.
    static func measure(_ text: String?, width: CGFloat) -> CGFloat {
        guard let text, width > 0 else { return 0 }
        let box = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                  attributes: [.font: textFont], context: nil)
        return ceil(box.height) + 4
    }
}
