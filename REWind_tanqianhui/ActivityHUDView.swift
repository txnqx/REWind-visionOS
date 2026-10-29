//
//  ActivityHUDView.swift
//  REWind_tanqianhui
//
//  The in-activity heads-up display: RE.Wind chip, instruction pill, left step
//  checklist, and the floating reach target label. Matches the three in-activity
//  frames in the concept document.
//

import SwiftUI

struct ActivityHUDView: View {
    let route: MemoryRoute
    let steps: [ActivityStep]
    let currentStepIndex: Int
    let completedStepCount: Int
    // When hand tracking is live the HUD shows the live reach readout; when it is
    // not, it offers a tap to advance instead of silently stalling.
    let isHandTrackingActive: Bool
    let liveReachCentimetres: Double
    var isInteractionBusy: Bool = false
    var feedback: String? = nil
    var instructionTitle: String? = nil
    var interactionProgress: Double = 0
    var placedOrnamentIndices: Set<Int> = []
    var selectedOrnamentIndex: Int? = nil
    let onExitRequested: () -> Void

    private let leftColumnInset: CGFloat = 128
    private var instructionTop: CGFloat { route == .christmasTree ? 56 : 76 }

    private var currentStep: ActivityStep? {
        guard steps.indices.contains(currentStepIndex) else {
            return nil
        }

        return steps[currentStepIndex]
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Instruction pill, centred at the top. Its text changes per step.
            if let currentStep {
                instructionPill(for: currentStep)
                    .id(currentStep.id)
                    .allowsHitTesting(false)
                    .offset(x: 48, y: instructionTop)
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 18) {
                    REWindChip()
                        // The column starts at y=16; align the logo's top with
                        // the instruction panel without moving the checklist.
                        .offset(y: instructionTop - 16)

                    if route == .christmasTree {
                        christmasChecklist
                            .padding(.top, 140)
                            .offset(y: 88)
                    } else {
                        checklist
                            .scaleEffect(route == .breakfast ? 0.85 : 1, anchor: .topLeading)
                            .padding(.top, route == .breakfast ? 0 : 140)
                            .offset(y: 88)
                    }
                }
                .offset(x: leftColumnInset, y: 16)

                Spacer()


            }

