//
//  MemoryExperience.swift
//  REWind_tanqianhui
//
//  Memory definitions, route markers and the per-memory activity step scripts
//  described in "RE.Wind. Spatial Rehabilitation Concept".
//

import Foundation

// The three core memory experiences. Raw values are stable identifiers and are
// used as the persistence key for saved sessions, so they must not be renamed.
enum MemoryRoute: String, CaseIterable, Identifiable, Codable {
    case playingBall
    case christmasTree
    case breakfast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playingBall:
            "Playing Ball with Dad"
        case .christmasTree:
            "Decorating the Christmas Tree"
        case .breakfast:
            "Breakfast Before School"
        }
    }

    // Two-line form used on the memory cards, kept as authored line breaks so the
    // card layout stays identical to the concept mockups.
    var cardTitle: String {
        switch self {
        case .playingBall:
            "Playing Ball\nwith Dad"
        case .christmasTree:
            "Decorating the\nChristmas Tree"
        case .breakfast:
            "Breakfast Before\nSchool"
        }
    }

    var cardImageName: String {
        switch self {
        case .playingBall:
            "Playing Ball With Dad"
        case .christmasTree:
            "Decorating The Christmas Tree"
        case .breakfast:
            "Breakfast In The Morning"
        }
    }

    var cardVideoName: String {
        switch self {
        case .playingBall:
            "Playing Ball With Dad Video.mp4"
        case .christmasTree:
            "Decorating The Christmas Tree Video.mp4"
        case .breakfast:
            "Breakfast In The Morning Video.mp4"
        }
    }

    // Outbound route, transcribed from the concept document. The first entry is
    // always the bedroom start, the last entry is the activity destination.
    var markerNames: [String] {
        switch self {
        case .playingBall:
            [
                "Location_Bedroom",
                "RouteMarker 1",
                "RouteMarker 2",
                "RouteMarker 3",
                "RouteMarker 6",
                "Location_Outdoor"
            ]
        case .christmasTree:
            [
                "Location_Bedroom",
                "RouteMarker 1",
                "RouteMarker 2",
                "RouteMarker 3",
                "Location_Living Room"
            ]
        case .breakfast:
            [
                "Location_Bedroom",
                "RouteMarker 1",
                "RouteMarker 2",
                "RouteMarker 3",
                "RouteMarker 4",
                "RouteMarker 5",
                "Location_Dining Room"
            ]
        }
    }

    // Stage 3. The document lists the return path for each memory as the exact
    // reverse of the outbound path, so it is derived rather than duplicated.
    var returnMarkerNames: [String] {
        markerNames.reversed()
    }

    var destinationName: String {
        markerNames.last ?? ""
    }

    // Movement target headline shown to the child on the dashboard.
    var primaryMovementSummary: String {
        switch self {
        case .playingBall:
            "Shoulder movement and forward reach"
        case .christmasTree:
            "Grasp, release and wrist rotation"
        case .breakfast:
            "Bilateral coordination and controlled reach"
        }
    }

    // Clinician-facing prescribed target, shown in the clinician detail rows.
    var clinicianMovementTarget: String {
        switch self {
        case .playingBall:
            "Shoulder flexion with forward and lateral reach"
        case .christmasTree:
            "Grasp, sustained hold, forearm rotation, controlled release"
        case .breakfast:
            "Bilateral object transfer with forearm supination"
        }
    }

    // Prescribed comfortable working range, in centimetres of reach.
    var prescribedSafeReachRange: ClosedRange<Double> {
        switch self {
        case .playingBall:
            20.0...45.0
        case .christmasTree:
            15.0...35.0
        case .breakfast:
            15.0...40.0
        }
    }

    // Line spoken back to the child on the completion panel.
    var completionMessage: String {
        switch self {
        case .playingBall:
            "You completed all 3 ball steps with Dad."
        case .christmasTree:
            "You've decorated all 3 ornaments."
        case .breakfast:
            "Breakfast is ready. Nicely done."
        }
    }

    // Short reflective quote shown beside the album, in the child's voice.
    var albumReflection: String {
        switch self {
        case .playingBall:
            "\"When I reached for the ball, I could feel my shoulder waking up.\""
        case .christmasTree:
            "\"I turned every ornament myself before hanging it.\""
        case .breakfast:
            "\"I poured the cereal with two hands, like I used to.\""
        }
    }

    var activitySteps: [ActivityStep] {
        switch self {
        case .playingBall:
            (1...3).map { number in
                ActivityStep(instruction: "Catch and pass the ball",
                    detail: "Hold the ball, move toward Dad, then release.",
                    checklistLabel: "Throw \(number) of 3", targetHint: "Catch here")
            }
        case .christmasTree:
            [
                ActivityStep(
                    instruction: "Pick up an ornament",
                    detail: "Tap or pinch an ornament to look closer.",
                    checklistLabel: "Ornament 1 of 3",
                    targetHint: "Pinch or grasp here"
                ),
                ActivityStep(
                    instruction: "Place it on the highlighted spot",
                    detail: "Hold the ornament, drag to the pulsing ring, then release.",
                    checklistLabel: "Ornament 1 of 3",
                    targetHint: "Place it here"
                ),
                ActivityStep(
                    instruction: "Well done!",
                    detail: "Your ornament is hanging on the tree.",
                    checklistLabel: "Ornament 1 of 3",
                    targetHint: nil
                ),
                ActivityStep(
                    instruction: "Pick up an ornament",
                    detail: "Tap or pinch an ornament to look closer.",
                    checklistLabel: "Ornament 2 of 3",
                    targetHint: "Pinch or grasp here"
                ),
                ActivityStep(
                    instruction: "Place it on the highlighted spot",
                    detail: "Hold the ornament, drag to the pulsing ring, then release.",
                    checklistLabel: "Ornament 2 of 3",
                    targetHint: "Place it here"
                ),
                ActivityStep(
                    instruction: "Well done!",
                    detail: "Your ornament is hanging on the tree.",
                    checklistLabel: "Ornament 2 of 3",
                    targetHint: nil
                ),
                ActivityStep(
                    instruction: "Pick up an ornament",
                    detail: "Tap or pinch an ornament to look closer.",
                    checklistLabel: "Ornament 3 of 3",
                    targetHint: "Pinch or grasp here"
                ),
                ActivityStep(
                    instruction: "Place it on the highlighted spot",
                    detail: "Hold the ornament, drag to the pulsing ring, then release.",
                    checklistLabel: "Ornament 3 of 3",
                    targetHint: "Place it here"
                ),
                ActivityStep(
                    instruction: "Well done!",
                    detail: "All three ornaments are hanging on the tree.",
                    checklistLabel: "Ornament 3 of 3",
                    targetHint: nil
                ),
            ]
        case .breakfast:
            [
                ActivityStep(instruction: "Pour the cereal", detail: "Hold the box and lift straight up. Keep holding.", checklistLabel: "Cereal 1 of 3", targetHint: "Lift cereal box here"),
                ActivityStep(instruction: "Pour the milk", detail: "Hold the carton and lift straight up. Keep holding.", checklistLabel: "Milk 2 of 3", targetHint: "Lift milk here"),
                ActivityStep(instruction: "Stir the cereal", detail: "Pick up the spoon and make gentle circles.", checklistLabel: "Stir 3 of 3", targetHint: "Pick up the spoon here")
            ]
        }
    }
}

// One instruction beat inside an activity. The HUD renders exactly one of these
// at a time in the top pill, and the whole array as the left-hand checklist.
struct ActivityStep: Identifiable, Hashable {
    let instruction: String
    let detail: String
    let checklistLabel: String
    let targetHint: String?

    var id: String { "\(checklistLabel)-\(instruction)" }
}
