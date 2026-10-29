import RealityKit
import Combine
import UIKit
import ImageIO
import CoreImage
import simd
import Metal
import ARKit
import QuartzCore

/// Warm PBR finishes, window daylight, and room-specific environment lighting.
@MainActor
enum InteriorLightingManager {
    // A consistent 10% lift over the accepted 40% setting, for the whole session.
    // Applied once to direct lighting, environment probes and baked fill.
    static let radianceScale: Float = 0.44
    static let exposureOffset: Float = log2(radianceScale)
    // A small lift for the three indoor activity rooms only. Outdoor sun,
    // daylight probe, sky and shared structural fill retain their existing levels.
    private static let activityRoomBrightness: Float = 1.10
    private static let brighterActivityRooms: Set<String> = ["Bedroom", "Living", "Dining"]
    private static let brighterActivityFixtures: Set<String> = [
        "WindowDaylight_Bedroom", "WindowDaylight_Living", "WindowDaylight_Dining",
        "CeilingLight_LocationBedroom_Downlight", "CeilingLight_LocationLivingRoom_Downlight",
        "CeilingLight_LocationDiningRoom_Downlight"
    ]
    // Furniture indirect light uses the same secondary UVs as contact shadows.
    private static let furnitureIndirectBindings: [String: String] = {
        guard let url = Bundle.main.url(forResource: "REWindFurnitureIndirectBindings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let bindings = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return bindings
    }()
    private static let furnitureIndirectTextures: [String: TextureResource] = {
        var textures: [String: TextureResource] = [:]
        for room in ["Kitchen", "Living"] {
            if let url = Bundle.main.url(forResource: "REWind" + room + "FurnitureIndirect", withExtension: "png"),
               let texture = try? TextureResource.load(contentsOf: url, options: .init(semantic: .raw)) {
                textures[room] = texture
            }
        }
        return textures
    }()

    // The coffee table has its own contact UVs so removed props cannot leave atlas marks.
    private static let coffeeTableIndirectTexture: TextureResource? = {
        guard let url = Bundle.main.url(forResource: "REWindCoffeeTableIndirect", withExtension: "png") else { return nil }
        return try? TextureResource.load(contentsOf: url, options: .init(semantic: .raw))
    }()

    // Diffuse indirect lighting baked on the existing structural contact UVs.
    // Direct window light, material detail and fixture emission remain separate.
    private static let structuralIndirectTexture: TextureResource? = {
        guard let url = Bundle.main.url(forResource: "REWindStructureIndirect", withExtension: "png") else { return nil }
        do {
            return try TextureResource.load(contentsOf: url, options: .init(semantic: .raw))
        } catch {
            print("REWind indirect lighting unavailable: \(error)")
            return nil
        }
    }()

    // Remove baked chromatic spill only on the dedicated stair-plaster subset.
    // This runs once at loading; it adds no per-frame filter or extra light.
    private static let neutralStairIndirectTexture: TextureResource? = {
        guard let url = Bundle.main.url(forResource: "REWindStructureIndirect", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let neutral = neutralRoomImage(image, warmth: false, hdr: false) else { return nil }
        return try? TextureResource.generate(from: neutral, options: .init(semantic: .raw))
    }()

    /// Preserve luminance and directional shading while removing captured color spill.
    private static func neutralRoomImage(_ image: CGImage, warmth: Bool, hdr: Bool = true) -> CGImage? {
        let input = CIImage(cgImage: image, options: hdr ? [:] : [.colorSpace: NSNull()])
        let gray = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        ])
        // A restrained red/blue balance avoids yellow-green cream. All gains
        // are <= 1, so this does not increase the room's lighting exposure.
        let output = warmth ? gray.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.965, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.935, w: 0)
        ]) : gray
        // The PNG is a raw lighting map: keep its numeric luminance unchanged.
        let context = hdr ? CIContext() : CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        return context.createCGImage(output, from: input.extent, format: hdr ? .RGBAh : .RGBA8,
            colorSpace: hdr ? CGColorSpace(name: CGColorSpace.extendedLinearSRGB) : nil)
    }

    private static let ceilingIndirectTexture: TextureResource? = {
        guard let url = Bundle.main.url(forResource: "REWindCeilingIndirect", withExtension: "png") else { return nil }
        return try? TextureResource.load(contentsOf: url, options: .init(semantic: .raw))
    }()

    static func makeInteriorLighting() -> Entity {
        let root = Entity()
        root.name = "InteriorLighting"
        return root
    }

    /// Trim only the app-generated outdoor rig. Never traverse the imported house lights.
    static func keepMainSun(in entity: Entity) {
        guard entity.name == "OutdoorLighting" else { return }
        func trimGeneratedLights(_ node: Entity) {
            if node.name != "SunLight_Left" {
                node.components.remove(DirectionalLightComponent.self)
                node.components.remove(PointLightComponent.self)
                node.components.remove(SpotLightComponent.self)
            }
            for child in node.children { trimGeneratedLights(child) }
        }
        trimGeneratedLights(entity)
    }

    static func auditLights(in house: Entity) {
        #if DEBUG
        if let gpu = MTLCreateSystemDefaultDevice() {
            print("REWind GPU: \(gpu.name), expanded light capacity: \(gpu.supportsFamily(.apple6))")
        }
        var count = 0
        func visit(_ entity: Entity) {
            if entity.components.has(DirectionalLightComponent.self) || entity.components.has(PointLightComponent.self) || entity.components.has(SpotLightComponent.self) {
                count += 1
                let p = entity.position(relativeTo: house)
                let d = entity.convert(direction: SIMD3<Float>(0,0,-1), to: house)
                let intensity = entity.components[SpotLightComponent.self]?.intensity ?? entity.components[DirectionalLightComponent.self]?.intensity ?? 0
                print("REWind light audit: \(entity.name), intensity \(intensity), position \(p), direction \(d)")
            }
            for child in entity.children { visit(child) }
        }
        visit(house)
        print("REWind light audit: \(count) authored sources before device budget")
        #endif
    }

    /// Window and door frames remain daylight portals after opaque pane geometry is removed.
    private static let sourceOpeningMeshNames: Set<String> = ["Front_door", "Plane_192", "Plane_196", "Plane_200", "Plane_202", "Plane_203", "Plane_208", "Plane_209", "Plane_210", "Plane_237", "Plane_239", "Plane_244", "Plane_248", "Plane_255", "Plane_358"]

    private static func isSourceOpening(_ entity: Entity) -> Bool {
        guard sourceOpeningMeshNames.contains(entity.name) else { return false }
        var node: Entity? = entity
        while let current = node {
            let name = current.name.lowercased()
            if name.hasPrefix("window_frame") || name.hasPrefix("window_type")
                || name.hasPrefix("exterior_door") || name.hasPrefix("front_door") {
                return true
            }
            node = current.parent
        }
        return false
    }

    /// Warm structural paint while preserving imported textures and PBR detail.
    static func applyReferenceFinish(to entity: Entity, usesContactUV: Bool = false, parentPath: String = "") {
        let path = entity.name == "root" ? "/root" : parentPath + "/" + entity.name
        let isCeilingFixture = path.lowercased().contains("/ceiling_lamp") || path.lowercased().contains("/ceiling_spot")
        let furnitureRoom = usesContactUV && !isCeilingFixture ? furnitureIndirectBindings[path] : nil
        let furnitureIndirect = path == "/root/Coffee_table/Plane_299"
            ? coffeeTableIndirectTexture : furnitureRoom.flatMap { furnitureIndirectTextures[$0] }
        // Retain the imported ceiling lights at their authored brightness.
        if var fixture = entity.components[SpotLightComponent.self] {
            fixture.color = UIColor(red: 1, green: 0.93, blue: 0.83, alpha: 1)
            fixture.innerAngleInDegrees = min(fixture.innerAngleInDegrees, 10)
            fixture.outerAngleInDegrees = max(fixture.outerAngleInDegrees, 85)
            entity.components.set(fixture)
            var shadow = SpotLightComponent.Shadow()
            shadow.depthBias = 2.0
            entity.components.set(shadow)
        }
        if var model = entity.components[ModelComponent.self] {
            #if DEBUG
            if ["Plane_009", "Plane_029", "Plane_032", "Plane_231"].contains(entity.name) {
                print("REWind structural materials: \(entity.name): \(model.materials.map { ($0 as? PhysicallyBasedMaterial)?.name ?? "unnamed" })")
            }
            #endif
            // Keep source-opening materials intact: shader variants can change their imported names.
            let isGlazedOpening = isSourceOpening(entity) || model.materials.contains {
                (($0 as? PhysicallyBasedMaterial)?.name ?? "").split(separator: "/").last?.lowercased() == "glass"
            }
            model.materials = model.materials.map { original in
                guard var material = original as? PhysicallyBasedMaterial else { return original }
                let name = (material.name ?? "").split(separator: "/").last.map(String.init)?.lowercased() ?? ""
                #if DEBUG
                if name == "ceilinglightemission" {
                    print("REWind ceiling bulb: \(entity.name), emission intensity \(material.emissiveIntensity)")
                }
                #endif
                if ["blue_wood", "painted_drywall", "white_drywall", "stairwellneutralplaster"].contains(name) {
                    // Match wall and ceiling plaster; retain imported normal and roughness maps.
                    material.baseColor = .init(tint: UIColor(red: 0.94, green: 0.94, blue: 0.935, alpha: 1))
                }
                if name == "stairwellneutralplaster" {
                    // Only the stair-facing plaster subset: suppress the tinted
                    // grazing reflection without changing the house light field.
                    material.specular = .init(floatLiteral: 0.08)
                    material.roughness = .init(floatLiteral: 0.90)
                }
                if usesContactUV,
                   ["Plane_009", "Plane_029", "Plane_032", "Plane_231"].contains(entity.name),
                   name != "glass", name != "ceilinglightemission",
                   let indirect = structuralIndirectTexture {
                    // Ceiling white plaster uses the same neutral paint as the walls;
                    // its separate baked fill retains brightness without a beige cast.
                    let isCeilingPlaster = path.contains("/Interior_floors/") && name == "white_drywall"
                    let receiverIndirect = name == "stairwellneutralplaster"
                        ? (neutralStairIndirectTexture ?? indirect)
                        : (isCeilingPlaster ? (ceilingIndirectTexture ?? indirect) : indirect)
                    var map = MaterialParameters.Texture(receiverIndirect)
                    map.uvIndex = 1
                    material.emissiveColor = .init(texture: map)
                    material.emissiveIntensity = 0.35
                }
                // Dense fabric meshes need a higher-resolution bake; retain their existing shading.
                if let furnitureIndirect, !isGlazedOpening,
                   ["white_wood", "constructive_wood", "black_wood"].contains(name) {
                    var map = MaterialParameters.Texture(furnitureIndirect)
                    map.uvIndex = 1
                    material.emissiveColor = .init(texture: map)
                    material.emissiveIntensity = 0.35
                    // A thin satin finish over the imported grain and roughness.
                    if ["white_wood", "constructive_wood", "black_wood"].contains(name) {
                        material.clearcoat = .init(floatLiteral: 0.14)
                        material.clearcoatRoughness = .init(floatLiteral: 0.32)
                    }
                }
                // Only baked receivers have a secondary contact-shadow UV set.
                // Imported props retain their authored UV0 occlusion mapping.
                if usesContactUV,
                   (furnitureIndirectBindings[path] != nil || ["Plane_009", "Plane_029", "Plane_032", "Plane_231"].contains(entity.name)),
                   var occlusion = material.ambientOcclusion.texture {
                    occlusion.uvIndex = 1
                    material.ambientOcclusion.texture = occlusion
                }
                material.emissiveIntensity *= radianceScale
                return material
            }
            entity.components.set(model)
            if let furnitureRoom, furnitureIndirect != nil {
                print("REWind furniture indirect: \(furnitureRoom), \(path)")
            }
        }
        for child in entity.children { applyReferenceFinish(to: child, usesContactUV: usesContactUV, parentPath: path) }
    }

    /// Retain authored definitions and fixture geometry while allocating the
    /// simulator's limited real-time light slots to the viewer's current room.
    @MainActor
    final class LightBudget {
        // Outdoor lighting from the saved 9 October version, before Dad tests.
        // Keep it independent of the indoor sun so restoring the garden cannot
        // change the accepted light on the dining table or in other rooms.
        private static let restoredOutdoorSunIntensity: Float = 80_000 * 0.92 * InteriorLightingManager.radianceScale
        // Activity-only reduction; authored indoor and garden-travel lighting stay unchanged.
        private static let ballActivitySunIntensity = restoredOutdoorSunIntensity * 0.38
        private weak var house: Entity?
        private let worldTracking: WorldTrackingProvider?
        private var lights: [Entity] = []
        private var lightPositions: [ObjectIdentifier: SIMD3<Float>] = [:]
        private(set) var viewerHouseY: Float = 49
        private var authored: [ObjectIdentifier: (SpotLightComponent?, PointLightComponent?, DirectionalLightComponent?)] = [:]
        private var elapsed: Double = 1
        private var lastSelection: Set<ObjectIdentifier>?
        private var launchBedroomRanking: [Entity]?
        private var lastTrackedViewerPosition: SIMD3<Float>?
        private var stationaryViewerPosition: SIMD3<Float>?
        private var stationaryLightSelection: Set<ObjectIdentifier>?
        private var wasOutdoors = false
        private var wasPlayingBall = false
        private var requestedSunIntensity: Float?
        private var presentedSunIntensity: Float?
        private var sunTransition: (any Cancellable)?
        #if DEBUG
        private var reviewElapsed: Double = 0
        private var reviewIndex = 0
        #endif

        init(house: Entity, worldTracking: WorldTrackingProvider? = nil) {
            self.house = house
            self.worldTracking = worldTracking
            func collect(_ node: Entity) {
                // Startup-cached activity lights remain unmanaged, just like
                // props attached later; never restore them as house fixtures.
                if node.name.hasPrefix("REWindProps_") { return }
                if node.components.has(SpotLightComponent.self) || node.components.has(PointLightComponent.self) || node.components.has(DirectionalLightComponent.self) {
                    if var light = node.components[SpotLightComponent.self] {
                        let roomGain = InteriorLightingManager.brighterActivityFixtures.contains(node.name)
                            ? InteriorLightingManager.activityRoomBrightness : 1
                        light.intensity *= InteriorLightingManager.radianceScale * roomGain; node.components.set(light)
                    }
                    if var light = node.components[PointLightComponent.self] {
                        light.intensity *= InteriorLightingManager.radianceScale; node.components.set(light)
                    }
                    if var light = node.components[DirectionalLightComponent.self] {
                        light.intensity *= InteriorLightingManager.radianceScale; node.components.set(light)
                    }
                    lights.append(node)
                    lightPositions[ObjectIdentifier(node)] = node.position(relativeTo: house)
                    authored[ObjectIdentifier(node)] = (node.components[SpotLightComponent.self], node.components[PointLightComponent.self], node.components[DirectionalLightComponent.self])
                }
                for child in node.children { collect(child) }
            }
            collect(house)
            update(deltaTime: 1)
        }

        /// Restore launch lighting under the return cover, before Home appears.
        /// Clear the outdoor fade as well as its cached intensity so it cannot
        /// overwrite the indoor sun after the bedroom has been restored.
        func restoreBedroomLighting() {
            sunTransition?.cancel()
            sunTransition = nil
            if let sun = lights.first(where: { $0.name == "SunLight_Left" }),
               let original = authored[ObjectIdentifier(sun)]?.2 {
                sun.components.set(original)
                sun.components.set(DirectionalLightComponent.Shadow(maximumDistance: 30, depthBias: 2.0))
                requestedSunIntensity = original.intensity
                presentedSunIntensity = original.intensity
            }
            wasOutdoors = false
            wasPlayingBall = false
            stationaryViewerPosition = nil
            stationaryLightSelection = nil
            lastSelection = nil
            update(deltaTime: 1, holdViewerPosition: true)
            #if DEBUG
            print("REWind bedroom lighting restored: launch fixtures, sun \(presentedSunIntensity ?? -1)")
            #endif
        }

        private func fadeSun(_ sun: Entity, to target: Float) {
            guard requestedSunIntensity != target else { return }
            requestedSunIntensity = target
            sunTransition?.cancel()
            let start = sun.components[DirectionalLightComponent.self]?.intensity ?? target
            presentedSunIntensity = start
            guard abs(start - target) > 1, let scene = sun.scene else {
                sun.components[DirectionalLightComponent.self]?.intensity = target
                presentedSunIntensity = target
                return
            }
            let began = CACurrentMediaTime()
            sunTransition = scene.subscribe(to: SceneEvents.Update.self) { [weak self, weak sun] _ in
                guard let self, let sun else { return }
                let t = Float(min(1, (CACurrentMediaTime() - began) / 1.2))
                let smooth = t * t * (3 - 2 * t)
                let intensity = start + (target - start) * smooth
                self.presentedSunIntensity = intensity
                sun.components[DirectionalLightComponent.self]?.intensity = intensity
                if t >= 1 { self.sunTransition?.cancel(); self.sunTransition = nil }
            }
        }

        func update(deltaTime: Double, suppressStairwell: Bool = false, softenPlayingBall: Bool = false, atBallActivity: Bool = false, holdViewerPosition: Bool = false) {
            guard let house else { return }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--rewind-room=all") {
                reviewElapsed += deltaTime
                let reviewRooms = ["living", "bedroom", "dining", "kitchen", "hallway", "stairwell"]
                if reviewElapsed >= 45, reviewIndex + 1 < reviewRooms.count, let root = house.parent {
                    reviewElapsed = 0
                    reviewIndex += 1
                    _ = InteriorLightingManager.configureRoomReview(house: house, environmentRoot: root, requestedRoom: reviewRooms[reviewIndex])
                }
            }
            #endif
            elapsed += deltaTime
            guard elapsed >= 0.4 else { return }
            elapsed = 0
            #if DEBUG
            let inspectionEye: SIMD3<Float> = ProcessInfo.processInfo.arguments.contains("--rewind-room=all") ? .zero : SIMD3<Float>(0, 1.6, 0)
            #else
            let inspectionEye = SIMD3<Float>(0, 1.6, 0)
            #endif
            // Head AnchorEntity transforms are intentionally opaque. ARKit's
            // device anchor provides the actual viewer position, including the
            // simulator camera height and movement between floors.
            // Retain the last valid headset pose through brief tracking loss.
            // Falling back to the origin can incorrectly switch the garden
            // back to the much brighter indoor sun on a single missed sample.
            var viewerPosition = lastTrackedViewerPosition ?? inspectionEye
            if let worldTracking, worldTracking.state == .running,
               let device = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), device.isTracked {
                let translation = device.originFromAnchorTransform.columns.3
                viewerPosition = SIMD3<Float>(translation.x, translation.y, translation.z)
                lastTrackedViewerPosition = viewerPosition
            }
            let trackedEye = house.convert(position: viewerPosition, from: nil)
            // Keep every stationary experience on its arrival lighting. Small
            // head movements must not re-rank fixtures or change the room mode.
            // Release the reference while travelling so the next room is lit.
            var holdLighting = holdViewerPosition || atBallActivity
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--rewind-room=all") { holdLighting = false }
            #endif
            if holdLighting {
                if stationaryViewerPosition == nil { stationaryViewerPosition = trackedEye }
            } else {
                stationaryViewerPosition = nil
                stationaryLightSelection = nil
            }
            let eye = stationaryViewerPosition ?? trackedEye
            viewerHouseY = eye.y
            // Keep the activity stable even when the user leans near a room
            // boundary. Travel uses hysteresis so a small head movement cannot
            // repeatedly reverse the sun fade at the doorway.
            let outdoors = atBallActivity || eye.y < (wasOutdoors ? 36.3 : 35.7)
            let playingBall = outdoors && softenPlayingBall
            if outdoors != wasOutdoors || playingBall != wasPlayingBall,
               let sun = lights.first(where: { $0.name == "SunLight_Left" }),
               let light = authored[ObjectIdentifier(sun)]?.2 {
                let target = outdoors
                    ? (playingBall ? Self.ballActivitySunIntensity : Self.restoredOutdoorSunIntensity)
                    : light.intensity
                fadeSun(sun, to: target)
                // Restore the garden's original shadow coverage and bias only.
                // Indoor shadow settings are unchanged.
                sun.components.set(DirectionalLightComponent.Shadow(
                    maximumDistance: 30, depthBias: outdoors ? 0.15 : 2.0))
                if outdoors { OutdoorLightingManager.auditLeafPlayback() }
                wasOutdoors = outdoors
                wasPlayingBall = playingBall
                stationaryLightSelection = nil
                lastSelection = nil
            }
            let room: String
            if eye.z > 3.05 { room = eye.y > 46 ? "Bedroom" : "Stairwell" }
            else if eye.x > -1.5 { room = "Dining" }
            else if eye.y < 41.1 { room = "Living" }
            else if eye.y > 44.8 { room = "Kitchen" }
            else { room = "Stairwell" }
            let portalNames: Set<String>
            switch room {
            case "Living": portalNames = ["WindowDaylight_Living", "DoorDaylight_LivingPorchLeft", "DoorDaylight_LivingPorchRight"]
            case "Dining": portalNames = ["WindowDaylight_Dining", "DoorDaylight_Entrance"]
            case "Stairwell": portalNames = ["WindowDaylight_Stairwell", "DoorDaylight_Entrance"]
            default: portalNames = ["WindowDaylight_" + room]
            }
            // Always retain the active room's ceiling fixture, even when an
            // activity uses some of the eight shared dynamic-light slots.
            let roomCeiling: String
            switch room {
            case "Living": roomCeiling = "CeilingLight_LocationLivingRoom_Downlight"
            case "Dining": roomCeiling = "CeilingLight_LocationDiningRoom_Downlight"
            case "Bedroom": roomCeiling = "CeilingLight_LocationBedroom_Downlight"
            case "Kitchen": roomCeiling = "CeilingLight_RouteMarker5_Downlight"
            default: roomCeiling = "CeilingLight_RouteMarker4_Downlight"
            }
            let candidates = lights.filter { light in
                // Indoor portal/ceiling beams must not illuminate the garden or
                // swap slots behind Dad when the wearer moves their head.
                if outdoors { return light.name == "SunLight_Left" }
                // Entrance daylight also belongs to Dining. Entering an
                // activity must not remove a portal used by the current room.
                if light.name == roomCeiling || portalNames.contains(light.name) { return true }
                guard suppressStairwell, light.name != "SunLight_Left" else { return true }
                let position = lightPositions[ObjectIdentifier(light)] ?? .zero
                return light.name != "WindowDaylight_Stairwell"
                    && light.name != "DoorDaylight_Entrance"
                    && light.name != "CeilingLight_RouteMarker4_Downlight" && position.z <= 3.05
            }
            // Score each source once, using cached house-local positions rather
            // than recomputing hierarchy transforms inside the sort comparator.
            let scores = Dictionary(uniqueKeysWithValues: candidates.map { light in
                (ObjectIdentifier(light), score(light))
            })
            var ranked = candidates.sorted { scores[ObjectIdentifier($0), default: 1000] < scores[ObjectIdentifier($1), default: 1000] }
            if room == "Bedroom", !outdoors {
                if let launchBedroomRanking {
                    let eligible = Set(candidates.map(ObjectIdentifier.init))
                    ranked = launchBedroomRanking.filter { eligible.contains(ObjectIdentifier($0)) }
                } else {
                    // Reuse the launch selection on every return. The retention
                    // bias from a previous room must not alter Home's lighting.
                    launchBedroomRanking = ranked
                }
            }
            func score(_ light: Entity) -> Float {

                    if light.name == "SunLight_Left" { return -1000 }
                    if light.name == roomCeiling { return -750 }
                    if portalNames.contains(light.name) { return -500 }
                    if light.name.hasPrefix("WindowDaylight_") || light.name.hasPrefix("DoorDaylight_") { return 1000 }
                    let delta = (lightPositions[ObjectIdentifier(light)] ?? .zero) - eye
                    // Avoid swapping nearly equidistant fixtures on every small head movement.
                    let retention: Float = lastSelection?.contains(ObjectIdentifier(light)) == true ? 0.6 : 0
                    return simd_length(SIMD3<Float>(delta.x, delta.y, delta.z * 3)) - retention
            }
            // Activity lights are added after the house light list is captured.
            // Count every enabled unmanaged light, including props under the house.
            let query = EntityQuery(where: .has(SpotLightComponent.self) || .has(PointLightComponent.self) || .has(DirectionalLightComponent.self))
            let managedLights = Set(lights.map(ObjectIdentifier.init))
            let externalCount = house.scene?.performQuery(query).filter { entity in
                guard !managedLights.contains(ObjectIdentifier(entity)) else { return false }
                var ancestor: Entity? = entity
                while let node = ancestor {
                    if !node.isEnabled { return false }
                    ancestor = node.parent
                }
                return true
            }.count ?? 0
            let availableSlots = max(0, 8 - externalCount)
            // Hold the actual fixtures as well as the reference position.
            // Repeated updates or disappearing prop lights must not change the
            // room brightness while Home, an activity or completion is visible.
            // Only an increased external light count may require fewer fixtures
            // to respect the renderer's eight-light limit.
            let selected: Set<ObjectIdentifier>
            if holdLighting, let stationaryLightSelection,
               stationaryLightSelection.count <= availableSlots {
                selected = stationaryLightSelection
            } else {
                selected = Set(ranked.prefix(availableSlots).map(ObjectIdentifier.init))
            }
            if holdLighting { stationaryLightSelection = selected }
            guard selected != lastSelection else { return }
            let previousSelection = lastSelection
            lastSelection = selected
            for light in lights {
                let id = ObjectIdentifier(light)
                guard previousSelection == nil || selected.contains(id) != (previousSelection?.contains(id) ?? false) else { continue }
                if selected.contains(id), let saved = authored[id] {
                    if let value = saved.0 { light.components.set(value) }
                    if let value = saved.1 { light.components.set(value) }
                    if var value = saved.2 {
                        if light.name == "SunLight_Left", let presentedSunIntensity {
                            value.intensity = presentedSunIntensity
                        }
                        light.components.set(value)
                    }
                } else {
                    // Keep definitions in authored; release only the renderer slot.
                    light.components.remove(SpotLightComponent.self)
                    light.components.remove(PointLightComponent.self)
                    light.components.remove(DirectionalLightComponent.self)
                }
            }
            print("REWind light budget: \(room), eye \(eye), \(availableSlots)/\(lights.count) allocated, \(externalCount) external lights: \(lights.filter { selected.contains(ObjectIdentifier($0)) }.map(\.name))")
        }
    }

    struct Room {
        let name: String
        let window: SIMD3<Float>
        let inward: SIMD3<Float>
        let target: SIMD3<Float>
        let lumens: Float
        let radius: Float
        var sourceLift: Float = 0.15
        var beamSetback: Float = 0
        let reviewFloor: SIMD3<Float>
        let reviewTarget: SIMD3<Float>
    }

    // Measured pane centers in the imported Z-up house. The bedroom's north
    // side-wall window replaces the previous pair on the bed-head wall.
    static let rooms: [Room] = [
        Room(name: "Bedroom", window: [-7, 52.29, 4.50], inward: [0, -1, 0],
             target: [-8.4, 49.45, 3.55], lumens: 600_000, radius: 8, beamSetback: 1.4,
             reviewFloor: [-6.0, 47.0, 3.1], reviewTarget: [-8.7, 49.0, 3.1]),
        Room(name: "Living", window: [-1.94, 38.89, 1.97], inward: [-1, 0, 0],
             target: [-3.95, 39.5, 0.12], lumens: 295_000, radius: 9, beamSetback: 0.7,
             reviewFloor: [-6.5, 38, 0], reviewTarget: [-2.5, 39, 0]),
        Room(name: "Kitchen", window: [-4.55, 53.32, 1.97], inward: [0, -1, 0],
             target: [-6, 46.5, 0.8], lumens: 180_000, radius: 12,
             reviewFloor: [-3.3, 48.5, 0], reviewTarget: [-6.3, 45.8, 0]),
        Room(name: "Dining", window: [4.402, 47.377, 1.278], inward: [-1, 0, 0],
             // Restore the 15 October table daylight, before the Dad tests.
             target: [1.62, 47.5, 0.842], lumens: 90_000, radius: 9, sourceLift: 0.75, beamSetback: 0.15,
             reviewFloor: [0.46, 47.55, 0], reviewTarget: [3.6, 48.5, 0]),
        Room(name: "Stairwell", window: [-1.94, 41.65, 4.52], inward: [-1, 0, 0],
             target: [-5.8, 41.5, 1.05], lumens: 450_000, radius: 11,
             reviewFloor: [-4.1, 41.5, 0.1], reviewTarget: [-7, 41.5, 0.1])
    ]

    static func addWindowDaylight(to house: Entity) {
        let group = Entity()
        group.name = "RoomWindowDaylight"
        var panes: [(Entity, SIMD3<Float>)] = []
        func visit(_ entity: Entity) {
            if let model = entity.components[ModelComponent.self] {
                let names = model.materials.compactMap { ($0 as? PhysicallyBasedMaterial)?.name?.split(separator: "/").last.map(String.init)?.lowercased() }
                if isSourceOpening(entity) && names.contains("white_wood") {
                    entity.components.set(DynamicLightShadowComponent(castsShadow: false))
                    panes.append((entity, entity.visualBounds(relativeTo: house).center))
                }
            }
            for child in entity.children { visit(child) }
        }
        visit(house)
        house.addChild(group)
        for room in rooms {
            guard let pane = panes.min(by: { simd_distance($0.1, room.window) < simd_distance($1.1, room.window) }),
                  simd_distance(pane.1, room.window) < 0.25 else {
                print("REWind daylight: missing audited window for \(room.name)")
                continue
            }
            let portalInset: Float = room.name == "Living" ? 0 : 0.30
            let portal = pane.1 + room.inward * portalInset + SIMD3<Float>(0, 0, room.sourceLift)
            let distance = simd_distance(portal, room.target)
            let source = portal - simd_normalize(room.target - portal) * room.beamSetback
            let reachCompensation = pow((distance + room.beamSetback) / distance, 2)
            let light = Entity()
            light.name = "WindowDaylight_" + room.name
            group.addChild(light)
            light.look(at: room.target, from: source, upVector: [0, 0, 1], relativeTo: house)
            light.components.set(SpotLightComponent(
                // Slight golden warmth throughout the rooms; retain output and falloff.
                color: room.name == "Bedroom"
                    ? .init(red: 1, green: 0.89, blue: 0.82, alpha: 1)
                    : (room.name == "Stairwell"
                        ? .init(red: 0.94, green: 0.93, blue: 0.91, alpha: 1)
                        : .init(red: 1, green: 0.92, blue: 0.80, alpha: 1)),
                intensity: room.lumens * reachCompensation,
                innerAngleInDegrees: room.name == "Stairwell" ? 16 : (room.name == "Dining" ? 10 : 22),
                outerAngleInDegrees: room.name == "Stairwell" ? 32 : (room.name == "Dining" ? 42 : (room.name == "Living" ? 56 : 48)), attenuationRadius: room.radius + room.beamSetback
            ))
            #if DEBUG
            if !ProcessInfo.processInfo.arguments.contains("--rewind-direct-only") {
                var shadow = SpotLightComponent.Shadow()
                shadow.depthBias = 1.0
                light.components.set(shadow)
            }
            #else
            var shadow = SpotLightComponent.Shadow()
                shadow.depthBias = 1.0
                light.components.set(shadow)
            #endif
            print("REWind daylight: \(room.name) window \(pane.1), inward \(room.inward)")
        }
        // Audited glass entrance and the paired living-room doors to the west porch.
        // Aim the entrance beam through the glazing toward the stair treads.
        let doorPortals: [(String, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, Float)] = [
            ("Entrance", [-0.645, 42.104, 1.191], [-1, 0, 0], [-6.15, 41.5, 1.4], 350_000),
            ("LivingPorchLeft", [-10.519, 37.705, 1.211], [1, 0, 0], [-6.9, 39.2, 0.15], 40_000),
            ("LivingPorchRight", [-10.522, 38.662, 1.211], [1, 0, 0], [-6.7, 40, 0.15], 40_000)
        ]
        for (name, center, inward, target, intensity) in doorPortals {
            guard let pane = panes.min(by: { simd_distance($0.1, center) < simd_distance($1.1, center) }),
                  simd_distance(pane.1, center) < 0.1 else {
                print("REWind daylight: missing audited door for \(name)")
                continue
            }
            let light = Entity()
            light.name = "DoorDaylight_" + name
            group.addChild(light)
            let portal = pane.1 + inward * 0.30 + SIMD3<Float>(0, 0, 0.75)
            let setback: Float = name == "Entrance" ? 1.8 : 0
            let distance = simd_distance(portal, target)
            let source = portal - simd_normalize(target - portal) * setback
            let reachCompensation = pow((distance + setback) / distance, 2)
            light.look(at: target, from: source, upVector: [0, 0, 1], relativeTo: house)
            light.components.set(SpotLightComponent(color: name == "Entrance"
                ? .init(red: 0.94, green: 0.93, blue: 0.91, alpha: 1)
                : .init(red: 1, green: 0.92, blue: 0.80, alpha: 1),
                intensity: intensity * reachCompensation,
                innerAngleInDegrees: name == "Entrance" ? 14 : 25,
                outerAngleInDegrees: name == "Entrance" ? 30 : 60, attenuationRadius: 8 + setback))
            #if DEBUG
            if !ProcessInfo.processInfo.arguments.contains("--rewind-direct-only") {
                var shadow = SpotLightComponent.Shadow()
                shadow.depthBias = 1.0
                light.components.set(shadow)
            }
            #else
            var shadow = SpotLightComponent.Shadow()
                shadow.depthBias = 1.0
                light.components.set(shadow)
            #endif
            print("REWind daylight: \(name) door \(pane.1), inward \(inward)")
        }
    }

    /// Local room captures supply static indoor reflections and soft diffuse fill.
    static func applyRoomProbes(to house: Entity, daylight: EnvironmentResource?) async {
        var probes: [String: Entity] = [:]
        var structuralProbes: [String: Entity] = [:]
        var sourceWindowProbes: [String: Entity] = [:]
        for room in rooms {
            let resourceName = "REWind" + room.name
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: "hdr"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                print("REWind probe: missing \(resourceName); retaining daylight")
                continue
            }
            do {
                let correctedImage = ["Bedroom", "Stairwell"].contains(room.name)
                    ? (neutralRoomImage(image, warmth: room.name == "Bedroom") ?? image) : image
                let environment = try await EnvironmentResource(equirectangular: correctedImage, withName: resourceName)
                let probe = Entity()
                probe.name = room.name + "InteriorReflectionProbe"
                probe.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
                // Neutral daylight balances the warm room capture without introducing blue sky.
                let source: ImageBasedLightComponent.Source = daylight.map { .blend(environment, $0, 0.90) } ?? .single(environment)
                #if DEBUG
                let diagnosticDirectOnly = ProcessInfo.processInfo.arguments.contains("--rewind-direct-only")
                #else
                let diagnosticDirectOnly = false
                #endif
                let roomExposure = exposureOffset + (brighterActivityRooms.contains(room.name) ? log2(activityRoomBrightness) : 0)
                var light = ImageBasedLightComponent(source: source, intensityExponent: diagnosticDirectOnly ? -12 : -0.65 + roomExposure)
                light.inheritsRotation = true
                probe.components.set(light)
                house.addChild(probe)
                probes[room.name] = probe
                // A restrained structural fill leaves room for direct sunlight and contact shading.
                let structuralProbe = Entity()
                structuralProbe.name = room.name + "StructuralReflectionProbe"
                structuralProbe.orientation = probe.orientation
                var structuralLight = ImageBasedLightComponent(source: source, intensityExponent: diagnosticDirectOnly ? -12 : (structuralIndirectTexture == nil ? 1.45 : 0.15) + exposureOffset)
                structuralLight.inheritsRotation = true
                structuralProbe.components.set(structuralLight)
                house.addChild(structuralProbe)
                structuralProbes[room.name] = structuralProbe
                if ["Living", "Bedroom", "Dining", "Stairwell"].contains(room.name) {
                    // Sky bounce on the source-window trim, without adding a dynamic light
                    // or changing the materials or the accepted sunlight patch.
                    let windowProbe = Entity()
                    windowProbe.name = room.name + "SourceWindowReflectionProbe"
                    windowProbe.orientation = probe.orientation
                    var windowLight = ImageBasedLightComponent(source: source, intensityExponent: diagnosticDirectOnly ? -12 : 2.2 + exposureOffset)
                    windowLight.inheritsRotation = true
                    windowProbe.components.set(windowLight)
                    house.addChild(windowProbe)
                    sourceWindowProbes[room.name] = windowProbe
                }
            } catch {
                print("REWind probe: \(resourceName): \(error)")
            }
        }
        var counts: [String: Int] = [:]
        func visit(_ entity: Entity) {
            if let model = entity.components[ModelComponent.self] {
                let b = entity.visualBounds(relativeTo: house)
                let c = b.center
                let sharedStructure = b.extents.x > 12 || b.extents.y > 15
                let interior = c.x > -10.7 && c.x < 4.9 && c.y > 34.6 && c.y < 53.5 && c.z > -0.1 && c.z < 8.5
                // Large shared floor/wall meshes retain the whole-house daylight
                // environment; individual furniture receives its local room capture.
                if (["Plane_009", "Plane_029", "Plane_032", "Plane_231"].contains(entity.name) || (interior && sharedStructure)), let probe = structuralProbes["Living"] {
                    // These meshes span multiple rooms: neutral indoor fill avoids
                    // applying blue outdoor sky reflections to all floors and walls.
                    entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: probe))
                } else if interior && !sharedStructure {
                    let name: String
                    if entity.name.lowercased().contains("stair") { name = "Stairwell" }
                    else if c.z > 3.05 { name = c.y > 46 ? "Bedroom" : "Stairwell" }
                    else if c.x > -4.2 && c.x < -1.5 && c.y > 40.5 && c.y < 44.8 { name = "Stairwell" }
                    else if c.x > -1.5 { name = "Dining" }
                    else if c.y < 42.25 { name = "Living" }
                    else { name = "Kitchen" }
                    let isPaintedStructure = model.materials.contains { material in
                        guard let pbr = material as? PhysicallyBasedMaterial else { return false }
                        let materialName = (pbr.name ?? "").split(separator: "/").last.map(String.init)?.lowercased() ?? ""
                        return ["white_drywall", "painted_drywall", "blue_wood"].contains(materialName)
                    }
                    if let probe = isPaintedStructure ? structuralProbes[name] : probes[name] {
                        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: probe))
                        counts[name, default: 0] += 1
                    }
                }
                let materialNames = model.materials.compactMap { ($0 as? PhysicallyBasedMaterial)?.name?.split(separator: "/").last.map(String.init)?.lowercased() }
                if isSourceOpening(entity), materialNames.contains("white_wood") {
                    let sourceRoom: String?
                    if c.x > -2.1 && c.x < -1.8 && c.y > 36.5 && c.y < 40.5 && c.z < 3 {
                        sourceRoom = "Living"
                    } else if simd_distance(c, SIMD3<Float>(-0.645, 42.104, 1.191)) < 0.15 {
                        sourceRoom = "Stairwell"
                    } else {
                        sourceRoom = rooms.first(where: { simd_distance(c, $0.window) < 0.25 })?.name
                    }
                    if let sourceRoom, let windowProbe = sourceWindowProbes[sourceRoom] {
                        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: windowProbe))
                        print("REWind source-opening bounce: \(sourceRoom), \(entity.name)")
                    }
                }
            }
            for child in entity.children { visit(child) }
        }
        visit(house)
        print("REWind room probes: \(counts)")
    }

    #if DEBUG
    static func configureRoomReview(house: Entity, environmentRoot: Entity, requestedRoom: String? = nil) -> Bool {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--rewind-room=") }) else { return false }
        let selection = requestedRoom ?? argument.dropFirst("--rewind-room=".count).lowercased()
        let requested = selection == "all" ? "living" : selection
        let hallway = Room(name: "Hallway", window: .zero, inward: .zero, target: .zero,
                           lumens: 0, radius: 0, reviewFloor: [-2.85, 42.47, 0], reviewTarget: [-3.2, 40, 0])
        guard let room = requested == "hallway" ? hallway : rooms.first(where: { $0.name.lowercased() == requested }) else { return false }
        let viewpoint = Entity()
        house.addChild(viewpoint)
        viewpoint.look(at: room.reviewTarget, from: room.reviewFloor, upVector: [0, 0, 1], relativeTo: house)
        let view = viewpoint.transformMatrix(relativeTo: environmentRoot)
        viewpoint.removeFromParent()
        environmentRoot.setTransformMatrix(simd_inverse(view), relativeTo: environmentRoot.parent)
        print("REWind room review: \(room.name)")
        return true
    }
    #endif
}