            VStack {
                Spacer()

                HStack { footer; Spacer() }
                    .offset(x: leftColumnInset, y: 52)
            }
        }
        .frame(width: 2000, height: 700, alignment: .top)
        .scaleEffect(1.0, anchor: .top)
        .animation(.easeInOut(duration: 0.32), value: currentStepIndex)
        .animation(.easeInOut(duration: 0.32), value: completedStepCount)
    }

    private func instructionPill(for step: ActivityStep) -> some View {
        VStack(spacing: 16) {
            Text(instructionTitle ?? step.instruction)
                .font(.system(size: 52, weight: .regular, design: .default))
                .foregroundStyle(REWindPalette.primaryText)

            Text(instructionDetail(for: step))
                .font(.system(size: 32, weight: .regular, design: .default))
                .foregroundStyle(REWindPalette.secondaryText)
        }
        .glassLegibleText()
        .multilineTextAlignment(.center)
        .padding(.horizontal, 68)
        .padding(.vertical, 32)
        .frame(minWidth: 760)
        .dashboardFlatGlass(cornerRadius: 32)
    }

    private func instructionDetail(for step: ActivityStep) -> String {
        let text = feedback ?? step.detail
        guard isHandTrackingActive else { return text }
        if route == .christmasTree && (text.contains("Tap") || text.contains("pinch")) {
            return "Look at an ornament and pinch to pick it up."
        }
        if route == .playingBall && feedback == nil {
            return "Close your hand around the ball. Move toward Dad and open your hand."
        }
        guard route == .breakfast else { return text }
        switch text {
        case "Hold the box and lift straight up. Keep holding.", "Hold the carton and lift straight up. Keep holding.", "Hold and lift straight up.", "Drag the box straight up, then release.", "Drag straight up, then release.", "Hold the milk, lift straight up, then release.":
            return "Grasp it and lift your hand straight up."
        case "Drag toward the bowl, then release to pour.":
            return "Keep holding. Tilt your hand toward the bowl."
        case "Pick up the spoon, then stir in gentle circles.":
            return "Grasp the spoon. Bring it over the bowl, then move in circles."
        default:
            return text
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                checklistRow(step: step, index: index)
            }

            Divider()
                .overlay(.white.opacity(0.24))
                .padding(.vertical, 12)

            Button(action: onExitRequested) {
                HStack(spacing: 16) {
                    Image(systemName: "bed.double")
                        .font(.system(size: 22, weight: .regular))
                        .frame(width: 30)

                    Text("Home")
                        .font(.system(size: 24, weight: .regular, design: .default))
                }
                .foregroundStyle(REWindPalette.secondaryText)
                .glassLegibleText()
                .frame(height: 48)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .frame(width: 430, alignment: .leading)
        .dashboardFlatGlass(cornerRadius: 32)
    }

    // Progress represents placement order, independently of ornament identity.
    // Retains the reference’s compact three-row progress panel.
    private var christmasChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<3, id: \.self) { ornamentIndex in
                let placedCount = min(3, placedOrnamentIndices.count)
                let isDone = ornamentIndex < placedCount
                let isCurrent = ornamentIndex == placedCount
                christmasOrnamentRow(ornamentIndex: ornamentIndex, isDone: isDone, isCurrent: isCurrent)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 30)
        .frame(width: 430, alignment: .leading)
        .dashboardFlatGlass(cornerRadius: 32)
    }

    // Identical progress markers avoid assigning a shape to a placement number.
    private func christmasOrnamentRow(ornamentIndex: Int, isDone: Bool, isCurrent: Bool) -> some View {
        let labels = ["Ornament 1 of 3", "Ornament 2 of 3", "Ornament 3 of 3"]
        let icons = ["circle.fill", "circle.fill", "circle.fill"]
        let label = labels[ornamentIndex]
        let icon = icons[ornamentIndex]

        return HStack(spacing: 22) {
            ZStack {
                Circle()
                    .strokeBorder(
                        isDone ? REWindPalette.accent.opacity(0.0) : .white.opacity(isCurrent ? 0.78 : 0.34),
                        lineWidth: 2.0
                    )
                    .frame(width: 40, height: 40)

                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40, weight: .regular))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(REWindPalette.accentDeep, REWindPalette.accent)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(isCurrent ? REWindPalette.accent : .white.opacity(0.34))
                }
            }
            .frame(width: 40)

            Text(label)
                .font(.system(size: 32, weight: .regular, design: .default))
                .foregroundStyle(
                    isDone
                        ? REWindPalette.secondaryText
                        : (isCurrent ? REWindPalette.primaryText : REWindPalette.tertiaryText)
                )
                .glassLegibleText()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 70)
        .background {
            Capsule(style: .continuous)
                    .fill(.white.opacity(isCurrent ? 0.17 : (isDone ? 0.09 : 0.06)))
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(isCurrent ? 0.20 : 0.06), lineWidth: 1)
                    }
        }
    }

    private func checklistRow(step: ActivityStep, index: Int) -> some View {
        let isDone = index < completedStepCount
        let isCurrent = index == currentStepIndex && !isDone

        return HStack(spacing: 16) {
            // Leading state dot: filled check when done, ring when active, faint
            // outline when still ahead.
            ZStack {
                Circle()
                    .strokeBorder(
                        isDone ? REWindPalette.accent.opacity(0.0) : .white.opacity(isCurrent ? 0.78 : 0.34),
                        lineWidth: 2.0
                    )
                    .frame(width: 30, height: 30)

                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30, weight: .regular))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(REWindPalette.accentDeep, REWindPalette.accent)
                } else if isCurrent {
                    Circle()
                        .fill(REWindPalette.accent)
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 30)

            Text(step.checklistLabel)
                .font(.system(size: 24, weight: .regular, design: .default))
                .foregroundStyle(
                    isDone
                        ? REWindPalette.secondaryText
                        : (isCurrent ? REWindPalette.primaryText : REWindPalette.tertiaryText)
                )
                .glassLegibleText()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 52)
        .background {
            Capsule(style: .continuous)
                    .fill(.white.opacity(isCurrent ? 0.17 : (isDone ? 0.09 : 0.06)))
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(isCurrent ? 0.20 : 0.06), lineWidth: 1)
                    }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if isHandTrackingActive && !(route == .breakfast && currentStepIndex == 2) {
            Text("Reach \(Int(liveReachCentimetres.rounded())) cm")
                .font(.system(size: 24)).foregroundStyle(.white)
                .padding(18).glassCapsule(opacity: 0.22)
        }
    }

}

