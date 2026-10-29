import SwiftUI

// Native glass surfaces shared by the existing spatial UI. Apply glass to
// the complete panel so blur and edge depth follow its content bounds.
enum REWindPalette {
    static let accent = Color(red: 1.0, green: 0.94, blue: 0.80)
    static let accentDeep = Color(red: 0.43, green: 0.36, blue: 0.27)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.86)
    static let tertiaryText = Color.white.opacity(0.68)
    static let glassTint = Color(red: 0.94, green: 0.92, blue: 0.89)
}

private struct REWindGlassAncestorKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var rewindHasGlassAncestor: Bool {
        get { self[REWindGlassAncestorKey.self] }
        set { self[REWindGlassAncestorKey.self] = newValue }
    }
}

private struct REWindGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.rewindHasGlassAncestor) private var hasGlassAncestor

    func body(content: Content) -> some View {
        Group {
            if hasGlassAncestor {
                // One environmental blur per panel. Inner cards need only a
                // gentle highlight and edge to retain the reference hierarchy.
                content
                    .background(.white.opacity(0.055), in: shape)
                    .overlay { shape.strokeBorder(.white.opacity(0.13), lineWidth: 1) }
            } else {
                content.glassBackgroundEffect(in: shape, displayMode: .implicit)
            }
        }
        .environment(\.rewindHasGlassAncestor, true)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 34, opacity: Double = 0.36) -> some View {
        modifier(REWindGlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }

    func glassCapsule(opacity: Double = 0.38) -> some View {
        modifier(REWindGlassSurface(shape: Capsule()))
    }

    func glassLegibleText() -> some View { self }

    func dashboardFlatGlass(cornerRadius: CGFloat, opacity: Double = 0.32) -> some View {
        glassPanel(cornerRadius: cornerRadius, opacity: opacity)
    }
}

// The small "RE.Wind" mark that sits in the corner of every in-activity panel.
struct REWindChip: View {
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(.white.opacity(0.94))
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.10), in: Circle())

            Text("RE.Wind")
                .font(.system(size: 27, weight: .semibold, design: .default))
                .foregroundStyle(REWindPalette.primaryText)
                .glassLegibleText()
        }
        .padding(.horizontal, 26)
        .frame(height: 60)
        .glassCapsule(opacity: 0.34)
    }
}

// Pill button used for "Return to Bedroom" and the Home shortcut.
struct GlassPillButton: View {
    let title: String
    let systemImage: String?
    var isProminent = false
    let action: () -> Void

    @State private var isFocused = false

    init(
        title: String,
        systemImage: String? = nil,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isProminent = isProminent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 30, weight: .medium))
                }

                Text(title)
                    .font(.system(size: 32, weight: .medium, design: .default))
            }
            .foregroundStyle(isFocused ? REWindPalette.primaryText : Color.white.opacity(0.94))
            .glassLegibleText()
            .padding(.horizontal, 42)
            .frame(height: 86)
            .glassCapsule(opacity: isProminent ? 0.50 : 0.38)
            .overlay {
                Capsule(style: .continuous).strokeBorder(
                    Color.white.opacity(isFocused ? 0.40 : 0.12),
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.22), value: isFocused)
        .onHover { isHovering in
            isFocused = isHovering
        }
    }
}

// Layered curved reflections keep the orb transparent in a RealityView attachment.
// These are decorative surfaces only; the existing home buttons own interaction.
struct ReferenceGlassOrb: View {
    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle().fill(.ultraThinMaterial).opacity(0.20)
                Circle().fill(RadialGradient(
                    colors: [.black.opacity(0.03), .black.opacity(0.12), .white.opacity(0.26)],
                    center: .center, startRadius: diameter * 0.24, endRadius: diameter * 0.51))
                Circle().strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.68), .white.opacity(0.12), .white.opacity(0.58)],
                    startPoint: .topTrailing, endPoint: .bottomLeading), lineWidth: 1.5)
                Circle().inset(by: diameter * 0.025).trim(from: 0.78, to: 0.96)
                    .stroke(.white.opacity(0.88), style: StrokeStyle(lineWidth: diameter * 0.023, lineCap: .round))
                    .blur(radius: diameter * 0.012)
                Circle().inset(by: diameter * 0.035).trim(from: 0.33, to: 0.47)
                    .stroke(Color(red: 1, green: 0.91, blue: 0.75).opacity(0.85),
                            style: StrokeStyle(lineWidth: diameter * 0.027, lineCap: .round))
                    .blur(radius: diameter * 0.014)
                Circle().inset(by: diameter * 0.075).trim(from: 0.55, to: 0.66)
                    .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: diameter * 0.026, lineCap: .round))
                    .blur(radius: diameter * 0.023)
                Circle().inset(by: diameter * 0.025).trim(from: 0.04, to: 0.30)
                    .stroke(.white.opacity(0.25), lineWidth: diameter * 0.013)
                    .blur(radius: diameter * 0.01)
            }
            .frame(width: diameter, height: diameter)
        }
    }
}
