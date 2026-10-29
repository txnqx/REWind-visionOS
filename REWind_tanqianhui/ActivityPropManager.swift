//
//  ActivityPropManager.swift
//  REWind_tanqianhui
//
//  Loads the per-memory activity props (the balls, the tree with its
//  ornaments and present, the breakfast table setting) and parents them under the
//  house so they travel with it.
//
//  The props ship as three small USDZs — 37 KB, 80 KB and 123 KB — rather than
//  being baked into the 382 MB house, so re-placing a prop never means re-exporting
//  and re-uploading the house.
//
//  Placement: each prop was positioned in Blender against its destination marker,
//  measured so the reach to it falls inside that memory's prescribed safe range
//  and so it is not occluded from the marker's line of sight. Grounding was then
//  re-checked by ray-casting the shipped house USDZ, which is what moved the
//  breakfast setting fully onto the dining table and the balls onto the lawn.
//
//  Frame caveat: the props were authored against the house export that carried a
//  180-degree Z rotation on its /root prim. The house shipping now has no such
//  rotation, so prop coordinates authored in the old frame land on the opposite
//  side of the origin - measured at 69-95 m away from their destination markers,
//  which is why they were nowhere to be seen at the end of a route. Rather than
//  re-export three bundles against a frame that may change again, each prop root
//  is placed *relative to its destination marker*, which is the one thing that is
//  stable across both exports. propTransformRelativeToMarker below carries that
//  authored offset; it was derived from the marker transform the props were built
//  against and is frame-independent by construction.

import Foundation
import RealityKit
import RealityKitContent
import UIKit
import QuartzCore

@MainActor
enum ActivityPropManager {
    // Name given to each loaded bundle's root, also used to find and remove it.
    private static let rootNamePrefix = "REWindProps_"
    private static var retiringProps: [String: Task<Void, Never>] = [:]
    private static var retirementAnimations: [String: AnimationPlaybackController] = [:]
    private static var christmasAnimationControllers: [AnimationPlaybackController] = []
    private static var christmasLightTimer: Timer?
    private struct ChristmasAwaitingFirstVisit: Component {}
    private struct ChristmasBulbBaseline: Component {
        var model: ModelComponent
    }
    private static var ballArrivalControllers: [AnimationPlaybackController] = []
    private static var ballGreetingAnimations: [(Entity, AnimationResource)] = []
    private static var ballGreetingControllers: [AnimationPlaybackController] = []

    // One representative mesh per glow point — the star topper plus the three
    // garland wraps. Each name lists the primary import and its "_001"
    // duplicate (the source file carries both for every mesh); only the FIRST
    // one found gets a light, never both, so a single wrap doesn't count as
    // two lights.
    //
    // Kept deliberately short (4 lights, not one per mesh): InteriorLightingManager.LightBudget
    // hard-caps this app to 8 total *simultaneous* dynamic lights on limited
    // GPUs/simulators ("Older rendering devices expose only eight dynamic
    // lights"). It gracefully frees up house-light slots for lights added
    // outside the house tree, but only up to that shared ceiling — an earlier
    // version of this code added 10 separate lights (one per mesh including
    // duplicates) and blew well past the budget, which is almost certainly why
    // the glow wasn't visible at all.
    private static let christmasLightMeshGroups: [[String]] = [
        ["Object_10", "Object_10_001"],   // star topper
        ["Object_0", "Object_0_001"],     // garland, top wrap
        ["Object_1", "Object_1_001"],     // garland, middle wrap
        ["Object_2", "Object_2_001"]      // garland, bottom wrap
    ]

