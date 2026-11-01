import SwiftUI

/// Personality editor. The star constellation above the text rearranges
/// itself as you type: every word becomes a star.
struct PersonalityView: View {
    @AppStorage(AppSettings.personalityKey) private var personality = ""
    @FocusState private var editing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ConstellationView(text: personality)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Text(currentName)
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(16)
                            .animation(nil, value: currentName)
                    }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PersonalityPreset.all) { preset in
                            let selected = preset.text == personality
                            Button {
                                personality = preset.text
                            } label: {
                                Text(preset.name)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                    .background(
                                        Capsule().fill(selected
                                            ? AnyShapeStyle(LinearGradient(colors: [Palette.magenta, Palette.coral],
                                                                           startPoint: .leading, endPoint: .trailing))
                                            : AnyShapeStyle(Color(.secondarySystemBackground)))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Describe Messiah's personality")
                        .font(.subheadline.weight(.semibold))
                    ZStack(alignment: .topLeading) {
                        if personality.isEmpty {
                            Text("e.g. Calm and kind, a bit funny, talks like an old friend…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                        }
                        TextEditor(text: $personality)
                            .focused($editing)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 150)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
                    Text("Used in every chat and in live chat. Leave empty for the default personality.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Personality")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = false }
            }
        }
    }

    private var currentName: String {
        if personality.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Default" }
        return PersonalityPreset.all.first { $0.text == personality }?.name ?? "Custom"
    }
}

// MARK: - Constellation

struct ConstellationView: View {
    let text: String

    private struct Star: Equatable {
        var point: CGPoint     // 0...1 in both axes
        var size: CGFloat
    }

    var body: some View {
        let stars = Self.stars(for: text)
        let links = Self.links(for: stars.map(\.point))

        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 0.04, green: 0.03, blue: 0.12),
                                        Color(red: 0.12, green: 0.04, blue: 0.20),
                                        Color(red: 0.20, green: 0.05, blue: 0.18)],
                               startPoint: .top, endPoint: .bottom)
                BackgroundStars()

                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    StarLine(a: stars[link.0].point, b: stars[link.1].point)
                        .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                }

                ForEach(Array(stars.enumerated()), id: \.offset) { i, star in
                    TwinklingStar(size: star.size, delay: Double(i % 5) * 0.37)
                        .position(x: star.point.x * w, y: star.point.y * h)
                }
            }
            .animation(.spring(response: 0.6, dampingFraction: 0.72), value: stars)
        }
    }

    // MARK: layout from text

    /// Stable FNV-1a hash (Swift's hashValue changes every launch).
    private static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    private static func stars(for text: String) -> [Star] {
        var words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if words.isEmpty { words = ["messiah", "calm", "clear", "kind", "bright"] }

        var seen: [String: Int] = [:]
        return words.prefix(18).map { word in
            let n = seen[word, default: 0]
            seen[word] = n + 1
            let h = hash(word + "#\(n)")
            let x = 0.08 + 0.84 * Double(h & 0xFFFF) / 65535
            let y = 0.10 + 0.72 * Double((h >> 16) & 0xFFFF) / 65535
            let size = 4 + CGFloat(min(word.count, 9)) * 0.7
            return Star(point: CGPoint(x: x, y: y), size: size)
        }
    }

    /// Joins each star to the nearest earlier star, like a constellation drawing.
    private static func links(for points: [CGPoint]) -> [(Int, Int)] {
        guard points.count > 1 else { return [] }
        var out: [(Int, Int)] = []
        for i in 1..<points.count {
            var best = 0
            var bestD = CGFloat.greatestFiniteMagnitude
            for j in 0..<i {
                let dx = points[i].x - points[j].x, dy = points[i].y - points[j].y
                let d = dx * dx + dy * dy
                if d < bestD { bestD = d; best = j }
            }
            out.append((best, i))
        }
        return out
    }
}

private struct StarLine: Shape {
    var a: CGPoint
    var b: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(a.x, a.y), AnimatablePair(b.x, b.y)) }
        set {
            a = CGPoint(x: newValue.first.first, y: newValue.first.second)
            b = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: a.x * rect.width, y: a.y * rect.height))
        p.addLine(to: CGPoint(x: b.x * rect.width, y: b.y * rect.height))
        return p
    }
}

private struct TwinklingStar: View {
    let size: CGFloat
    let delay: Double
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: size, height: size)
            .shadow(color: Palette.magenta.opacity(0.9), radius: size * 0.9)
            .shadow(color: .white.opacity(0.6), radius: size * 0.3)
            .opacity(bright ? 1 : 0.65)
            .scaleEffect(bright ? 1.1 : 0.9)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true).delay(delay)) {
                    bright = true
                }
            }
    }
}

/// Fixed faint starfield behind the constellation.
private struct BackgroundStars: View {
    var body: some View {
        Canvas { ctx, size in
            var h: UInt64 = 0x9E3779B97F4A7C15
            for _ in 0..<70 {
                h = h &* 6364136223846793005 &+ 1442695040888963407
                let x = CGFloat(h >> 40 & 0xFFFF) / 65535 * size.width
                let y = CGFloat(h >> 20 & 0xFFFF) / 65535 * size.height
                let r = 0.4 + CGFloat(h & 0xF) / 15 * 0.9
                let a = 0.15 + Double(h >> 8 & 0xF) / 15 * 0.45
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity(a)))
            }
        }
        .allowsHitTesting(false)
    }
}
