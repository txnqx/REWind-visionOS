//
//  MemorySessionStore.swift
//  REWind_tanqianhui
//
//  Records what happened during an activity so the Stage 4 dashboard can show
//  real numbers, and keeps a short session history on disk for the
//  "Progress Over Time" charts.
//

import Foundation
import Observation

// One completed activity. Values are recorded as they happen during the
// activity and written once on completion.
struct MemorySession: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var route: MemoryRoute
    var completedAt: Date
    // Duration the child spent inside the activity, excluding travel.
    var durationSeconds: Double
    // Furthest reach recorded, in centimetres from the shoulder start position.
    var maximumReachCentimetres: Double
    // Typical reach across the completed interactions, in centimetres.
    var comfortableReachCentimetres: Double
    // Total wrist rotation swept during the activity, in degrees.
    var wristRotationDegrees: Double
    var completedInteractions: Int
    var totalInteractions: Int
    // Interactions performed with each hand, for the bilateral-use row.
    var leftHandInteractions: Int
    var rightHandInteractions: Int
    // Actual model manipulation, distinct from clinical hand-tracking measures.
    // Optional for backwards compatibility with existing saved sessions.
    var objectTravelCentimetres: Double? = nil
    var objectRotationDegrees: Double? = nil
    var activeManipulationSeconds: Double? = nil
    // Legacy automatic reviews recorded counts without validated object actions.
    // Keep their history, but do not award completion from those counts alone.
    var completionVerified: Bool? = nil

    var isComplete: Bool {
        let expected = route == .christmasTree ? (totalInteractions == 9 ? 9 : 3) : route.activitySteps.count
        let verified = completionVerified ?? ((objectTravelCentimetres ?? 0) > 0 && (activeManipulationSeconds ?? 0) > 0)
        return verified && totalInteractions == expected && completedInteractions == expected
    }

    var bilateralSummary: String {
        guard leftHandInteractions + rightHandInteractions > 0 else {
            return "Not recorded"
        }

        return "Left \(leftHandInteractions) · Right \(rightHandInteractions)"
    }

    var durationSummary: String {
        let totalSeconds = Int(durationSeconds.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes == 0 {
            return "\(seconds)s"
        }

        return "\(minutes)m \(seconds)s"
    }
}

// Accumulates measurements while an activity is running. The activity view owns
// one of these and hands it to the store when the last step finishes.
@MainActor
final class MemorySessionRecorder {
    let route: MemoryRoute
    private let startedAt = Date()
    private var reachSamples: [Double] = []
    private var rotationDegrees: Double = 0
    private var completedInteractions = 0
    private var objectTravel: Double = 0
    private var objectRotation: Double = 0
    private var activeManipulation: Double = 0
    private var livePeakReach: Double = 0
    private var leftHandInteractions = 0
    private var rightHandInteractions = 0

    init(route: MemoryRoute) {
        self.route = route
    }

    // Called once per completed interaction. `reachCentimetres` is the furthest
    // extension measured during that interaction.
    func recordInteraction(reachCentimetres: Double, usedLeftHand: Bool, usedRightHand: Bool) {
        if reachCentimetres > 0 { reachSamples.append(reachCentimetres) }

        if usedLeftHand {
            leftHandInteractions += 1
        }

        if usedRightHand {
            rightHandInteractions += 1
        }
    }

    // Called as the wrist turns; contributions are additive so a partial turn
    // followed by another partial turn reads as the total sweep.
    func recordWristRotation(degrees: Double) {
        rotationDegrees += max(0, degrees)
    }

    // For gesture-driven activities (e.g. Christmas tree) where steps advance via
    // object actions rather than unrelated hand-reach events, sync completed steps.
    func recordManualCompletions(_ count: Int) {
        completedInteractions = max(completedInteractions, route == .christmasTree ? count / 3 : count)
    }

    func recordObjectMovement(centimetres: Double, degrees: Double, activeSeconds: Double) {
        guard centimetres.isFinite, degrees.isFinite, activeSeconds.isFinite else { return }
        objectTravel += max(0, centimetres)
        objectRotation += max(0, degrees)
        activeManipulation += max(0, activeSeconds)
    }

    func recordLiveReach(_ centimetres: Double) {
        if centimetres.isFinite { livePeakReach = max(livePeakReach, centimetres) }
    }

