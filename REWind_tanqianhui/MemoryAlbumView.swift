//
//  MemoryAlbumView.swift
//  REWind_tanqianhui
//
//  Stage 4. The Memory Album that rests on the bed with a gentle glow, and the
//  shared progress dashboard that appears above it. Matches the dashboard frame
//  in the concept document: memory header, Movement Progress stat tiles,
//  Progress Over Time charts, and the memory strip along the bottom.
//

import SwiftUI
import UIKit

// The closed album resting on the bed. Looking at or tapping it opens the
// dashboard.
struct MemoryAlbumView: View {
    let completedCount: Int
    let totalCount: Int
    let onOpen: () -> Void

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            Text("RE.Wind")
                .font(.system(size: 34, weight: .regular, design: .default))
                .foregroundStyle(.white.opacity(0.92))

            Text("Your memories\nare growing")
                .font(.system(size: 82, weight: .regular, design: .default))
                .lineSpacing(12)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text("Open your Memory Album\nto see how today's moments\nhelped you move.")
                .font(.system(size: 38, weight: .regular, design: .default))
                .lineSpacing(10)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(action: onOpen) {
                HStack(spacing: 24) {
                    Text("Look at the album")
                        .font(.system(size: 36, weight: .regular, design: .default))

                    Image(systemName: "chevron.right")
                        .font(.system(size: 36, weight: .regular))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 52)
                .frame(height: 104)
                .glassCapsule(opacity: isFocused ? 0.46 : 0.34)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .onHover { isHovering in
                isFocused = isHovering
            }
        }
        .glassLegibleText()
        .padding(52)
        .frame(width: 980, height: 700, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.26), value: isFocused)
        .accessibilityLabel("\(completedCount) of \(totalCount) memories collected")
    }
}

struct MemoryAlbumPointerView: View {
    @State private var glow = false
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                Image(systemName: "book.fill")
                    .font(.system(size: 38, weight: .regular))

                Text("Your latest memories\nare here")
                    .font(.system(size: 27, weight: .regular, design: .default))
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 34)
            .frame(height: 82)
            .glassCapsule(opacity: 0.34)

            Image(systemName: "chevron.down")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(.white)
                .glassLegibleText()
        }
        .glassLegibleText()
        .shadow(color: Color(red: 1, green: 0.82, blue: 0.47).opacity(glow ? 0.35 : 0.12), radius: glow ? 16 : 7)
        .overlay(alignment: .bottom) {
            ZStack {
                ForEach(0..<5) { index in
                    Circle().fill(Color(red: 1, green: 0.88, blue: 0.62))
                        .frame(width: index % 2 == 0 ? 3 : 2)
                        .blur(radius: 0.7)
                        .offset(x: CGFloat(index - 2) * 23, y: glow ? -12 - CGFloat(index % 3) * 9 : 16)
                        .opacity(glow ? 0.7 : 0.08)
                }
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { glow = true } }
        .allowsHitTesting(false)
    }
}

// The shared dashboard. One panel, two reading levels: an encouraging child view
// and a detail view for the clinician.
struct MemoryDashboardView: View {
    enum Audience: String, CaseIterable, Identifiable {
        case child = "For me"
        case clinician = "For my clinician"

        var id: String { rawValue }
    }

    let session: MemorySession
    let history: [MemorySession]
    let reachChangeCentimetres: Double?
    let completedRoutes: Set<MemoryRoute>
    var onSelectRoute: (MemoryRoute) -> Void = { _ in }
    let onClose: () -> Void
    let onReturnHome: () -> Void

    @State private var audience: Audience = .child
    @State private var hasAppeared = false