// Exact-material batching reduces render-server encoding work without removing
// geometry or changing either UV set. Keep spatial chunks small for culling.
extension InteriorLightingManager {
    private struct BatchSemantic<T>: MeshBufferSemantic {
        typealias Element = T
        let id: MeshBuffers.Identifier
    }
    private struct BatchSource {
        let entity: Entity
        let part: MeshResource.Part
        let transform: simd_float4x4
        let material: any Material
    }
    static func batchStaticGeometry(in house: Entity) async {
        var groups: [String: [BatchSource]] = [:]
        var inspectedParts = 0
        var eligibleParts = 0
        var entities: [String: Entity] = [:]
        func index(_ node: Entity, path: String) {
            let key = path.isEmpty ? node.name : path + "/" + node.name
            entities[key.split(separator: "/").suffix(2).joined(separator: "/")] = node
            for child in node.children { index(child, path: key) }
        }
        for child in house.children { index(child, path: "") }
        var signatures: [String: [String: String]] = [:]
        for line in staticMaterialManifest.split(separator: "\n") {
            let fields = line.split(separator: "=")
            let binding = fields[0].split(separator: "|")
            guard fields.count == 2, binding.count == 2 else { continue }
            signatures[String(binding[0]), default: [:]][String(binding[1])] = String(fields[1])
        }
        for (path, materials) in signatures {
            let names = path.split(separator: "/").map(String.init)
            guard names.count == 2, !names[0].hasPrefix("Interior_door"),
                  !names[0].hasPrefix("Node_"),
                  !["Counter_top_001", "Dining_table", "Bed_blanket_002", "Coffee_table", "Leather_chair", "Leather_chair_002", "Leather_chair_006"].contains(names[0]),
                  let entity = entities[path], let parent = entity.parent, entity.isEnabled,
                  entity.availableAnimations.isEmpty, parent.availableAnimations.isEmpty,
                  !entity.components.has(InputTargetComponent.self),
                  !entity.components.has(CollisionComponent.self),
                  let model = entity.components[ModelComponent.self],
                  model.materials.allSatisfy({ $0 is PhysicallyBasedMaterial }) else { continue }
            let contents = model.mesh.contents
            guard contents.skeletons.isEmpty, contents.instances.count == 1,
                  let instance = contents.instances.first,
                  let meshModel = contents.models[instance.model] else { continue }
            let centre = entity.visualBounds(relativeTo: house).center
            let probe = entity.components[ImageBasedLightReceiverComponent.self]?.imageBasedLight.name ?? "inherited"
            let indirect = names[0].hasPrefix("Ceiling_") ? "none" : (furnitureIndirectBindings["/root/" + path] ?? "none")
            let shadow = entity.components[DynamicLightShadowComponent.self]?.castsShadow ?? true
            var eligible: [(String, BatchSource)] = []
            for part in meshModel.parts {
                inspectedParts += 1
                let vertices = part.positions.count
                guard model.materials.indices.contains(part.materialIndex),
                      let material = model.materials[part.materialIndex] as? PhysicallyBasedMaterial,
                      let name = material.name?.split(separator: "/").last.map(String.init),
                      let signature = materials[name], part.blendShapeNames.isEmpty,
                      batchIndices(part) != nil, vertices > 0,
                      part.buffers.allSatisfy({ id, buffer in
                          if id == .triangleIndices || id.name.hasPrefix("original") { return true }
                          return !id.isBlendShape && buffer.rate == .vertex && buffer.count == vertices
                              && (buffer.get(SIMD2<Float>.self) != nil || buffer.get(SIMD3<Float>.self) != nil || buffer.get(SIMD4<Float>.self) != nil || buffer.get(UInt32.self) != nil)
                      }) else { continue }
                // Transparent surfaces keep their original sorting and bounds.
                if case .transparent = material.blending { continue }
                // Bulbs retain their entities; static fixture housings can share draws.
                if name.lowercased() == "ceilinglightemission" { continue }
                eligibleParts += 1
                let layout = part.buffers.keys.filter { !$0.name.hasPrefix("original") }.map(\.name).sorted().joined(separator: ",")
                // The same finish can cover both a closed solid and a thin sheet.
                // Preserve their distinct face-culling policies when combining parts.
                let fixture = names[0].hasPrefix("Ceiling_")
                let key = "\(signature)|\(fixture)|\(material.faceCulling)|\(probe)|\(indirect)|\(shadow)|\(Int(floor(centre.x / 4)))|\(Int(floor(centre.y / 4)))|\(Int(floor(centre.z / 3)))|\(layout)"
                eligible.append((key, BatchSource(entity: entity, part: part,
                    transform: entity.transformMatrix(relativeTo: house) * instance.transform, material: material)))
            }
            // Unmerged parts remain on their original model, with the original
            // material indices and buffers. One unique material need not prevent
            // the shared opaque parts of an object from being batched.
            guard !eligible.isEmpty else { continue }
            for (key, source) in eligible { groups[key, default: []].append(source) }
        }
        groups = groups.filter { $0.value.count > 1 }
        var originals = 0, batches = 0, triangles = 0
        var preparedBatches: [ModelEntity] = []
        var replaced: [ObjectIdentifier: Entity] = [:]
        var replacedParts: [ObjectIdentifier: Set<String>] = [:]
        for key in groups.keys.sorted() {
            guard let sources = groups[key], let first = sources.first else { continue }
            var merged = MeshResource.Part(id: "static", materialIndex: 0)
            var indices: [UInt32] = []
            var offset: UInt32 = 0
            for source in sources {
                var sourceIndices = batchIndices(source.part)!
                let m = source.transform
                let linear = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                    SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z), SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
                if simd_determinant(linear) < 0 {
                    for i in stride(from: 0, to: sourceIndices.count, by: 3) { sourceIndices.swapAt(i + 1, i + 2) }
                }
                indices.append(contentsOf: sourceIndices.map { $0 + offset })
                offset += UInt32(source.part.positions.count)
            }
            for id in first.part.buffers.keys where id != .triangleIndices && !id.name.hasPrefix("original") {
                if first.part.buffers[id]?.get(SIMD2<Float>.self) != nil {
                    let values = sources.flatMap { $0.part.buffers[id]!.get(SIMD2<Float>.self)!.elements }
                    merged[BatchSemantic<SIMD2<Float>>(id: id)] = MeshBuffer(values)
                } else if first.part.buffers[id]?.get(SIMD4<Float>.self) != nil {
                    var values: [SIMD4<Float>] = []
                    for source in sources {
                        let m = source.transform
                        let linear = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z), SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
                        values.append(contentsOf: source.part.buffers[id]!.get(SIMD4<Float>.self)!.elements.map { value in
                            guard id == .tangents else { return value }
                            let direction = simd_normalize(linear * SIMD3(value.x, value.y, value.z))
                            return SIMD4(direction, value.w * (simd_determinant(linear) < 0 ? -1 : 1))
                        })
                    }
                    merged[BatchSemantic<SIMD4<Float>>(id: id)] = MeshBuffer(values)
                } else if first.part.buffers[id]?.get(UInt32.self) != nil {
                    let values = sources.flatMap { $0.part.buffers[id]!.get(UInt32.self)!.elements }
                    merged[BatchSemantic<UInt32>(id: id)] = MeshBuffer(values)
                } else {
                    var values: [SIMD3<Float>] = []
                    for source in sources {
                        let m = source.transform
                        let linear = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z), SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
                        let normalMatrix = simd_transpose(simd_inverse(linear))
                        values.append(contentsOf: source.part.buffers[id]!.get(SIMD3<Float>.self)!.elements.map { value in
                            if id == .positions || id.name == "points" { let v = m * SIMD4(value, 1); return SIMD3(v.x, v.y, v.z) }
                            if id == .normals || id.name == "normals" { return simd_normalize(normalMatrix * value) }
                            if id == .tangents || id == .bitangents { return simd_normalize(linear * value) }
                            return value
                        })
                    }
                    merged[BatchSemantic<SIMD3<Float>>(id: id)] = MeshBuffer(values)
                }
            }
            merged.triangleIndices = MeshBuffer(indices)
            var contents = MeshResource.Contents()
            contents.models = .init([.init(id: "static", parts: [merged])])
            contents.instances = .init([.init(id: "static", model: "static")])
            do {
                let mesh = try await MeshResource(from: contents)
                let batch = ModelEntity(mesh: mesh, materials: [first.material])
                batch.name = "StaticBatch_\(batches)"
                if let receiver = first.entity.components[ImageBasedLightReceiverComponent.self] { batch.components.set(receiver) }
                if let shadow = first.entity.components[DynamicLightShadowComponent.self] { batch.components.set(shadow) }
                preparedBatches.append(batch)
                for source in sources {
                    let id = ObjectIdentifier(source.entity)
                    replaced[id] = source.entity
                    replacedParts[id, default: []].insert(source.part.id)
                }
                originals += sources.count; batches += 1; triangles += indices.count / 3
            } catch {
                // Prepare every replacement before committing any of them.
                print("Static batching retained all originals: \(error)")
                return
            }
            await Task.yield()
        }
        // Prepare retained submeshes before changing the live scene. If any
        // rebuild fails, every original model remains intact.
        var retainedModels: [ObjectIdentifier: ModelComponent] = [:]
        do {
            for (id, entity) in replaced {
                guard var model = entity.components[ModelComponent.self],
                      let instance = model.mesh.contents.instances.first,
                      var sourceModel = model.mesh.contents.models[instance.model] else { continue }
                let remaining = sourceModel.parts.filter { !(replacedParts[id]?.contains($0.id) ?? false) }
                if !remaining.isEmpty {
                    sourceModel.parts = .init(remaining)
                    var contents = model.mesh.contents
                    contents.models = .init([sourceModel])
                    model.mesh = try await MeshResource(from: contents)
                    retainedModels[id] = model
                }
            }
        } catch {
            print("Static batching retained all originals: \(error)")
            return
        }
        for batch in preparedBatches { house.addChild(batch) }
        for (id, entity) in replaced {
            if let model = retainedModels[id] { entity.components.set(model) }
            else { entity.components.remove(ModelComponent.self) }
        }
        print("REWind static batching: \(originals) material parts -> \(batches) batches; \(triangles) triangles preserved; \(eligibleParts)/\(inspectedParts) parts eligible")
    }
    private static func batchIndices(_ part: MeshResource.Part) -> [UInt32]? {
        if let indices = part.buffers[.triangleIndices]?.get(UInt32.self) { return indices.elements }
        return part.buffers[.triangleIndices]?.get(UInt16.self)?.elements.map(UInt32.init)
    }
    private static let staticMaterialManifest = """
Art/Circle_002|Glossy_white=68dab8d5ccc98739
Art_001/Circle_003|Glossy_yellow=f26a33f1348cfcf2
Art_002/Circle_002|Glossy_white=9e6d5f568f36688d
Art_003/Circle_002|Glossy_white=9e6d5f568f36688d
Art_004/Circle_003|Glossy_yellow=10b3696cf22a74ec
Art_005/Circle_002|Glossy_white=9c5dbef8ffb54e1e
Art_006/Circle_020|Glossy_white=68dab8d5ccc98739
Art_007/Circle_003|Glossy_yellow=10b3696cf22a74ec
Art_008/Circle_023|Glossy_white=9c5dbef8ffb54e1e
Art_009/Circle_002|Glossy_white=9c5dbef8ffb54e1e
Art_010/Circle_002|Glossy_white=68dab8d5ccc98739
Art_011/Circle_003|Glossy_yellow=cdc055870fbc5593
Art_012/Circle_020|Glossy_white=9c5dbef8ffb54e1e
Art_013/Circle_002|Glossy_white=9c5dbef8ffb54e1e
Art_014/Circle_003|Glossy_yellow=10b3696cf22a74ec
Art_015/Circle_020|Glossy_white=fa5d6b9fcc35e91d
Art_016/Circle_003|Glossy_yellow=cdc055870fbc5593
Art_017/Circle_023|Glossy_white=68dab8d5ccc98739
Art_018/Circle_003|Glossy_yellow=925fa35abc2bf173
Art_019/Circle_002|Glossy_white=9c5dbef8ffb54e1e
Art_020/Circle_003|Glossy_yellow=10b3696cf22a74ec
Art_021/Circle_020|Glossy_white=9c5dbef8ffb54e1e
Art_022/Circle_002|Glossy_white=9c5dbef8ffb54e1e
Art_023/Circle_003|Glossy_yellow=d0e9b539bb47d0ce
Art_024/Circle_020|Glossy_white=68dab8d5ccc98739
Art_025/Circle_002|Glossy_white=9c5dbef8ffb54e1e
Art_026/Circle_002|Glossy_white=f3b22091b1df207d
Art_027/Circle_002|Glossy_white=f3b22091b1df207d
Art_028/Circle_003|Glossy_yellow=d0e9b539bb47d0ce
Art_029/Circle_002|Glossy_white=f3b22091b1df207d
Art_030/Circle_003|Glossy_yellow=d0e9b539bb47d0ce
Art_031/Circle_002|Glossy_white=710687e7f1406be0
Art_032/Circle_002|Glossy_white=f3b22091b1df207d
Art_033/Circle_003|Glossy_yellow=9d78d7922c035937
Art_034/Circle_002|Glossy_white=f3b22091b1df207d
Art_035/Circle_003|Glossy_yellow=9d78d7922c035937
Art_036/Circle_002|Glossy_white=68dab8d5ccc98739
Art_037/Circle_002|Glossy_white=fa5d6b9fcc35e91d
Art_038/Circle_003|Glossy_yellow=925fa35abc2bf173
Art_039/Circle_003|Glossy_yellow=925fa35abc2bf173
Art_040/Circle_023|Glossy_white=fa5d6b9fcc35e91d
Art_041/Circle_023|Glossy_white=fa5d6b9fcc35e91d
Art_042/Circle_020|Glossy_white=68dab8d5ccc98739
Art_043/Circle_002|Glossy_white=710687e7f1406be0
Art_044/Circle_003|Glossy_yellow=9d78d7922c035937
Art_045/Circle_020|Glossy_white=710687e7f1406be0
Art_046/Circle_003|Glossy_yellow=9d78d7922c035937
Art_047/Circle_023|Glossy_white=710687e7f1406be0
Art_048/Circle_002|Glossy_white=710687e7f1406be0
Art_049/Circle_003|Glossy_yellow=9d78d7922c035937
Art_050/Circle_020|Glossy_white=710687e7f1406be0
Art_051/Circle_003|Glossy_yellow=d0e9b539bb47d0ce
Art_052/Circle_003|Glossy_yellow=f26a33f1348cfcf2
Art_053/Circle_002|Glossy_white=9e6d5f568f36688d
Art_054/Circle_002|Glossy_white=fa5d6b9fcc35e91d
Art_055/Circle_002|Glossy_white=f3b22091b1df207d
Art_056/Circle_002|Glossy_white=710687e7f1406be0
Art_057/Circle_002|Glossy_white=f3b22091b1df207d
Art_058/Circle_002|Glossy_white=fa5d6b9fcc35e91d
Art_059/Circle_002|Glossy_white=fa5d6b9fcc35e91d
Art_060/Circle_002|Glossy_white=68dab8d5ccc98739
Art_061/Circle_002|Glossy_white=fa5d6b9fcc35e91d
Art_062/Circle_002|Glossy_white=fa5d6b9fcc35e91d
Bed/Plane_291|Constructive_wood=de13716e2fe56c8e
Bed/Plane_291|White_fabric=080cfd46765968f8
Bed_001/Plane_277|White_fabric=c91ce2753bd70a02
Bed_002/Plane_291|Constructive_wood=77e89426cea78717
Bed_002/Plane_291|White_fabric=ba23e7496f9779ea
Bed_003/Plane_277|White_fabric=ba23e7496f9779ea
Bed_004/Plane_291|Constructive_wood=faaa8e22b59aea72
Bed_004/Plane_291|White_fabric=ca8199574a8ae2fb
Bed_005/Plane_277|White_fabric=ca8199574a8ae2fb
Bed_006/Plane_291|Constructive_wood=77e89426cea78717
Bed_006/Plane_291|White_fabric=ba23e7496f9779ea
Bed_007/Plane_277|White_fabric=ba23e7496f9779ea
Bed_blanket/Plane_310|Fabric=4c8e805710536c5b
Bed_blanket_001/Plane_310|Fabric=97f477601b2536fe
Bed_blanket_002/Plane_310|Fabric=efc540e07fa27834
Bed_blanket_003/Plane_310|Fabric=97f477601b2536fe
Bedside_table/Plane_316|Constructive_wood=de13716e2fe56c8e
Bedside_table/Plane_316|Dark_metal=aa0066d682ec57b3
Bedside_table_001/Plane_316|Constructive_wood=cb7bb70b4cb7fecc
Bedside_table_001/Plane_316|Dark_metal=4a3dbebe6a54a505
Bedside_table_002/Plane_316|Constructive_wood=77e89426cea78717
Bedside_table_002/Plane_316|Dark_metal=6d06e5e1ca46a044
Bedside_table_003/Plane_316|Constructive_wood=77e89426cea78717
Bedside_table_003/Plane_316|Dark_metal=6d06e5e1ca46a044
Bedside_table_004/Plane_316|Constructive_wood=faaa8e22b59aea72
Bedside_table_004/Plane_316|Dark_metal=a2a72064cfaf0b41
Bedside_table_005/Plane_316|Constructive_wood=faaa8e22b59aea72
Bedside_table_005/Plane_316|Dark_metal=a2a72064cfaf0b41
Bedside_table_006/Plane_316|Constructive_wood=77e89426cea78717
Bedside_table_006/Plane_316|Dark_metal=6d06e5e1ca46a044
Bedside_table_007/Plane_316|Constructive_wood=77e89426cea78717
Bedside_table_007/Plane_316|Dark_metal=6d06e5e1ca46a044
Brealfast_table/Plane_302|Constructive_wood=cb7bb70b4cb7fecc
Brealfast_table/Plane_302|Dark_metal=4a3dbebe6a54a505
Brealfast_table/Plane_302|White_wood=6ee6cf8f714c26e5
Cabinet/Plane_306|Blue_wood=9fea581defc5d2fb
Cabinet/Plane_306|Dark_metal=4a3dbebe6a54a505
Cabinet/Plane_306|Glass_furniture=17b8ac12a01b2724
Cabinet/Plane_306|White_wood=6ee6cf8f714c26e5
Cabinet_001/Plane_323|Constructive_wood=de13716e2fe56c8e
Cabinet_001/Plane_323|Dark_metal=aa0066d682ec57b3
Cabinet_002/Plane_333|Constructive_wood=3ef82d1456172973
Cabinet_002/Plane_333|Dark_metal=5d485fc17c6f202f
Cabinet_003/Plane_357|Dark_metal=a2a72064cfaf0b41
Cabinet_003/Plane_357|White_wood=92d6d1a6a41ddc67
Cabinet_004/Plane_290|Constructive_wood=faaa8e22b59aea72
Cabinet_004/Plane_290|Dark_metal=a2a72064cfaf0b41
Cabinet_005/Plane_323|Constructive_wood=de13716e2fe56c8e
Cabinet_005/Plane_323|Dark_metal=aa0066d682ec57b3
Cabinet_006/Plane_323|Constructive_wood=de13716e2fe56c8e
Cabinet_006/Plane_323|Dark_metal=aa0066d682ec57b3
Cabinet_007/Plane_333|Constructive_wood=3ef82d1456172973
Cabinet_007/Plane_333|Dark_metal=5d485fc17c6f202f
Cabinet_008/Plane_323|Constructive_wood=faaa8e22b59aea72
Cabinet_008/Plane_323|Dark_metal=a2a72064cfaf0b41
Cabinet_009/Plane_373|Dark_metal=a2a72064cfaf0b41
Cabinet_009/Plane_373|White_wood=92d6d1a6a41ddc67
Cabinet_010/Plane_373|Dark_metal=6d06e5e1ca46a044
Cabinet_010/Plane_373|White_wood=19e0696ae5a8d70a
Cabinet_011/Plane_373|Dark_metal=6d06e5e1ca46a044
Cabinet_011/Plane_373|White_wood=19e0696ae5a8d70a
Cabinet_012/Plane_323|Constructive_wood=77e89426cea78717
Cabinet_012/Plane_323|Dark_metal=6d06e5e1ca46a044
Cabinet_013/Plane_290|Constructive_wood=de13716e2fe56c8e
Cabinet_013/Plane_290|Dark_metal=aa0066d682ec57b3
Cabinet_014/Plane_306|Blue_wood=9fea581defc5d2fb
Cabinet_014/Plane_306|Dark_metal=4a3dbebe6a54a505
Cabinet_014/Plane_306|Glass_furniture=17b8ac12a01b2724
Cabinet_014/Plane_306|White_wood=6ee6cf8f714c26e5
Cabinet_015/Plane_321|Blue_wood=691cbc411a8a18cc
Cabinet_015/Plane_321|Dark_metal=5d485fc17c6f202f
Cabinet_015/Plane_321|Glass_furniture=6f6afb884615abbd
Cabinet_015/Plane_321|White_wood=c4e6d45525c82619
Ceiling_lamp/Ceiling_lamp|CeilingLightEmission=f2458c209d844b2a
Ceiling_lamp/Ceiling_lamp|Dark_metal=97dc2a3af337a69a
Ceiling_lamp/Ceiling_lamp|White_wood=22cbf8cb684258df
Ceiling_lamp_001/Ceiling_lamp_001|CeilingLightEmission=f2458c209d844b2a
Ceiling_lamp_001/Ceiling_lamp_001|Dark_metal=4a3dbebe6a54a505
Ceiling_lamp_001/Ceiling_lamp_001|White_wood=6ee6cf8f714c26e5
Ceiling_lamp_002/Ceiling_lamp_002|CeilingLightEmission=f2458c209d844b2a
Ceiling_lamp_002/Ceiling_lamp_002|Dark_metal=5d485fc17c6f202f
Ceiling_lamp_002/Ceiling_lamp_002|White_wood=c4e6d45525c82619
Ceiling_lamp_003/Ceiling_lamp_003|CeilingLightEmission=f2458c209d844b2a
Ceiling_lamp_003/Ceiling_lamp_003|Dark_metal=a2a72064cfaf0b41
Ceiling_lamp_003/Ceiling_lamp_003|White_wood=92d6d1a6a41ddc67
Ceiling_lamp_004/Ceiling_lamp_004|CeilingLightEmission=f2458c209d844b2a
Ceiling_lamp_004/Ceiling_lamp_004|Dark_metal=aa0066d682ec57b3
Ceiling_lamp_004/Ceiling_lamp_004|White_wood=314521219fa27ae9
Ceiling_lamp_005/Ceiling_lamp_005|CeilingLightEmission=f2458c209d844b2a
Ceiling_lamp_005/Ceiling_lamp_005|Dark_metal=5d485fc17c6f202f
Ceiling_lamp_005/Ceiling_lamp_005|White_wood=c4e6d45525c82619
Ceiling_lamp_006/Ceiling_lamp_006|CeilingLightEmission=f2458c209d844b2a
Ceiling_lamp_006/Ceiling_lamp_006|Dark_metal=aa0066d682ec57b3
Ceiling_lamp_006/Ceiling_lamp_006|White_wood=314521219fa27ae9
Ceiling_lamp_007/Ceiling_lamp_007|CeilingLightEmission=f2458c209d844b2a
Ceiling_lamp_007/Ceiling_lamp_007|Dark_metal=a2a72064cfaf0b41
Ceiling_lamp_007/Ceiling_lamp_007|White_wood=92d6d1a6a41ddc67
Ceiling_spot/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot/Circle_008|Dark_metal=4a3dbebe6a54a505
Ceiling_spot_001/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_001/Circle_008|Dark_metal=4a3dbebe6a54a505
Ceiling_spot_002/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_002/Circle_008|Dark_metal=4a3dbebe6a54a505
Ceiling_spot_003/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_003/Circle_008|Dark_metal=4a3dbebe6a54a505
Ceiling_spot_004/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_004/Circle_008|Dark_metal=4a3dbebe6a54a505
Ceiling_spot_005/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_005/Circle_008|Dark_metal=4a3dbebe6a54a505
Ceiling_spot_006/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_006/Circle_008|Dark_metal=aa0066d682ec57b3
Ceiling_spot_007/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_007/Circle_008|Dark_metal=aa0066d682ec57b3
Ceiling_spot_008/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_008/Circle_008|Dark_metal=6d06e5e1ca46a044
Ceiling_spot_009/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_009/Circle_008|Dark_metal=6d06e5e1ca46a044
Ceiling_spot_010/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_010/Circle_008|Dark_metal=6d06e5e1ca46a044
Ceiling_spot_011/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_011/Circle_008|Dark_metal=6d06e5e1ca46a044
Ceiling_spot_012/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_012/Circle_008|Dark_metal=a2a72064cfaf0b41
Ceiling_spot_013/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_013/Circle_008|Dark_metal=a2a72064cfaf0b41
Ceiling_spot_014/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_014/Circle_008|Dark_metal=4a3dbebe6a54a505
Ceiling_spot_015/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_015/Circle_008|Dark_metal=a2a72064cfaf0b41
Ceiling_spot_016/Circle_008|CeilingLightEmission=f2458c209d844b2a
Ceiling_spot_016/Circle_008|Dark_metal=a2a72064cfaf0b41
Ceiling_trim/Plane_242|White_wood=314521219fa27ae9
Central_Heating/Plane_355|Glossy_Black_2=e8695977cc62853d
Central_Heating/Plane_355|Glossy_white=fa5d6b9fcc35e91d
Central_Heating/Plane_355|bright_metal=110c29a8cff981ed
Central_roof_cover/Plane_078|Roof_wood=ffb717ea6e8b4591
Central_roof_cover_001/Plane_076|Roof_wood=12dc861532fc5359
Central_roof_cover_002/Plane_079|Roof_wood=12dc861532fc5359
Central_roof_cover_003/Plane_084|Roof_wood=12dc861532fc5359
Central_roof_cover_004/Plane_087|Roof_wood=12dc861532fc5359
Chair/Plane_313|Constructive_wood=cb7bb70b4cb7fecc
Chair/Plane_313|Dark_metal=4a3dbebe6a54a505
Chair/Plane_313|White_wood=6ee6cf8f714c26e5
Chair_001/Plane_313|Constructive_wood=cb7bb70b4cb7fecc
Chair_001/Plane_313|Dark_metal=4a3dbebe6a54a505
Chair_001/Plane_313|White_wood=6ee6cf8f714c26e5
Chair_002/Plane_313|Constructive_wood=cb7bb70b4cb7fecc
Chair_002/Plane_313|Dark_metal=4a3dbebe6a54a505
Chair_002/Plane_313|White_wood=6ee6cf8f714c26e5
Chair_003/Plane_313|Constructive_wood=cb7bb70b4cb7fecc
Chair_003/Plane_313|Dark_metal=4a3dbebe6a54a505
Chair_003/Plane_313|White_wood=6ee6cf8f714c26e5
Chair_005/Plane_313|Constructive_wood=3ef82d1456172973
Chair_005/Plane_313|Dark_metal=5d485fc17c6f202f
Chair_005/Plane_313|White_wood=c4e6d45525c82619
Chair_006/Plane_313|Constructive_wood=3ef82d1456172973
Chair_006/Plane_313|Dark_metal=5d485fc17c6f202f
Chair_006/Plane_313|White_wood=c4e6d45525c82619
Chair_007/Plane_313|Constructive_wood=3ef82d1456172973
Chair_007/Plane_313|Dark_metal=5d485fc17c6f202f
Chair_007/Plane_313|White_wood=c4e6d45525c82619
Chair_008/Plane_313|Constructive_wood=3ef82d1456172973
Chair_008/Plane_313|Dark_metal=5d485fc17c6f202f
Chair_008/Plane_313|White_wood=c4e6d45525c82619
Chair_009/Plane_313|Constructive_wood=3ef82d1456172973
Chair_009/Plane_313|Dark_metal=5d485fc17c6f202f
Chair_009/Plane_313|White_wood=c4e6d45525c82619
Chair_010/Plane_313|Constructive_wood=3ef82d1456172973
Chair_010/Plane_313|Dark_metal=5d485fc17c6f202f
Chair_010/Plane_313|White_wood=c4e6d45525c82619
Chair_012/Plane_313|Constructive_wood=3ef82d1456172973
Chair_012/Plane_313|Dark_metal=5d485fc17c6f202f
Chair_012/Plane_313|White_wood=c4e6d45525c82619
Chair_013/Plane_313|Constructive_wood=3ef82d1456172973
Chair_013/Plane_313|Dark_metal=5d485fc17c6f202f
Chair_013/Plane_313|White_wood=c4e6d45525c82619
Chair_blanket/Plane_188|Dark_blue_fabric=116acf7513df0bc0
Chair_blanket_001/Plane_188|Dark_blue_fabric=23b1ed074d6da821
Chair_blanket_002/Plane_188|Dark_blue_fabric=1e42f72ac40a280e
Circle/Circle|Dark_metal=4a3dbebe6a54a505
Circle_001/Circle_030|Dark_metal=4a3dbebe6a54a505
Circle_002/Circle_031|Dark_metal=4a3dbebe6a54a505
Clock/Circle_007|Glossy_Black=ce0f5cf46fe3ec25
Clock/Circle_007|Glossy_white=9e6d5f568f36688d
Clock_001/Circle_007|Glossy_Black=52460b83284bbc44
Clock_001/Circle_007|Glossy_white=9c5dbef8ffb54e1e
Clock_002/Circle_007|Glossy_Black=e8695977cc62853d
Clock_002/Circle_007|Glossy_white=fa5d6b9fcc35e91d
Coffee_table/Plane_299|Constructive_wood=f0bcb384a7995a80
Coffee_table/Plane_299|Dark_metal=97dc2a3af337a69a
Coffee_table_001/Plane_299|Constructive_wood=77e89426cea78717
Coffee_table_001/Plane_299|Dark_metal=6d06e5e1ca46a044
Couch/Plane_289|Constructive_wood=f0bcb384a7995a80
Couch/Plane_289|Fabric=5dadb36f1857c90e
Couch_001/Plane_289|Constructive_wood=77e89426cea78717
Couch_001/Plane_289|Fabric=97f477601b2536fe
Couch_blanket/Plane_297|Dark_blue_fabric=116acf7513df0bc0
Couch_blanket_001/Plane_297|Dark_blue_fabric=1e42f72ac40a280e
Counter_top/Plane_265|Constructive_wood=cb7bb70b4cb7fecc
Counter_top_001/Plane_005|Constructive_wood=cb7bb70b4cb7fecc
Counter_top_002/Plane_006|Constructive_wood=cb7bb70b4cb7fecc
Counter_top_trim/Plane_293|Constructive_wood=cb7bb70b4cb7fecc
Curved_ultrawide_monitor/Plane_347|Black_plastic=d1724b5d725765ef
Curved_ultrawide_monitor/Plane_347|Dark_metal=6d06e5e1ca46a044
Curved_ultrawide_monitor/Plane_347|Ultrawide_screen=c69598826f7a3184
Curved_ultrawide_monitor_001/Plane_347|Black_plastic=87f9c8815289834f
Curved_ultrawide_monitor_001/Plane_347|Dark_metal=a2a72064cfaf0b41
Curved_ultrawide_monitor_001/Plane_347|Ultrawide_screen=f0a39bbb59fc0162
Cutting_board/Cube_004|White_wood=6ee6cf8f714c26e5
Decorative_table/Plane_320|Constructive_wood=3ef82d1456172973
Decorative_table/Plane_320|Dark_metal=5d485fc17c6f202f
Decorative_table/Plane_320|White_wood=c4e6d45525c82619
Decorative_table_001/Plane_319|Constructive_wood=3ef82d1456172973
Decorative_table_001/Plane_319|Dark_metal=5d485fc17c6f202f
Decorative_table_001/Plane_319|White_wood=c4e6d45525c82619
Decorative_table_002/Plane_320|Constructive_wood=de13716e2fe56c8e
Decorative_table_002/Plane_320|Dark_metal=aa0066d682ec57b3
Decorative_table_002/Plane_320|White_wood=314521219fa27ae9
Decorative_table_003/Plane_319|Constructive_wood=77e89426cea78717
Decorative_table_003/Plane_319|Dark_metal=6d06e5e1ca46a044
Decorative_table_003/Plane_319|White_wood=19e0696ae5a8d70a
Decorative_table_004/Plane_320|Constructive_wood=77e89426cea78717
Decorative_table_004/Plane_320|Dark_metal=6d06e5e1ca46a044
Decorative_table_004/Plane_320|White_wood=19e0696ae5a8d70a
Decorative_table_005/Plane_319|Constructive_wood=faaa8e22b59aea72
Decorative_table_005/Plane_319|Dark_metal=a2a72064cfaf0b41
Decorative_table_005/Plane_319|White_wood=92d6d1a6a41ddc67
Decorative_table_006/Plane_319|Constructive_wood=3ef82d1456172973
Decorative_table_006/Plane_319|Dark_metal=5d485fc17c6f202f
Decorative_table_006/Plane_319|White_wood=c4e6d45525c82619
Decorative_table_007/Plane_320|Constructive_wood=3ef82d1456172973
Decorative_table_007/Plane_320|Dark_metal=5d485fc17c6f202f
Decorative_table_007/Plane_320|White_wood=c4e6d45525c82619
Decorative_table_008/Plane_319|Constructive_wood=faaa8e22b59aea72
Decorative_table_008/Plane_319|Dark_metal=a2a72064cfaf0b41
Decorative_table_008/Plane_319|White_wood=92d6d1a6a41ddc67
Decorative_table_009/Plane_320|Constructive_wood=faaa8e22b59aea72
Decorative_table_009/Plane_320|Dark_metal=a2a72064cfaf0b41
Decorative_table_009/Plane_320|White_wood=92d6d1a6a41ddc67
Decorative_table_010/Plane_319|Constructive_wood=77e89426cea78717
Decorative_table_010/Plane_319|Dark_metal=6d06e5e1ca46a044
Decorative_table_010/Plane_319|White_wood=19e0696ae5a8d70a
Decorative_table_011/Plane_320|Constructive_wood=77e89426cea78717
Decorative_table_011/Plane_320|Dark_metal=6d06e5e1ca46a044
Decorative_table_011/Plane_320|White_wood=19e0696ae5a8d70a
Decorative_table_012/Plane_319|Constructive_wood=de13716e2fe56c8e
Decorative_table_012/Plane_319|Dark_metal=aa0066d682ec57b3
Decorative_table_012/Plane_319|White_wood=314521219fa27ae9
Decorative_table_013/Plane_320|Constructive_wood=de13716e2fe56c8e
Decorative_table_013/Plane_320|Dark_metal=aa0066d682ec57b3
Decorative_table_013/Plane_320|White_wood=314521219fa27ae9
Desk/Plane_334|Dark_metal=a2a72064cfaf0b41
Desk/Plane_334|White_wood=92d6d1a6a41ddc67
Desk_001/Plane_334|Dark_metal=6d06e5e1ca46a044
Desk_001/Plane_334|White_wood=19e0696ae5a8d70a
Dining_table/Plane_312|Constructive_wood=3ef82d1456172973
Dining_table/Plane_312|Dark_metal=5d485fc17c6f202f
Donut/Circle_011|Chocolade=b3a3855b49446f30
Donut/Circle_011|Donut=e7b2625fb7fb97d8
Donut/Circle_011|Sprinkles=cb9461901dd74c44
Donut_001/Circle_011|Chocolade=b3a3855b49446f30
Donut_001/Circle_011|Donut=e7b2625fb7fb97d8
Donut_001/Circle_011|Sprinkles=cb9461901dd74c44
Donut_002/Circle_011|Chocolade=b3a3855b49446f30
Donut_002/Circle_011|Donut=e7b2625fb7fb97d8
Donut_002/Circle_011|Sprinkles=cb9461901dd74c44
Door_frame/Plane_193|White_wood=314521219fa27ae9
Dryer/Plane_354|Glossy_Black_2=e8695977cc62853d
Dryer/Plane_354|Glossy_white=fa5d6b9fcc35e91d
Electric_wiring/Circle_027|Orange_wiring=093567918540b117
Expansion_vessel/Sphere|Glossy_white=fa5d6b9fcc35e91d
Exterior_door/Plane_192|Dark_metal=aa0066d682ec57b3
Exterior_door/Plane_192|Glass=a3abf08155880dc1
Exterior_door/Plane_192|White_wood=314521219fa27ae9
Exterior_door/Plane_192|bright_metal=110c29a8cff981ed
Exterior_door_001/Plane_192|Dark_metal=97dc2a3af337a69a
Exterior_door_001/Plane_192|Glass=a3abf08155880dc1
Exterior_door_001/Plane_192|White_wood=22cbf8cb684258df
Exterior_door_001/Plane_192|bright_metal=5ea39c543c83ea20
Exterior_door_002/Plane_192|Dark_metal=97dc2a3af337a69a
Exterior_door_002/Plane_192|Glass=a3abf08155880dc1
Exterior_door_002/Plane_192|White_wood=22cbf8cb684258df
Exterior_door_002/Plane_192|bright_metal=5ea39c543c83ea20
Exterior_door_003/Plane_192|Dark_metal=97dc2a3af337a69a
Exterior_door_003/Plane_192|Glass=a3abf08155880dc1
Exterior_door_003/Plane_192|White_wood=22cbf8cb684258df
Exterior_door_003/Plane_192|bright_metal=5ea39c543c83ea20
Exterior_door_004/Plane_192|Dark_metal=97dc2a3af337a69a
Exterior_door_004/Plane_192|Glass=a3abf08155880dc1
Exterior_door_004/Plane_192|White_wood=22cbf8cb684258df
Exterior_door_004/Plane_192|bright_metal=5ea39c543c83ea20
Exterior_door_005/Plane_192|Dark_metal=aa0066d682ec57b3
Exterior_door_005/Plane_192|Glass=a3abf08155880dc1
Exterior_door_005/Plane_192|White_wood=314521219fa27ae9
Exterior_door_005/Plane_192|bright_metal=110c29a8cff981ed
Exterior_door_006/Plane_192|Dark_metal=aa0066d682ec57b3
Exterior_door_006/Plane_192|Glass=a3abf08155880dc1
Exterior_door_006/Plane_192|White_wood=314521219fa27ae9
Exterior_door_006/Plane_192|bright_metal=110c29a8cff981ed
Exterior_door_007/Plane_192|Dark_metal=4a3dbebe6a54a505
Exterior_door_007/Plane_192|Glass=a3abf08155880dc1
Exterior_door_007/Plane_192|White_wood=6ee6cf8f714c26e5
Exterior_door_007/Plane_192|bright_metal=c6d53880431bd676
Exterior_door_008/Plane_192|Dark_metal=4a3dbebe6a54a505
Exterior_door_008/Plane_192|Glass=a3abf08155880dc1
Exterior_door_008/Plane_192|White_wood=6ee6cf8f714c26e5
Exterior_door_008/Plane_192|bright_metal=c6d53880431bd676
Exterior_door_009/Plane_192|Dark_metal=4a3dbebe6a54a505
Exterior_door_009/Plane_192|Glass=a3abf08155880dc1
Exterior_door_009/Plane_192|White_wood=6ee6cf8f714c26e5
Exterior_door_009/Plane_192|bright_metal=c6d53880431bd676
Exterior_door_010/Plane_192|Dark_metal=4a3dbebe6a54a505
Exterior_door_010/Plane_192|Glass=a3abf08155880dc1
Exterior_door_010/Plane_192|White_wood=6ee6cf8f714c26e5
Exterior_door_010/Plane_192|bright_metal=c6d53880431bd676
Exterior_door_013/Plane_192|Dark_metal=aa0066d682ec57b3
Exterior_door_013/Plane_192|Glass=a3abf08155880dc1
Exterior_door_013/Plane_192|White_wood=314521219fa27ae9
Exterior_door_013/Plane_192|bright_metal=110c29a8cff981ed
Exterior_door_014/Plane_192|Dark_metal=aa0066d682ec57b3
Exterior_door_014/Plane_192|Glass=a3abf08155880dc1
Exterior_door_014/Plane_192|White_wood=314521219fa27ae9
Exterior_door_014/Plane_192|bright_metal=110c29a8cff981ed
Exterior_door_015/Plane_192|Dark_metal=aa0066d682ec57b3
Exterior_door_015/Plane_192|Glass=a3abf08155880dc1
Exterior_door_015/Plane_192|White_wood=314521219fa27ae9
Exterior_door_015/Plane_192|bright_metal=110c29a8cff981ed
Exterior_walls/Plane_009|Bathroom_walls=303c6d73a7a3142a
Exterior_walls/Plane_009|Blue_wood=8bce413a3fb9e2f7
Exterior_walls/Plane_009|Painted_drywall=1e8cd5441fc74c1f
Exterior_walls/Plane_009|White_drywall=5134e4b75c8f1a5d
Exterior_walls/Plane_009|White_wood=d2420ebf3d25b2f3
Extraction_hood_case/Plane_288|Blue_wood=9fea581defc5d2fb
Extraction_hood_case/Plane_288|Constructive_wood=cb7bb70b4cb7fecc
Fence_Pole/Cube|Cobblestone=9afbd6f8735e2db5
Fence_Pole/Cube|Stone=2124659109f80491
Fence_Pole/Cube|White_wood=314521219fa27ae9
Fence_Pole_001/Cube_007|Cobblestone=9afbd6f8735e2db5
Fence_Pole_001/Cube_007|Stone=2124659109f80491
Fence_Pole_001/Cube_007|White_wood=314521219fa27ae9
Fence_Pole_002/Cube_009|Cobblestone=9afbd6f8735e2db5
Fence_Pole_002/Cube_009|Stone=2124659109f80491
Fence_Pole_002/Cube_009|White_wood=314521219fa27ae9
Fence_Pole_003/Cube_011|Cobblestone=9afbd6f8735e2db5
Fence_Pole_003/Cube_011|Stone=2124659109f80491
Fence_Pole_003/Cube_011|White_wood=314521219fa27ae9
Fence_Pole_004/Cube_013|Cobblestone=9afbd6f8735e2db5
Fence_Pole_004/Cube_013|Stone=2124659109f80491
Fence_Pole_004/Cube_013|White_wood=314521219fa27ae9
Fence_wall/Cube_003|Cobblestone=9afbd6f8735e2db5
Fence_wall/Cube_003|Stone=2124659109f80491
Fence_wall_001/Cube_008|Cobblestone=9afbd6f8735e2db5
Fence_wall_001/Cube_008|Stone=2124659109f80491
Fence_wall_002/Cube_010|Cobblestone=9afbd6f8735e2db5
Fence_wall_002/Cube_010|Stone=2124659109f80491
Fence_wall_003/Cube_012|Cobblestone=9afbd6f8735e2db5
Fence_wall_003/Cube_012|Stone=2124659109f80491
Fence_wall_004/Cube_014|Cobblestone=9afbd6f8735e2db5
Fence_wall_004/Cube_014|Stone=2124659109f80491
Fence_wood/Plane_194|White_wood=314521219fa27ae9
Fence_wood_001/Plane_198|White_wood=314521219fa27ae9
Fence_wood_002/Plane_204|White_wood=314521219fa27ae9
Fence_wood_003/Plane_205|White_wood=314521219fa27ae9
Fence_wood_004/Plane_206|White_wood=314521219fa27ae9
Flat_roof_details/Plane_222|White_wood=314521219fa27ae9
Floor_trim/Plane_241|White_wood=314521219fa27ae9
Foundation_ledge/Plane_049|Stone=2124659109f80491
Foundation_wall/Plane_050|Cobblestone=9afbd6f8735e2db5
Fridge/Plane_250|bright_metal=c6d53880431bd676
Front_door/Front_door|Blue_wood=691cbc411a8a18cc
Front_door/Front_door|Dark_metal=5d485fc17c6f202f
Front_door/Front_door|Glass=a3abf08155880dc1
Front_door/Front_door|White_wood=c4e6d45525c82619
Front_door/Front_door|bright_metal=c4b26db15ea46bc0
Front_door_frame/Plane_358|Glass=a3abf08155880dc1
Front_door_frame/Plane_358|White_wood=c4e6d45525c82619
Fuse_box/Plane_360|Glossy_white=710687e7f1406be0
Fuse_box/Plane_360|Orange_wiring=9e738942a412e59b
Fuse_box_001/Plane_349|Glossy_white=fa5d6b9fcc35e91d
Fuse_box_001/Plane_349|Orange_wiring=093567918540b117
Gaming_chair/Plane_335|Black_plastic=87f9c8815289834f
Gaming_chair/Plane_335|Blue_gaming_chair_leather_001=2855cd6f91bd5bc4
Gaming_chair/Plane_335|Dark_metal=a2a72064cfaf0b41
Gaming_chair/Plane_335|White_gaming_chair_leather=e1e28b28a87c893c
Gaming_chair_001/Plane_335|Black_plastic=d1724b5d725765ef
Gaming_chair_001/Plane_335|Blue_gaming_chair_leather_001=d861a8ee33d4f3fd
Gaming_chair_001/Plane_335|Dark_metal=6d06e5e1ca46a044
Gaming_chair_001/Plane_335|White_gaming_chair_leather=38e07ba083beaf1e
Garage_beams/Plane_240|Constructive_wood=de13716e2fe56c8e
Garage_door_001/Plane_189|White_wood=314521219fa27ae9
Garage_door_002/Plane_189|White_wood=314521219fa27ae9
Garage_floor/Plane_033|Concrete=34a74c7319186a2a
Garage_foundation_ledge/Plane_051|Stone=2124659109f80491
Garage_foundation_wall/Plane_054|Cobblestone=9afbd6f8735e2db5
Garage_porch_beams/Plane_040|White_wood=314521219fa27ae9
Garage_porch_beams_001/Plane_045|White_wood=314521219fa27ae9
Garage_porch_ceiling_001/Plane_217|White_wood=314521219fa27ae9
Garage_porch_fence/Plane_258|White_wood=314521219fa27ae9
Garage_porch_floor/Plane_015|Porch_wood=cae928f74d37211f
Garage_rail/Circle_029|bright_metal=110c29a8cff981ed
Garage_rail_001/Circle_029|bright_metal=110c29a8cff981ed
Garage_rail_002/Circle_029|bright_metal=110c29a8cff981ed
Garage_rail_003/Circle_029|bright_metal=110c29a8cff981ed
Garage_roof/Plane_028|Constructive_wood=de13716e2fe56c8e
Garage_roof/Plane_028|Roof_wood=12dc861532fc5359
Garage_roof/Plane_028|White_wood=314521219fa27ae9
Garage_walls/Plane_151|Blue_wood=81f357ca6c1b7ce1
Garage_walls/Plane_151|Constructive_wood=de13716e2fe56c8e
Garage_walls/Plane_151|White_wood=314521219fa27ae9
Handrail/Plane_252|Dark_metal=97dc2a3af337a69a
Handrail/Plane_252|White_wood=22cbf8cb684258df
House_plan/Plane_341|Constructive_wood=faaa8e22b59aea72
House_plan/Plane_341|Ground_floor_plan=47ae0ac3e2e8f10c
House_plan_001/Plane_343|Constructive_wood=77e89426cea78717
House_plan_001/Plane_343|First_floor_plan=45f45622329b08b4
House_plan_002/Plane_341|Constructive_wood=de13716e2fe56c8e
House_plan_002/Plane_341|Ground_floor_plan=4107b9066d57a09e
House_plan_003/Plane_343|Constructive_wood=de13716e2fe56c8e
House_plan_003/Plane_343|First_floor_plan=14bfbbcce696bd7b
Interior_door/Plane_228|Dark_metal=97dc2a3af337a69a
Interior_door/Plane_228|White_wood=22cbf8cb684258df
Interior_door/Plane_228|bright_metal=5ea39c543c83ea20
Interior_door_001/Plane_236|Dark_metal=6d06e5e1ca46a044
Interior_door_001/Plane_236|White_wood=19e0696ae5a8d70a
Interior_door_001/Plane_236|bright_metal=5cb5da71c051919d
Interior_door_002/Plane_228|Dark_metal=6d06e5e1ca46a044
Interior_door_002/Plane_228|White_wood=19e0696ae5a8d70a
Interior_door_002/Plane_228|bright_metal=5cb5da71c051919d
Interior_door_003/Plane_228|Dark_metal=a2a72064cfaf0b41
Interior_door_003/Plane_228|White_wood=92d6d1a6a41ddc67
Interior_door_003/Plane_228|bright_metal=fe19d0ef67bc6a86
Interior_door_004/Plane_228|Dark_metal=a2a72064cfaf0b41
Interior_door_004/Plane_228|White_wood=92d6d1a6a41ddc67
Interior_door_004/Plane_228|bright_metal=fe19d0ef67bc6a86
Interior_door_005/Plane_228|Dark_metal=6d06e5e1ca46a044
Interior_door_005/Plane_228|White_wood=19e0696ae5a8d70a
Interior_door_005/Plane_228|bright_metal=5cb5da71c051919d
Interior_door_frames/Plane_197|White_wood=314521219fa27ae9
Interior_floors/Plane_032|Bathroom_floor=d2e61df706268e20
Interior_floors/Plane_032|Roof_wood=466513aa3e66070f
Interior_floors/Plane_032|White_drywall=5134e4b75c8f1a5d
Interior_floors/Plane_032|Wood_floor=d56dd57e6ae4e8da
Interior_walls/Plane_029|Bathroom_walls=303c6d73a7a3142a
Interior_walls/Plane_029|Painted_drywall=1e8cd5441fc74c1f
Keyboard/Plane_352|Glossy_white=710687e7f1406be0
Keyboard/Plane_352|RGB=2e38e77b22c314a4
Keyboard_001/Plane_352|Glossy_white=f3b22091b1df207d
Keyboard_001/Plane_352|RGB=2e38e77b22c314a4
Kitchen_cabinets/Plane_230|Blue_wood=9fea581defc5d2fb
Kitchen_cabinets_001/Plane_007|Blue_wood=9fea581defc5d2fb
Kitchen_cabinets_002/Plane_008|Blue_wood=9fea581defc5d2fb
Kitchen_ceiling_trim/Plane_285|Constructive_wood=cb7bb70b4cb7fecc
Kitchen_ceiling_trim_001/Plane_010|Constructive_wood=cb7bb70b4cb7fecc
Kitchen_ceiling_trim_002/Plane_011|Constructive_wood=cb7bb70b4cb7fecc
Kitchen_kabinets/Plane_266|Blue_wood=9fea581defc5d2fb
Kitchen_kabinets_001/Plane_002|Blue_wood=9fea581defc5d2fb
Kitchen_kabinets_002/Plane_004|Blue_wood=9fea581defc5d2fb
Kitchen_tap/Circle_012|Glossy_white=9c5dbef8ffb54e1e
Kitchen_tap/Circle_012|bright_metal=c6d53880431bd676
Kitchen_tiles/Plane_251|Kitchen_tiles=e76b5f158b6b89b1
Kitchen_tiles_001/Plane_001|Kitchen_tiles=e76b5f158b6b89b1
Leather_chair/Plane_327|Brown_leather=9990d2bbcc62e369
Leather_chair/Plane_327|Dark_metal=97dc2a3af337a69a
Leather_chair_001/Plane_327|Brown_leather=9990d2bbcc62e369
Leather_chair_001/Plane_327|Dark_metal=97dc2a3af337a69a
Leather_chair_002/Plane_327|Brown_leather=c05d232b64b6adb9
Leather_chair_002/Plane_327|Dark_metal=5d485fc17c6f202f
Leather_chair_003/Plane_327|Brown_leather=c05d232b64b6adb9
Leather_chair_003/Plane_327|Dark_metal=5d485fc17c6f202f
Leather_chair_004/Plane_327|Brown_leather=2d028a55d5a43a75
Leather_chair_004/Plane_327|Dark_metal=aa0066d682ec57b3
Leather_chair_005/Plane_327|Brown_leather=398c711f5d832d0e
Leather_chair_005/Plane_327|Dark_metal=6d06e5e1ca46a044
Leather_chair_006/Plane_327|Brown_leather=58998b2535628a8c
Leather_chair_006/Plane_327|Dark_metal=a2a72064cfaf0b41
Leather_chair_007/Plane_327|Brown_leather=398c711f5d832d0e
Leather_chair_007/Plane_327|Dark_metal=6d06e5e1ca46a044
Leather_chair_008/Plane_327|Brown_leather=398c711f5d832d0e
Leather_chair_008/Plane_327|Dark_metal=6d06e5e1ca46a044
Light_switch/Plane_344|Wall_socket_white=10c0db9de56cefa4
Light_switch_001/Plane_344|Wall_socket_white=10c0db9de56cefa4
Light_switch_002/Plane_344|Wall_socket_white=10c0db9de56cefa4
Light_switch_003/Plane_344|Wall_socket_white=8d280b27042fee7b
Light_switch_004/Plane_344|Wall_socket_white=8d280b27042fee7b
Light_switch_005/Plane_344|Wall_socket_white=8d280b27042fee7b
Light_switch_006/Plane_344|Wall_socket_white=8d280b27042fee7b
Light_switch_007/Plane_344|Wall_socket_white=ead0f86f7d04c736
Light_switch_008/Plane_344|Wall_socket_white=ead0f86f7d04c736
Light_switch_009/Plane_344|Wall_socket_white=ff8315a2b5eeff0e
Light_switch_010/Plane_344|Wall_socket_white=ff8315a2b5eeff0e
Light_switch_011/Plane_344|Wall_socket_white=10c0db9de56cefa4
Light_switch_012/Plane_344|Wall_socket_white=10c0db9de56cefa4
Light_switch_013/Plane_344|Wall_socket_white=10c0db9de56cefa4
Light_switch_014/Plane_344|Wall_socket_white=10c0db9de56cefa4
Light_switch_015/Plane_344|Wall_socket_white=bd941b4da0b85f4c
Light_switch_016/Plane_344|Wall_socket_white=bd941b4da0b85f4c
Light_switch_017/Plane_344|Wall_socket_white=bd941b4da0b85f4c
Light_switch_018/Plane_344|Wall_socket_white=bd941b4da0b85f4c
Light_switch_019/Plane_344|Wall_socket_white=bd941b4da0b85f4c
Light_switch_020/Plane_344|Wall_socket_white=bd941b4da0b85f4c
Light_switch_021/Plane_344|Wall_socket_white=8d280b27042fee7b
Light_switch_022/Plane_344|Wall_socket_white=ff8315a2b5eeff0e
Light_switch_023/Plane_344|Wall_socket_white=ff8315a2b5eeff0e
Light_switch_024/Plane_344|Wall_socket_white=ff8315a2b5eeff0e
Lightblocker/Plane_187|Lightblocker=bd863b0021a6eb50
Loft_ladder/Plane_356|White_wood=92d6d1a6a41ddc67
Loft_ladder_001/Plane_338|Dark_metal=a2a72064cfaf0b41
Loft_ladder_001/Plane_338|White_wood=92d6d1a6a41ddc67
Loft_ladder_002/Plane_336|White_wood=92d6d1a6a41ddc67
Mouse/Plane_340|Black_plastic=87f9c8815289834f
Mouse/Plane_340|Glossy_white=710687e7f1406be0
Mouse/Plane_340|RGB=2e38e77b22c314a4
Mouse_001/Plane_340|Black_plastic=d1724b5d725765ef
Mouse_001/Plane_340|Glossy_white=f3b22091b1df207d
Mouse_001/Plane_340|RGB=2e38e77b22c314a4
Mouse_pad/Plane_351|Black_plastic=87f9c8815289834f
Mouse_pad/Plane_351|RGB=2e38e77b22c314a4
Mouse_pad_001/Plane_351|Black_plastic=d1724b5d725765ef
Mouse_pad_001/Plane_351|RGB=2e38e77b22c314a4
Node_0_001/Lemon_Fruit_01/Assembly_2/Lemon_Fruit_01_001/Mesh_0_001|Branches_03_Mat_001=c8bf6528bd043b05
Node_0_001/Lemon_Fruit_01/Assembly_2/Lemon_Fruit_01_002/Mesh_1_001|LemonTreeBark_Mat_001=8517f878db074d66
Node_0_001/Lemon_Fruit_01/Assembly_2/Lemon_Fruit_01_003/Mesh_2_001|Cap_02_Mat_001=a2cf6067cc0c8d03
Node_0_001/Lemon_Fruit_01/Assembly_2/Lemon_Fruit_01_004/Mesh_3_001|LemonTreeFruitSkin_Mat_001=195e57ebf5946684
Node_0_001/Lemon_Fruit_01/Assembly_2/Lemon_Fruit_01_005/Mesh_4_001|LemonTreeLeaf_Mat_001=d06b41b9b675f42d
Node_0_002/Lemon_Fruit_01_007/Assembly_2_001/Lemon_Fruit_01_008/Mesh_0_002|Branches_03_Mat_002=0798262774873f85
Node_0_002/Lemon_Fruit_01_007/Assembly_2_001/Lemon_Fruit_01_009/Mesh_1_002|LemonTreeBark_Mat_002=a5774df8f77d97bd
Node_0_002/Lemon_Fruit_01_007/Assembly_2_001/Lemon_Fruit_01_010/Mesh_2_002|Cap_02_Mat_002=59b0c3021060d035
Node_0_002/Lemon_Fruit_01_007/Assembly_2_001/Lemon_Fruit_01_011/Mesh_3_002|LemonTreeFruitSkin_Mat_002=3eee7f4a92029ce1
Node_0_002/Lemon_Fruit_01_007/Assembly_2_001/Lemon_Fruit_01_012/Mesh_4_002|LemonTreeLeaf_Mat_002=0eb121b602cadebe
Node_0_003/Lemon_Fruit_01_013/Assembly_2_002/Lemon_Fruit_01_014/Mesh_0_003|Branches_03_Mat_003=0798262774873f85
Node_0_003/Lemon_Fruit_01_013/Assembly_2_002/Lemon_Fruit_01_015/Mesh_1_003|LemonTreeBark_Mat_003=a5774df8f77d97bd
Node_0_003/Lemon_Fruit_01_013/Assembly_2_002/Lemon_Fruit_01_016/Mesh_2_003|Cap_02_Mat_003=59b0c3021060d035
Node_0_003/Lemon_Fruit_01_013/Assembly_2_002/Lemon_Fruit_01_017/Mesh_3_003|LemonTreeFruitSkin_Mat_003=3eee7f4a92029ce1
Node_0_003/Lemon_Fruit_01_013/Assembly_2_002/Lemon_Fruit_01_018/Mesh_4_003|LemonTreeLeaf_Mat_003=0eb121b602cadebe
Node_0_004/Lemon_Fruit_01_019/Assembly_2_003/Lemon_Fruit_01_020/Mesh_0_004|Branches_03_Mat_004=0798262774873f85
Node_0_004/Lemon_Fruit_01_019/Assembly_2_003/Lemon_Fruit_01_021/Mesh_1_004|LemonTreeBark_Mat_004=a5774df8f77d97bd
Node_0_004/Lemon_Fruit_01_019/Assembly_2_003/Lemon_Fruit_01_022/Mesh_2_004|Cap_02_Mat_004=59b0c3021060d035
Node_0_004/Lemon_Fruit_01_019/Assembly_2_003/Lemon_Fruit_01_023/Mesh_3_004|LemonTreeFruitSkin_Mat_004=3eee7f4a92029ce1
Node_0_004/Lemon_Fruit_01_019/Assembly_2_003/Lemon_Fruit_01_024/Mesh_4_004|LemonTreeLeaf_Mat_004=0eb121b602cadebe
Node_0_005/Azalea_Flowers_Pink_01/Assembly_2_004/Azalea_Flowers_Pink_01_001/Mesh_0_005|AzaleaLeaf_2_Mat=860c9b22f8d3e933
Node_0_005/Azalea_Flowers_Pink_01/Assembly_2_004/Azalea_Flowers_Pink_01_002/Mesh_1_005|AzaleaFlower_1_Mat=568d71b35e4657fc
Node_0_005/Azalea_Flowers_Pink_01/Assembly_2_004/Azalea_Flowers_Pink_01_003/Mesh_2_005|AzaleaLeaf_1_Mat=fde39c4add766133
Node_0_005/Azalea_Flowers_Pink_01/Assembly_2_004/Azalea_Flowers_Pink_01_004/Mesh_3_005|FlowerStem_05_Mat=74b78d0c49eb8dff
Node_0_005/Azalea_Flowers_Pink_01/Assembly_2_004/Azalea_Flowers_Pink_01_005/Mesh_4_005|Cap_01_Mat=a8937309fb74cb83
Node_0_005/Azalea_Flowers_Pink_01/Assembly_2_004/Azalea_Flowers_Pink_01_006/Mesh_5|AzaleaFlower_2_Mat=6d589af7233fd37c
Node_0_005/Azalea_Flowers_Pink_01/Assembly_2_004/Azalea_Flowers_Pink_01_007/Mesh_6|Branches_09_Mat=5db9ed6c3d02e4fb
Node_0_006/Azalea_Flowers_Pink_01_008/Assembly_2_005/Azalea_Flowers_Pink_01_009/Mesh_0_006|AzaleaLeaf_2_Mat_001=860c9b22f8d3e933
Node_0_006/Azalea_Flowers_Pink_01_008/Assembly_2_005/Azalea_Flowers_Pink_01_010/Mesh_1_006|AzaleaFlower_1_Mat_001=568d71b35e4657fc
Node_0_006/Azalea_Flowers_Pink_01_008/Assembly_2_005/Azalea_Flowers_Pink_01_011/Mesh_2_006|AzaleaLeaf_1_Mat_001=fde39c4add766133
Node_0_006/Azalea_Flowers_Pink_01_008/Assembly_2_005/Azalea_Flowers_Pink_01_012/Mesh_3_006|FlowerStem_05_Mat_001=74b78d0c49eb8dff
Node_0_006/Azalea_Flowers_Pink_01_008/Assembly_2_005/Azalea_Flowers_Pink_01_013/Mesh_4_006|Cap_01_Mat_001=a8937309fb74cb83
Node_0_006/Azalea_Flowers_Pink_01_008/Assembly_2_005/Azalea_Flowers_Pink_01_014/Mesh_5_001|AzaleaFlower_2_Mat_001=6d589af7233fd37c
Node_0_006/Azalea_Flowers_Pink_01_008/Assembly_2_005/Azalea_Flowers_Pink_01_015/Mesh_6_001|Branches_09_Mat_001=5db9ed6c3d02e4fb
Node_0_007/Azalea_Flowers_Pink_01_016/Assembly_2_006/Azalea_Flowers_Pink_01_017/Mesh_0_007|AzaleaLeaf_2_Mat_002=d6c2726114cabe17
Node_0_007/Azalea_Flowers_Pink_01_016/Assembly_2_006/Azalea_Flowers_Pink_01_018/Mesh_1_007|AzaleaFlower_1_Mat_002=140752ff80178cec
Node_0_007/Azalea_Flowers_Pink_01_016/Assembly_2_006/Azalea_Flowers_Pink_01_019/Mesh_2_007|AzaleaLeaf_1_Mat_002=adf3ad78833120cc
Node_0_007/Azalea_Flowers_Pink_01_016/Assembly_2_006/Azalea_Flowers_Pink_01_020/Mesh_3_007|FlowerStem_05_Mat_002=ab29bde9ab7103df
Node_0_007/Azalea_Flowers_Pink_01_016/Assembly_2_006/Azalea_Flowers_Pink_01_021/Mesh_4_007|Cap_01_Mat_002=25dd2a624197638d
Node_0_007/Azalea_Flowers_Pink_01_016/Assembly_2_006/Azalea_Flowers_Pink_01_022/Mesh_5_002|AzaleaFlower_2_Mat_002=3caeffe2a8b55c12
Node_0_007/Azalea_Flowers_Pink_01_016/Assembly_2_006/Azalea_Flowers_Pink_01_023/Mesh_6_002|Branches_09_Mat_002=8f4ab351207a88eb
Node_0_008/Azalea_Flowers_Pink_01_024/Assembly_2_007/Azalea_Flowers_Pink_01_025/Mesh_0_008|AzaleaLeaf_2_Mat_003=860c9b22f8d3e933
Node_0_008/Azalea_Flowers_Pink_01_024/Assembly_2_007/Azalea_Flowers_Pink_01_026/Mesh_1_008|AzaleaFlower_1_Mat_003=568d71b35e4657fc
Node_0_008/Azalea_Flowers_Pink_01_024/Assembly_2_007/Azalea_Flowers_Pink_01_027/Mesh_2_008|AzaleaLeaf_1_Mat_003=fde39c4add766133
Node_0_008/Azalea_Flowers_Pink_01_024/Assembly_2_007/Azalea_Flowers_Pink_01_028/Mesh_3_008|FlowerStem_05_Mat_003=74b78d0c49eb8dff
Node_0_008/Azalea_Flowers_Pink_01_024/Assembly_2_007/Azalea_Flowers_Pink_01_029/Mesh_4_008|Cap_01_Mat_003=a8937309fb74cb83
Node_0_008/Azalea_Flowers_Pink_01_024/Assembly_2_007/Azalea_Flowers_Pink_01_030/Mesh_5_003|AzaleaFlower_2_Mat_003=6d589af7233fd37c
Node_0_008/Azalea_Flowers_Pink_01_024/Assembly_2_007/Azalea_Flowers_Pink_01_031/Mesh_6_003|Branches_09_Mat_003=5db9ed6c3d02e4fb
Node_0_009/Azalea_Flowers_Pink_01_032/Assembly_2_008/Azalea_Flowers_Pink_01_033/Mesh_0_009|AzaleaLeaf_2_Mat_004=860c9b22f8d3e933
Node_0_009/Azalea_Flowers_Pink_01_032/Assembly_2_008/Azalea_Flowers_Pink_01_034/Mesh_1_009|AzaleaFlower_1_Mat_004=568d71b35e4657fc
Node_0_009/Azalea_Flowers_Pink_01_032/Assembly_2_008/Azalea_Flowers_Pink_01_035/Mesh_2_009|AzaleaLeaf_1_Mat_004=fde39c4add766133
Node_0_009/Azalea_Flowers_Pink_01_032/Assembly_2_008/Azalea_Flowers_Pink_01_036/Mesh_3_009|FlowerStem_05_Mat_004=74b78d0c49eb8dff
Node_0_009/Azalea_Flowers_Pink_01_032/Assembly_2_008/Azalea_Flowers_Pink_01_037/Mesh_4_009|Cap_01_Mat_004=a8937309fb74cb83
Node_0_009/Azalea_Flowers_Pink_01_032/Assembly_2_008/Azalea_Flowers_Pink_01_038/Mesh_5_004|AzaleaFlower_2_Mat_004=6d589af7233fd37c
Node_0_009/Azalea_Flowers_Pink_01_032/Assembly_2_008/Azalea_Flowers_Pink_01_039/Mesh_6_004|Branches_09_Mat_004=5db9ed6c3d02e4fb
Olive_Oil/Plane_304|Bottle_cap=52e0d8bf4db63173
Olive_Oil/Plane_304|Bottle_glass=df1eed573a1c3b71
Olive_Oil/Plane_304|Olive_oil=2e38e77b22c314a4
Olive_Oil_001/Plane_304|Bottle_cap=52e0d8bf4db63173
Olive_Oil_001/Plane_304|Bottle_glass=df1eed573a1c3b71
Olive_Oil_001/Plane_304|Olive_oil=2e38e77b22c314a4
Olive_Oil_002/Plane_304|Bottle_cap=7dfde3dc98254d0d
Olive_Oil_002/Plane_304|Bottle_glass=8a9024747b45807b
Olive_Oil_002/Plane_304|Olive_oil=2e38e77b22c314a4
Olive_Oil_003/Plane_304|Bottle_cap=52e0d8bf4db63173
Olive_Oil_003/Plane_304|Bottle_glass=df1eed573a1c3b71
Olive_Oil_003/Plane_304|Olive_oil=2e38e77b22c314a4
Olive_Oil_004/Plane_304|Bottle_cap=52e0d8bf4db63173
Olive_Oil_004/Plane_304|Bottle_glass=df1eed573a1c3b71
Olive_Oil_004/Plane_304|Olive_oil=2e38e77b22c314a4
Olive_Oil_005/Plane_304|Bottle_cap=52e0d8bf4db63173
Olive_Oil_005/Plane_304|Bottle_glass=df1eed573a1c3b71
Olive_Oil_005/Plane_304|Olive_oil=2e38e77b22c314a4
Olive_Oil_006/Plane_304|Bottle_cap=52e0d8bf4db63173
Olive_Oil_006/Plane_304|Bottle_glass=df1eed573a1c3b71
Olive_Oil_006/Plane_304|Olive_oil=2e38e77b22c314a4
Olive_Oil_007/Plane_304|Bottle_cap=52e0d8bf4db63173
Olive_Oil_007/Plane_304|Bottle_glass=df1eed573a1c3b71
Olive_Oil_007/Plane_304|Olive_oil=2e38e77b22c314a4
Olive_Oil_008/Plane_304|Bottle_cap=52e0d8bf4db63173
Olive_Oil_008/Plane_304|Bottle_glass=df1eed573a1c3b71
Olive_Oil_008/Plane_304|Olive_oil=2e38e77b22c314a4
Olive_Oil_009/Plane_304|Bottle_cap=52e0d8bf4db63173
Olive_Oil_009/Plane_304|Bottle_glass=df1eed573a1c3b71
Olive_Oil_009/Plane_304|Olive_oil=2e38e77b22c314a4
Olive_Oil_010/Plane_304|Bottle_cap=52e0d8bf4db63173
Olive_Oil_010/Plane_304|Bottle_glass=df1eed573a1c3b71
Olive_Oil_010/Plane_304|Olive_oil=2e38e77b22c314a4
Outdoor_chair/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_001/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_002/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_003/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_004/Plane_369|Constructive_wood=3ef82d1456172973
Outdoor_chair_005/Plane_369|Constructive_wood=3ef82d1456172973
Outdoor_chair_006/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_007/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_008/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_009/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_010/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_011/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_012/Plane_369|Constructive_wood=3ef82d1456172973
Outdoor_chair_013/Plane_369|Constructive_wood=3ef82d1456172973
Outdoor_chair_014/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_015/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_016/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_017/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_018/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_019/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_020/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_021/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_022/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_chair_023/Plane_369|Constructive_wood=de13716e2fe56c8e
Outdoor_table/Plane_371|Constructive_wood=de13716e2fe56c8e
Outdoor_table/Plane_371|Dark_metal=aa0066d682ec57b3
Outdoor_table_001/Plane_371|Constructive_wood=de13716e2fe56c8e
Outdoor_table_001/Plane_371|Dark_metal=aa0066d682ec57b3
Outdoor_table_002/Plane_371|Constructive_wood=3ef82d1456172973
Outdoor_table_002/Plane_371|Dark_metal=5d485fc17c6f202f
Outdoor_table_003/Plane_371|Constructive_wood=de13716e2fe56c8e
Outdoor_table_003/Plane_371|Dark_metal=aa0066d682ec57b3
Outdoor_table_004/Plane_371|Constructive_wood=de13716e2fe56c8e
Outdoor_table_004/Plane_371|Dark_metal=aa0066d682ec57b3
Oven___microwave/Plane_259|Glossy_Black_2=52460b83284bbc44
Oven___microwave/Plane_259|bright_metal=c6d53880431bd676
Oven___microwave_001/Plane_259|Glossy_Black_2=52460b83284bbc44
Oven___microwave_001/Plane_259|bright_metal=c6d53880431bd676
Oven___microwave_002/Plane_267|Glossy_Black_2=52460b83284bbc44
Oven___microwave_002/Plane_267|bright_metal=c6d53880431bd676
PC/Mesh|Antracite_metal=7e47df0956aac656
PC/Mesh|Glass_furniture=75d4384bea01348c
PC/Mesh|Hardware=bb8d70555f458a8a
PC/Mesh|bright_metal=5cb5da71c051919d
PC_001/Mesh|Antracite_metal=e1a7378360030794
PC_001/Mesh|Glass_furniture=91c612317b835123
PC_001/Mesh|Hardware=955a8db9291f546a
PC_001/Mesh|bright_metal=fe19d0ef67bc6a86
Pan/Circle_005|bright_metal=c6d53880431bd676
Pan_001/Circle_005|bright_metal=c6d53880431bd676
Pan_002/Circle_005|bright_metal=c6d53880431bd676
Pan_003/Circle_005|bright_metal=c6d53880431bd676
Pan_004/Circle_006|bright_metal=c6d53880431bd676
Pan_005/Circle_010|bright_metal=c6d53880431bd676
Pan_Hook/Plane_301|Dark_metal=4a3dbebe6a54a505
Pan_Hook_001/Plane_301|Dark_metal=4a3dbebe6a54a505
Pan_Hook_002/Plane_301|Dark_metal=4a3dbebe6a54a505
Pan_Hook_003/Plane_301|Dark_metal=4a3dbebe6a54a505
Pan_Hook_004/Plane_301|Dark_metal=4a3dbebe6a54a505
Pan_Hook_005/Plane_301|Dark_metal=4a3dbebe6a54a505
Pan_hook_bar/Plane_298|Dark_metal=4a3dbebe6a54a505
Pepper/Circle_014|Constructive_wood=cb7bb70b4cb7fecc
Pepper/Circle_014|bright_metal=c6d53880431bd676
Pepper_001/Circle_014|Constructive_wood=cb7bb70b4cb7fecc
Pepper_001/Circle_014|bright_metal=c6d53880431bd676
Pepper_002/Circle_014|Constructive_wood=cb7bb70b4cb7fecc
Pepper_002/Circle_014|bright_metal=c6d53880431bd676
Pepper_003/Circle_014|Constructive_wood=cb7bb70b4cb7fecc
Pepper_003/Circle_014|bright_metal=c6d53880431bd676
Pepper_004/Circle_014|Constructive_wood=cb7bb70b4cb7fecc
Pepper_004/Circle_014|bright_metal=c6d53880431bd676
Pepper_005/Circle_014|Constructive_wood=cb7bb70b4cb7fecc
Pepper_005/Circle_014|bright_metal=c6d53880431bd676
Pepper_006/Circle_014|Constructive_wood=cb7bb70b4cb7fecc
Pepper_006/Circle_014|bright_metal=c6d53880431bd676
Pepper_007/Circle_014|Constructive_wood=cb7bb70b4cb7fecc
Pepper_007/Circle_014|bright_metal=c6d53880431bd676
Pepper_008/Circle_014|Constructive_wood=cb7bb70b4cb7fecc
Pepper_008/Circle_014|bright_metal=c6d53880431bd676
Pepper_009/Circle_014|Constructive_wood=cb7bb70b4cb7fecc
Pepper_009/Circle_014|bright_metal=c6d53880431bd676
Pepper_010/Circle_014|Constructive_wood=cb7bb70b4cb7fecc
Pepper_010/Circle_014|bright_metal=c6d53880431bd676
Pillow_A/Plane_295|Yellow_fabric=574658ed4c9da3db
Pillow_A_001/Plane_295|Yellow_fabric=a9aa6462e37a3690
Pillow_B/Plane_296|Yellow_fabric=574658ed4c9da3db
Pillow_B_001/Plane_296|Yellow_fabric=574658ed4c9da3db
Pillow_B_002/Plane_296|Yellow_fabric=800774807c7f9ff1
Pillow_B_003/Plane_296|Yellow_fabric=02503d4b84f0bd43
Pillow_B_004/Plane_296|Yellow_fabric=a9aa6462e37a3690
Pillow_B_005/Plane_296|Yellow_fabric=a9aa6462e37a3690
Pillow_B_006/Plane_296|Yellow_fabric=164b84e8b97dbc93
Pillow_B_007/Plane_296|Yellow_fabric=a9aa6462e37a3690
Pillow_C/Plane_294|Yellow_fabric=574658ed4c9da3db
Pillow_C_001/Plane_294|Yellow_fabric=a9aa6462e37a3690
Plane_003/Plane_195|Rug=14e9252ca92a65ab
Plane_004/Plane_213|Constructive_wood=f0bcb384a7995a80
Plane_014/Plane_262|Black_wood=08ce2ad96cd14011
Plane_014/Plane_262|SHC_Art_2=0e1f72bd0e7fadb1
Plane_015/Plane_262|Black_wood=8584c3f8e3df586f
Plane_015/Plane_262|SHC_Art_2=8245af818f8f0f28
Plane_032/Plane_262|Black_wood=6aa9971d22b2ebef
Plane_032/Plane_262|SHC_Art_2=f921341a16533c6d
Plane_033/Plane_262|Black_wood=fb1013a3608d97ca
Plane_033/Plane_262|SHC_Art_2=cb2f702fa8379c2b
Plane_067/Plane_213|Constructive_wood=faaa8e22b59aea72
Plane_072/Plane_262|Black_wood=6aa9971d22b2ebef
Plane_072/Plane_262|SHC_Art_2=f921341a16533c6d
Plant_A/Plane_214|Material_014=eb5e76b89d172cc1
Plant_A_001/Plane_214|Material_014=eb5e76b89d172cc1
Plant_A_002/Plane_214|Material_014=fa2e88b370435f4b
Plant_A_003/Plane_214|Material_014=eb5e76b89d172cc1
Plant_A_004/Plane_214|Material_014=9223746e40bc17d4
Plant_A_005/Plane_214|Material_014=9223746e40bc17d4
Plant_A_006/Plane_214|Material_014=9223746e40bc17d4
Plant_A_007/Plane_214|Material_014=9223746e40bc17d4
Plant_A_008/Plane_214|Material_014=9223746e40bc17d4
Plant_A_009/Plane_214|Material_014=3751e8b47d1e20b4
Plant_A_010/Plane_214|Material_014=3751e8b47d1e20b4
Plant_A_011/Plane_214|Material_014=3751e8b47d1e20b4
Plant_A_012/Plane_214|Material_014=fa2e88b370435f4b
Plant_A_013/Plane_214|Material_014=9223746e40bc17d4
Plant_A_014/Plane_214|Material_014=eb5e76b89d172cc1
Plant_A_015/Plane_214|Material_014=9223746e40bc17d4
Plant_A_016/Plane_214|Material_014=3751e8b47d1e20b4
Plant_A_017/Plane_214|Material_014=fa2e88b370435f4b
Plant_A_018/Plane_214|Material_014=e4b9964d979d7086
Plant_A_019/Plane_214|Material_014=e4b9964d979d7086
Plant_A_020/Plane_214|Material_014=e4b9964d979d7086
Plant_A_021/Plane_214|Material_014=e4b9964d979d7086
Plant_A_022/Plane_214|Material_014=4d2f8e59544ff6ad
Plant_A_023/Plane_214|Material_014=e4b9964d979d7086
Plant_A_024/Plane_214|Material_014=4d2f8e59544ff6ad
Plant_A_025/Plane_214|Material_014=e4b9964d979d7086
Plant_A_026/Plane_214|Material_014=eb5e76b89d172cc1
Plant_A_027/Plane_214|Material_014=fa2e88b370435f4b
Plant_A_028/Plane_214|Material_014=fa2e88b370435f4b
Plant_A_029/Plane_214|Material_014=3751e8b47d1e20b4
Plant_A_030/Plane_214|Material_014=fa2e88b370435f4b
Plant_A_031/Plane_214|Material_014=fa2e88b370435f4b
Plant_A_032/Plane_214|Material_014=3751e8b47d1e20b4
Plant_A_033/Plane_214|Material_014=fa2e88b370435f4b
Plant_A_034/Plane_214|Material_014=4d2f8e59544ff6ad
Plant_A_035/Plane_214|Material_014=4d2f8e59544ff6ad
Plant_A_036/Plane_214|Material_014=4d2f8e59544ff6ad
Plant_A_037/Plane_214|Material_014=4d2f8e59544ff6ad
Plant_A_038/Plane_214|Material_014=4d2f8e59544ff6ad
Plant_A_039/Plane_214|Material_014=e4b9964d979d7086
Plant_B_001/Plane_245|Material_014=eb5e76b89d172cc1
Plant_B_002/Plane_245|Material_014=9223746e40bc17d4
Plant_B_003/Plane_245|Material_014=9223746e40bc17d4
Plant_B_004/Plane_317|Material_014=9223746e40bc17d4
Plant_B_005/Plane_245|Material_014=3751e8b47d1e20b4
Plant_B_006/Plane_245|Material_014=3751e8b47d1e20b4
Plant_B_007/Plane_245|Material_014=fa2e88b370435f4b
Plant_B_008/Plane_245|Material_014=9223746e40bc17d4
Plant_B_009/Plane_317|Material_014=3751e8b47d1e20b4
Plant_B_010/Plane_245|Material_014=fa2e88b370435f4b
Plant_B_011/Plane_245|Material_014=9223746e40bc17d4
Plant_B_012/Plane_245|Material_014=3751e8b47d1e20b4
Plant_B_013/Plane_245|Material_014=e4b9964d979d7086
Plant_B_014/Plane_245|Material_014=e4b9964d979d7086
Plant_B_015/Plane_245|Material_014=4d2f8e59544ff6ad
Plant_B_016/Plane_245|Material_014=4d2f8e59544ff6ad
Plant_B_017/Plane_245|Material_014=e4b9964d979d7086
Plant_B_018/Plane_317|Material_014=fa2e88b370435f4b
Plant_B_019/Plane_245|Material_014=3751e8b47d1e20b4
Plant_B_020/Plane_245|Material_014=3751e8b47d1e20b4
Plant_B_021/Plane_245|Material_014=4d2f8e59544ff6ad
Plant_B_022/Plane_245|Material_014=4d2f8e59544ff6ad
Plant_B_023/Plane_245|Material_014=4d2f8e59544ff6ad
Plant_B_024/Plane_317|Material_014=4d2f8e59544ff6ad
Plant_B_025/Plane_245|Material_014=4d2f8e59544ff6ad
Plant_B_026/Plane_245|Material_014=e4b9964d979d7086
Plant_B_027/Plane_245|Material_014=e4b9964d979d7086
Plant_pot/Circle_004|Dirt=24e8e14d19bc3acd
Plant_pot/Circle_004|Glossy_white=fa5d6b9fcc35e91d
Plant_pot_001/Circle_004|Dirt=3dd2b9fb0b305ae1
Plant_pot_001/Circle_004|Glossy_white=9e6d5f568f36688d
Plant_pot_002/Circle_004|Dirt=3dd2b9fb0b305ae1
Plant_pot_002/Circle_004|Glossy_white=9e6d5f568f36688d
Plant_pot_003/Circle_004|Dirt=3dd2b9fb0b305ae1
Plant_pot_003/Circle_004|Glossy_white=9e6d5f568f36688d
Plant_pot_004/Circle_004|Dirt=3dd2b9fb0b305ae1
Plant_pot_004/Circle_004|Glossy_white=9e6d5f568f36688d
Plant_pot_005/Circle_004|Dirt=3dd2b9fb0b305ae1
Plant_pot_005/Circle_004|Glossy_white=9e6d5f568f36688d
Plant_pot_006/Circle_004|Dirt=1fb955bf65a913a4
Plant_pot_006/Circle_004|Glossy_white=9c5dbef8ffb54e1e
Plant_pot_007/Circle_004|Dirt=1fb955bf65a913a4
Plant_pot_007/Circle_004|Glossy_white=9c5dbef8ffb54e1e
Plant_pot_008/Circle_004|Dirt=1fb955bf65a913a4
Plant_pot_008/Circle_004|Glossy_white=9c5dbef8ffb54e1e
Plant_pot_009/Circle_004|Dirt=1fb955bf65a913a4
Plant_pot_009/Circle_004|Glossy_white=9c5dbef8ffb54e1e
Plant_pot_010/Circle_004|Dirt=1fb955bf65a913a4
Plant_pot_010/Circle_004|Glossy_white=9c5dbef8ffb54e1e
Plant_pot_011/Circle_004|Dirt=1fb955bf65a913a4
Plant_pot_011/Circle_004|Glossy_white=9c5dbef8ffb54e1e
Plant_pot_012/Circle_004|Dirt=1fb955bf65a913a4
Plant_pot_012/Circle_004|Glossy_white=9c5dbef8ffb54e1e
Plant_pot_013/Circle_004|Dirt=1fb955bf65a913a4
Plant_pot_013/Circle_004|Glossy_white=9c5dbef8ffb54e1e
Plant_pot_014/Circle_004|Dirt=50153d75152991bc
Plant_pot_014/Circle_004|Glossy_white=68dab8d5ccc98739
Plant_pot_015/Circle_004|Dirt=50153d75152991bc
Plant_pot_015/Circle_004|Glossy_white=68dab8d5ccc98739
Plant_pot_016/Circle_004|Dirt=50153d75152991bc
Plant_pot_016/Circle_004|Glossy_white=68dab8d5ccc98739
Plant_pot_017/Circle_004|Dirt=50153d75152991bc
Plant_pot_017/Circle_004|Glossy_white=68dab8d5ccc98739
Plant_pot_018/Circle_004|Dirt=50153d75152991bc
Plant_pot_018/Circle_004|Glossy_white=68dab8d5ccc98739
Plant_pot_019/Circle_004|Dirt=50153d75152991bc
Plant_pot_019/Circle_004|Glossy_white=68dab8d5ccc98739
Plant_pot_020/Circle_004|Dirt=24e8e14d19bc3acd
Plant_pot_020/Circle_004|Glossy_white=fa5d6b9fcc35e91d
Plant_pot_021/Circle_004|Dirt=24e8e14d19bc3acd
Plant_pot_021/Circle_004|Glossy_white=fa5d6b9fcc35e91d
Plant_pot_022/Circle_004|Dirt=1fb955bf65a913a4
Plant_pot_022/Circle_004|Glossy_white=9c5dbef8ffb54e1e
Plant_pot_023/Circle_004|Dirt=24e8e14d19bc3acd
Plant_pot_023/Circle_004|Glossy_white=fa5d6b9fcc35e91d
Plant_pot_024/Circle_004|Dirt=1fb955bf65a913a4
Plant_pot_024/Circle_004|Glossy_white=9c5dbef8ffb54e1e
Plant_pot_025/Circle_004|Dirt=1fb955bf65a913a4
Plant_pot_025/Circle_004|Glossy_white=9c5dbef8ffb54e1e
Plant_pot_026/Circle_004|Dirt=3dd2b9fb0b305ae1
Plant_pot_026/Circle_004|Glossy_white=9e6d5f568f36688d
Plant_pot_027/Circle_004|Dirt=1fb955bf65a913a4
Plant_pot_027/Circle_004|Glossy_white=9c5dbef8ffb54e1e
Plant_pot_028/Circle_004|Dirt=50153d75152991bc
Plant_pot_028/Circle_004|Glossy_white=68dab8d5ccc98739
Plant_pot_029/Circle_004|Dirt=50153d75152991bc
Plant_pot_029/Circle_004|Glossy_white=68dab8d5ccc98739
Plant_pot_030/Circle_004|Dirt=24e8e14d19bc3acd
Plant_pot_030/Circle_004|Glossy_white=fa5d6b9fcc35e91d
Plant_pot_031/Circle_004|Dirt=8ca4370d62f7548c
Plant_pot_031/Circle_004|Glossy_white=f3b22091b1df207d
Plant_pot_032/Circle_004|Dirt=8ca4370d62f7548c
Plant_pot_032/Circle_004|Glossy_white=f3b22091b1df207d
Plant_pot_033/Circle_004|Dirt=8ca4370d62f7548c
Plant_pot_033/Circle_004|Glossy_white=f3b22091b1df207d
Plant_pot_034/Circle_004|Dirt=8ca4370d62f7548c
Plant_pot_034/Circle_004|Glossy_white=f3b22091b1df207d
Plant_pot_035/Circle_004|Dirt=8ca4370d62f7548c
Plant_pot_035/Circle_004|Glossy_white=f3b22091b1df207d
Plant_pot_036/Circle_004|Dirt=8ca4370d62f7548c
Plant_pot_036/Circle_004|Glossy_white=f3b22091b1df207d
Plant_pot_037/Circle_004|Dirt=b41345138aed61b2
Plant_pot_037/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_038/Circle_004|Dirt=8ca4370d62f7548c
Plant_pot_038/Circle_004|Glossy_white=f3b22091b1df207d
Plant_pot_039/Circle_004|Dirt=b41345138aed61b2
Plant_pot_039/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_040/Circle_004|Dirt=b41345138aed61b2
Plant_pot_040/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_041/Circle_004|Dirt=8ca4370d62f7548c
Plant_pot_041/Circle_004|Glossy_white=f3b22091b1df207d
Plant_pot_042/Circle_004|Dirt=b41345138aed61b2
Plant_pot_042/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_043/Circle_004|Dirt=8ca4370d62f7548c
Plant_pot_043/Circle_004|Glossy_white=f3b22091b1df207d
Plant_pot_044/Circle_004|Dirt=3dd2b9fb0b305ae1
Plant_pot_044/Circle_004|Glossy_white=9e6d5f568f36688d
Plant_pot_045/Circle_004|Dirt=24e8e14d19bc3acd
Plant_pot_045/Circle_004|Glossy_white=fa5d6b9fcc35e91d
Plant_pot_046/Circle_004|Dirt=24e8e14d19bc3acd
Plant_pot_046/Circle_004|Glossy_white=fa5d6b9fcc35e91d
Plant_pot_047/Circle_004|Dirt=50153d75152991bc
Plant_pot_047/Circle_004|Glossy_white=68dab8d5ccc98739
Plant_pot_048/Circle_004|Dirt=24e8e14d19bc3acd
Plant_pot_048/Circle_004|Glossy_white=fa5d6b9fcc35e91d
Plant_pot_049/Circle_004|Dirt=24e8e14d19bc3acd
Plant_pot_049/Circle_004|Glossy_white=fa5d6b9fcc35e91d
Plant_pot_050/Circle_004|Dirt=24e8e14d19bc3acd
Plant_pot_050/Circle_004|Glossy_white=fa5d6b9fcc35e91d
Plant_pot_051/Circle_004|Dirt=50153d75152991bc
Plant_pot_051/Circle_004|Glossy_white=68dab8d5ccc98739
Plant_pot_052/Circle_004|Dirt=50153d75152991bc
Plant_pot_052/Circle_004|Glossy_white=68dab8d5ccc98739
Plant_pot_053/Circle_004|Dirt=50153d75152991bc
Plant_pot_053/Circle_004|Glossy_white=68dab8d5ccc98739
Plant_pot_054/Circle_004|Dirt=24e8e14d19bc3acd
Plant_pot_054/Circle_004|Glossy_white=fa5d6b9fcc35e91d
Plant_pot_055/Circle_004|Dirt=b41345138aed61b2
Plant_pot_055/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_056/Circle_004|Dirt=b41345138aed61b2
Plant_pot_056/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_057/Circle_004|Dirt=b41345138aed61b2
Plant_pot_057/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_058/Circle_004|Dirt=b41345138aed61b2
Plant_pot_058/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_059/Circle_004|Dirt=b41345138aed61b2
Plant_pot_059/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_060/Circle_004|Dirt=b41345138aed61b2
Plant_pot_060/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_061/Circle_004|Dirt=b41345138aed61b2
Plant_pot_061/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_062/Circle_004|Dirt=b41345138aed61b2
Plant_pot_062/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_063/Circle_004|Dirt=b41345138aed61b2
Plant_pot_063/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_064/Circle_004|Dirt=b41345138aed61b2
Plant_pot_064/Circle_004|Glossy_white=710687e7f1406be0
Plant_pot_065/Circle_004|Dirt=8ca4370d62f7548c
Plant_pot_065/Circle_004|Glossy_white=f3b22091b1df207d
Plant_pot_066/Circle_004|Dirt=8ca4370d62f7548c
Plant_pot_066/Circle_004|Glossy_white=f3b22091b1df207d
Plant_pot_067/Circle_004|Dirt=8ca4370d62f7548c
Plant_pot_067/Circle_004|Glossy_white=f3b22091b1df207d
Plant_table/Circle_001|Constructive_wood=f0bcb384a7995a80
Plant_table_001/Circle_001|Constructive_wood=cb7bb70b4cb7fecc
Plant_table_002/Circle_001|Constructive_wood=cb7bb70b4cb7fecc
Plant_table_003/Circle_001|Constructive_wood=3ef82d1456172973
Plant_table_004/Circle_001|Constructive_wood=de13716e2fe56c8e
Plant_table_005/Circle_001|Constructive_wood=de13716e2fe56c8e
Plant_table_006/Circle_001|Constructive_wood=3ef82d1456172973
Plate/Circle_015|Glossy_white=9c5dbef8ffb54e1e
Plate_holder/Plane_307|Constructive_wood=cb7bb70b4cb7fecc
Plate_holder_001/Plane_307|Constructive_wood=cb7bb70b4cb7fecc
Plate_holder_002/Plane_307|Constructive_wood=cb7bb70b4cb7fecc
Plate_holder_003/Plane_307|Constructive_wood=cb7bb70b4cb7fecc
Plate_holder_004/Plane_307|Constructive_wood=cb7bb70b4cb7fecc
Plate_holder_005/Plane_307|Constructive_wood=cb7bb70b4cb7fecc
Plate_holder_006/Plane_307|Constructive_wood=cb7bb70b4cb7fecc
Plates/Circle_016|Glossy_white=9c5dbef8ffb54e1e
Plates_001/Circle_016|Glossy_white=9c5dbef8ffb54e1e
Plates_002/Circle_016|Glossy_white=9c5dbef8ffb54e1e
Plates_003/Circle_016|Glossy_white=9c5dbef8ffb54e1e
Plates_004/Circle_016|Glossy_white=9c5dbef8ffb54e1e
Plates_005/Circle_016|Glossy_white=9c5dbef8ffb54e1e
Plates_006/Circle_016|Glossy_white=9c5dbef8ffb54e1e
Pool/Plane_014|Pool_tiles=6055c62d82b20b37
Pool_edge/Plane_278|Concrete=34a74c7319186a2a
Pool_ladder/Circle_033|Dark_metal=aa0066d682ec57b3
Pool_water/Plane_279|Pool_water=8364ddcdf1bb11c4
Pool_water_001/Plane_280|Pool_volume=2e38e77b22c314a4
Porch_Stairs/Plane_042|Stone_paths=412c64cbac4bff57
Porch_Stairs_001/Plane_047|Stone_paths=412c64cbac4bff57
Porch_Stairs_002/Plane_048|Stone_paths=412c64cbac4bff57
Porch_Stairs_003/Plane_052|Stone_paths=412c64cbac4bff57
Porch_Stairs_004/Plane_053|Stone_paths=412c64cbac4bff57
Porch_Stairs_005/Plane_056|Stone_paths=412c64cbac4bff57
Porch_Stairs_006/Plane_057|Stone_paths=412c64cbac4bff57
Porch_Stairs_007/Plane_060|Stone_paths=412c64cbac4bff57
Porch_beams/Plane_026|White_wood=314521219fa27ae9
Porch_beams_001/Plane_043|White_wood=314521219fa27ae9
Porch_collum_001/Plane_034|Cobblestone=d2145cabbd1bcc20
Porch_collum_001/Plane_034|Stone=7df8dabe637dda1c
Porch_collum_001/Plane_034|White_wood=c4e6d45525c82619
Porch_collum_002/Plane_034|Cobblestone=9afbd6f8735e2db5
Porch_collum_002/Plane_034|Stone=2124659109f80491
Porch_collum_002/Plane_034|White_wood=314521219fa27ae9
Porch_collum_003/Plane_034|Cobblestone=9afbd6f8735e2db5
Porch_collum_003/Plane_034|Stone=2124659109f80491
Porch_collum_003/Plane_034|White_wood=314521219fa27ae9
Porch_collum_004/Plane_046|Cobblestone=9afbd6f8735e2db5
Porch_collum_004/Plane_046|Stone=2124659109f80491
Porch_collum_004/Plane_046|White_wood=314521219fa27ae9
Porch_collum_005/Plane_034|Cobblestone=9afbd6f8735e2db5
Porch_collum_005/Plane_034|Stone=2124659109f80491
Porch_collum_005/Plane_034|White_wood=314521219fa27ae9
Porch_collum_006/Plane_046|Cobblestone=9afbd6f8735e2db5
Porch_collum_006/Plane_046|Stone=2124659109f80491
Porch_collum_006/Plane_046|White_wood=314521219fa27ae9
Porch_fence/Plane_253|White_wood=314521219fa27ae9
Porch_fence_pole/Plane_256|White_wood=314521219fa27ae9
Porch_fence_pole_001/Plane_256|White_wood=314521219fa27ae9
Porch_fence_pole_002/Plane_256|White_wood=314521219fa27ae9
Porch_fence_pole_003/Plane_256|White_wood=314521219fa27ae9
Porch_fence_pole_004/Plane_256|White_wood=314521219fa27ae9
Porch_fence_pole_005/Plane_256|White_wood=314521219fa27ae9
Porch_fence_pole_006/Plane_256|White_wood=314521219fa27ae9
Porch_fence_pole_007/Plane_256|White_wood=314521219fa27ae9
Porch_fence_pole_008/Plane_256|White_wood=314521219fa27ae9
Porch_fence_pole_009/Plane_256|White_wood=314521219fa27ae9
Porch_fence_poles/Cube_002|White_wood=c4e6d45525c82619
Porch_fence_poles_001/Cube_002|White_wood=c4e6d45525c82619
Porch_fence_poles_002/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_003/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_004/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_005/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_006/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_007/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_008/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_009/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_010/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_011/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_012/Cube_002|White_wood=c4e6d45525c82619
Porch_fence_poles_013/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_014/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_015/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_016/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_017/Cube_002|White_wood=314521219fa27ae9
Porch_fence_poles_018/Cube_002|White_wood=314521219fa27ae9
Powderroom_mirror/Plane_325|Mirror_material=fe9a7244f520a91b
Roof/Plane_022|Roof_wood=12dc861532fc5359
Roof/Plane_022|White_drywall=6dd2d306090f10db
Roof/Plane_022|White_wood=314521219fa27ae9
Roof_Cover_001/Plane_223|Roof_wood=f597690d49ce1f2f
Roof_Cover_002/Plane_080|Roof_wood=12dc861532fc5359
Roof_Cover_003/Plane_083|Roof_wood=12dc861532fc5359
Roof_Cover_004/Plane_085|Roof_wood=12dc861532fc5359
Roof_Cover_005/Plane_086|Roof_wood=12dc861532fc5359
Roof_Cover_006/Plane_116|Roof_wood=12dc861532fc5359
Roof_Cover_007/Plane_088|Roof_wood=12dc861532fc5359
Roof_Cover_008/Plane_089|Roof_wood=12dc861532fc5359
Roof_Cover_009/Plane_090|Roof_wood=12dc861532fc5359
Roof_Cover_010/Plane_091|Roof_wood=12dc861532fc5359
Roof_Cover_011/Plane_092|Roof_wood=12dc861532fc5359
Roof_Cover_012/Plane_093|Roof_wood=12dc861532fc5359
Roof_Cover_013/Plane_094|Roof_wood=12dc861532fc5359
Roof_Cover_014/Plane_095|Roof_wood=12dc861532fc5359
Roof_Cover_015/Plane_096|Roof_wood=12dc861532fc5359
Roof_Cover_016/Plane_097|Roof_wood=12dc861532fc5359
Roof_Cover_017/Plane_098|Roof_wood=12dc861532fc5359
Roof_Cover_018/Plane_099|Roof_wood=12dc861532fc5359
Roof_Cover_036/Plane_117|Roof_wood=12dc861532fc5359
Roof_Cover_037/Plane_118|Roof_wood=12dc861532fc5359
Roof_Cover_038/Plane_119|Roof_wood=12dc861532fc5359
Roof_Cover_056/Plane_224|Roof_wood=12dc861532fc5359
Roof_Cover_057/Plane_225|Roof_wood=ffb717ea6e8b4591
Roof_corner_pieces_002/Plane_231|Painted_drywall=1e8cd5441fc74c1f
Roof_corner_pieces_002/Plane_231|White_drywall=5134e4b75c8f1a5d
SHC_Old_Book_001/Plane_229|Paper=4bf2229621039143
SHC_Old_Book_001/Plane_229|SHC_Old_Book_Material=749844f3003a0b1f
SHC_Old_Book_002/Plane_229|Paper=4bf2229621039143
SHC_Old_Book_002/Plane_229|SHC_Old_Book_Material=749844f3003a0b1f
SHC_Old_Book_003/Plane_229|Paper=4bf2229621039143
SHC_Old_Book_003/Plane_229|SHC_Old_Book_Material=749844f3003a0b1f
SHC_Old_Book_004/Plane_229|Paper=4bf2229621039143
SHC_Old_Book_004/Plane_229|SHC_Old_Book_Material=749844f3003a0b1f
SHC_Old_Book_005/Plane_232|Paper=21d443dcd8a4a652
SHC_Old_Book_005/Plane_232|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_006/Plane_232|Paper=4bf2229621039143
SHC_Old_Book_006/Plane_232|SHC_Old_Book_Material=749844f3003a0b1f
SHC_Old_Book_007/Plane_229|Paper=88762ae12a0d6d54
SHC_Old_Book_007/Plane_229|SHC_Old_Book_Material=37a1273a75b78d08
SHC_Old_Book_008/Plane_232|Paper=88762ae12a0d6d54
SHC_Old_Book_008/Plane_232|SHC_Old_Book_Material=37a1273a75b78d08
SHC_Old_Book_009/Plane_305|Paper=88762ae12a0d6d54
SHC_Old_Book_009/Plane_305|SHC_Old_Book_Material=37a1273a75b78d08
SHC_Old_Book_010/Plane_229|Paper=88762ae12a0d6d54
SHC_Old_Book_010/Plane_229|SHC_Old_Book_Material=37a1273a75b78d08
SHC_Old_Book_011/Plane_229|Paper=88762ae12a0d6d54
SHC_Old_Book_011/Plane_229|SHC_Old_Book_Material=37a1273a75b78d08
SHC_Old_Book_012/Plane_308|Paper=88762ae12a0d6d54
SHC_Old_Book_012/Plane_308|SHC_Old_Book_Material=37a1273a75b78d08
SHC_Old_Book_013/Plane_229|Paper=88762ae12a0d6d54
SHC_Old_Book_013/Plane_229|SHC_Old_Book_Material=37a1273a75b78d08
SHC_Old_Book_014/Plane_229|Paper=21d443dcd8a4a652
SHC_Old_Book_014/Plane_229|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_015/Plane_229|Paper=88762ae12a0d6d54
SHC_Old_Book_015/Plane_229|SHC_Old_Book_Material=37a1273a75b78d08
SHC_Old_Book_016/Plane_229|Paper=88762ae12a0d6d54
SHC_Old_Book_016/Plane_229|SHC_Old_Book_Material=37a1273a75b78d08
SHC_Old_Book_017/Plane_232|Paper=4bf2229621039143
SHC_Old_Book_017/Plane_232|SHC_Old_Book_Material=749844f3003a0b1f
SHC_Old_Book_018/Plane_315|Paper=88762ae12a0d6d54
SHC_Old_Book_018/Plane_315|SHC_Old_Book_Material=37a1273a75b78d08
SHC_Old_Book_019/Plane_232|Paper=21d443dcd8a4a652
SHC_Old_Book_019/Plane_232|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_020/Plane_308|Paper=21d443dcd8a4a652
SHC_Old_Book_020/Plane_308|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_021/Plane_1256|Paper=21d443dcd8a4a652
SHC_Old_Book_021/Plane_1256|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_022/Plane_1261|Paper=21d443dcd8a4a652
SHC_Old_Book_022/Plane_1261|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_023/Plane_1262|Paper=21d443dcd8a4a652
SHC_Old_Book_023/Plane_1262|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_024/Plane_1256|Paper=21d443dcd8a4a652
SHC_Old_Book_024/Plane_1256|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_025/Plane_1261|Paper=21d443dcd8a4a652
SHC_Old_Book_025/Plane_1261|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_026/Plane_315|Paper=21d443dcd8a4a652
SHC_Old_Book_026/Plane_315|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_027/Plane_1262|Paper=21d443dcd8a4a652
SHC_Old_Book_027/Plane_1262|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_028/Plane_1262|Paper=21d443dcd8a4a652
SHC_Old_Book_028/Plane_1262|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_029/Plane_1262|Paper=21d443dcd8a4a652
SHC_Old_Book_029/Plane_1262|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_030/Plane_229|Paper=21d443dcd8a4a652
SHC_Old_Book_030/Plane_229|SHC_Old_Book_Material=f1518bdfd21d676a
SHC_Old_Book_031/Plane_229|Paper=88762ae12a0d6d54
SHC_Old_Book_031/Plane_229|SHC_Old_Book_Material=37a1273a75b78d08
SHC_Old_Book_032/Plane_229|Paper=88762ae12a0d6d54
SHC_Old_Book_032/Plane_229|SHC_Old_Book_Material=37a1273a75b78d08
SHC_Old_Book_033/Plane_229|Paper=f1083eedea687329
SHC_Old_Book_033/Plane_229|SHC_Old_Book_Material=90dd25060bcf0bd7
SHC_Old_Book_034/Plane_308|Paper=f1083eedea687329
SHC_Old_Book_034/Plane_308|SHC_Old_Book_Material=90dd25060bcf0bd7
SHC_Old_Book_035/Plane_229|Paper=4bf2229621039143
SHC_Old_Book_035/Plane_229|SHC_Old_Book_Material=749844f3003a0b1f
SHC_Old_Book_036/Plane_229|Paper=f1083eedea687329
SHC_Old_Book_036/Plane_229|SHC_Old_Book_Material=90dd25060bcf0bd7
SHC_Old_Book_037/Plane_232|Paper=f1083eedea687329
SHC_Old_Book_037/Plane_232|SHC_Old_Book_Material=90dd25060bcf0bd7
SHC_Old_Book_038/Plane_229|Paper=b27aef48404add34
SHC_Old_Book_038/Plane_229|SHC_Old_Book_Material=3d602eaf559bd780
SHC_Old_Book_039/Plane_229|Paper=b27aef48404add34
SHC_Old_Book_039/Plane_229|SHC_Old_Book_Material=3d602eaf559bd780
SHC_Old_Book_040/Plane_232|Paper=b27aef48404add34
SHC_Old_Book_040/Plane_232|SHC_Old_Book_Material=3d602eaf559bd780
SHC_Old_Book_041/Plane_232|Paper=b27aef48404add34
SHC_Old_Book_041/Plane_232|SHC_Old_Book_Material=3d602eaf559bd780
SHC_Old_Book_042/Plane_232|Paper=b27aef48404add34
SHC_Old_Book_042/Plane_232|SHC_Old_Book_Material=3d602eaf559bd780
SHC_Old_Book_043/Plane_229|Paper=b5a4668d2f4ae661
SHC_Old_Book_043/Plane_229|SHC_Old_Book_Material=e413e9ac53305e55
SHC_Old_Book_044/Plane_229|Paper=b5a4668d2f4ae661
SHC_Old_Book_044/Plane_229|SHC_Old_Book_Material=e413e9ac53305e55
SHC_Old_Book_045/Plane_229|Paper=b5a4668d2f4ae661
SHC_Old_Book_045/Plane_229|SHC_Old_Book_Material=e413e9ac53305e55
SHC_Old_Book_046/Plane_229|Paper=b5a4668d2f4ae661
SHC_Old_Book_046/Plane_229|SHC_Old_Book_Material=e413e9ac53305e55
SHC_Old_Book_047/Plane_229|Paper=b5a4668d2f4ae661
SHC_Old_Book_047/Plane_229|SHC_Old_Book_Material=e413e9ac53305e55
SHC_Old_Book_048/Plane_229|Paper=b5a4668d2f4ae661
SHC_Old_Book_048/Plane_229|SHC_Old_Book_Material=e413e9ac53305e55
SHC_Old_Book_049/Plane_229|Paper=4bf2229621039143
SHC_Old_Book_049/Plane_229|SHC_Old_Book_Material=749844f3003a0b1f
SHC_Old_Book_050/Plane_229|Paper=b5a4668d2f4ae661
SHC_Old_Book_050/Plane_229|SHC_Old_Book_Material=e413e9ac53305e55
SHC_Old_Book_051/Plane_232|Paper=b5a4668d2f4ae661
SHC_Old_Book_051/Plane_232|SHC_Old_Book_Material=e413e9ac53305e55
SHC_Old_Book_052/Plane_229|Paper=b5a4668d2f4ae661
SHC_Old_Book_052/Plane_229|SHC_Old_Book_Material=e413e9ac53305e55
SHC_Old_Book_053/Plane_315|Paper=b5a4668d2f4ae661
SHC_Old_Book_053/Plane_315|SHC_Old_Book_Material=e413e9ac53305e55
SHC_Old_Book_054/Plane_229|Paper=b5a4668d2f4ae661
SHC_Old_Book_054/Plane_229|SHC_Old_Book_Material=e413e9ac53305e55
SHC_Old_Book_055/Plane_308|Paper=b5a4668d2f4ae661
SHC_Old_Book_055/Plane_308|SHC_Old_Book_Material=e413e9ac53305e55
SHC_Old_Book_056/Plane_232|Paper=b27aef48404add34
SHC_Old_Book_056/Plane_232|SHC_Old_Book_Material=3d602eaf559bd780
SHC_Old_Book_057/Plane_229|Paper=b27aef48404add34
SHC_Old_Book_057/Plane_229|SHC_Old_Book_Material=3d602eaf559bd780
SHC_Old_Book_058/Plane_229|Paper=b27aef48404add34
SHC_Old_Book_058/Plane_229|SHC_Old_Book_Material=3d602eaf559bd780
Shelves/Plane_215|Constructive_wood=f0bcb384a7995a80
Shelves/Plane_215|Dark_metal=97dc2a3af337a69a
Shelves_001/Plane_235|Constructive_wood=cb7bb70b4cb7fecc
Shelves_001/Plane_235|Dark_metal=4a3dbebe6a54a505
Shelves_002/Plane_235|Constructive_wood=f0bcb384a7995a80
Shelves_002/Plane_235|Dark_metal=97dc2a3af337a69a
Shelves_003/Plane_215|Constructive_wood=cb7bb70b4cb7fecc
Shelves_003/Plane_215|Dark_metal=4a3dbebe6a54a505
Shelves_004/Plane_311|Constructive_wood=cb7bb70b4cb7fecc
Shelves_004/Plane_311|Dark_metal=4a3dbebe6a54a505
Shelves_005/Plane_311|Constructive_wood=cb7bb70b4cb7fecc
Shelves_005/Plane_311|Dark_metal=4a3dbebe6a54a505
Shelves_006/Plane_311|Constructive_wood=3ef82d1456172973
Shelves_006/Plane_311|Dark_metal=5d485fc17c6f202f
Shelves_007/Plane_215|Constructive_wood=cb7bb70b4cb7fecc
Shelves_007/Plane_215|Dark_metal=4a3dbebe6a54a505
Shelves_008/Plane_311|Constructive_wood=de13716e2fe56c8e
Shelves_008/Plane_311|Dark_metal=aa0066d682ec57b3
Shelves_009/Plane_311|Constructive_wood=cb7bb70b4cb7fecc
Shelves_009/Plane_311|Dark_metal=4a3dbebe6a54a505
Shelves_010/Plane_309|Constructive_wood=cb7bb70b4cb7fecc
Shelves_010/Plane_309|Dark_metal=4a3dbebe6a54a505
Shelves_011/Plane_215|Constructive_wood=3ef82d1456172973
Shelves_011/Plane_215|Dark_metal=5d485fc17c6f202f
Shelves_012/Plane_314|Constructive_wood=de13716e2fe56c8e
Shelves_012/Plane_314|Dark_metal=aa0066d682ec57b3
Shelves_013/Plane_311|Constructive_wood=cb7bb70b4cb7fecc
Shelves_013/Plane_311|Dark_metal=4a3dbebe6a54a505
Shelves_014/Plane_215|Constructive_wood=77e89426cea78717
Shelves_014/Plane_215|Dark_metal=6d06e5e1ca46a044
Shelves_015/Plane_311|Constructive_wood=77e89426cea78717
Shelves_015/Plane_311|Dark_metal=6d06e5e1ca46a044
Shelves_016/Plane_235|Constructive_wood=f0bcb384a7995a80
Shelves_016/Plane_235|Dark_metal=97dc2a3af337a69a
Shelves_017/Plane_311|Constructive_wood=de13716e2fe56c8e
Shelves_017/Plane_311|Dark_metal=aa0066d682ec57b3
Shelves_018/Plane_215|Constructive_wood=de13716e2fe56c8e
Shelves_018/Plane_215|Dark_metal=aa0066d682ec57b3
Shelves_019/Plane_311|Constructive_wood=faaa8e22b59aea72
Shelves_019/Plane_311|Dark_metal=a2a72064cfaf0b41
Shelves_020/Plane_314|Constructive_wood=faaa8e22b59aea72
Shelves_020/Plane_314|Dark_metal=a2a72064cfaf0b41
Shelves_021/Plane_314|Constructive_wood=faaa8e22b59aea72
Shelves_021/Plane_314|Dark_metal=a2a72064cfaf0b41
Shelves_022/Plane_314|Constructive_wood=faaa8e22b59aea72
Shelves_022/Plane_314|Dark_metal=a2a72064cfaf0b41
Shelves_023/Plane_314|Constructive_wood=faaa8e22b59aea72
Shelves_023/Plane_314|Dark_metal=a2a72064cfaf0b41
Shelves_024/Plane_215|Constructive_wood=faaa8e22b59aea72
Shelves_024/Plane_215|Dark_metal=a2a72064cfaf0b41
Shelves_025/Plane_311|Constructive_wood=faaa8e22b59aea72
Shelves_025/Plane_311|Dark_metal=a2a72064cfaf0b41
Shelves_026/Plane_311|Constructive_wood=faaa8e22b59aea72
Shelves_026/Plane_311|Dark_metal=a2a72064cfaf0b41
Sink/Plane_257|Granite=6cc82c69783defeb
Sink/Plane_257|bright_metal=c6d53880431bd676
Sink_Tap/Circle_028|Antracite_metal=acc4e2804bd6b20e
Sink_Tap/Circle_028|Glossy_white=fa5d6b9fcc35e91d
Sink_Tap_001/Circle_028|Antracite_metal=acc4e2804bd6b20e
Sink_Tap_001/Circle_028|Glossy_white=fa5d6b9fcc35e91d
Sink_Tap_002/Circle_028|Antracite_metal=4748657eae2c6317
Sink_Tap_002/Circle_028|Glossy_white=68dab8d5ccc98739
Sink_Tap_003/Circle_028|Antracite_metal=e1a7378360030794
Sink_Tap_003/Circle_028|Glossy_white=710687e7f1406be0
Sink_Tap_004/Circle_028|Antracite_metal=e1a7378360030794
Sink_Tap_004/Circle_028|Glossy_white=710687e7f1406be0
Sloped_interior_door/Plane_234|Dark_metal=6d06e5e1ca46a044
Sloped_interior_door/Plane_234|White_wood=19e0696ae5a8d70a
Sloped_interior_door/Plane_234|bright_metal=5cb5da71c051919d
Soap_bottle/Plane_324|Glossy_white=9c5dbef8ffb54e1e
Soap_bottle_/Plane_324|Glossy_white=fa5d6b9fcc35e91d
Soap_bottle_001/Plane_324|Glossy_white=9c5dbef8ffb54e1e
Soap_bottle_002/Plane_324|Glossy_white=9c5dbef8ffb54e1e
Soap_bottle_003/Plane_324|Glossy_white=9c5dbef8ffb54e1e
Soap_bottle_004/Plane_324|Glossy_white=fa5d6b9fcc35e91d
Soap_bottle_005/Plane_324|Glossy_white=fa5d6b9fcc35e91d
Soap_bottle_006/Plane_324|Glossy_white=fa5d6b9fcc35e91d
Soap_bottle_007/Plane_324|Glossy_white=fa5d6b9fcc35e91d
Soap_bottle__001/Plane_324|Glossy_white=fa5d6b9fcc35e91d
Soap_bottle__002/Plane_324|Glossy_white=fa5d6b9fcc35e91d
Soap_bottle__003/Plane_324|Glossy_white=9c5dbef8ffb54e1e
Soap_bottle__004/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__005/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__006/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__007/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__008/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__009/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__010/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__011/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__012/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__013/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__014/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__015/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__016/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__017/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__018/Plane_324|Glossy_white=710687e7f1406be0
Soap_bottle__019/Plane_324|Glossy_white=710687e7f1406be0
Solar_battery/Plane_350|Black_plastic=daac43abc2473a14
Solar_battery/Plane_350|Glossy_white=fa5d6b9fcc35e91d
Solar_battery_001/Plane_350|Black_plastic=daac43abc2473a14
Solar_battery_001/Plane_350|Glossy_white=fa5d6b9fcc35e91d
Solar_panels/Plane_353|Dark_metal=aa0066d682ec57b3
Solar_panels/Plane_353|Solar_panel=95e4ae48c08d34af
Solar_panels_001/Plane_353|Dark_metal=aa0066d682ec57b3
Solar_panels_001/Plane_353|Solar_panel=95e4ae48c08d34af
Soundbar/Plane_331|Black_plastic=67ae0a3d88fa24e9
Soundbar/Plane_331|Grey_fabric=5dadb36f1857c90e
Soundbar_001/Plane_331|Black_plastic=d1724b5d725765ef
Soundbar_001/Plane_331|Grey_fabric=97f477601b2536fe
Stair_fence/Plane_249|White_wood=19e0696ae5a8d70a
Stair_fence_poles/Cube_001|White_wood=19e0696ae5a8d70a
Stairs/Plane_247|White_wood=22cbf8cb684258df
Standing_lamp/Plane_233|Constructive_wood=f0bcb384a7995a80
Standing_lamp/Plane_233|Dark_metal=97dc2a3af337a69a
Standing_lamp/Plane_233|Light=2e38e77b22c314a4
Stool_001/Plane_292|Constructive_wood=cb7bb70b4cb7fecc
Stool_001/Plane_292|Dark_metal=4a3dbebe6a54a505
Stool_001/Plane_292|Grey_fabric=07fb671e08f58d74
Stool_002/Plane_292|Constructive_wood=cb7bb70b4cb7fecc
Stool_002/Plane_292|Dark_metal=4a3dbebe6a54a505
Stool_002/Plane_292|Grey_fabric=07fb671e08f58d74
Stool_003/Plane_292|Constructive_wood=cb7bb70b4cb7fecc
Stool_003/Plane_292|Dark_metal=4a3dbebe6a54a505
Stool_003/Plane_292|Grey_fabric=07fb671e08f58d74
Stool_004/Plane_292|Constructive_wood=cb7bb70b4cb7fecc
Stool_004/Plane_292|Dark_metal=4a3dbebe6a54a505
Stool_004/Plane_292|Grey_fabric=07fb671e08f58d74
Suzanne/Suzanne_001|Glossy_white=9e6d5f568f36688d
TV/Plane_303|Glossy_Black=ce0f5cf46fe3ec25
TV/Plane_303|Tv_display=559fe984d491a2eb
TV_001/Plane_303|Glossy_Black=e8695977cc62853d
TV_001/Plane_303|Tv_display=aa94de744610911c
TV_002/Plane_303|Glossy_Black=dba184b08fef932f
TV_002/Plane_303|Tv_display=44258fd2adcbc80b
TV_003/Plane_303|Glossy_Black=805ebfd897183108
TV_003/Plane_303|Tv_display=77cc7b66e69d22a4
TV_004/Plane_303|Glossy_Black=805ebfd897183108
TV_004/Plane_303|Tv_display=77cc7b66e69d22a4
Terrain_002/Plane_059|Grass_particles=21f8bd0b88b43a80
Terrain_002/Plane_059|Stone_paths=412c64cbac4bff57
Terrain_002/Plane_059|Stone_paths_grey=412c64cbac4bff57
Terrain_003/Plane_061|Grass_particles=21f8bd0b88b43a80
Terrain_005/Plane_063|Grass_particles=21f8bd0b88b43a80
Terrain_007/Plane_066|Grass=cc3a122eb3ff59e3
Wahing_machine/Plane_348|Glossy_Black_2=e8695977cc62853d
Wahing_machine/Plane_348|Glossy_white=fa5d6b9fcc35e91d
Wall_art/Circle_026|Constructive_wood=f0bcb384a7995a80
Wall_art_001/Plane_246|Glossy_Black=ce0f5cf46fe3ec25
Wall_art_001/Plane_246|SHC_Art=20f4577a69a799cf
Wall_art_002/Circle_034|Constructive_wood=f0bcb384a7995a80
Wall_art_003/Plane_246|Glossy_Black=dba184b08fef932f
Wall_art_003/Plane_246|SHC_Art=70d363cadeecddd7
Wall_art_004/Circle_021|Constructive_wood=3ef82d1456172973
Wall_art_005/Circle_021|Constructive_wood=cb7bb70b4cb7fecc
Wall_art_006/Plane_246|Glossy_Black=e5f0241263329e92
Wall_art_006/Plane_246|SHC_Art=99041fd258f856c7
Wall_art_007/Circle_026|Constructive_wood=3ef82d1456172973
Wall_art_008/Plane_246|Glossy_Black=e8695977cc62853d
Wall_art_008/Plane_246|SHC_Art=af603243cf6917f2
Wall_art_009/Circle_021|Constructive_wood=de13716e2fe56c8e
Wall_art_010/Circle_026|Constructive_wood=de13716e2fe56c8e
Wall_art_011/Circle_021|Constructive_wood=cb7bb70b4cb7fecc
Wall_art_012/Circle_021|Constructive_wood=3ef82d1456172973
Wall_art_013/Circle_026|Constructive_wood=cb7bb70b4cb7fecc
Wall_art_014/Circle_034|Constructive_wood=77e89426cea78717
Wall_art_015/Circle_026|Constructive_wood=77e89426cea78717
Wall_art_016/Circle_021|Constructive_wood=3ef82d1456172973
Wall_art_017/Plane_246|Glossy_Black=805ebfd897183108
Wall_art_017/Plane_246|SHC_Art=937edf25dc490cbe
Wall_art_018/Circle_021|Constructive_wood=faaa8e22b59aea72
Wall_art_019/Circle_021|Constructive_wood=faaa8e22b59aea72
Wall_art_020/Plane_246|Glossy_Black=dba184b08fef932f
Wall_art_020/Plane_246|SHC_Art=70d363cadeecddd7
Wall_art_021/Plane_326|Black_wood=fb1013a3608d97ca
Wall_art_021/Plane_326|SHC_Art_001=ce6b7e811f9394d7
Wall_art_022/Plane_262|Black_wood=08ce2ad96cd14011
Wall_art_022/Plane_262|SHC_Art_2=0e1f72bd0e7fadb1
Wall_art_023/Plane_326|Black_wood=ac7ea1f412c043ef
Wall_art_023/Plane_326|SHC_Art_001=595a50e49f9e35fd
Wall_art_024/Plane_326|Black_wood=8584c3f8e3df586f
Wall_art_024/Plane_326|SHC_Art_001=cc366596d567b2a1
Wall_art_025/Plane_262|Black_wood=ac7ea1f412c043ef
Wall_art_025/Plane_262|SHC_Art_2=8fdf09f504e24516
Wall_art_026/Plane_326|Black_wood=ac7ea1f412c043ef
Wall_art_026/Plane_326|SHC_Art_001=595a50e49f9e35fd
Wall_outlet/Plane_339|Wall_socket_black=ad02797c658b3aaa
Wall_outlet/Plane_339|Wall_socket_white=ead0f86f7d04c736
Wall_outlet_001/Plane_339|Wall_socket_black=ad02797c658b3aaa
Wall_outlet_001/Plane_339|Wall_socket_white=ead0f86f7d04c736
Wall_outlet_002/Plane_339|Wall_socket_black=ad02797c658b3aaa
Wall_outlet_002/Plane_339|Wall_socket_white=ead0f86f7d04c736
Wall_outlet_003/Plane_339|Wall_socket_black=8e0da69eee5b3830
Wall_outlet_003/Plane_339|Wall_socket_white=8d280b27042fee7b
Wall_outlet_004/Plane_339|Wall_socket_black=e728a627161b5656
Wall_outlet_004/Plane_339|Wall_socket_white=ff8315a2b5eeff0e
Wall_outlet_005/Plane_339|Wall_socket_black=e728a627161b5656
Wall_outlet_005/Plane_339|Wall_socket_white=ff8315a2b5eeff0e
Wall_outlet_006/Plane_339|Wall_socket_black=e728a627161b5656
Wall_outlet_006/Plane_339|Wall_socket_white=ff8315a2b5eeff0e
Wall_outlet_007/Plane_339|Wall_socket_black=8e0da69eee5b3830
Wall_outlet_007/Plane_339|Wall_socket_white=8d280b27042fee7b
Wall_outlet_008/Plane_339|Wall_socket_black=8e0da69eee5b3830
Wall_outlet_008/Plane_339|Wall_socket_white=8d280b27042fee7b
Wall_outlet_009/Plane_339|Wall_socket_black=8e0da69eee5b3830
Wall_outlet_009/Plane_339|Wall_socket_white=8d280b27042fee7b
Wall_outlet_010/Plane_339|Wall_socket_black=8e0da69eee5b3830
Wall_outlet_010/Plane_339|Wall_socket_white=8d280b27042fee7b
Wall_outlet_011/Plane_339|Wall_socket_black=8e0da69eee5b3830
Wall_outlet_011/Plane_339|Wall_socket_white=8d280b27042fee7b
Wall_outlet_012/Plane_339|Wall_socket_black=b4f9fcb39f4f63ce
Wall_outlet_012/Plane_339|Wall_socket_white=979cacd206c620ae
Wall_outlet_013/Plane_339|Wall_socket_black=b4f9fcb39f4f63ce
Wall_outlet_013/Plane_339|Wall_socket_white=979cacd206c620ae
Wall_outlet_014/Plane_339|Wall_socket_black=b4f9fcb39f4f63ce
Wall_outlet_014/Plane_339|Wall_socket_white=979cacd206c620ae
Wall_outlet_015/Plane_339|Wall_socket_black=b4f9fcb39f4f63ce
Wall_outlet_015/Plane_339|Wall_socket_white=979cacd206c620ae
Wall_outlet_016/Plane_339|Wall_socket_black=2225c1b25e75ff47
Wall_outlet_016/Plane_339|Wall_socket_white=10c0db9de56cefa4
Wall_outlet_017/Plane_339|Wall_socket_black=8e0da69eee5b3830
Wall_outlet_017/Plane_339|Wall_socket_white=8d280b27042fee7b
Wall_outlet_018/Plane_339|Wall_socket_black=2225c1b25e75ff47
Wall_outlet_018/Plane_339|Wall_socket_white=10c0db9de56cefa4
Wall_outlet_019/Plane_339|Wall_socket_black=2225c1b25e75ff47
Wall_outlet_019/Plane_339|Wall_socket_white=10c0db9de56cefa4
Wall_outlet_020/Plane_339|Wall_socket_black=2225c1b25e75ff47
Wall_outlet_020/Plane_339|Wall_socket_white=10c0db9de56cefa4
Wall_outlet_021/Plane_339|Wall_socket_black=2225c1b25e75ff47
Wall_outlet_021/Plane_339|Wall_socket_white=10c0db9de56cefa4
Wall_outlet_022/Plane_339|Wall_socket_black=2225c1b25e75ff47
Wall_outlet_022/Plane_339|Wall_socket_white=10c0db9de56cefa4
Wall_outlet_023/Plane_339|Wall_socket_black=2225c1b25e75ff47
Wall_outlet_023/Plane_339|Wall_socket_white=10c0db9de56cefa4
Wall_outlet_024/Plane_339|Wall_socket_black=2225c1b25e75ff47
Wall_outlet_024/Plane_339|Wall_socket_white=10c0db9de56cefa4
Wall_outlet_025/Plane_339|Wall_socket_black=177372aca6b3a7e9
Wall_outlet_025/Plane_339|Wall_socket_white=bd941b4da0b85f4c
Wall_outlet_026/Plane_339|Wall_socket_black=e728a627161b5656
Wall_outlet_026/Plane_339|Wall_socket_white=ff8315a2b5eeff0e
Wall_outlet_027/Plane_339|Wall_socket_black=2225c1b25e75ff47
Wall_outlet_027/Plane_339|Wall_socket_white=10c0db9de56cefa4
Wall_outlet_028/Plane_339|Wall_socket_black=2225c1b25e75ff47
Wall_outlet_028/Plane_339|Wall_socket_white=10c0db9de56cefa4
Wall_outlet_029/Plane_339|Wall_socket_black=e728a627161b5656
Wall_outlet_029/Plane_339|Wall_socket_white=ff8315a2b5eeff0e
Wall_outlet_030/Plane_339|Wall_socket_black=177372aca6b3a7e9
Wall_outlet_030/Plane_339|Wall_socket_white=bd941b4da0b85f4c
Wall_outlet_031/Plane_339|Wall_socket_black=177372aca6b3a7e9
Wall_outlet_031/Plane_339|Wall_socket_white=bd941b4da0b85f4c
Wall_outlet_032/Plane_339|Wall_socket_black=177372aca6b3a7e9
Wall_outlet_032/Plane_339|Wall_socket_white=bd941b4da0b85f4c
Wall_outlet_033/Plane_339|Wall_socket_black=177372aca6b3a7e9
Wall_outlet_033/Plane_339|Wall_socket_white=bd941b4da0b85f4c
Wall_outlet_034/Plane_339|Wall_socket_black=177372aca6b3a7e9
Wall_outlet_034/Plane_339|Wall_socket_white=bd941b4da0b85f4c
Wall_outlet_035/Plane_339|Wall_socket_black=177372aca6b3a7e9
Wall_outlet_035/Plane_339|Wall_socket_white=bd941b4da0b85f4c
Wall_outlet_036/Plane_339|Wall_socket_black=2225c1b25e75ff47
Wall_outlet_036/Plane_339|Wall_socket_white=10c0db9de56cefa4
Wall_outlet_037/Plane_339|Wall_socket_black=2225c1b25e75ff47
Wall_outlet_037/Plane_339|Wall_socket_white=10c0db9de56cefa4
Wall_outlet_038/Plane_339|Wall_socket_black=177372aca6b3a7e9
Wall_outlet_038/Plane_339|Wall_socket_white=bd941b4da0b85f4c
Wall_outlet_039/Plane_339|Wall_socket_black=177372aca6b3a7e9
Wall_outlet_039/Plane_339|Wall_socket_white=bd941b4da0b85f4c
Wall_outlet_040/Plane_339|Wall_socket_black=177372aca6b3a7e9
Wall_outlet_040/Plane_339|Wall_socket_white=bd941b4da0b85f4c
Wall_outlet_041/Plane_339|Wall_socket_black=177372aca6b3a7e9
Wall_outlet_041/Plane_339|Wall_socket_white=bd941b4da0b85f4c
Wall_outlet_042/Plane_339|Wall_socket_black=177372aca6b3a7e9
Wall_outlet_042/Plane_339|Wall_socket_white=bd941b4da0b85f4c
Wall_outlet_043/Plane_339|Wall_socket_black=2225c1b25e75ff47
Wall_outlet_043/Plane_339|Wall_socket_white=10c0db9de56cefa4
Wall_outlet_044/Plane_339|Wall_socket_black=e728a627161b5656
Wall_outlet_044/Plane_339|Wall_socket_white=ff8315a2b5eeff0e
Wall_outlet_045/Plane_339|Wall_socket_black=e728a627161b5656
Wall_outlet_045/Plane_339|Wall_socket_white=ff8315a2b5eeff0e
Wall_outlet_046/Plane_339|Wall_socket_black=e728a627161b5656
Wall_outlet_046/Plane_339|Wall_socket_white=ff8315a2b5eeff0e
Wall_outlet_047/Plane_339|Wall_socket_black=e728a627161b5656
Wall_outlet_047/Plane_339|Wall_socket_white=ff8315a2b5eeff0e
Wall_siding/Plane_140|Blue_wood=81f357ca6c1b7ce1
Wall_siding_001/Plane_141|Blue_wood=81f357ca6c1b7ce1
Wall_siding_002/Plane_142|Blue_wood=81f357ca6c1b7ce1
Wall_siding_003/Plane_143|Blue_wood=81f357ca6c1b7ce1
Wall_siding_004/Plane_144|Blue_wood=81f357ca6c1b7ce1
Wall_siding_005/Plane_146|Blue_wood=81f357ca6c1b7ce1
Wall_siding_006/Plane_148|Blue_wood=81f357ca6c1b7ce1
Wall_siding_007/Plane_149|Blue_wood=81f357ca6c1b7ce1
Wall_siding_008/Plane_150|Blue_wood=81f357ca6c1b7ce1
Wall_siding_009/Plane_152|Blue_wood=81f357ca6c1b7ce1
Wall_siding_010/Plane_153|Blue_wood=81f357ca6c1b7ce1
Wall_siding_011/Plane_154|Blue_wood=81f357ca6c1b7ce1
Wall_siding_013/Plane_260|Blue_wood=3053ac04a449b3f1
Wall_siding_014/Plane_261|Blue_wood=cba446ae96384a9f
Wall_siding_015/Plane_201|Blue_wood=691cbc411a8a18cc
Wall_siding_016/Plane_263|Blue_wood=691cbc411a8a18cc
Wall_siding_017/Plane_264|Blue_wood=691cbc411a8a18cc
Wall_siding_021/Plane_272|Blue_wood=81f357ca6c1b7ce1
Wall_siding_022/Plane_273|Blue_wood=691cbc411a8a18cc
Wall_siding_023/Plane_274|Blue_wood=691cbc411a8a18cc
Wall_siding_024/Plane_275|Blue_wood=691cbc411a8a18cc
Wall_siding_025/Plane_276|Blue_wood=691cbc411a8a18cc
Wall_siding_026/Plane_268|Blue_wood=9fea581defc5d2fb
Wall_siding_027/Plane_281|Blue_wood=81f357ca6c1b7ce1
Wall_siding_028/Plane_282|Blue_wood=9fea581defc5d2fb
Wall_siding_029/Plane_283|Blue_wood=9fea581defc5d2fb
Wall_siding_030/Plane_286|Blue_wood=9fea581defc5d2fb
Wall_siding_031/Plane_287|Blue_wood=81f357ca6c1b7ce1
Wall_siding_032/Plane_207|Blue_wood=81f357ca6c1b7ce1
Wall_siding_033/Plane_211|Blue_wood=81f357ca6c1b7ce1
Wall_siding_034/Plane_212|Blue_wood=81f357ca6c1b7ce1
Wall_siding_035/Plane_216|Blue_wood=81f357ca6c1b7ce1
Wall_siding_036/Plane_218|Blue_wood=81f357ca6c1b7ce1
Wall_siding_037/Plane_219|Blue_wood=81f357ca6c1b7ce1
Wall_siding_038/Plane_220|Blue_wood=3053ac04a449b3f1
Wall_siding_039/Plane_221|Blue_wood=3053ac04a449b3f1
Wall_siding_040/Plane_226|Blue_wood=3053ac04a449b3f1
Wall_siding_041/Plane_227|Blue_wood=3053ac04a449b3f1
Window_Cover/Plane_329|Glossy_white=9e6d5f568f36688d
Window_Cover/Plane_329|Window_cover=5dadb36f1857c90e
Window_Cover_001/Plane_329|Glossy_white=9e6d5f568f36688d
Window_Cover_001/Plane_329|Window_cover=5dadb36f1857c90e
Window_Cover_002/Plane_329|Glossy_white=9e6d5f568f36688d
Window_Cover_002/Plane_329|Window_cover=5dadb36f1857c90e
Window_Cover_003/Plane_329|Glossy_white=9e6d5f568f36688d
Window_Cover_003/Plane_329|Window_cover=5dadb36f1857c90e
Window_Cover_004/Plane_329|Glossy_white=9e6d5f568f36688d
Window_Cover_004/Plane_329|Window_cover=5dadb36f1857c90e
Window_Cover_005/Plane_329|Glossy_white=9e6d5f568f36688d
Window_Cover_005/Plane_329|Window_cover=5dadb36f1857c90e
Window_Cover_006/Plane_329|Glossy_white=9e6d5f568f36688d
Window_Cover_006/Plane_329|Window_cover=5dadb36f1857c90e
Window_Cover_007/Plane_329|Glossy_white=9e6d5f568f36688d
Window_Cover_007/Plane_329|Window_cover=5dadb36f1857c90e
Window_Cover_008/Plane_329|Glossy_white=9e6d5f568f36688d
Window_Cover_008/Plane_329|Window_cover=5dadb36f1857c90e
Window_Cover_009/Plane_329|Glossy_white=9e6d5f568f36688d
Window_Cover_009/Plane_329|Window_cover=5dadb36f1857c90e
Window_Cover_010/Plane_329|Glossy_white=fa5d6b9fcc35e91d
Window_Cover_010/Plane_329|Window_cover=4c8e805710536c5b
Window_Cover_011/Plane_329|Glossy_white=fa5d6b9fcc35e91d
Window_Cover_011/Plane_329|Window_cover=4c8e805710536c5b
Window_Cover_012/Plane_329|Glossy_white=fa5d6b9fcc35e91d
Window_Cover_012/Plane_329|Window_cover=4c8e805710536c5b
Window_Cover_013/Plane_329|Glossy_white=fa5d6b9fcc35e91d
Window_Cover_013/Plane_329|Window_cover=4c8e805710536c5b
Window_Cover_014/Plane_329|Glossy_white=9c5dbef8ffb54e1e
Window_Cover_014/Plane_329|Window_cover=07fb671e08f58d74
Window_Cover_015/Plane_329|Glossy_white=9c5dbef8ffb54e1e
Window_Cover_015/Plane_329|Window_cover=07fb671e08f58d74
Window_Cover_016/Plane_329|Glossy_white=68dab8d5ccc98739
Window_Cover_016/Plane_329|Window_cover=e3535eadbe9086cc
Window_Cover_017/Plane_329|Glossy_white=68dab8d5ccc98739
Window_Cover_017/Plane_329|Window_cover=e3535eadbe9086cc
Window_Cover_018/Plane_329|Glossy_white=68dab8d5ccc98739
Window_Cover_018/Plane_329|Window_cover=e3535eadbe9086cc
Window_Cover_019/Plane_329|Glossy_white=68dab8d5ccc98739
Window_Cover_019/Plane_329|Window_cover=e3535eadbe9086cc
Window_Cover_020/Plane_329|Glossy_white=68dab8d5ccc98739
Window_Cover_020/Plane_329|Window_cover=e3535eadbe9086cc
Window_Cover_021/Plane_329|Glossy_white=68dab8d5ccc98739
Window_Cover_021/Plane_329|Window_cover=e3535eadbe9086cc
Window_Cover_022/Plane_329|Glossy_white=68dab8d5ccc98739
Window_Cover_022/Plane_329|Window_cover=e3535eadbe9086cc
Window_Cover_023/Plane_329|Glossy_white=68dab8d5ccc98739
Window_Cover_023/Plane_329|Window_cover=e3535eadbe9086cc
Window_Cover_024/Plane_329|Glossy_white=fa5d6b9fcc35e91d
Window_Cover_024/Plane_329|Window_cover=4c8e805710536c5b
Window_Cover_025/Plane_329|Glossy_white=fa5d6b9fcc35e91d
Window_Cover_025/Plane_329|Window_cover=4c8e805710536c5b
Window_Cover_026/Plane_329|Glossy_white=fa5d6b9fcc35e91d
Window_Cover_026/Plane_329|Window_cover=4c8e805710536c5b
Window_Cover_027/Plane_329|Glossy_white=fa5d6b9fcc35e91d
Window_Cover_027/Plane_329|Window_cover=4c8e805710536c5b
Window_Cover_028/Plane_329|Glossy_white=f3b22091b1df207d
Window_Cover_028/Plane_329|Window_cover=97f477601b2536fe
Window_Cover_029/Plane_329|Glossy_white=f3b22091b1df207d
Window_Cover_029/Plane_329|Window_cover=97f477601b2536fe
Window_Cover_030/Plane_329|Glossy_white=f3b22091b1df207d
Window_Cover_030/Plane_329|Window_cover=97f477601b2536fe
Window_Cover_031/Plane_329|Glossy_white=f3b22091b1df207d
Window_Cover_031/Plane_329|Window_cover=97f477601b2536fe
Window_Cover_032/Plane_329|Glossy_white=f3b22091b1df207d
Window_Cover_032/Plane_329|Window_cover=97f477601b2536fe
Window_Cover_033/Plane_329|Glossy_white=f3b22091b1df207d
Window_Cover_033/Plane_329|Window_cover=97f477601b2536fe
Window_Cover_034/Plane_329|Glossy_white=f3b22091b1df207d
Window_Cover_034/Plane_329|Window_cover=97f477601b2536fe
Window_Cover_035/Plane_329|Glossy_white=fa5d6b9fcc35e91d
Window_Cover_035/Plane_329|Window_cover=4c8e805710536c5b
Window_Cover_036/Plane_329|Glossy_white=f3b22091b1df207d
Window_Cover_036/Plane_329|Window_cover=97f477601b2536fe
Window_Cover_037/Plane_329|Glossy_white=710687e7f1406be0
Window_Cover_037/Plane_329|Window_cover=efc540e07fa27834
Window_Cover_038/Plane_329|Glossy_white=710687e7f1406be0
Window_Cover_038/Plane_329|Window_cover=efc540e07fa27834
Window_Cover_039/Plane_329|Glossy_white=710687e7f1406be0
Window_Cover_039/Plane_329|Window_cover=efc540e07fa27834
Window_Cover_040/Plane_329|Glossy_white=710687e7f1406be0
Window_Cover_040/Plane_329|Window_cover=efc540e07fa27834
Window_Cover_041/Plane_329|Glossy_white=710687e7f1406be0
Window_Cover_041/Plane_329|Window_cover=efc540e07fa27834
Window_Cover_042/Plane_329|Glossy_white=710687e7f1406be0
Window_Cover_042/Plane_329|Window_cover=efc540e07fa27834
Window_Type_D1/Plane_255|Glass=a3abf08155880dc1
Window_Type_D1/Plane_255|White_wood=c4e6d45525c82619
Window_frame_A1_003/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_003/Plane_196|White_wood=22cbf8cb684258df
Window_frame_A1_004/Plane_199|White_wood=22cbf8cb684258df
Window_frame_A1_005/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_005/Plane_200|White_wood=22cbf8cb684258df
Window_frame_A1_006/Plane_202|Glass=a3abf08155880dc1
Window_frame_A1_006/Plane_202|White_wood=314521219fa27ae9
Window_frame_A1_007/Plane_203|Glass=a3abf08155880dc1
Window_frame_A1_007/Plane_203|White_wood=314521219fa27ae9
Window_frame_A1_008/Plane_202|Glass=a3abf08155880dc1
Window_frame_A1_008/Plane_202|White_wood=314521219fa27ae9
Window_frame_A1_009/Plane_203|Glass=a3abf08155880dc1
Window_frame_A1_009/Plane_203|White_wood=314521219fa27ae9
Window_frame_A1_010/Plane_202|Glass=a3abf08155880dc1
Window_frame_A1_010/Plane_202|White_wood=314521219fa27ae9
Window_frame_A1_011/Plane_203|Glass=a3abf08155880dc1
Window_frame_A1_011/Plane_203|White_wood=314521219fa27ae9
Window_frame_A1_012/Plane_208|Glass=a3abf08155880dc1
Window_frame_A1_012/Plane_208|White_wood=314521219fa27ae9
Window_frame_A1_013/Plane_209|Glass=a3abf08155880dc1
Window_frame_A1_013/Plane_209|White_wood=314521219fa27ae9
Window_frame_A1_014/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_014/Plane_196|White_wood=92d6d1a6a41ddc67
Window_frame_A1_015/Plane_199|White_wood=314521219fa27ae9
Window_frame_A1_016/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_016/Plane_200|White_wood=92d6d1a6a41ddc67
Window_frame_A1_017/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_017/Plane_196|White_wood=19e0696ae5a8d70a
Window_frame_A1_018/Plane_199|White_wood=314521219fa27ae9
Window_frame_A1_019/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_019/Plane_200|White_wood=19e0696ae5a8d70a
Window_frame_A1_020/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_020/Plane_196|White_wood=22cbf8cb684258df
Window_frame_A1_021/Plane_199|White_wood=22cbf8cb684258df
Window_frame_A1_022/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_022/Plane_200|White_wood=22cbf8cb684258df
Window_frame_A1_023/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_023/Plane_196|White_wood=92d6d1a6a41ddc67
Window_frame_A1_024/Plane_199|White_wood=92d6d1a6a41ddc67
Window_frame_A1_025/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_025/Plane_200|White_wood=92d6d1a6a41ddc67
Window_frame_A1_026/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_026/Plane_196|White_wood=c4e6d45525c82619
Window_frame_A1_027/Plane_199|White_wood=c4e6d45525c82619
Window_frame_A1_028/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_028/Plane_200|White_wood=c4e6d45525c82619
Window_frame_A1_029/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_029/Plane_196|White_wood=c4e6d45525c82619
Window_frame_A1_030/Plane_199|White_wood=c4e6d45525c82619
Window_frame_A1_031/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_031/Plane_200|White_wood=c4e6d45525c82619
Window_frame_A1_032/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_032/Plane_196|White_wood=c4e6d45525c82619
Window_frame_A1_033/Plane_199|White_wood=c4e6d45525c82619
Window_frame_A1_034/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_034/Plane_200|White_wood=c4e6d45525c82619
Window_frame_A1_035/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_035/Plane_196|White_wood=6ee6cf8f714c26e5
Window_frame_A1_036/Plane_199|White_wood=6ee6cf8f714c26e5
Window_frame_A1_037/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_037/Plane_200|White_wood=6ee6cf8f714c26e5
Window_frame_A1_038/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_038/Plane_196|White_wood=6ee6cf8f714c26e5
Window_frame_A1_039/Plane_199|White_wood=6ee6cf8f714c26e5
Window_frame_A1_040/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_040/Plane_200|White_wood=6ee6cf8f714c26e5
Window_frame_A1_041/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_041/Plane_196|White_wood=314521219fa27ae9
Window_frame_A1_042/Plane_199|White_wood=314521219fa27ae9
Window_frame_A1_043/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_043/Plane_200|White_wood=314521219fa27ae9
Window_frame_A1_044/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_044/Plane_196|White_wood=314521219fa27ae9
Window_frame_A1_045/Plane_199|White_wood=314521219fa27ae9
Window_frame_A1_046/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_046/Plane_200|White_wood=314521219fa27ae9
Window_frame_A1_047/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_047/Plane_196|White_wood=22cbf8cb684258df
Window_frame_A1_048/Plane_199|White_wood=22cbf8cb684258df
Window_frame_A1_049/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_049/Plane_200|White_wood=22cbf8cb684258df
Window_frame_A1_050/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_050/Plane_196|White_wood=22cbf8cb684258df
Window_frame_A1_051/Plane_199|White_wood=22cbf8cb684258df
Window_frame_A1_052/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_052/Plane_200|White_wood=22cbf8cb684258df
Window_frame_A1_053/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_053/Plane_196|White_wood=19e0696ae5a8d70a
Window_frame_A1_054/Plane_199|White_wood=19e0696ae5a8d70a
Window_frame_A1_055/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_055/Plane_200|White_wood=19e0696ae5a8d70a
Window_frame_A1_056/Plane_237|Glass=a3abf08155880dc1
Window_frame_A1_056/Plane_237|White_wood=19e0696ae5a8d70a
Window_frame_A1_057/Plane_238|White_wood=19e0696ae5a8d70a
Window_frame_A1_058/Plane_239|Glass=a3abf08155880dc1
Window_frame_A1_058/Plane_239|White_wood=19e0696ae5a8d70a
Window_frame_A1_059/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_059/Plane_196|White_wood=22cbf8cb684258df
Window_frame_A1_060/Plane_199|White_wood=22cbf8cb684258df
Window_frame_A1_061/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_061/Plane_200|White_wood=22cbf8cb684258df
Window_frame_A1_062/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_062/Plane_196|White_wood=22cbf8cb684258df
Window_frame_A1_063/Plane_199|White_wood=22cbf8cb684258df
Window_frame_A1_064/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_064/Plane_200|White_wood=22cbf8cb684258df
Window_frame_A1_065/Plane_196|Glass=a3abf08155880dc1
Window_frame_A1_065/Plane_196|White_wood=314521219fa27ae9
Window_frame_A1_066/Plane_199|White_wood=314521219fa27ae9
Window_frame_A1_067/Plane_200|Glass=a3abf08155880dc1
Window_frame_A1_067/Plane_200|White_wood=314521219fa27ae9
Window_frame_A1_068/Plane_248|Glass=a3abf08155880dc1
Window_frame_A1_068/Plane_248|White_wood=19e0696ae5a8d70a
Window_frame_A1_069/Plane_254|White_wood=19e0696ae5a8d70a
Window_frame_A1_070/Plane_248|Glass=a3abf08155880dc1
Window_frame_A1_070/Plane_248|White_wood=19e0696ae5a8d70a
Window_frame_A1_071/Plane_254|White_wood=19e0696ae5a8d70a
Window_frame_A1_072/Plane_248|Glass=a3abf08155880dc1
Window_frame_A1_072/Plane_248|White_wood=19e0696ae5a8d70a
Window_frame_A1_073/Plane_254|White_wood=19e0696ae5a8d70a
Window_frame_A1_074/Plane_248|Glass=a3abf08155880dc1
Window_frame_A1_074/Plane_248|White_wood=19e0696ae5a8d70a
Window_frame_A1_075/Plane_254|White_wood=19e0696ae5a8d70a
Window_frame_A1_076/Plane_248|Glass=a3abf08155880dc1
Window_frame_A1_076/Plane_248|White_wood=19e0696ae5a8d70a
Window_frame_A1_077/Plane_254|White_wood=19e0696ae5a8d70a
Window_frame_A1_078/Plane_157|White_wood=c4e6d45525c82619
Window_frame_B1/Plane_210|Glass=a3abf08155880dc1
Window_frame_B1/Plane_210|White_wood=314521219fa27ae9
Window_frame_B1_002/Plane_210|Glass=a3abf08155880dc1
Window_frame_B1_002/Plane_210|White_wood=314521219fa27ae9
Window_frame_B1_003/Plane_210|Glass=a3abf08155880dc1
Window_frame_B1_003/Plane_210|White_wood=92d6d1a6a41ddc67
Window_frame_B1_004/Plane_210|Glass=a3abf08155880dc1
Window_frame_B1_004/Plane_210|White_wood=92d6d1a6a41ddc67
Window_frame_C1/Plane_244|Glass=a3abf08155880dc1
Window_frame_C1/Plane_244|White_wood=92d6d1a6a41ddc67
Window_frame_C1_001/Plane_055|White_wood=92d6d1a6a41ddc67
Window_frame_C1_002/Plane_191|White_wood=92d6d1a6a41ddc67
Window_frame_C1_003/Plane_244|Glass=a3abf08155880dc1
Window_frame_C1_003/Plane_244|White_wood=92d6d1a6a41ddc67
Window_frame_C1_004/Plane_243|White_wood=92d6d1a6a41ddc67
Window_frame_C1_005/Plane_244|Glass=a3abf08155880dc1
Window_frame_C1_005/Plane_244|White_wood=92d6d1a6a41ddc67
Window_frame_C1_006/Plane_243|White_wood=92d6d1a6a41ddc67
Window_frame_C1_007/Plane_244|Glass=a3abf08155880dc1
Window_frame_C1_007/Plane_244|White_wood=92d6d1a6a41ddc67
Wine_glass/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_001/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_002/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_003/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_004/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_005/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_006/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_007/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_008/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_009/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_010/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_011/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_012/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_013/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_014/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_015/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_016/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_017/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_018/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_019/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_020/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_021/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_022/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_023/Circle_019|Bottle_glass=df1eed573a1c3b71
Wine_glass_024/Circle_019|Bottle_glass=df1eed573a1c3b71
Wooden_crate/Plane_300|Constructive_wood=f0bcb384a7995a80
Wooden_crate_001/Plane_300|Constructive_wood=f0bcb384a7995a80
Wooden_crate_002/Plane_300|Constructive_wood=f0bcb384a7995a80
Wooden_crate_003/Plane_300|Constructive_wood=f0bcb384a7995a80
Wooden_crate_004/Plane_300|Constructive_wood=f0bcb384a7995a80
Wooden_crate_005/Plane_300|Constructive_wood=f0bcb384a7995a80
Wooden_crate_006/Plane_300|Constructive_wood=f0bcb384a7995a80
Wooden_crate_007/Plane_300|Constructive_wood=cb7bb70b4cb7fecc
Wooden_crate_008/Plane_300|Constructive_wood=cb7bb70b4cb7fecc
Wooden_crate_009/Plane_300|Constructive_wood=cb7bb70b4cb7fecc
Wooden_crate_010/Plane_300|Constructive_wood=cb7bb70b4cb7fecc
Wooden_crate_011/Plane_300|Constructive_wood=cb7bb70b4cb7fecc
Wooden_crate_012/Plane_300|Constructive_wood=cb7bb70b4cb7fecc
Wooden_crate_013/Plane_300|Constructive_wood=cb7bb70b4cb7fecc
Wooden_crate_014/Plane_318|Constructive_wood=cb7bb70b4cb7fecc
Wooden_crate_015/Plane_300|Constructive_wood=3ef82d1456172973
Wooden_crate_016/Plane_300|Constructive_wood=3ef82d1456172973
Wooden_crate_017/Plane_300|Constructive_wood=3ef82d1456172973
Wooden_crate_018/Plane_300|Constructive_wood=cb7bb70b4cb7fecc
Wooden_crate_019/Plane_318|Constructive_wood=3ef82d1456172973
Wooden_crate_020/Plane_300|Constructive_wood=de13716e2fe56c8e
Wooden_crate_021/Plane_300|Constructive_wood=cb7bb70b4cb7fecc
Wooden_crate_022/Plane_300|Constructive_wood=cb7bb70b4cb7fecc
Wooden_crate_023/Plane_300|Constructive_wood=77e89426cea78717
Wooden_crate_024/Plane_300|Constructive_wood=77e89426cea78717
Wooden_crate_025/Plane_300|Constructive_wood=faaa8e22b59aea72
Wooden_crate_026/Plane_300|Constructive_wood=faaa8e22b59aea72
Wooden_crate_027/Plane_300|Constructive_wood=faaa8e22b59aea72
Wooden_crate_028/Plane_300|Constructive_wood=faaa8e22b59aea72
Wooden_crate_029/Plane_300|Constructive_wood=faaa8e22b59aea72
Wooden_crate_030/Plane_300|Constructive_wood=faaa8e22b59aea72
Wooden_crate_031/Plane_300|Constructive_wood=f0bcb384a7995a80
Wooden_crate_032/Plane_300|Constructive_wood=de13716e2fe56c8e
Wooden_crate_033/Plane_300|Constructive_wood=de13716e2fe56c8e
Wooden_crate_034/Plane_300|Constructive_wood=3ef82d1456172973
Wooden_crate_035/Plane_300|Constructive_wood=de13716e2fe56c8e
Wooden_crate_036/Plane_300|Constructive_wood=de13716e2fe56c8e
Wooden_crate_037/Plane_318|Constructive_wood=de13716e2fe56c8e
Wooden_crate_038/Plane_318|Constructive_wood=de13716e2fe56c8e
Wooden_crate_039/Plane_300|Constructive_wood=de13716e2fe56c8e
Wooden_crate_040/Plane_300|Constructive_wood=faaa8e22b59aea72
Wooden_crate_041/Plane_300|Constructive_wood=faaa8e22b59aea72
Wooden_crate_042/Plane_318|Constructive_wood=faaa8e22b59aea72
Wooden_crate_043/Plane_300|Constructive_wood=faaa8e22b59aea72
Wooden_crate_044/Plane_300|Constructive_wood=77e89426cea78717
extraction_hood/Plane_284|Glossy_Black_2=52460b83284bbc44
extraction_hood/Plane_284|bright_metal=c6d53880431bd676
porch_ceiling/Plane_017|White_wood=314521219fa27ae9
porch_floor/Plane_003|Porch_wood=cae928f74d37211f
"""
}
