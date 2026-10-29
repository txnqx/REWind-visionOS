 //
//  SpawnOffsets.swift
//  REWind_tanqianhui
//
//  Where the viewer stands relative to a navigation marker.
//
//  The markers are authored as reference points, not as eye positions, so a
//  viewpoint offset is applied on top of each one.
//
//  WHAT THE MARKERS ACTUALLY ARE
//
//  Measured by ray-casting the shipped house USDZ - the real triangle soup, in
//  RealityKit's runtime frame, not inferred from Blender. For each marker, the
//  nearest walkable surface (Interior_floors, porch_floor, Terrain, Stairs)
//  directly beneath it, and the nearest surface above:
//
//      marker                  z      floor below            eye     ceiling    head
//      Location_Dining Room  1.197    0.000 Interior_floors  1.197    2.900     1.703
//      Location_Living Room  1.077    0.000 Interior_floors  1.077    2.900     1.823
//      Location_Outdoor      0.877   -0.100 porch_floor      0.977    5.845     4.969
//      RouteMarker_1         4.460    3.100 Interior_floors  1.360    6.023     1.563
//      RouteMarker_2         4.234    3.100 Interior_floors  1.134    5.037     0.802
//      RouteMarker_3         1.972    1.161 Stairs           0.810    5.786     3.815
//      RouteMarker_4         1.357    0.000 Interior_floors  1.357    2.623     1.266
//      RouteMarker_5         1.237    0.000 Interior_floors  1.237    2.900     1.663
//      RouteMarker_6         1.217    0.000 Interior_floors  1.217    2.900     1.683
//      Location_Bedroom      4.830   -0.100 porch_floor      4.930    6.473     1.642
//
//  Nine of the ten are already standing eye heights over the floor they belong to,
//  between 0.81 m and 1.36 m. They need no offset, and applying one to them is what
//  drove the route underground.
//
//  Location_Bedroom is the one broken marker, and not merely by height. It is the
//  only marker with roof geometry BETWEEN it and any walkable floor: the stack at
//  its XY is porch_floor at -0.100, porch_ceiling at 2.974, then Roof at 3.335 and
//  Roof_Cover_012 at 3.676 - and only then the marker at 4.830. There is no second
//  floor under it at all. It is authored outside the building envelope, sitting
//  over the porch roof. That is the "spawn point is still in the roof" report, and
//  it cannot be fixed by lowering alone: dropping straight down from there lands on
//  the porch roof, then inside the porch ceiling, then outside on the porch.
//
//  A previous attempt used forward 1.25 / lateral 0.60 with no drop. Re-measured,
//  that lands at world (-10.255, 48.315, 4.810) - still no second floor beneath it,
//  nearest surface below is the top of Bed_004 at 3.548 and the nearest above is the
//  ceiling slab at 6.023. It moved along the roof rather than off it, which is why
//  the device still showed the same thing. That approach is superseded.
//
//  THE FIX
//
//  The app starts from Location_Bedroom and applies the requested marker-local
//  offset:
//
//      forward 2.0, lateral 0.0, down 2.0
//
//  Because the spawn path and the route path both read this one table, the return
//  walk finishes exactly where the session started, by construction.
//
//  Not confirmed, per CLAUDE.md: every number above is a USD ray-cast against the
//  shipped asset, not RealityKit runtime behaviour. This needs a device test.
//

import Foundation
import simd

enum SpawnOffsets {
    // Marker-local placement of the viewer. Applied as the local translation
    // (lateral, -down, -forward), matching the marker axes: local -Z is forward,
    // local -Y is down, local +X is right.
    struct ViewOffset {
        var forward: Float
        var down: Float
        var lateral: Float

        static let zero = ViewOffset(forward: 0, down: 0, lateral: 0)

        var localTranslation: SIMD3<Float> {
            SIMD3<Float>(lateral, -down, -forward)
        }

        var isIdentity: Bool {
            forward == 0 && down == 0 && lateral == 0
        }
    }

    private static let bedroomOffset = ViewOffset(forward: 1.5, down: 2.25, lateral: 0.0)
    private static let routeOffset = ViewOffset(forward: 0.0, down: 1.5, lateral: 0.0)
    private static let routeMarker2Offset = ViewOffset(forward: 1.0, down: 1.5, lateral: 0.0)
    private static let routeMarker3Offset = ViewOffset(forward: 1.0, down: 1.5, lateral: 0.0)
    private static let livingRoomOffset = ViewOffset(forward: 0.25, down: 2.0, lateral: 0.0)
    // Lower only the ball-activity viewpoint by 15 cm; keep its horizontal placement.
    private static let outdoorOffset = ViewOffset(forward: 1.0, down: 1.83, lateral: 0.0)

    // Apply the same marker-local camera offset to every route marker/location so
    // travel viewpoints match the bedroom spawn point.
    private static let offsets: [String: ViewOffset] = [
        "Location_Bedroom": bedroomOffset,
        "RouteMarker 1": ViewOffset(forward: 0.17, down: 1.5, lateral: 0.25),
        "RouteMarker 2": routeMarker2Offset,
        "RouteMarker 3": routeMarker3Offset,
        "RouteMarker 4": ViewOffset(forward: 0, down: 1.78, lateral: 0),
        "RouteMarker 5": ViewOffset(forward: 0, down: 1.66, lateral: 0),
        "RouteMarker 6": ViewOffset(forward: 0, down: 1.64, lateral: 0),
        "Location_Living Room": livingRoomOffset,
        "Location_Dining Room": ViewOffset(forward: 0.20, down: 1.62, lateral: 0.0),
        "Location_Outdoor": outdoorOffset
    ]

    // Marker names differ between the Swift route tables and the USD prims
    // ("Location_Living Room" vs "Location_Living_Room"), so look up on a
    // normalized form rather than requiring an exact spelling.
    static func offset(for markerName: String) -> ViewOffset {
        if let exact = offsets[markerName] {
            return exact
        }

        let wanted = normalized(markerName)

        for (name, offset) in offsets where normalized(name) == wanted {
            return offset
        }

        return .zero
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // The viewer pose at a marker: the marker's own transform with its offset
    // applied in marker-local space.
    static func viewMatrix(
        markerMatrix: simd_float4x4,
        markerName: String
    ) -> simd_float4x4 {
        let offset = offset(for: markerName)

        guard !offset.isIdentity else {
            return markerMatrix
        }

        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4<Float>(offset.localTranslation, 1)

        return markerMatrix * translation
    }
}