    private var route: MemoryRoute {
        session.route
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(.white.opacity(0.24))
                .padding(.vertical, 24)

            HStack(alignment: .top, spacing: 34) {
                reflectionCard
                    .frame(width: 360)

                VStack(alignment: .leading, spacing: 28) {
                    if audience == .child {
                        movementProgressSection
                    } else {
                        clinicianDetailSection
                    }

                    progressOverTimeSection
                }
            }

            Spacer(minLength: 26)

            memoryStrip
        }
        .padding(.horizontal, 52)
        .padding(.vertical, 42)
        // Grown from 1280x840 so the larger dashboard type is not cramped.
        .frame(width: 1560, height: audience == .clinician ? 1240 : 1000)
        .dashboardFlatGlass(cornerRadius: 48, opacity: 0.40)
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.96)
        .animation(.easeInOut(duration: 0.3), value: audience)
        .task {
            withAnimation(.easeOut(duration: 0.65)) {
                hasAppeared = true
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(REWindPalette.secondaryText)
                    .glassLegibleText()
                    .frame(width: 62, height: 62)
                    .glassCapsule(opacity: 0.36)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)

            VStack(alignment: .leading, spacing: 7) {
                Text(route.title)
                    .font(.system(size: 44, weight: .regular, design: .default))
                    .foregroundStyle(REWindPalette.primaryText)

                Text(session.isComplete ? "Memory completed" : "Previous session")
                    .font(.system(size: 26, weight: .regular, design: .default))
                    .foregroundStyle(REWindPalette.tertiaryText)
            }
            .glassLegibleText()
            .padding(.leading, 12)

            Spacer()

            audiencePicker

            Text(session.completedAt.formatted(.dateTime.month(.abbreviated).day().year()))
                .font(.system(size: 25, weight: .regular, design: .default))
                .foregroundStyle(REWindPalette.tertiaryText)
                .glassLegibleText()
                .padding(.leading, 24)

            // The bedroom shortcut the document asks for.
            Button(action: onReturnHome) {
                Image(systemName: "bed.double")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(REWindPalette.secondaryText)
                    .glassLegibleText()
                    .frame(width: 70, height: 62)
                    .glassCapsule(opacity: 0.36)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .padding(.leading, 18)
        }
    }

    private var audiencePicker: some View {
        HStack(spacing: 4) {
            ForEach(Audience.allCases) { option in
                Button {
                    audience = option
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 25, weight: audience == option ? .semibold : .regular))
                        .foregroundStyle(
                            audience == option ? REWindPalette.primaryText : REWindPalette.tertiaryText
                        )
                        .glassLegibleText()
                        .padding(.horizontal, 26)
                        .frame(height: 54)
                        .background {
                            Capsule()
                                .fill(.white.opacity(audience == option ? 0.24 : 0.0))
                        }
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
        }
        .padding(5)
        .glassCapsule(opacity: 0.32)
    }

    private var reflectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            MemoryBundleThumbnail(imageName: route.cardImageName)
                .frame(height: 206)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .opacity(1.0)

            HStack(spacing: 13) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(REWindPalette.accentDeep, REWindPalette.accent)

                Text(session.isComplete ? "Memory completed" : "Previous session")
                    .font(.system(size: 28, weight: .regular, design: .default))
                    .foregroundStyle(REWindPalette.primaryText)
            }
            .glassLegibleText()

            Text(route.albumReflection)
                .font(.system(size: 25, weight: .regular, design: .default))
                .foregroundStyle(REWindPalette.secondaryText)
                .glassLegibleText()
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .dashboardFlatGlass(cornerRadius: 32, opacity: 0.32)
    }

    private var movementProgressSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Movement Progress")
                .font(.system(size: 32, weight: .regular, design: .default))
                .foregroundStyle(REWindPalette.secondaryText)
                .glassLegibleText()

            HStack(spacing: 20) {
                StatTile(
                    systemImage: "figure.arms.open",
                    title: hasMeasuredReach ? "Reach Distance" : "Object Movement",
                    value: reachValueText,
                    caption: reachCaptionText
                )

                StatTile(
                    systemImage: "arrow.triangle.2.circlepath",
                    title: hasMeasuredRotation ? "Wrist Rotation" : ((session.objectRotationDegrees ?? 0) > 0 ? "Object Rotation" : "Active Movement"),
                    value: rotationValueText,
                    caption: rotationCaptionText
                )

                StatTile(
                    systemImage: "checkmark.circle",
                    title: "Activity Completion",
                    value: "\(session.completedInteractions) / \(session.totalInteractions)",
                    caption: "Finished in \(session.durationSummary)"
                )
            }

            Text(howTodayHelpedText)
                .font(.system(size: 26, weight: .regular, design: .default))
                .foregroundStyle(REWindPalette.secondaryText)
                .glassLegibleText()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var clinicianDetailSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Session Detail")
                .font(.system(size: 32, weight: .regular, design: .default))
                .foregroundStyle(REWindPalette.secondaryText)
                .glassLegibleText()

            VStack(spacing: 0) {
                DetailRow(label: "Prescribed movement target", value: route.clinicianMovementTarget)
                DetailRow(label: "Prescribed safe range", value: prescribedRangeText)
                DetailRow(
                    label: "Completed interactions",
                    value: "\(session.completedInteractions) of \(session.totalInteractions)"
                )
                DetailRow(label: "Maximum reach", value: measuredReachText(session.maximumReachCentimetres))
                DetailRow(label: "Comfortable reach", value: measuredReachText(session.comfortableReachCentimetres))
                DetailRow(label: hasMeasuredRotation ? "Wrist rotation swept" : ((session.objectRotationDegrees ?? 0) > 0 ? "Object rotation" : "Active movement"), value: rotationValueText)
                DetailRow(label: "Bilateral hand use", value: session.bilateralSummary)
                DetailRow(label: "Session duration", value: session.durationSummary)
                DetailRow(label: "Change across sessions", value: changeAcrossSessionsText, isLast: true)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .dashboardFlatGlass(cornerRadius: 28, opacity: 0.30)
        }
    }

    private var progressOverTimeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Progress Over Time")
                    .font(.system(size: 32, weight: .regular, design: .default))
                    .foregroundStyle(REWindPalette.secondaryText)
                    .glassLegibleText()

                Spacer()

                Text(history.count <= 1 ? "First session" : "Last \(history.count) sessions")
                    .font(.system(size: 24, weight: .regular, design: .default))
                    .foregroundStyle(REWindPalette.tertiaryText)
                    .glassLegibleText()
            }

            HStack(spacing: 20) {
                BarChartTile(
                    title: hasMeasuredReach ? "Reach Distance" : "Object Movement",
                    unit: "cm",
                    values: history.map { hasMeasuredReach ? $0.maximumReachCentimetres : ($0.objectTravelCentimetres ?? 0) }
                )

                BarChartTile(
                    title: hasMeasuredRotation ? "Wrist Rotation" : ((session.objectRotationDegrees ?? 0) > 0 ? "Object Rotation" : "Active Movement"),
                    unit: hasMeasuredRotation || (session.objectRotationDegrees ?? 0) > 0 ? "°" : "s",
                    values: history.map { hasMeasuredRotation ? $0.wristRotationDegrees : ((session.objectRotationDegrees ?? 0) > 0 ? ($0.objectRotationDegrees ?? 0) : ($0.activeManipulationSeconds ?? 0)) }
                )

                BarChartTile(
                    title: "Completed Interactions",
                    unit: "",
                    values: history.map { Double($0.completedInteractions) }
                )
            }
        }
    }

    private var memoryStrip: some View {
        HStack(spacing: 16) {
            ForEach(MemoryRoute.allCases) { item in
                MemoryStripCard(
                    route: item,
                    isCurrent: item == route,
                    isCompleted: completedRoutes.contains(item)
                )
                .contentShape(.interaction, RoundedRectangle(cornerRadius: 24, style: .continuous))
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onTapGesture { onSelectRoute(item) }
                .hoverEffect { effect, _, _ in effect }
            }
        }
    }

    // MARK: - Derived text
    //
    // Reach and rotation are only reported as measurements when hand tracking
    // actually produced them. A zero means the activity was advanced manually, so
    // it is labelled rather than shown as "0 cm".

    private var hasMeasuredReach: Bool {
        session.maximumReachCentimetres > 0
    }

    private var hasMeasuredRotation: Bool {
        session.wristRotationDegrees > 0
    }

    private var reachValueText: String {
        hasMeasuredReach ? "\(Int(session.maximumReachCentimetres.rounded())) cm" : "\(Int((session.objectTravelCentimetres ?? 0).rounded())) cm"
    }

    private var reachCaptionText: String {
        guard hasMeasuredReach else {
            return "Measured while moving objects"
        }

        return "Usually \(Int(session.comfortableReachCentimetres.rounded())) cm"
    }

    private var rotationValueText: String {
        if hasMeasuredRotation { return "\(Int(session.wristRotationDegrees.rounded()))°" }
        if let rotation = session.objectRotationDegrees, rotation > 0 { return "\(Int(rotation.rounded()))°" }
        return "\(Int((session.activeManipulationSeconds ?? 0).rounded())) s"
    }

    private var rotationCaptionText: String {
        hasMeasuredRotation ? "Hand-tracked turning" : ((session.objectRotationDegrees ?? 0) > 0 ? "Measured object turning" : "Time moving the objects")
    }

    private var prescribedRangeText: String {
        let range = route.prescribedSafeReachRange
        return "\(Int(range.lowerBound))-\(Int(range.upperBound)) cm"
    }

    private func measuredReachText(_ value: Double) -> String {
        value > 0 ? "\(Int(value.rounded())) cm" : "Not measured"
    }

    private var changeAcrossSessionsText: String {
        guard let reachChangeCentimetres else {
            return "No earlier session to compare"
        }

        let rounded = Int(reachChangeCentimetres.rounded())
        if rounded == 0 {
            return "Reach unchanged"
        }

        return rounded > 0 ? "Reach +\(rounded) cm" : "Reach \(rounded) cm"
    }

    private var howTodayHelpedText: String {
        guard let reachChangeCentimetres, hasMeasuredReach else {
            return "Today you practised \(route.primaryMovementSummary.lowercased())."
        }

        let rounded = Int(reachChangeCentimetres.rounded())
        if rounded > 0 {
            return "Today you reached \(rounded) cm further than last time."
        }

        if rounded == 0 {
            return "You held the same reach as last time. That is good steady progress."
        }

        return "A shorter reach today is completely fine. You still finished every step."
    }
}