// Small floating callout used as world-anchored guidance near ornaments and
// tree slots. Shown as a separate RealityKit attachment positioned in 3D space.
struct ChristmasCalloutView: View {
    let text: String
    var neutralBackdrop = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.7), lineWidth: 2.0)
                    .frame(width: 36, height: 36)
                Circle()
                    .strokeBorder(.white, lineWidth: 2.2)
                    .frame(width: 18, height: 18)
            }

            Text(text)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white)
                .glassLegibleText()
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Color(white: 0.48).opacity(neutralBackdrop ? 0.32 : 0), in: Capsule())
        .glassCapsule(opacity: 0.28)
    }
}

struct ChristmasPlacementRimView: View {
    let isActive: Bool
    let isPlaced: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let gold = Color(red: 1.0, green: 0.94, blue: 0.72)

        ZStack {
            Circle()
                .stroke(gold.opacity(isActive ? 0.65 : 0.48), lineWidth: isActive ? 12 : 10)
                .blur(radius: isActive ? 9 : 7)
                .frame(width: isActive ? 164 : 150, height: isActive ? 164 : 150)

            Circle()
                .stroke(gold.opacity(isActive ? 1.0 : 0.84), style: StrokeStyle(lineWidth: isActive ? 4 : 3, lineCap: .round, dash: [12, 8]))
                .shadow(color: gold.opacity(isActive ? 0.55 : 0.32), radius: isActive ? 12 : 8)
                .frame(width: isActive ? 164 : 150, height: isActive ? 164 : 150)

            Circle()
                .stroke(.white.opacity(0.30), lineWidth: 1)
                .padding(7)
                .frame(width: isActive ? 164 : 150, height: isActive ? 164 : 150)
        }
        .padding(52)
        .frame(width: 260, height: 260)
        .allowsHitTesting(false)
        .scaleEffect(isPlaced ? 1.12 : (pulse ? 1.065 : 0.96))
        .opacity(isPlaced ? 0 : (pulse ? 1 : 0.84))
        .animation(.easeOut(duration: 0.9), value: isPlaced)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.65).repeatForever(autoreverses: true)) { pulse = true }
        }
        .animation(.easeInOut(duration: 0.16), value: isActive)
    }
}