    func makeSession() -> MemorySession {
        let totalInteractions = route == .christmasTree ? 3 : route.activitySteps.count
        let comfortableReach = reachSamples.isEmpty
            ? 0
            : reachSamples.reduce(0, +) / Double(reachSamples.count)

        return MemorySession(
            route: route,
            completedAt: Date(),
            durationSeconds: Date().timeIntervalSince(startedAt),
            maximumReachCentimetres: max(livePeakReach, reachSamples.max() ?? 0),
            comfortableReachCentimetres: comfortableReach,
            wristRotationDegrees: rotationDegrees,
            completedInteractions: completedInteractions,
            totalInteractions: totalInteractions,
            leftHandInteractions: leftHandInteractions,
            rightHandInteractions: rightHandInteractions,
            objectTravelCentimetres: objectTravel,
            objectRotationDegrees: objectRotation,
            activeManipulationSeconds: activeManipulation,
            completionVerified: completedInteractions == totalInteractions
        )
    }
}

// Session history, persisted as JSON in Application Support. Deliberately small
// and file-based: there is no server in this concept, and the clinician view
// reads the same local history the child does.
@MainActor
@Observable
final class MemorySessionStore {
    // Sessions in the order they were completed, oldest first.
    private(set) var sessions: [MemorySession] = []
    // The most recently completed session, i.e. what the dashboard is currently about.
    private(set) var latestSession: MemorySession?
    // Completion belongs to this app run; historical sessions remain on disk.
    private(set) var completedRoutes: Set<MemoryRoute> = []
    private let fileName = "memory_sessions.json"
    private let maximumStoredSessions = 40
    private let storageDirectory: URL?

    init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
        load()
        // A relaunch starts a fresh set of activities. Never hydrate current-run
        // completion from historical sessions or older completion receipts.
        latestSession = nil
    }

    func resetCurrentRun() {
        completedRoutes.removeAll()
        latestSession = nil
    }

    var hasCompletedAllMemories: Bool {
        completedRoutes.count == MemoryRoute.allCases.count
    }

    func record(_ session: MemorySession) {
        sessions.append(session)

        if sessions.count > maximumStoredSessions {
            sessions.removeFirst(sessions.count - maximumStoredSessions)
        }

        latestSession = session
        if session.isComplete {
            completedRoutes.insert(session.route)
        }
        save()
    }

    // Chronological history for one memory, newest last, capped for the charts.
    func history(for route: MemoryRoute, limit: Int) -> [MemorySession] {
        let matching = sessions.filter { $0.route == route }
        guard matching.count > limit else {
            return matching
        }

        return Array(matching.suffix(limit))
    }

    // Change in maximum reach against the previous session of the same memory.
    // Nil when there is no earlier session to compare against.
    func reachChangeCentimetres(for session: MemorySession) -> Double? {
        let sameRoute = sessions.filter { $0.route == session.route }
        guard let index = sameRoute.firstIndex(of: session), index > 0 else {
            return nil
        }

        return session.maximumReachCentimetres - sameRoute[index - 1].maximumReachCentimetres
    }

    private var storeURL: URL? {
        guard let directory = storageDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            print("❌ SESSION STORE: application support directory unavailable")
            return nil
        }

        // Application Support is not guaranteed to exist on first launch.
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                print("❌ SESSION STORE: could not create \(directory.path): \(error)")
                return nil
            }
        }

        return directory.appendingPathComponent(fileName)
    }

    private func load() {
        guard let storeURL, FileManager.default.fileExists(atPath: storeURL.path) else {
            print("ℹ️ SESSION STORE: no saved sessions yet")
            return
        }

        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = try decoder.decode([MemorySession].self, from: data)
            latestSession = sessions.last
            print("✅ SESSION STORE: loaded \(sessions.count) sessions")
        } catch {
            // A decode failure must not block the experience; start clean.
            print("❌ SESSION STORE: load failed, starting empty: \(error)")
            sessions = []
            latestSession = nil
        }
    }

    private func save() {
        guard let storeURL else {
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(sessions).write(to: storeURL, options: .atomic)
            print("✅ SESSION STORE: saved \(sessions.count) sessions")
        } catch {
            print("❌ SESSION STORE: save failed: \(error)")
        }
    }
}