// MARK: - Dashboard building blocks

private struct StatTile: View {
    let systemImage: String
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(REWindPalette.accent)

                Text(title)
                    .font(.system(size: 24, weight: .medium, design: .default))
                    .foregroundStyle(REWindPalette.tertiaryText)
            }

            Text(value)
                .font(.system(size: 54, weight: .semibold, design: .default))
                .foregroundStyle(REWindPalette.primaryText)

            Text(caption)
                .font(.system(size: 22, weight: .regular, design: .default))
                .foregroundStyle(REWindPalette.tertiaryText)
                .lineLimit(1)
        }
        .glassLegibleText()
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardFlatGlass(cornerRadius: 28, opacity: 0.30)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var isLast = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text(label)
                    .font(.system(size: 24, weight: .regular, design: .default))
                    .foregroundStyle(REWindPalette.tertiaryText)

                Spacer(minLength: 28)

                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .default))
                    .foregroundStyle(REWindPalette.primaryText)
                    .multilineTextAlignment(.trailing)
            }
            .glassLegibleText()
            .padding(.vertical, 14)

            if !isLast {
                Rectangle()
                    .fill(.white.opacity(0.16))
                    .frame(height: 1)
            }
        }
    }
}

private struct BarChartTile: View {
    let title: String
    let unit: String
    let values: [Double]