// Stage 2 completion panel. Shown when the last activity step finishes; its
// single action returns the child to the bedroom along the reverse route.
struct ActivityCompletionView: View {
    let route: MemoryRoute
    let session: MemorySession
    let completedRoutes: Set<MemoryRoute>
    let onRouteRequested: (MemoryRoute) -> Void
    let onReturnHome: () -> Void

    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 18) {
            completionSummary

            VStack(alignment: .leading, spacing: 22) {
                Text("Moments I want to visit")
                    .font(.system(size: 28, weight: .regular, design: .default))
                    .foregroundStyle(REWindPalette.primaryText)
                    .glassLegibleText()

                HStack(spacing: 34) {
                    ForEach(nextRoutes, id: \.rawValue) { nextRoute in
                        CompletionMemoryCard(
                            route: nextRoute,
                            isCompleted: isRouteCompleted(nextRoute),
                            onRouteRequested: onRouteRequested
                        )
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(width: 760, alignment: .leading)
            .dashboardFlatGlass(cornerRadius: 30)
        }
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.95)
        .task {
            withAnimation(.easeOut(duration: 0.7)) {
                hasAppeared = true
            }
        }
    }

    private var completionSummary: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 74, height: 74)
                    .glassBackgroundEffect(in: Circle())

                Circle()
                    .strokeBorder(.white.opacity(0.72), lineWidth: 2)
                    .frame(width: 58, height: 58)

                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.white)

                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(REWindPalette.accent)
                    .offset(x: -56, y: -28)

                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(REWindPalette.accent)
                    .offset(x: 58, y: -10)

                Image(systemName: "sparkle")
                    .font(.system(size: 8, weight: .regular))
                    .foregroundStyle(REWindPalette.accent)
                    .offset(x: -42, y: 26)
            }
            .scaleEffect(hasAppeared ? 1.0 : 0.86)

            VStack(spacing: 8) {
                Text("All done!")
                    .font(.system(size: 54, weight: .regular, design: .default))
                    .foregroundStyle(REWindPalette.primaryText)

                Text(route.completionMessage)
                    .font(.system(size: 28, weight: .regular, design: .default))
                    .foregroundStyle(REWindPalette.secondaryText)
            }
            .glassLegibleText()
            .multilineTextAlignment(.center)

            GlassPillButton(
                title: "Return to Bedroom",
                systemImage: "house",
                isProminent: true,
                action: onReturnHome
            )
            .scaleEffect(0.82)
            .padding(.top, 2)
        }
        .padding(.horizontal, 92)
        .padding(.vertical, 34)
        .frame(width: 760)
        .dashboardFlatGlass(cornerRadius: 34)
    }

    private var nextRoutes: [MemoryRoute] {
        MemoryRoute.allCases
            .filter { $0 != route }
            .sorted { first, second in
                let firstCompleted = isRouteCompleted(first)
                let secondCompleted = isRouteCompleted(second)

                if firstCompleted != secondCompleted {
                    return !firstCompleted && secondCompleted
                }

                return first.rawValue < second.rawValue
            }
    }

    private func isRouteCompleted(_ route: MemoryRoute) -> Bool {
        completedRoutes.contains(route)
    }
}

private struct CompletionMemoryCard: View {
    let route: MemoryRoute
    let isCompleted: Bool
    let onRouteRequested: (MemoryRoute) -> Void

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardImage
            Spacer(minLength: 18)

            HStack(alignment: .top, spacing: 14) {
                Text(route.title)
                    .font(.system(size: 28, weight: .regular, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .glassLegibleText()

                Spacer(minLength: 0)

                completionBadge
            }
            .padding(.horizontal, 8)

            Button {
                guard !isCompleted else { return }
                onRouteRequested(route)
            } label: {
                Text(isCompleted ? "Completed" : "Revisit this memory")
                    .font(.system(size: 20, weight: .regular, design: .default))
                    .foregroundStyle(isCompleted ? .white.opacity(0.58) : .white)
                    .glassLegibleText()
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Capsule())
                    .glassCapsule(opacity: isCompleted ? 0.22 : 0.34)
            }
            .buttonStyle(.plain)
            .contentShape(.interaction, Capsule())
            .hoverEffect(.highlight)
            .disabled(isCompleted)
        }
        .padding(16)
        .frame(width: 330, height: 440, alignment: .top)
        .dashboardFlatGlass(cornerRadius: 26)
        .opacity(isCompleted ? 0.74 : 1.0)
        .scaleEffect(isFocused && !isCompleted ? 1.025 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .onHover { isFocused = $0 }
    }

    private var cardImage: some View {
        AsyncImage(url: imageURL) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [.white.opacity(0.20), .white.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: routeFallbackSymbol)
                        .font(.system(size: 42, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
        .frame(width: 300, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var imageURL: URL? {
        Bundle.main.url(forResource: route.cardImageName, withExtension: "png")
    }

    private var routeFallbackSymbol: String {
        switch route {
        case .playingBall:
            "figure.child"
        case .christmasTree:
            "tree"
        case .breakfast:
            "cup.and.saucer"
        }
    }

    @ViewBuilder
    private var completionBadge: some View {
        if isCompleted {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 38, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(REWindPalette.accentDeep, .white)
        } else {
            Circle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 2.4)
                .frame(width: 38, height: 38)
        }
    }
}
