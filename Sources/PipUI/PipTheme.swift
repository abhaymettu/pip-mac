import SwiftUI
import AppKit

public enum PipTheme {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255,
                alpha: 1
            )
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? color(dark) : color(light)
        })
    }

    public static let oat = adaptive(0xF6F3EC, 0x252420)
    public static let porcelain = adaptive(0xFFFEFA, 0x302F2A)
    public static let ink = adaptive(0x292D29, 0xF5F1E8)
    public static let secondary = adaptive(0x62675F, 0xBABCB2)
    public static let fern = adaptive(0x41624D, 0xA8C3A8)
    public static let apricot = adaptive(0xE9AD83, 0xDDA079)
    public static let brick = adaptive(0xA13932, 0xF0A199)

    // Borders are opaque. State always has accompanying text and/or an icon.
    public static let border = adaptive(0xCFD0C6, 0x626358)
    public static let canvas = oat
    public static let surface = porcelain
    public static let primaryText = ink
    public static let secondaryText = secondary
    public static let accent = fern
    public static let error = brick

    public static let title = Font.system(size: 28, weight: .semibold)
    public static let heading = Font.system(size: 19, weight: .semibold)
    public static let cardLabel = Font.system(size: 15, weight: .medium)
    public static let body = Font.system(size: 14)
    public static let caption = Font.system(size: 12)
    public static let mono = Font.system(size: 12, design: .monospaced)

    public static let cardRadius: CGFloat = 14
    public static let borderWidth: CGFloat = 1
    public static let pagePadding: CGFloat = 24
    public static let spacing: CGFloat = 12
    public static let compressionDuration = 0.10
    public static let releaseDuration = 0.18

    // Verify disabled-control contrast with Increase Contrast enabled on-device.
}

public struct CardStyle: ViewModifier {
    public var emphasized: Bool

    public init(emphasized: Bool = false) {
        self.emphasized = emphasized
    }

    public func body(content: Content) -> some View {
        content
            .padding(16)
            .background(PipTheme.surface, in: RoundedRectangle(cornerRadius: PipTheme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PipTheme.cardRadius)
                    .strokeBorder(
                        emphasized ? PipTheme.accent : PipTheme.border,
                        lineWidth: emphasized ? 2 : PipTheme.borderWidth
                    )
            }
            .shadow(color: .black.opacity(0.035), radius: 2, y: 1)
    }
}

public struct PillStyle: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .font(PipTheme.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(PipTheme.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(PipTheme.border, lineWidth: 1) }
    }
}

public extension View {
    func pipCard(emphasized: Bool = false) -> some View {
        modifier(CardStyle(emphasized: emphasized))
    }

    func pipPill() -> some View {
        modifier(PillStyle())
    }
}

public struct PipMacBook: View {
    public var activeSide: PipSide?
    public var compressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(activeSide: PipSide? = nil, compressed: Bool = false) {
        self.activeSide = activeSide
        self.compressed = compressed
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width - 30, 390.0)
            ZStack {
                RoundedRectangle(cornerRadius: 17)
                    .fill(PipTheme.surface)
                RoundedRectangle(cornerRadius: 17)
                    .strokeBorder(PipTheme.border, lineWidth: 2)
                VStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(PipTheme.border)
                        .frame(width: width * 0.69, height: 28)
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(PipTheme.border, lineWidth: 1)
                        .frame(width: width * 0.32, height: 33)
                }
                HStack {
                    contact(.left)
                    Spacer()
                    contact(.right)
                }
                .padding(.horizontal, 9)
            }
            .frame(width: width, height: 104)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 122)
        .accessibilityLabel("MacBook, left and right chassis edges")
    }

    private func contact(_ side: PipSide) -> some View {
        Capsule()
            .fill(PipTheme.apricot)
            .frame(width: 7, height: 24)
            .overlay {
                Capsule().strokeBorder(
                    activeSide == side ? PipTheme.ink : PipTheme.border,
                    lineWidth: activeSide == side ? 2 : 1
                )
            }
            .offset(x: !reduceMotion && compressed && activeSide == side
                    ? (side == .left ? 2 : -2) : 0)
            .opacity(reduceMotion && compressed && activeSide == side ? 0.6 : 1)
            .animation(.easeOut(duration: PipTheme.releaseDuration), value: compressed)
    }
}

public struct PipEnvelopePoint: Identifiable, Sendable {
    public let id: Int
    public let low: Double
    public let high: Double

    public init(id: Int, low: Double, high: Double) {
        self.id = id
        self.low = low
        self.high = high
    }
}

public struct PipWaveform: View {
    public var points: [PipEnvelopePoint]
    public var threshold: Double
    public var annotation: String

    public init(
        points: [PipEnvelopePoint],
        threshold: Double = 0.55,
        annotation: String = "Waiting for diagnostic samples"
    ) {
        self.points = points
        self.threshold = threshold
        self.annotation = annotation
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                let mid = size.height / 2
                var guide = Path()
                let y = mid - threshold * mid
                guide.move(to: CGPoint(x: 0, y: y))
                guide.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(
                    guide,
                    with: .color(PipTheme.secondary),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )

                var trace = Path()
                for (index, point) in points.enumerated() {
                    let x = CGFloat(index) / CGFloat(max(points.count - 1, 1)) * size.width
                    trace.move(to: CGPoint(x: x, y: mid - point.high * mid))
                    trace.addLine(to: CGPoint(x: x, y: mid - point.low * mid))
                }
                context.stroke(trace, with: .color(PipTheme.ink), lineWidth: 1)
            }
            .frame(height: 72)
            HStack {
                Label(annotation, systemImage: "waveform.path")
                Spacer()
                Text("Dashed line: threshold")
            }
            .font(PipTheme.caption)
            .foregroundStyle(PipTheme.secondary)
        }
        .padding(12)
        .background(PipTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