    // Bars are drawn against the largest value in the series, with a floor so a
    // single-session series still renders a readable bar.
    private var normalizedHeights: [Double] {
        guard let maximum = values.max(), maximum > 0 else {
            return values.map { _ in 0 }
        }

        return values.map { max(0.08, $0 / maximum) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 23, weight: .medium, design: .default))
                .foregroundStyle(REWindPalette.tertiaryText)

            if values.isEmpty {
                Text("No data yet")
                    .font(.system(size: 23, weight: .regular, design: .default))
                    .foregroundStyle(REWindPalette.tertiaryText)
                    .frame(height: 92, alignment: .bottom)
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Array(normalizedHeights.enumerated()), id: \.offset) { index, height in
                        let isLatest = index == normalizedHeights.count - 1

                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                isLatest
                                    ? REWindPalette.accent
                                    : Color.white.opacity(0.38)
                            )
                            .frame(width: 20, height: 92 * height)
                    }
                }
                .frame(height: 92, alignment: .bottom)
            }

            Text(latestValueText)
                .font(.system(size: 26, weight: .semibold, design: .default))
                .foregroundStyle(REWindPalette.primaryText)
        }
        .glassLegibleText()
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardFlatGlass(cornerRadius: 26, opacity: 0.28)
    }

    private var latestValueText: String {
        guard let latest = values.last else {
            return ", "
        }

        return "\(Int(latest.rounded()))\(unit)"
    }
}

private struct MemoryStripCard: View {
    let route: MemoryRoute
    let isCurrent: Bool
    let isCompleted: Bool

    var body: some View {
        HStack(spacing: 17) {
            MemoryBundleThumbnail(imageName: route.cardImageName)
                .frame(width: 104, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(route.title)
                    .font(.system(size: 24, weight: .semibold, design: .default))
                    .foregroundStyle(isCompleted ? REWindPalette.primaryText : REWindPalette.tertiaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(isCompleted ? "Collected" : "Not visited yet")
                    .font(.system(size: 21, weight: .regular, design: .default))
                    .foregroundStyle(REWindPalette.tertiaryText)
            }
            .glassLegibleText()

            Spacer(minLength: 0)

            if isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(REWindPalette.accentDeep, REWindPalette.accent)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardFlatGlass(cornerRadius: 24, opacity: isCurrent ? 0.34 : 0.26)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    REWindPalette.accent.opacity(isCurrent ? 0.8 : 0.0),
                    lineWidth: 2.0
                )
        }
    }
}

// Loads a memory image from the app bundle. The card art is a loose bundle
// resource rather than an asset catalog entry, so Image(named:) cannot find it.
struct MemoryBundleThumbnail: View {
    let imageName: String

    var body: some View {
        if let url = Bundle.main.url(forResource: imageName, withExtension: "png"),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
        } else {
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(maxWidth: .infinity)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(REWindPalette.tertiaryText)
                }
        }
    }
}