    // Attaches one warm point light per glow point (star + 3 garland wraps),
    // then starts a shared timer that pulses their intensity together in a
    // slow breathing glow. Safe to call more than once for the same tree (e.g.
    // when re-showing already-loaded props): existing lights are found by name
    // and reused rather than duplicated, and the timer is restarted fresh.
    private static func attachChristmasLightPulse(to tree: Entity) {
        var lightEntities: [Entity] = []

        for group in christmasLightMeshGroups {
            guard let host = group.compactMap({ tree.findEntity(named: $0) }).first else { continue }

            let lightName = "\(host.name)_Glow"
            let light: Entity
            if let existing = host.children.first(where: { $0.name == lightName }) {
                light = existing
            } else {
                light = Entity()
                light.name = lightName
                light.components.set(PointLightComponent(
                    color: .init(red: 1.0, green: 0.85, blue: 0.55, alpha: 1.0),
                    intensity: 400 * InteriorLightingManager.radianceScale,
                    attenuationRadius: 0.5
                ))
                host.addChild(light)
            }
            light.isEnabled = true
            lightEntities.append(light)
        }

        // The yellow bulbs are Object_6 (needlaes_eevee material) in the
        // supplied USDZ. Pulse their existing emission, adding no light sources,
        // geometry, textures, or transparent overlays.
        var bulbs: [Entity] = []
        func collectBulbs(_ entity: Entity) {
            if let model = entity.components[ModelComponent.self],
               model.materials.contains(where: { $0 is PhysicallyBasedMaterial }) {
                let baseline = entity.components[ChristmasBulbBaseline.self]?.model ?? model
                entity.components.set(ChristmasBulbBaseline(model: baseline))
                bulbs.append(entity)
            }
            for child in entity.children { collectBulbs(child) }
        }
        if let bulbRoot = tree.findEntity(named: "Object_6") ?? tree.findEntity(named: "Object_6_001") {
            collectBulbs(bulbRoot)
        }
        guard !lightEntities.isEmpty || !bulbs.isEmpty else {
            print("⚠️ Christmas light pulse: no star/garland meshes found under \(tree.name)")
            return
        }

        christmasLightTimer?.invalidate()

        // Bright enough to read against the house's daylight IBL, not just in
        // an unlit preview: existing in-scene point lights here run 180–650
        // at radii of 0.55–1.2 m (see the memory-album glow and home-orb key
        // light in ImmersiveView.swift), so this sits in the same range rather
        // than the much dimmer/smaller values a first pass used.
        let minIntensity: Float = 180 * InteriorLightingManager.radianceScale
        let maxIntensity: Float = 2678 * InteriorLightingManager.radianceScale
        let periodSeconds: TimeInterval = 3.6
        let startTime = CACurrentMediaTime()
        // One main-run-loop callback; do not enqueue a new Swift task per tick.
        // A 3.6-second breathing cycle needs no per-frame material traversal.
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard tree.isEnabledInHierarchy else { return }
                let elapsed = CACurrentMediaTime() - startTime
                let pulse = Float(0.5 * (1 - cos(2 * Double.pi * elapsed / periodSeconds)))
                let intensity = minIntensity + (maxIntensity - minIntensity) * pulse
                for light in lightEntities {
                    light.components[PointLightComponent.self]?.intensity = intensity
                }
                for entity in bulbs {
                    guard let original = entity.components[ChristmasBulbBaseline.self]?.model else { continue }
                    var model = original
                    model.materials = original.materials.map { material in
                        guard var lit = material as? PhysicallyBasedMaterial else { return material }
                        // Imported emission can have a zero intensity scalar;
                        // multiplying it leaves the bulbs static. Use an explicit
                        // warm self-lit emission on just these existing yellow bulbs.
                        // Keep a visible glow at the trough, then breathe brighter.
                        lit.emissiveColor = .init(color: UIColor(red: 1, green: 0.78, blue: 0.36, alpha: 1))
                        lit.emissiveIntensity = 0.35 + 4.25 * pulse
                        return lit
                    }
                    entity.components.set(model)
                }
            }
        }
        christmasLightTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        print("Christmas pulse active: \(bulbs.count) bulb meshes, \(lightEntities.count) existing lights")
    }

    private static func bundleName(for route: MemoryRoute) -> String {
        switch route {
        case .playingBall:
            "REWind_Props_PlayingBall"
        case .christmasTree:
            "REWind_Props_ChristmasTree"
        case .breakfast:
            "REWind_Props_Breakfast"
        }
    }

    private static func rootName(for route: MemoryRoute) -> String {
        rootNamePrefix + route.rawValue
    }

    // Loads one memory's props and attaches them to the house. Idempotent: calling
    // it again for a route that is already loaded just re-enables what is there.
    private static var preparations: [MemoryRoute: Task<Entity, Error>] = [:]
    private static weak var loadedHouse: Entity?

    /// Prepare the chosen activity during its card video. Nothing is attached,
    /// enabled or removed from the live scene until normal navigation requests it.
    static func prefetch(_ route: MemoryRoute) {
        guard preparations[route] == nil,
              loadedHouse?.findEntity(named: rootName(for: route)) == nil else { return }
        preparations[route] = Task { @MainActor in
            switch route {
            case .breakfast: return try await makeBreakfastProps()
            case .christmasTree: return try await makeChristmasTreeProps()
            case .playingBall: return try await Entity(named: "PlayingBall_ManAndBall", in: realityKitContentBundle)
            }
        }
    }

    /// Decode while the completed scene is still visible, before travel starts.
    /// This leaves only attachment/renderer warm-up beneath the brief cover.
    static func prepareForTravel(_ route: MemoryRoute) async {
        prefetch(route)
        if let preparation = preparations[route] { _ = try? await preparation.value }
    }

    /// Attach and shade the expensive Christmas resources before Home is revealed.
    /// Keep the tree visible until its first activity completes, with glow lights
    /// and animation playback idle until that activity is selected.
    static func prepareChristmasForHome(in house: Entity) async {
        guard let props = await showProps(for: .christmasTree, in: house) else { return }
        props.components.set(ChristmasAwaitingFirstVisit())
        props.isEnabled = true
        if let tree = props.findEntity(named: "Christmas_Tree") {
            for group in christmasLightMeshGroups {
                for hostName in group {
                    tree.findEntity(named: hostName + "_Glow")?.isEnabled = false
                }
            }
        }
        christmasLightTimer?.invalidate()
        christmasLightTimer = nil
        christmasAnimationControllers.forEach { $0.stop() }
        christmasAnimationControllers.removeAll()
        print("Christmas startup preparation complete; visible with house before Home")
    }

    private static func preparedProps(for route: MemoryRoute) async throws -> Entity {
        if preparations[route] == nil { prefetch(route) }
        guard let preparation = preparations.removeValue(forKey: route) else {
            throw CocoaError(.fileReadUnknown)
        }
        return try await preparation.value
    }

    @discardableResult
    static func showProps(for route: MemoryRoute, in houseEntity: Entity) async -> Entity? {
        loadedHouse = houseEntity
        let nameForRoute = rootName(for: route)
        retiringProps.removeValue(forKey: nameForRoute)?.cancel()
        retirementAnimations.removeValue(forKey: nameForRoute)?.stop()
        if let existing = houseEntity.findEntity(named: nameForRoute) {
            if route == .playingBall { prepareBallArrival(in: existing) }
            existing.components.set(OpacityComponent(opacity: 1))
            existing.isEnabled = true
            if route == .christmasTree {
                existing.components.remove(ChristmasAwaitingFirstVisit.self)
                straightenChristmasProps(in: existing)
                if let tree = existing.findEntity(named: "Christmas_Tree") {
                    christmasAnimationControllers = playAnimationsRecursively(on: tree, repeats: true)
                    attachChristmasLightPulse(to: tree)
                }
            }
            print("✅ PROPS ALREADY LOADED: \(route.rawValue)")
            return existing
        }

        let setupBegan = CACurrentMediaTime()
        defer { print("PERF attach activity: \(1000 * (CACurrentMediaTime() - setupBegan)) ms") }
        let name = bundleName(for: route)

        // Playing ball: load the animated dad + ball USDZ if available.
        // The dad stands ≈50 ft (15.24 m) forward of Location_Outdoor on the grass.
        // Falls through to the placeholder path if the asset is missing.
        if route == .playingBall {
            do {
                let dadAndBall = try await preparedProps(for: route)
                dadAndBall.name = rootName(for: route)
                houseEntity.addChild(dadAndBall)
                anchor(dadAndBall, for: route, in: houseEntity, using: dadAndBallTransformRelativeToMarker())
                groundDad(dadAndBall, in: houseEntity)
                prepareBallArrival(in: dadAndBall)
                applyActivityShading(to: dadAndBall, in: houseEntity, probeName: "DaytimeSkyImageBasedLight")
                print("✅ PLAYING BALL (Dad+Ball) LOADED")
                return dadAndBall
            } catch {
                print("⚠️ PlayingBall_ManAndBall failed to load: \(error). No placeholder will be shown.")
                return nil
            }
        }

        if route == .christmasTree {
            do {
                let props = try await preparedProps(for: route)
                props.name = rootName(for: route)
                houseEntity.addChild(props)
                anchor(props, for: route, in: houseEntity, using: placeholderTransformRelativeToMarker(for: route))
                applyChristmasShading(to: props, in: houseEntity)
                if let tree = props.findEntity(named: "Christmas_Tree") {
                    christmasAnimationControllers = playAnimationsRecursively(on: tree, repeats: true)
                    attachChristmasLightPulse(to: tree)
                }
                print("✅ CHRISTMAS PROPS LOADED")
                return props
            } catch {
                fatalError("Christmas activity must load the supplied USDZ assets, but loading failed: \(error)")
            }
        }

        if route == .breakfast {
            // This is the existing green book on the dining table only.
            houseEntity.findEntity(named: "SHC_Old_Book_005")?.isEnabled = false
            do {
                let props = try await preparedProps(for: route)
                props.name = rootName(for: route)
                houseEntity.addChild(props)
                placeBreakfast(props, in: houseEntity)
                applyActivityShading(to: props, in: houseEntity, probeName: "DiningInteriorReflectionProbe")
                print("✅ BREAKFAST: supplied cereal animation, spoon and decorative strawberries loaded")
                return props
            } catch {
                print("❌ BREAKFAST ASSET LOAD: \(error)")
                return nil
            }
        }

        do {
            let props = try await Entity(named: name, in: realityKitContentBundle)
            props.name = rootName(for: route)
            houseEntity.addChild(props)
            removeHumanModelIfNeeded(for: route, from: props)

            // Anchor the bundle to its destination marker rather than trusting the
            // authored world coordinates, which belong to a superseded house frame.
            if anchor(props, for: route, in: houseEntity, using: propTransformRelativeToMarker(for: route)) {
                applyChildCorrections(for: route, in: props)

                print("""
                ✅ PROPS LOADED: \(name) -> \(props.name)
                props world position: \(Transform(matrix: props.transformMatrix(relativeTo: nil)).translation)
                """)
            }

            return props
        } catch {
            // A missing prop bundle must not take the memory down with it: the walk
            // and the HUD still work, the room is simply unfurnished.
            print("❌ PROPS FAILED TO LOAD: \(name): \(error)")
            return nil
        }
    }

    /// Activity models arrive after the house's probe assignment. Retain their
    /// imported PBR materials and give them the same lighting as living-room props.
    private static func applyChristmasShading(to root: Entity, in house: Entity) {
        applyActivityShading(to: root, in: house, probeName: "LivingInteriorReflectionProbe")
    }

    private static func applyActivityShading(to root: Entity, in house: Entity, probeName: String) {
        let began = CACurrentMediaTime()
        defer { print("PERF activity shading: \(1000 * (CACurrentMediaTime() - began)) ms") }
        let probe = house.findEntity(named: probeName)
        var meshCount = 0
        func visit(_ entity: Entity) {
            if entity.components.has(ModelComponent.self) {
                if let probe {
                    entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: probe))
                }
                entity.components.set(DynamicLightShadowComponent(castsShadow: true))
                meshCount += 1
            }
            for child in entity.children { visit(child) }
        }
        visit(root)
        print("REWind Christmas shading: \(meshCount) models, living-room probe \(probe != nil), imported materials retained")
    }

    private static func makeChristmasTreeProps() async throws -> Entity {
        let root = Entity()
        root.name = "ChristmasActivityProps"

        // Wrap the animated USDZ in a plain container. The container holds position
        // and scale and is what straightenChristmasProps targets. The animation system
        // only drives the inner entity's local transform, so the container's orientation
        // (set to world-upright by straightenChristmasProps) is never overridden.
        let treeContainer = Entity()
        treeContainer.name = "Christmas_Tree"
        treeContainer.position = SIMD3<Float>(0.34, 0.40, -0.84)
        treeContainer.scale = SIMD3<Float>(repeating: 0.72)

        let treeAnimated = try await loadRequiredChristmasEntity(named: "XMas_Tree_animated")
        treeAnimated.name = "Christmas_Tree_Animated"
        treeAnimated.position = .zero
        // Prefetch creates resources only. Start playback when attached to the
        // live scene, after the preceding activity has finished its fade.
        treeContainer.addChild(treeAnimated)
        root.addChild(treeContainer)

        let crateCenter = SIMD3<Float>(-0.62, 0.44, -0.58)
        let crateGroup = Entity()
        crateGroup.name = "Christmas_Ornament_Crate_Group"
        crateGroup.position = crateCenter
        root.addChild(crateGroup)

        let crate = try await loadRequiredChristmasEntity(named: "Crate_4")
        let crateWrapper = Entity()
        crateWrapper.name = "Christmas_Ornament_Crate"
        let crateBounds = crate.visualBounds(relativeTo: crate)
        if crateBounds.extents.y > crateBounds.extents.z {
            crate.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        }
        // Keep the crate texture but soften its near-white sunlit finish.
        func softenCrate(_ node: Entity) {
            if var model = node.components[ModelComponent.self] {
                model.materials = model.materials.map { original in
                    guard var material = original as? PhysicallyBasedMaterial else { return original }
                    material.baseColor.tint = UIColor(red: 0.74, green: 0.71, blue: 0.66, alpha: 1)
                    material.roughness.scale = max(material.roughness.scale, 0.78)
                    material.specular.scale = 0.18
                    return material
                }
                node.components.set(model)
            }
            for child in node.children { softenCrate(child) }
        }
        softenCrate(crate)
        crateWrapper.addChild(crate)
        fitAndCenter(crateWrapper, toLargestDimension: 0.32)
        crateWrapper.scale.y *= 0.72
        crateGroup.addChild(crateWrapper)

        let ornaments = [
            ("Christmas_ornaments_1", "Christmas_Ornament_1", SIMD3<Float>(-0.082, 0, 0.025), Float(0.17)),
            ("Christmas_ornaments_2", "Christmas_Ornament_2", SIMD3<Float>(0.0, 0, -0.038), Float(0.17)),
            ("Christmas_ornaments_3", "Christmas_Ornament_3", SIMD3<Float>(0.082, 0, 0.025), Float(0.17))
        ]

        for definition in ornaments {
            let (resourceName, entityName, position, largestDimension) = definition
            let ornamentSlot = Entity()
            ornamentSlot.name = "\(entityName)_Slot"
            ornamentSlot.position = position

            // Keep input on the unscaled slot so its 5.5 cm hit target covers
            // this ornament without overlapping the neighbouring crate slots.
            ornamentSlot.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.050)]))
            ornamentSlot.components.set(InputTargetComponent(allowedInputTypes: .all))
            ornamentSlot.components.set(HoverEffectComponent())

            let imported = try await loadRequiredChristmasEntity(named: resourceName)
            let heroNames = ["Object_0_096", "Object_0_039", "Object_0_075"]
            guard let hero = heroNames.compactMap({ imported.findEntity(named: $0) }).first else {
                throw RequiredChristmasAssetLoadError.missingBundledUSDZ(resourceName + " ornament mesh")
            }
            // Each export includes tiny, distant remnants of the original scene.
            // Clone only its intended ornament, retaining the original PBR material.
            let ornament = Entity()
            ornament.name = entityName
            let upright = Entity()
            upright.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            ornament.addChild(upright)
            let model = hero.clone(recursive: true)
            model.transform = Transform(matrix: hero.transformMatrix(relativeTo: imported))
            upright.addChild(model)
            fitAndCenter(ornament, toLargestDimension: largestDimension)

            // Pickup guidance is a glass callout; a zero-intensity point light
            // still consumes a renderer slot and must not be attached here.
            // Keep the crate ornaments upright, with the same preview and
            // hanging frame used after pickup.
            let cratePose = Entity()
            cratePose.name = "OrnamentCratePose"
            ornamentSlot.addChild(cratePose)
            cratePose.addChild(ornament)
            let fitted = ornament.visualBounds(relativeTo: cratePose)
            let hook = Entity()
            hook.name = "OrnamentHook"
            hook.position = [fitted.center.x, fitted.max.y, fitted.center.z]
            cratePose.addChild(hook)
            crateGroup.addChild(ornamentSlot)
            // Upright bounds have an exact lowest vertex. Seat that vertex on
            // the crate base instead of keeping the former tilted-pose offsets.
            let crateFloor = crateWrapper.visualBounds(relativeTo: crateGroup).min.y + 0.012
            ornamentSlot.position.y = crateFloor - fitted.min.y
        }

        // Attach targets to the tree so its upright correction also moves the hooks.
        // These audited branch positions start in props-root coordinates; convert
        // them once to tree coordinates, including its presentation scale.
        let slotDefinitions: [(String, SIMD3<Float>)] = [
            ("OrnamentSlot_1", SIMD3<Float>(0.03078, 0.87533, -0.47945)),
            ("OrnamentSlot_2", SIMD3<Float>(0.50703, 1.06487, -0.45296)),
            ("OrnamentSlot_3", SIMD3<Float>(0.02658, 1.17228, -0.60776))
        ]
        for (slotName, slotPosition) in slotDefinitions {
            let slot = Entity()
            slot.name = slotName
            slot.position = treeContainer.convert(position: slotPosition, from: root)
            treeContainer.addChild(slot)
        }

        return root
    }

    @discardableResult
    private static func playAnimationsRecursively(on entity: Entity, repeats: Bool = false) -> [AnimationPlaybackController] {
        var controllers: [AnimationPlaybackController] = []

        for animation in entity.availableAnimations {
            controllers.append(entity.playAnimation(repeats ? animation.repeat() : animation))
        }

        for child in entity.children {
            controllers.append(contentsOf: playAnimationsRecursively(on: child, repeats: repeats))
        }

        return controllers
    }

    // Returns 0, 1, or 2 for the three Christmas ornament slots; nil for anything else.
    // The tap gesture targets the *slot* entity (collision lives there), so both the
    // slot name and the ornament name are accepted.
    static func christmasOrnamentIndex(of entity: Entity) -> Int? {
        switch entity.name {
        case "Christmas_Ornament_1", "Christmas_Ornament_1_Slot": return 0
        case "Christmas_Ornament_2", "Christmas_Ornament_2_Slot": return 1
        case "Christmas_Ornament_3", "Christmas_Ornament_3_Slot": return 2
        default: return nil
        }
    }

    private static func removeEntitiesNamed(_ name: String, from entity: Entity) {
        for child in Array(entity.children) {
            removeEntitiesNamed(name, from: child)

            if child.name == name {
                child.removeFromParent()
            }
        }
    }

    private static func fitAndCenter(_ entity: Entity, toLargestDimension targetDimension: Float) {
        let bounds = entity.visualBounds(relativeTo: entity)
        let largestDimension = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        guard largestDimension > 0.001 else {
            return
        }

        let scaleFactor = targetDimension / largestDimension
        entity.scale = SIMD3<Float>(repeating: scaleFactor)
        entity.position = SIMD3<Float>(
            -bounds.center.x * scaleFactor,
            -bounds.center.y * scaleFactor,
            -bounds.center.z * scaleFactor
        )
    }

    private static func loadRequiredChristmasEntity(named resourceName: String) async throws -> Entity {
        do {
            return try await Entity(named: resourceName, in: realityKitContentBundle)
        } catch {
            print("⚠️ CHRISTMAS ENTITY NAMED LOAD FAILED: \(resourceName): \(error). Trying exact USDZ URL.")
        }

        guard let url = realityKitContentBundle.url(forResource: resourceName, withExtension: "usdz") else {
            throw RequiredChristmasAssetLoadError.missingBundledUSDZ(resourceName)
        }

        return try await Entity(contentsOf: url)
    }

    private static func removeEmbeddedLights(from entity: Entity) {
        entity.components.remove(PointLightComponent.self)
        entity.components.remove(SpotLightComponent.self)
        entity.components.remove(DirectionalLightComponent.self)

        for child in entity.children {
            removeEmbeddedLights(from: child)
        }
    }

    private enum RequiredChristmasAssetLoadError: LocalizedError {
        case missingBundledUSDZ(String)

        var errorDescription: String? {
            switch self {
            case .missingBundledUSDZ(let resourceName):
                "Missing required Christmas USDZ asset: \(resourceName).usdz"
            }
        }
    }

    @discardableResult
    private static func anchor(_ props: Entity, for route: MemoryRoute, in houseEntity: Entity, using relativeTransform: simd_float4x4) -> Bool {
        guard let marker = findMarker(named: destinationMarkerName(for: route), in: houseEntity) else {
            // Without the marker there is no trustworthy anchor, so leave the
            // bundle where it was authored and say so, rather than silently
            // dropping the props somewhere arbitrary.
            print("⚠️ PROPS ANCHOR MISSING: \(destinationMarkerName(for: route)) not found; using authored transform")
            return false
        }

        let markerInHouse = marker.transformMatrix(relativeTo: houseEntity)
        props.setTransformMatrix(markerInHouse * relativeTransform, relativeTo: houseEntity)

        if route == .christmasTree {
            straightenChristmasProps(in: props)
        }

        print("✅ PROPS ANCHORED TO: \(marker.name)")
        return true
    }

    // Remove marker pitch/roll in the house frame, so later travel cannot tilt
    // these props again. Their room positions and sizes stay unchanged.
    static func straightenChristmasProps(in root: Entity) {
        guard let house = root.parent else { return }
        let up = houseUp(in: house)
        for name in ["Christmas_Tree", "Christmas_Ornament_Crate_Group"] {
            guard let entity = root.findEntity(named: name) else { continue }
            var pose = Transform(matrix: entity.transformMatrix(relativeTo: house))
            var right = pose.rotation.act(SIMD3<Float>(1, 0, 0))
            right = simd_normalize(right - up * simd_dot(right, up))
            pose.rotation = simd_quatf(simd_float3x3(columns: (right, up, simd_cross(right, up))))
            entity.setTransformMatrix(pose.matrix, relativeTo: house)
        }
        // Anchor the crate's bottom to the living-room floor, not marker eye height.
        // Preserve its horizontal room position and keep all three ornaments inside.
        if let group = root.findEntity(named: "Christmas_Ornament_Crate_Group"),
           let crate = group.findEntity(named: "Christmas_Ornament_Crate") {
            let bounds = crate.visualBounds(relativeTo: house)
            let bottom = simd_dot(bounds.center, up) - simd_dot(bounds.extents, up) / 2
            var position = group.position(relativeTo: house)
            position += up * (0.001 - bottom) // audited living-room floor = 0 m
            group.setPosition(position, relativeTo: house)
        }
    }

    private static func houseUp(in house: Entity) -> SIMD3<Float> {
        // The house is Z-up in USD; accommodate the importer's Y-up conversion.
        if let table = house.findEntity(named: "Dining_table") {
            let size = table.visualBounds(relativeTo: house).extents
            return size.z < size.y ? [0, 0, 1] : [0, 1, 0]
        }
        return [0, 0, 1]
    }

    private static func groundDad(_ dad: Entity, in house: Entity) {
        let up = houseUp(in: house)
        var pose = Transform(matrix: dad.transformMatrix(relativeTo: house))
        var right = pose.rotation.act(SIMD3<Float>(1, 0, 0))
        right = simd_normalize(right - up * simd_dot(right, up))
        pose.rotation = simd_quatf(simd_float3x3(columns: (right, up, simd_cross(right, up))))
        // Read-only triangle audit: the lawn under this tree is z = -0.600 m.
        // The supplied character's feet are at local y = 0.001 m; animated root
        // bounds include the flying ball and cannot be used for grounding.
        if up.z > 0.5 {
            pose.translation.z = -0.601
        } else {
            pose.translation.y = -0.601
        }
        // Move 45 cm toward the adjacent outdoor tree, keeping Dad beside it.
        if let tree = house.findEntity(named: "Node_0_001") {
            var toward = tree.position(relativeTo: house) - pose.translation
            toward -= up * simd_dot(toward, up)
            if simd_length(toward) > 0.6 { pose.translation += simd_normalize(toward) * 0.45 }
        }
        dad.setTransformMatrix(pose.matrix, relativeTo: house)
        print("DAD GROUNDED: \(pose.translation)")
    }

    private static func makeBreakfastProps() async throws -> Entity {
        let root = Entity()
        let cereal = try await loadRequiredChristmasEntity(named: "Breakfast_Cereal_Pour")
        cereal.name = "Breakfast_Cereal_Animation"
        cereal.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        // This is the USDZ's presentation floor, not part of the bowl or animation.
        cereal.findEntity(named: "Ground")?.isEnabled = false
        root.addChild(cereal)
        if let box = cereal.findEntity(named: "Box_Pivot") {
            addInputProxy(named: "Breakfast_Box", to: box, bounds: box.visualBounds(relativeTo: box))
        }
        let bowlTarget = Entity()
        bowlTarget.name = "Breakfast_Bowl"
        bowlTarget.position = [0, 0.045, 0]
        bowlTarget.components.set(CollisionComponent(shapes: [.generateBox(size: [0.24, 0.10, 0.24])]))
        bowlTarget.components.set(InputTargetComponent(allowedInputTypes: .all))
        root.addChild(bowlTarget)

        let spoon = Entity()
        spoon.name = "Breakfast_Spoon"
        let spoonModel = try await loadRequiredChristmasEntity(named: "Breakfast_Spoon")
        fitAndCenter(spoonModel, toLargestDimension: 0.21)
        spoonModel.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        spoon.addChild(spoonModel)
        // Start flat on the tabletop; the interaction controller tilts it only while held.
        let spoonBounds = spoon.visualBounds(relativeTo: spoon)
        spoon.position = [0.145, -spoonBounds.min.y + 0.0006, 0.055]
        spoon.components.set(CollisionComponent(shapes: [.generateBox(size: [0.09, 0.07, 0.23])]))
        spoon.components.set(InputTargetComponent(allowedInputTypes: .all))
        spoon.components.set(HoverEffectComponent())
        root.addChild(spoon)

        let milk = Entity()
        milk.name = "Breakfast_Milk"
        let milkModel = try await loadRequiredChristmasEntity(named: "Breakfast_Milk_Pink")
        fitAndCenter(milkModel, toLargestDimension: 0.26)
        milk.addChild(milkModel)
        let milkBounds = milk.visualBounds(relativeTo: milk)
        milk.position = [0.24, -milkBounds.min.y + 0.003, -0.08]
        milk.components.set(CollisionComponent(shapes: [.generateBox(size: simd_max(milkBounds.extents, SIMD3<Float>(0.22, 0.30, 0.18))).offsetBy(translation: milkBounds.center)]))
        milk.components.set(InputTargetComponent(allowedInputTypes: .all))
        milk.components.set(HoverEffectComponent())
        root.addChild(milk)
        // The supplied carton has a separate Plastic cap mesh. Preserve it and
        // animate it away from its actual position before exposing the nozzle.
        if let cap = milkModel.findEntity(named: "Plastic") {
            let capBounds = cap.visualBounds(relativeTo: milk)
            let capTransform = cap.transformMatrix(relativeTo: milk)
            cap.removeFromParent()
            let capHolder = Entity()
            capHolder.name = "Breakfast_MilkCap"
            milk.addChild(capHolder)
            capHolder.addChild(cap)
            cap.setTransformMatrix(capTransform, relativeTo: milk)
            let outward = simd_normalize(SIMD3<Float>(0, 0.65, 0.75))
            let nozzle = Entity()
            nozzle.name = "Breakfast_MilkNozzle"
            nozzle.position = capBounds.center - outward * 0.009
            nozzle.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: outward)
            milk.addChild(nozzle)
            let opening = ModelEntity(mesh: .generateCylinder(height: 0.001, radius: capBounds.extents.x * 0.34),
                materials: [SimpleMaterial(color: UIColor(white: 0.12, alpha: 1), roughness: 0.8, isMetallic: false)])
            opening.name = "Breakfast_MilkOpening"
            opening.isEnabled = false
            nozzle.addChild(opening)
        }
        let stream = Entity()
        stream.name = "Breakfast_MilkStream"
        var milkMaterial = PhysicallyBasedMaterial()
        milkMaterial.baseColor = .init(tint: UIColor(red: 1, green: 0.99, blue: 0.97, alpha: 1))
        milkMaterial.roughness = .init(floatLiteral: 0.16)
        milkMaterial.specular = .init(floatLiteral: 0.65)
        milkMaterial.clearcoat = .init(floatLiteral: 0.18)
        milkMaterial.faceCulling = .none
        // A small diffuse lift approximates milk's subsurface scattering in the warm room.
        milkMaterial.emissiveColor = .init(color: UIColor(white: 1, alpha: 1))
        milkMaterial.emissiveIntensity = 0.12
        let flow = ModelEntity(mesh: .generateSphere(radius: 0.001), materials: [milkMaterial])
        flow.name = "MilkFlow"
        stream.addChild(flow)
        stream.isEnabled = false
        root.addChild(stream)

        let strawberries = try await loadRequiredChristmasEntity(named: "Breakfast_Strawberries")
        strawberries.name = "Breakfast_Strawberries_Decoration"
        fitAndCenter(strawberries, toLargestDimension: 0.27)
        // fitAndCenter places the visual centre at the origin; rest its bottom on the table.
        strawberries.position += SIMD3<Float>(-0.31, 0, 0.16)
        root.addChild(strawberries)
        // Measure in the common tabletop coordinate system after imported scale,
        // rotation and centering. Local extents alone miss authored root transforms.
        for item in [strawberries, spoon, milk] {
            // The props have not entered a Scene yet. Excluding inactive entities
            // here produces an empty bound and can send their positions to infinity.
            let bottom = item.visualBounds(relativeTo: root).min.y
            if bottom.isFinite { item.position.y -= bottom }
        }
        return root
    }

    private static func addInputProxy(named name: String, to parent: Entity, bounds: BoundingBox) {
        let proxy = Entity()
        proxy.name = name
        proxy.position = bounds.center
        proxy.components.set(CollisionComponent(shapes: [.generateBox(size: simd_max(bounds.extents, SIMD3<Float>(repeating: 0.06)))]))
        proxy.components.set(InputTargetComponent(allowedInputTypes: .all))
        proxy.components.set(HoverEffectComponent())
        parent.addChild(proxy)
    }

    private static func placeBreakfast(_ props: Entity, in house: Entity) {
        guard let marker = findMarker(named: "Location_Dining Room", in: house),
              let table = house.findEntity(named: "Dining_table") else { return }
        let up = houseUp(in: house)
        let markerPose = Transform(matrix: marker.transformMatrix(relativeTo: house))
        var right = markerPose.rotation.act(SIMD3<Float>(1, 0, 0))
        right = simd_normalize(right - up * simd_dot(right, up))
        let back = simd_cross(right, up)
        let bounds = table.visualBounds(relativeTo: house)
        var point = markerPose.translation - back * 0.94
        if up.z > 0.5 {
            point.x = min(max(point.x, bounds.min.x + 0.23), bounds.max.x - 0.23)
            point.y = min(max(point.y, bounds.min.y + 0.55), bounds.max.y - 0.55)
            point.z = bounds.max.z
        } else {
            point.x = min(max(point.x, bounds.min.x + 0.23), bounds.max.x - 0.23)
            point.z = min(max(point.z, bounds.min.z + 0.55), bounds.max.z - 0.55)
            point.y = bounds.max.y
        }
        props.transform = Transform(scale: SIMD3(repeating: 1.12), rotation: simd_quatf(simd_float3x3(columns: (right, up, back))), translation: point)
        for name in ["Breakfast_Strawberries_Decoration", "Breakfast_Spoon", "Breakfast_Milk", "Breakfast_Cereal_Animation"] {
            if let item = props.findEntity(named: name) {
                print("BREAKFAST CONTACT: \(name) bounds \(item.visualBounds(relativeTo: props, excludeInactive: true))")
            }
        }
        print("BREAKFAST TABLE: centre \(point), up \(up), table \(bounds)")
    }

    private static func makePlaceholderProps(for route: MemoryRoute) -> Entity {
        let root = Entity()

        switch route {
        case .playingBall:
            addModel(
                named: "Placeholder_Ball_1",
                mesh: .generateSphere(radius: 0.12),
                color: UIColor(red: 0.18, green: 0.38, blue: 0.96, alpha: 1.0),
                to: root,
                position: SIMD3<Float>(-0.22, 0.12, 0.0)
            )
            addModel(
                named: "Placeholder_Ball_2",
                mesh: .generateSphere(radius: 0.12),
                color: UIColor(red: 0.96, green: 0.22, blue: 0.20, alpha: 1.0),
                to: root,
                position: SIMD3<Float>(0.0, 0.12, -0.08)
            )
            addModel(
                named: "Placeholder_Ball_3",
                mesh: .generateSphere(radius: 0.12),
                color: UIColor(red: 0.98, green: 0.80, blue: 0.18, alpha: 1.0),
                to: root,
                position: SIMD3<Float>(0.22, 0.12, 0.0)
            )

        case .christmasTree:
            addModel(
                named: "Placeholder_Tree_Trunk",
                mesh: .generateBox(size: 0.18),
                color: UIColor(red: 0.35, green: 0.18, blue: 0.08, alpha: 1.0),
                to: root,
                position: SIMD3<Float>(0.0, 0.24, 0.0),
                scale: SIMD3<Float>(0.7, 2.2, 0.7)
            )
            addModel(
                named: "Placeholder_Tree_Foliage_Lower",
                mesh: .generateSphere(radius: 0.38),
                color: UIColor(red: 0.08, green: 0.36, blue: 0.18, alpha: 1.0),
                to: root,
                position: SIMD3<Float>(0.0, 0.58, 0.0),
                scale: SIMD3<Float>(1.0, 0.78, 1.0)
            )
            addModel(
                named: "Placeholder_Tree_Foliage_Upper",
                mesh: .generateSphere(radius: 0.28),
                color: UIColor(red: 0.10, green: 0.46, blue: 0.22, alpha: 1.0),
                to: root,
                position: SIMD3<Float>(0.0, 0.96, 0.0),
                scale: SIMD3<Float>(0.9, 1.0, 0.9)
            )
            addModel(
                named: "Placeholder_Ornament_1",
                mesh: .generateSphere(radius: 0.050),
                color: UIColor(red: 0.96, green: 0.15, blue: 0.22, alpha: 1.0),
                to: root,
                position: SIMD3<Float>(-0.18, 0.72, 0.26)
            )
            addModel(
                named: "Placeholder_Ornament_2",
                mesh: .generateSphere(radius: 0.050),
                color: UIColor(red: 0.98, green: 0.78, blue: 0.18, alpha: 1.0),
                to: root,
                position: SIMD3<Float>(0.18, 0.86, 0.22)
            )
            addModel(
                named: "Placeholder_Present",
                mesh: .generateBox(size: 0.18),
                color: UIColor(red: 0.82, green: 0.12, blue: 0.22, alpha: 1.0),
                to: root,
                position: SIMD3<Float>(0.32, 0.09, 0.18)
            )

        case .breakfast:
            addModel(
                named: "Placeholder_Cereal_Box",
                mesh: .generateBox(size: 0.18),
                color: UIColor(red: 0.95, green: 0.56, blue: 0.16, alpha: 1.0),
                to: root,
                position: SIMD3<Float>(-0.18, 0.22, 0.0),
                scale: SIMD3<Float>(0.72, 1.8, 0.36)
            )
            addModel(
                named: "Placeholder_Bowl",
                mesh: .generateSphere(radius: 0.16),
                color: UIColor(red: 0.92, green: 0.94, blue: 0.96, alpha: 1.0),
                to: root,
                position: SIMD3<Float>(0.12, 0.12, 0.0),
                scale: SIMD3<Float>(1.0, 0.38, 1.0)
            )
            addModel(
                named: "Placeholder_Spoon",
                mesh: .generateBox(size: 0.16),
                color: UIColor(red: 0.72, green: 0.76, blue: 0.80, alpha: 1.0),
                to: root,
                position: SIMD3<Float>(0.34, 0.10, 0.04),
                scale: SIMD3<Float>(1.5, 0.10, 0.18)
            )
        }

        return root
    }

    private static func addModel(
        named name: String,
        mesh: MeshResource,
        color: UIColor,
        to parent: Entity,
        position: SIMD3<Float>,
        scale: SIMD3<Float> = SIMD3<Float>(1.0, 1.0, 1.0)
    ) {
        let material = SimpleMaterial(color: color, roughness: 0.68, isMetallic: false)
        let model = ModelEntity(mesh: mesh, materials: [material])
        model.name = name
        model.position = position
        model.scale = scale
        parent.addChild(model)
    }


    // Per-child corrections applied after the bundle is anchored.
    //
    // The playing-ball bundle is rigid, but it straddles two ground planes in the
    // source asset: the removed human model was on the lawn while the balls were
    // authored over the raised porch deck, half a metre higher. Even after dropping
    // the balls as one group only the middle ball touched down - the other two
    // floated 0.060 m and 0.180 m, because the lawn is not level under them.
    //
    // Each ball is its own Xform directly under the bundle Root, so each is seated
    // on its own. Ray-cast against the shipped house after the nudge, every ball
    // rests on the lawn with a ground gap of 0.000 m; the stripes sit 0.092 m up
    // because they band the ball around its middle. The group ends up 2.73 m from
    // the viewer at -12.3 degrees off-forward.
    //
    // Nothing else is corrected. The tree trunk and crate already measure a 0.000 m
    // gap on the living-room floor, and the whole breakfast setting sits on the
    // dining table once the bundle translation below is applied.
    private static func applyChildCorrections(for route: MemoryRoute, in props: Entity) {
        guard route == .playingBall else {
            return
        }

        for (childName, nudge) in ballGroundingNudges {
            guard let ball = props.findEntity(named: childName) else {
                print("⚠️ PROPS CHILD MISSING: \(childName)")
                continue
            }

            // Prop-root-local, so this survives any change to the anchor transform.
            ball.position += nudge
        }
    }

    // Per-ball seating on the lawn. Each ball and the stripe painted around it move
    // together.
    private static let ballGroundingNudges: [String: SIMD3<Float>] = [
        "Prop_Ball_1":       SIMD3<Float>(-0.300000, 1.799999, -0.766830),
        "Prop_BallStripe_1": SIMD3<Float>(-0.300000, 1.799999, -0.766830),
        "Prop_Ball_2":       SIMD3<Float>(-0.300000, 1.799999, -0.706830),
        "Prop_BallStripe_2": SIMD3<Float>(-0.300000, 1.799999, -0.706830),
        "Prop_Ball_3":       SIMD3<Float>(-0.300000, 1.799999, -0.886829),
        "Prop_BallStripe_3": SIMD3<Float>(-0.300000, 1.799999, -0.886829)
    ]

    private static let humanModelEntityNames: Set<String> = [
        "Dad",
        "Dad_ArmR",
        "BHead",
        "VTorso",
        "WShirt",
        "3Arm",
        "3LegA",
        "FLegL"
    ]

    private static func removeHumanModelIfNeeded(for route: MemoryRoute, from props: Entity) {
        guard route == .playingBall else {
            return
        }

        var entitiesToRemove: [Entity] = []

        func walk(_ entity: Entity) {
            if isHumanModelEntity(entity.name) {
                entitiesToRemove.append(entity)
                return
            }

            for child in entity.children {
                walk(child)
            }
        }

        walk(props)

        for entity in entitiesToRemove {
            entity.removeFromParent()
        }
    }

    private static func isHumanModelEntity(_ name: String) -> Bool {
        humanModelEntityNames.contains(name) || name.hasPrefix("Dad_")
    }

    // The destination marker each prop set belongs to. These must match the last
    // entry of the corresponding route in MemoryExperience.swift.
    private static func destinationMarkerName(for route: MemoryRoute) -> String {
        switch route {
        case .playingBall:
            "Location_Outdoor"
        case .christmasTree:
            "Location_Living Room"
        case .breakfast:
            "Location_Dining Room"
        }
    }

    // Marker names differ between the Swift route tables and the USD prims
    // ("Location_Living Room" vs "Location_Living_Room"), so match on a normalized
    // form rather than requiring an exact hit.
    private static func findMarker(named name: String, in houseEntity: Entity) -> Entity? {
        if let exact = houseEntity.findEntity(named: name) {
            return exact
        }

        let wanted = normalized(name)
        var match: Entity?

        func walk(_ entity: Entity) {
            if match == nil, normalized(entity.name) == wanted {
                match = entity
            }

            guard match == nil else { return }

            for child in entity.children {
                walk(child)
            }
        }

        walk(houseEntity)
        return match
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // Where each prop root sits relative to its destination marker. Derived from
    // the marker transforms in the house export the props were authored against,
    // as inverse(marker) applied to the authored prop root, so re-exporting the
    // house in a different global frame does not move the props off their mark.
    private static func propTransformRelativeToMarker(for route: MemoryRoute) -> simd_float4x4 {
        switch route {
        case .playingBall:
            simd_float4x4(
                SIMD4<Float>( 0.909234,  0.019178,  0.415843, 0.0),
                SIMD4<Float>( 0.416285, -0.041875, -0.908270, 0.0),
                SIMD4<Float>(-0.000005,  0.998939, -0.046058, 0.0),
                SIMD4<Float>( 7.692780, -2.459377, -34.303905, 1.0)
            )
        case .christmasTree:
            simd_float4x4(
                SIMD4<Float>(  0.496974, 0.076846, -0.864356, 0.0),
                SIMD4<Float>( -0.867766, 0.044002, -0.495022, 0.0),
                SIMD4<Float>( -0.000007, 0.996072,  0.088552, 0.0),
                SIMD4<Float>(-36.174756, 0.507835, -17.875998, 1.0)
            )
        case .breakfast:
            simd_float4x4(
                SIMD4<Float>( 0.011866, -0.138477,  0.990295, 0.0),
                SIMD4<Float>( 0.999930,  0.001649, -0.011751, 0.0),
                SIMD4<Float>(-0.000005,  0.990364,  0.138487, 0.0),
                SIMD4<Float>(47.551170, -1.127650, -0.561686, 1.0)
            )
        }
    }

    // Temporary primitive props sit close to each destination marker. When the
    // final USDZ files are ready, set usePlaceholderProps to false and the
    // authored asset transforms above will be used instead.
    private static func placeholderTransformRelativeToMarker(for route: MemoryRoute) -> simd_float4x4 {
        switch route {
        case .playingBall:
            translationMatrix(SIMD3<Float>(0.0, 0.0, -0.72))
        case .christmasTree:
            translationMatrix(SIMD3<Float>(0.0, -1.35, -1.05))
        case .breakfast:
            translationMatrix(SIMD3<Float>(0.0, 0.18, -0.48))
        }
    }

    // Dad + ball model: positioned on the left side of the bushes (viewer's left = -X),
    // roughly 10 m forward (-Z) of Location_Outdoor, grounded at terrain level.
    // +20° Y rotation corrects the model's intrinsic orientation so dad faces
    // Location_Outdoor (45° was too much; reduced by 25° per visual feedback).
    private static func dadAndBallTransformRelativeToMarker() -> simd_float4x4 {
        let cos20: Float = 0.93969
        let sin20: Float = 0.34202
        return simd_float4x4(
            SIMD4<Float>( cos20, 0, -sin20, 0),   // X axis after +20° Y rotation
            SIMD4<Float>( 0,     1,  0,     0),   // Y axis unchanged
            SIMD4<Float>( sin20, 0,  cos20, 0),   // Z axis after +20° Y rotation
            SIMD4<Float>(-3.5, -1.5, -11.5,  1)   // translation
        )
    }

    private static func translationMatrix(_ translation: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1.0, 0.0, 0.0, 0.0),
            SIMD4<Float>(0.0, 1.0, 0.0, 0.0),
            SIMD4<Float>(0.0, 0.0, 1.0, 0.0),
            SIMD4<Float>(translation.x, translation.y, translation.z, 1.0)
        )
    }

    static func ballMotionParent(in root: Entity) -> Entity? {
        func find(_ entity: Entity) -> Entity? {
            if entity.name == "Activity_Interactive_Ball" { return nil }
            if entity.name == "Sphere_0", entity.components.has(ModelComponent.self) { return entity }
            return entity.children.lazy.compactMap { find($0) }.first
        }
        var ancestor = find(root)
        while let node = ancestor {
            if node.name == "Root" { return node.parent }
            ancestor = node.parent
        }
        return nil
    }

    static func ballStartingPosition(in root: Entity) -> SIMD3<Float>? {
        guard let parent = ballMotionParent(in: root) else { return nil }
        let start = AuthoredBallMotion.positions[0]
        return parent.convert(position: [start.z, -start.x, start.y], to: nil)
    }

    private static func prepareBallArrival(in root: Entity) {
        ballGreetingControllers.forEach { $0.stop() }
        ballGreetingControllers = []
        ballGreetingAnimations = []
        ballArrivalControllers.forEach { $0.stop() }
        func pose(_ entity: Entity) -> [AnimationPlaybackController] {
            if !entity.availableAnimations.isEmpty {
                return entity.availableAnimations.map {
                    let playback = entity.playAnimation($0)
                    playback.pause()
                    playback.time = 0
                    return playback
                }
            }
            return entity.children.flatMap { pose($0) }
        }
        ballArrivalControllers = pose(root)
        guard let wrapper = prepareBallPresentation(in: root),
              let hand = ballStartingPosition(in: root) else { return }
        wrapper.setTransformMatrix(Transform(translation: hand).matrix, relativeTo: nil)
        prepareBallGreeting(in: root, ball: wrapper)
    }

    // Three existing arm joints, sampled once before travel. No duplicate mesh,
    // texture, lights, or persistent per-frame Swift task is needed for the wave.
    private static func prepareBallGreeting(in root: Entity, ball: Entity) {
        func findRig(_ entity: Entity) -> ModelEntity? {
            if let model = entity as? ModelEntity,
               model.jointNames.contains(where: { $0.hasSuffix("mixamorig_RightHand_030") }) { return model }
            return entity.children.lazy.compactMap { findRig($0) }.first
        }
        guard let rig = findRig(root) else {
            print("Dad greeting: compatible arm rig unavailable; retaining holding pose")
            return
        }
        let joints = ["mixamorig_RightArm_028", "mixamorig_RightForeArm_029", "mixamorig_RightHand_030"]
        let names = joints.compactMap { leaf in rig.jointNames.first { $0.hasSuffix(leaf) } }
        guard names.count == joints.count else { return }
        // Local rotations measured from this asset's first throwing pose and
        // a greeting pose solved on the same skeleton; translations stay intact.
        let resting: [simd_quatf] = [
            simd_quatf(vector: SIMD4<Float>(0.581701565, 0.048511920, -0.207322194, 0.785039732)),
            simd_quatf(vector: SIMD4<Float>(-0.066308626, -0.000428908, -0.477133693, 0.876325531)),
            simd_quatf(vector: SIMD4<Float>(0.002318220, -0.047307561, 0.001080522, 0.998877096))
        ]
        let raised: [simd_quatf] = [
            simd_quatf(vector: SIMD4<Float>(0.280424217, 0.077287677, -0.125143996, 0.948539854)),
            simd_quatf(vector: SIMD4<Float>(0.393560362, -0.154960738, 0.781044902, -0.459419494)),
            simd_quatf(vector: SIMD4<Float>(0.002318220, -0.047307561, 0.001080522, 0.998877096))
        ]
        func ease(_ value: Float) -> Float {
            let t = min(1, max(0, value))
            return t * t * (3 - 2 * t)
        }
        var armFrames: [JointTransforms] = []
        var ballFrames: [Transform] = []
        let home = ball.transform
        for index in 0...96 {
            let time = Float(index) / 30
            let amount = ease(time / 0.70) * ease((3.2 - time) / 0.85)
            let wavePhase = min(1, max(0, (time - 0.70) / 1.65))
            let wave = sin(wavePhase * .pi * 4) * sin(wavePhase * .pi) * 0.14
            let transforms = joints.indices.map { joint -> Transform in
                var target = raised[joint]
                if joint == 2 { target = target * simd_quatf(angle: wave, axis: [0, 0, 1]) }
                return Transform(rotation: simd_slerp(resting[joint], target, amount))
            }
            armFrames.append(JointTransforms(transforms))
            var held = home
            // Bring the same ball into the left hand while the right greets.
            held.translation += SIMD3<Float>(0.10, 0, -0.08) * amount
            ballFrames.append(held)
        }
        do {
            let arm = try AnimationResource.generate(with: SampledAnimation<JointTransforms>(
                jointNames: names, frames: armFrames, name: "DadArrivalWave", frameInterval: 1.0 / 30.0,
                isScaleAnimated: false, isRotationAnimated: true, isTranslationAnimated: false,
                bindTarget: .jointTransforms, blendLayer: 100, fillMode: .forwards))
            let heldBall = try AnimationResource.generate(with: SampledAnimation<Transform>(
                frames: ballFrames, name: "DadLeftHandBall", frameInterval: 1.0 / 30.0,
                bindTarget: .transform, fillMode: .forwards))
            ballGreetingAnimations = [(rig, arm), (ball, heldBall)]
        } catch {
            print("Dad greeting preparation failed: \(error)")
        }
    }

    static func beginBallArrivalGreeting() {
        guard ballGreetingControllers.isEmpty else { return }
        ballGreetingControllers = ballGreetingAnimations.map { entity, animation in
            entity.playAnimation(animation)
        }
    }

    static func takeBallArrivalControllers() -> [AnimationPlaybackController] {
        ballGreetingControllers.forEach { $0.stop() }
        ballGreetingControllers = []
        ballGreetingAnimations = []
        defer { ballArrivalControllers = [] }
        return ballArrivalControllers
    }

    /// Keep one 26 cm ball from arrival through departure. The imported ball
    /// has a different authored scale and must never replace the interaction mesh.
    @discardableResult
    static func prepareBallPresentation(in root: Entity) -> Entity? {
        if let existing = root.findEntity(named: "Activity_Interactive_Ball") { return existing }
        func findMesh(_ entity: Entity) -> Entity? {
            if entity.name == "Sphere_0", entity.components.has(ModelComponent.self) { return entity }
            return entity.children.lazy.compactMap { findMesh($0) }.first
        }
        guard let original = findMesh(root) else { return nil }
        let centre = original.visualBounds(relativeTo: nil).center
        let sphere = original.clone(recursive: true)
        sphere.isEnabled = true
        sphere.transform = .identity
        let bounds = sphere.visualBounds(relativeTo: sphere)
        let diameter = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        guard diameter > 0.0001 else { return nil }
        let scale = 0.26 / diameter
        sphere.scale = SIMD3(repeating: scale)
        sphere.position = -bounds.center * scale
        let wrapper = Entity()
        wrapper.name = "Activity_Interactive_Ball"
        wrapper.addChild(sphere)
        root.addChild(wrapper)
        wrapper.setTransformMatrix(Transform(translation: centre).matrix, relativeTo: nil)
        original.isEnabled = false
        return wrapper
    }

    // Hides every loaded prop set. Used when returning home so the bedroom is not
    // looking at another memory's furniture.
    static func finishDepartureFades() async {
        let pending = Array(retiringProps.values)
        for task in pending { await task.value }
    }

    static func hideAllProps(in houseEntity: Entity) {
        christmasLightTimer?.invalidate()
        christmasLightTimer = nil
        for route in MemoryRoute.allCases {
            let name = rootName(for: route)
            guard let root = houseEntity.findEntity(named: name), root.isEnabled,
                  !root.components.has(ChristmasAwaitingFirstVisit.self),
                  retiringProps[name] == nil else { continue }
            let frames = (0...24).map { index -> Float in
                let t = Float(index) / 24
                return 1 - t * t * (3 - 2 * t)
            }
            root.components.set(OpacityComponent(opacity: 1))
            if let animation = try? AnimationResource.generate(with: SampledAnimation<Float>(
                frames: frames, name: "ActivityDepartureFade", frameInterval: 0.36 / 24,
                bindTarget: .opacity, blendLayer: 200, fillMode: .forwards)) {
                retirementAnimations[name] = root.playAnimation(animation)
            }
            retiringProps[name] = Task { @MainActor in
                let started = CACurrentMediaTime()
                while let playback = retirementAnimations[name], playback.isValid,
                      !playback.isComplete, playback.time < 0.36,
                      CACurrentMediaTime() - started < 1.5 {
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                root.components.set(OpacityComponent(opacity: 0))
                root.isEnabled = false
                // Stopping the tree's tracks restores their rest transforms.
                // Do that only after the whole activity has become invisible.
                if route == .christmasTree {
                    christmasAnimationControllers.forEach { $0.stop() }
                    christmasAnimationControllers.removeAll()
                }
                retirementAnimations.removeValue(forKey: name)?.stop()
                root.components.set(OpacityComponent(opacity: 1))
                retiringProps.removeValue(forKey: name)
            }
        }
    }
}
