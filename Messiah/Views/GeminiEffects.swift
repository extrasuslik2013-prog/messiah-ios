import SwiftUI

/// Soft drifting color blobs (magenta / coral / amber, matching the icon).
struct GeminiBackgroundGlow: View {
    private struct Blob {
        let color: Color
        let x: Double, y: Double, size: Double, speed: Double, phase: Double
    }

    private let blobs: [Blob] = [
        Blob(color: Palette.magenta, x: 0.30, y: 0.40, size: 0.75, speed: 0.22, phase: 0),
        Blob(color: Palette.coral, x: 0.70, y: 0.50, size: 0.65, speed: 0.17, phase: 2),
        Blob(color: Palette.amber, x: 0.50, y: 0.65, size: 0.55, speed: 0.27, phase: 4),
    ]

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<blobs.count, id: \.self) { i in
                        let b = blobs[i]
                        let w = geo.size.width
                        Ellipse()
                            .fill(b.color)
                            .frame(width: w * b.size, height: w * b.size * 0.8)
                            .position(x: geo.size.width * (b.x + 0.12 * sin(t * b.speed + b.phase)),
                                      y: geo.size.height * (b.y + 0.08 * cos(t * b.speed * 1.3 + b.phase)))
                            .scaleEffect(1 + 0.08 * sin(t * b.speed * 2 + b.phase))
                            .blur(radius: 60)
                            .opacity(0.35)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Status text with a light sweeping shimmer ("Thinking", "Preparing voice").
struct GeminiShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation) { tl in
            let p = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .overlay {
                    LinearGradient(colors: [.clear, Color(red: 1, green: 0.4, blue: 0.6), .clear],
                                   startPoint: UnitPoint(x: p * 2 - 0.6, y: 0.5),
                                   endPoint: UnitPoint(x: p * 2 - 0.1, y: 0.5))
                        .mask(Text(text).font(.subheadline.weight(.medium)))
                }
        }
    }
}
