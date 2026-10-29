import Foundation
import Combine
import Observation
import RealityKit
import Metal
import QuartzCore
import simd

/// Object interactions own progression; tracked movement supplies measurements only.
@MainActor @Observable
final class ActivityInteractionController {
    private(set) var isBusy = false
    private(set) var isReady = false
    private var feedbackValue: String?
    private(set) var feedback: String? {
        get { feedbackValue }
        set { if feedbackValue != newValue { feedbackValue = newValue } }
    }
    private(set) var calloutTarget: Entity?
    private var calloutTextValue = ""
    private(set) var calloutText: String {
        get { calloutTextValue }
        set { if calloutTextValue != newValue { calloutTextValue = newValue } }
    }
    private(set) var ball: Entity?
    private(set) var interactionProgress: Double = 0
    @ObservationIgnored private var lastProgressPublication = Date.distantPast

    // Hand/object transforms stay at tracking cadence. The progress attachment
    // does not need a new SwiftUI/RealityView transaction for every joint sample.
    private func publishProgress(_ value: Double) {
        let value = min(1, max(0, value))
        guard value != interactionProgress else { return }
        let now = Date()
        guard value == 0 || value == 1 || now.timeIntervalSince(lastProgressPublication) >= 0.08 else { return }
        lastProgressPublication = now
        interactionProgress = value
    }
    private(set) var isPlacementArmed = false
    private(set) var isOverPlacementTarget = false
    private var dragged: Entity?
    private var dragOrigin = SIMD3<Float>.zero
    private var lastDelta = SIMD3<Float>.zero
    private var lastDragTime = Date()
    private var stirAngle: Double?
    private var stirDirectionSample: SIMD2<Float>?
    private var stirTravel: Double = 0
    private var stirActiveSeconds: Double = 0
    private var gestureFraction: Double = 0
    private var lastTapTime = Date.distantPast
    var onMovement: ((Double, Double, Double) -> Void)?
    var onSound: ((String, Entity, Bool) -> Void)?
    private var route: MemoryRoute?
    private var root: Entity?
    private var step = 0
    private(set) var selectedOrnamentIndex: Int?
    private(set) var placedOrnamentIndices: Set<Int> = []
    private(set) var spoonIsHeld = false
    private var spoonAtBowl = false
    var isSpoonAtBowl: Bool { spoonIsHeld && spoonAtBowl }
    private var spoonPickupOrientation = simd_quatf()
    private var spoonHandleLocal = SIMD3<Float>.zero
    private var spoonTipLocal = SIMD3<Float>.zero
    @ObservationIgnored private var spoonSurfaceProfile: [SIMD3<Float>] = []
    // One input source owns each pinch from beginning to end. ARKit samples
    // never acquire, move or release the spoon independently of that gesture.
    private var spoonDeviceOrigin: SIMD3<Float>?
    private var spoonUsesDevicePose = false
    private var spoonPoseMissing = false
    private var spoonLiftFraction: Float = 0
    private var spoonInsideBowl = false
    private var spoonStirDistance: Double = 0
    private var handOpenSince: Date?
    private var lastGraspRelease = Date.distantPast
    private var graspUsesPrecision = false
    private var handLastTracked = Date.distantPast
    var instructionTitle: String? {
        guard route == .breakfast else { return nil }
        if step == 2 { return spoonIsHeld ? (spoonAtBowl ? "Stir the cereal" : "Bring the spoon to the bowl") : "Pick up the spoon" }
        if isBusy { return step == 0 ? "Pouring cereal" : "Pouring milk" }
        if breakfastLifted { return "Pour into the bowl" }
        return step == 0 ? "Lift the cereal box" : "Lift the milk carton"
    }
    private var breakfastLifted = false
    private var pointerTiltOrigin = SIMD3<Float>.zero
    private var ballReturns = 0
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var controllers: [AnimationPlaybackController] = []
    private var suspendedInputTargets: [(Entity, InputTargetComponent)] = []
    private var rest: [(Entity, Transform)] = []
    private var ballLateralAxis = SIMD3<Float>(1, 0, 0)
    private var ballHome = SIMD3<Float>.zero
    private var preview: Entity?
    private var onProgress: ((Int, Int) -> Void)?
    private var onComplete: (() -> Void)?
    private struct FluidVertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
    }
    private var fluidBuffer: LowLevelMesh?
    private var fluidResource: MeshResource?
    private var fluidIndexCount = 0
    private var lastStirUpdate = Date.distantPast
    private var stirPhase: Float = 0
    private var cerealLandingMeshes: [(Entity, Transform)] = []
    private var mixingGrains: [Entity] = []
    @ObservationIgnored private weak var prewarmedBreakfastRoot: Entity?

    /// Prime mesh queries and the paused cereal clip before the journey. On
    /// arrival, installing callbacks must not block the first hand interaction.
    func prewarmBreakfast(in root: Entity) {
        prepare(route: .breakfast, root: root, onProgress: { _, _ in }, onComplete: {})
        isReady = false
        prewarmedBreakfastRoot = root
    }

    private func prepareCerealMotion(in cereal: Entity) {
        cerealLandingMeshes = []
        func collect(_ entity: Entity, isParticle: Bool = false) {
            let particle = isParticle || entity.name.hasPrefix("CerealPiece_")
            if particle && entity.components.has(ModelComponent.self) {
                cerealLandingMeshes.append((entity, entity.transform))
            }
            for child in entity.children { collect(child, isParticle: particle) }
        }
        collect(cereal)
        mixingGrains.forEach { $0.removeFromParent() }; mixingGrains = []
        guard let root, let source = cerealLandingMeshes.first?.0 else { return }
        var grainScale: Float?
        for index in 0..<18 {
            let grain = source.clone(recursive: false)
            grain.name = "StirredCereal_\(index)"
            grain.transform = .identity
            // Every grain is the same mesh with the same identity transform.
            // Compute its bounds once instead of repeating the render query.
            if grainScale == nil {
                let bounds = grain.visualBounds(relativeTo: grain)
                grainScale = 0.009 / max(0.001, bounds.extents.max())
            }
            grain.scale = SIMD3(repeating: grainScale ?? 1)
            grain.isEnabled = false
            root.addChild(grain); mixingGrains.append(grain)
        }
    }

    private func settleCerealParticles() {
        guard let cereal = root?.findEntity(named: "Breakfast_Cereal_Animation") else { return }
        for (mesh, rest) in cerealLandingMeshes {
            mesh.transform = rest
            guard let parent = mesh.parent else { continue }
            let centre = mesh.visualBounds(relativeTo: cereal).center
            let fraction = min(1, max(0, (0.16 - centre.y) / 0.07))
            if fraction > 0, simd_length(parent.scale) > 0.01 {
                let offset = parent.convert(direction: SIMD3<Float>(0, -0.035 * fraction, 0), from: cereal)
                if offset.x.isFinite && offset.y.isFinite && offset.z.isFinite { mesh.position += offset }
            }
        }
    }

    private func updateStirredContents(angle: Float, movement: Double) {
        guard movement > 0.001, Date().timeIntervalSince(lastStirUpdate) >= 1.0 / 30 else { return }
        lastStirUpdate = Date(); stirPhase = angle
        for (index, grain) in mixingGrains.enumerated() {
            let phase = Float(index) * 2.399 + angle * 0.12
            let radius: Float = 0.018 + Float(index % 5) * 0.010
            grain.position = [radius * cos(phase), 0.041 + sin(phase * 2) * 0.0005, radius * sin(phase)]
            grain.orientation = simd_quatf(angle: phase, axis: [0, 1, 0])
            grain.isEnabled = true
        }
        if let flow = root?.findEntity(named: "MilkFlow") as? ModelEntity,
           let mesh = try? milkFlowMesh(lip: .zero, progress: 1, includingStream: false, stirringPhase: angle) {
            if flow.model?.mesh !== mesh { flow.model?.mesh = mesh }
        }
    }

    private(set) var isHandGrasping = false
    private var graspHand: Bool?
    private var graspEntity: Entity?
    @ObservationIgnored private var graspBounds: [ObjectIdentifier: BoundingBox] = [:]
    private var graspOrigin = SIMD3<Float>.zero
    private var graspRotation = simd_quatf()
    private var spoonPickupHandleWorld = SIMD3<Float>.zero
    private var lastHandPosition = SIMD3<Float>.zero
    private var lastHandTime = Date()
    private var handDrivenUpdate = false
    private var heldBreakfastVisual: Entity?
    private var hiddenBreakfastVisual: Entity?
    private var heldBreakfastStart = Transform()
    private var handPourActive = false
    private var handPourFinished = false

    /// Direct grasp is local to a nearby object. A closed hand at a distance
    /// cannot select anything, and opening that same hand releases the object.
    func updateHandGrasp(_ sample: HandGraspSample) {
        guard isReady, let route else { return }
        // Milk and spoon belong exclusively to a system-targeted pinch.
        // ARKit proximity samples must never acquire them or take over an
        // ongoing drag. Cereal retains its existing tracked-grasp behaviour.
        if route == .breakfast && step >= 1 { return }
        if let hand = graspHand {
            guard sample.isLeft == hand else { return }
            guard sample.isTracked else {
                // Brief occlusion while grasping must not drop the utensil.
                guard Date().timeIntervalSince(handLastTracked) > 0.35 else { return }
                if route == .breakfast && step < 2 && heldBreakfastVisual != nil {
                    releaseHandHeldBreakfast()
                    return
                }
                // Tracking loss is cancellation, never an implicit throw.
                if route == .playingBall || route == .christmasTree {
                    dragged?.setPosition(dragOrigin, relativeTo: nil)
                }
                resetHeldBreakfastVisual()
                dragged = nil; graspHand = nil; graspEntity = nil; isHandGrasping = false
                handOpenSince = nil
                if let root { onSound?("Mixing", root, false); onSound?("Cutlery", root, false) }
                return
            }
            handLastTracked = Date()
            // Releasing a spoon does not require all fingers to become rigidly straight.
            // A precision pickup releases when thumb and index separate; a whole-hand
            // grasp releases on two extended fingers without a remaining fist.
            let precisionReleased = graspUsesPrecision && sample.isPrecisionGripReleased
            let handReleased = sample.openFingers >= 2 && sample.curledFingers < 2 && !sample.isPrecisionGrip
            if precisionReleased || (route != .breakfast && handReleased) {
                if handOpenSince == nil { handOpenSince = Date() }
                guard Date().timeIntervalSince(handOpenSince!) >= 0.08 else { return }
                if route == .breakfast && step < 2 && heldBreakfastVisual != nil {
                    releaseHandHeldBreakfast()
                } else { dragEnded() }
                lastGraspRelease = Date()
                graspHand = nil; graspEntity = nil; isHandGrasping = false
                return
            }
            handOpenSince = nil
            guard (!isBusy || handPourActive), let entity = graspEntity else { return }
            let displacement = sample.palmPosition - graspOrigin
            let moved = simd_distance(sample.palmPosition, lastHandPosition)
            let now = Date()
            let dt = min(0.1, now.timeIntervalSince(lastHandTime))
            if moved > 0.001 && moved < 0.15 { onMovement?(Double(moved) * 100, 0, dt) }
            lastHandPosition = sample.palmPosition; lastHandTime = now
            handDrivenUpdate = true
            defer { handDrivenUpdate = false }
            if route == .breakfast && step < 2 {
                let rotation = sample.orientation * graspRotation.inverse
                if let visual = heldBreakfastVisual {
                    var pose = heldBreakfastStart
                    // Rotate around the acquired palm contact, not the model's
                    // exported pivot. Otherwise tilting makes the carton drift
                    // away from the hand even when wrist tracking is accurate.
                    pose.translation = sample.palmPosition
                        + rotation.act(heldBreakfastStart.translation - graspOrigin)
                    pose.rotation = rotation * heldBreakfastStart.rotation
                    visual.setTransformMatrix(pose.matrix, relativeTo: nil)
                }
                // Pouring never takes ownership of a tracked carton transform.
                // The same grasp remains live until the user opens their hand.
                if handPourActive { return }
                if !breakfastLifted {
                    gestureFraction = min(1, Double(max(0, displacement.y) / 0.12))
                    publishProgress(gestureFraction)
                    if gestureFraction >= 0.96 {
                        breakfastLifted = true
                        gestureFraction = 0; interactionProgress = 0
                        updateBreakfastCallout()
                    }
                }
                if breakfastLifted {
                    let tilt = acos(min(1, max(-1, simd_dot(rotation.act(SIMD3<Float>(0, 1, 0)), SIMD3<Float>(0, 1, 0)))))
                    gestureFraction = min(1, Double(tilt / 0.65))
                    publishProgress(gestureFraction)
                    feedback = "Keep holding. Tilt your hand toward the bowl."
                    if gestureFraction >= 0.96 {
                        beginHandControlledPour(entity)
                    }
                } else { feedback = "Lift your hand straight up." }
            } else {
                dragChanged(entity, translation: displacement)
            }
            return
        }
        let deliberatePickup = route == .breakfast ? sample.isPrecisionGrip : sample.curledFingers >= 2
        guard sample.isTracked, !isBusy, Date().timeIntervalSince(lastGraspRelease) > 0.45,
              deliberatePickup else { return }
        let candidates: [Entity]
        switch route {
        case .breakfast:
            candidates = [root?.findEntity(named: step == 0 ? "Breakfast_Box" : (step == 1 ? "Breakfast_Milk" : "Breakfast_Spoon"))].compactMap { $0 }
        case .playingBall: candidates = [ball].compactMap { $0 }
        case .christmasTree: candidates = [preview].compactMap { $0 }
        }
        guard let entity = candidates.first(where: { entity in
            let visual = entity.name == "Breakfast_Box" ? (entity.parent ?? entity) : entity
            // Cache the resting local bounds once. Recursive visualBounds on a
            // cereal hierarchy is unnecessary work on every hand-anchor sample.
            let id = ObjectIdentifier(visual)
            let bounds: BoundingBox
            if let cached = graspBounds[id] { bounds = cached }
            else {
                let measured = visual.visualBounds(relativeTo: visual, excludeInactive: true)
                // Match the cereal's forgiving pickup volume for the slimmer carton.
                if entity.name == "Breakfast_Milk" {
                    let half = simd_max(measured.extents, SIMD3<Float>(0.22, 0.30, 0.18)) * 0.5
                    bounds = BoundingBox(min: measured.center - half, max: measured.center + half)
                } else { bounds = measured }
                graspBounds[id] = bounds
            }
            let localPalm = visual.convert(position: sample.palmPosition, from: nil)
            let nearest = simd_min(simd_max(localPalm, bounds.min), bounds.max)
            let separation = simd_distance(sample.palmPosition, visual.convert(position: nearest, to: nil))
            if separation <= (route == .breakfast ? 0.16 : 0.12) { return true }
            // A closed hand approaching the active carton can acquire it short
            // of its surface. Preserve the contact offset, so it does not jump
            // toward the palm and the accepted table layout stays unchanged.
            let eye = viewerPose().translation
            let toObject = visual.convert(position: bounds.center, to: nil) - eye
            let toHand = sample.palmPosition - eye
            guard simd_length(toObject) > 0.01, simd_length(toHand) > 0.20 else { return false }
            return route == .breakfast && separation <= 0.40
                && simd_dot(simd_normalize(toObject), simd_normalize(toHand)) > 0.93
        }) else { return }
        // Let a tracked grasp take over the same object from a system pinch drag.
        // Otherwise the first targeted-drag event can permanently block hand following.
        guard dragged == nil || dragged === entity else { return }
        if dragged != nil { dragged = nil }
        entity.stopAllAnimations(recursive: false)
        handLastTracked = Date(); handOpenSince = nil
        graspUsesPrecision = route == .breakfast && sample.isPrecisionGrip
        graspHand = sample.isLeft; graspEntity = entity; isHandGrasping = true
        graspOrigin = sample.palmPosition; graspRotation = sample.orientation
        lastHandPosition = sample.palmPosition; lastHandTime = Date()
        handDrivenUpdate = true
        dragChanged(entity, translation: .zero)
        if route == .breakfast && step < 2 {
            if step == 0, let source = root?.findEntity(named: "Box_Pivot")?.findEntity(named: "scene_001"), let root {
                // The Blender clip owns the source transforms. A resource-sharing
                // display clone lets the real grasp move freely without fighting
                // those animation channels. The source is hidden until pouring.
                let visual = source.clone(recursive: true)
                visual.name = "HandHeldCereal"
                visual.stopAllAnimations()
                let pose = source.transformMatrix(relativeTo: nil)
                root.addChild(visual)
                visual.setTransformMatrix(pose, relativeTo: nil)
                source.isEnabled = false
                hiddenBreakfastVisual = source
                heldBreakfastVisual = visual
            } else { heldBreakfastVisual = entity }
            if let visual = heldBreakfastVisual { heldBreakfastStart = Transform(matrix: visual.transformMatrix(relativeTo: nil)) }
        }
        handDrivenUpdate = false
    }

    var viewerPose: () -> Transform = { Transform(translation: [0, 1.6, 0]) }

    func prepare(route: MemoryRoute, root: Entity, onProgress: @escaping (Int, Int) -> Void, onComplete: @escaping () -> Void) {
        let preparationBegan = Date()
        defer { print("PERF interaction preparation: \(Date().timeIntervalSince(preparationBegan) * 1000) ms") }
        let reuseBreakfast = route == .breakfast && prewarmedBreakfastRoot === root
        if !reuseBreakfast { cancel() }
        prewarmedBreakfastRoot = nil
        self.route = route
        self.root = root
        self.onProgress = onProgress
        self.onComplete = onComplete
        step = 0
        breakfastLifted = false; spoonIsHeld = false; spoonAtBowl = false; ballReturns = 0
        selectedOrnamentIndex = nil; placedOrnamentIndices = []
        interactionProgress = 0; stirTravel = 0; stirActiveSeconds = 0
        isReady = true
        if route == .breakfast {
            if !reuseBreakfast {
                if let cereal = root.findEntity(named: "Breakfast_Cereal_Animation") {
                    var began = CACurrentMediaTime()
                    controllers = clips(in: cereal)
                    controllers.forEach { $0.pause(); $0.time = 0 }
                    print("PERF breakfast clips: \(1000 * (CACurrentMediaTime() - began)) ms")
                    began = CACurrentMediaTime()
                    prepareCerealMotion(in: cereal)
                    print("PERF cereal motion: \(1000 * (CACurrentMediaTime() - began)) ms")
                    print("BREAKFAST CLIPS: \(controllers.map(\.duration))")
                }
                if let spoon = root.findEntity(named: "Breakfast_Spoon") {
                    remember(spoon)
                    cacheSpoonSurface(spoon)
                }
                if let milk = root.findEntity(named: "Breakfast_Milk") { remember(milk) }
                if let cap = root.findEntity(named: "Breakfast_MilkCap") { remember(cap); cap.isEnabled = true }
                root.findEntity(named: "Breakfast_MilkOpening")?.isEnabled = false
            }
            updateBreakfastCallout()
            feedback = "Hold and lift straight up."
        } else if route == .christmasTree {
            ActivityPropManager.straightenChristmasProps(in: root)
            for i in 1...3 {
                if let ornament = root.findEntity(named: "Christmas_Ornament_\(i)_Slot") {
                    remember(ornament)
                    if let cratePose = ornament.findEntity(named: "OrnamentCratePose") { remember(cratePose) }
                }
            }
        } else {
            prepareBall(in: root)
        }
    }

    /// Stop input and motion without restoring rest poses while props are visible.
    func suspendForDeparture() {
        isReady = false
        task?.cancel(); task = nil
        previewTask?.cancel(); previewTask = nil
        controllers.forEach { $0.pause() }
        onProgress = nil; onComplete = nil
    }

    func cancel() {
        prewarmedBreakfastRoot = nil
        handPourActive = false; handPourFinished = false
        graspBounds.removeAll(keepingCapacity: true)
        spoonDeviceOrigin = nil; spoonUsesDevicePose = false; spoonPoseMissing = false
        spoonInsideBowl = false; spoonLiftFraction = 0; spoonStirDistance = 0
        resetHeldBreakfastVisual()
        graspHand = nil; graspEntity = nil; isHandGrasping = false
        cerealLandingMeshes.forEach { $0.0.transform = $0.1 }; cerealLandingMeshes = []
        mixingGrains.forEach { $0.removeFromParent() }; mixingGrains = []
        for (entity, target) in suspendedInputTargets { entity.components.set(target) }
        suspendedInputTargets = []
        fluidBuffer = nil; fluidResource = nil; fluidIndexCount = 0
        task?.cancel(); task = nil
        previewTask?.cancel(); previewTask = nil
        controllers.forEach { $0.stop() }; controllers = []
        for (entity, transform) in rest { entity.stopAllAnimations(); entity.transform = transform }
        rest = []
        // Preserve the same visible ball during Home travel and prop fade-out.
        // Restoring the larger imported mesh here caused the size jump.
        ball?.components.remove(InputTargetComponent.self)
        ball?.components.remove(CollisionComponent.self)
        ball = nil
        preview = nil; selectedOrnamentIndex = nil; placedOrnamentIndices = []
        root?.findEntity(named: "Breakfast_MilkStream")?.isEnabled = false
        dragged = nil; isPlacementArmed = false; isOverPlacementTarget = false
        spoonSurfaceProfile = []
        interactionProgress = 0
        if let root {
            for sound in ["CerealPour", "MilkPour", "Cutlery", "Mixing"] { onSound?(sound, root, false) }
        }
        onMovement = nil; onSound = nil
        calloutTarget = nil
        isBusy = false; isReady = false; feedback = nil
        onProgress = nil; onComplete = nil; route = nil; root = nil
    }

    func tap(_ entity: Entity) {
        guard isReady, !isBusy, let route else { return }
        guard Date().timeIntervalSince(lastTapTime) > 0.25 else { return }
        lastTapTime = Date()
        switch route {
        case .breakfast:
            guard ancestor(of: entity, names: ["Breakfast_Box", "Breakfast_Milk", "Breakfast_Bowl", "Breakfast_Spoon"]) != nil else { return }
            feedback = step < 2 ? (breakfastLifted ? "Keep holding. Tilt toward the bowl." : "Hold and lift straight up.") : "Look at the spoon, pinch and hold, then bring it over the bowl."
        case .christmasTree:
            guard let slot = ornamentSlot(for: entity),
                  let index = ActivityPropManager.christmasOrnamentIndex(of: slot),
                  !placedOrnamentIndices.contains(index) else { return }
            if preview == nil { previewOrnament(slot, index: index) }
            else if slot === preview, step % 3 == 1 {
                previewTask?.cancel(); previewTask = nil
                placeOrnament(slot, index: index)
            }
        case .playingBall:
            guard ancestor(of: entity, names: ["Activity_Interactive_Ball"]) != nil else { return }
            calloutText = "Move toward Dad · release"
            feedback = "Hold the ball, move it toward Dad, then release."
        }
    }

    private func ornamentSlot(for entity: Entity) -> Entity? {
        var candidate: Entity? = entity
        while let item = candidate {
            if item.name.hasSuffix("_Slot"), ActivityPropManager.christmasOrnamentIndex(of: item) != nil { return item }
            candidate = item.parent
        }
        return nil
    }

    /// SwiftUI's targeted drag supplies scene-space movement for both mouse and
    /// Vision Pro pinch-and-drag. Time without movement never advances an activity.
    func targetedDragChanged(_ entity: Entity, translation: SIMD3<Float>, handPosition: SIMD3<Float>? = nil) {
        guard route == .breakfast, step == 2 else { dragChanged(entity, translation: translation); return }
        guard ancestor(of: entity, names: ["Breakfast_Spoon"]) != nil, !isBusy else { return }
        if dragged == nil {
            spoonUsesDevicePose = handPosition != nil
            spoonDeviceOrigin = handPosition
            spoonPoseMissing = false
            dragChanged(entity, translation: .zero, spatialSpoonInput: spoonUsesDevicePose)
        }
        if spoonUsesDevicePose {
            guard let handPosition else { spoonPoseMissing = true; return }
            if spoonPoseMissing {
                spoonDeviceOrigin = handPosition - lastDelta
                spoonPoseMissing = false
            }
            guard let origin = spoonDeviceOrigin else { return }
            dragChanged(entity, translation: handPosition - origin, spatialSpoonInput: true)
        } else {
            dragChanged(entity, translation: translation, spatialSpoonInput: false)
        }
    }

    func dragChanged(_ entity: Entity, translation: SIMD3<Float>, spatialSpoonInput: Bool? = nil) {
        guard isReady, !isBusy, let route else { return }
        if dragged == nil {
            pointerTiltOrigin = .zero
            switch route {
            case .breakfast:
                guard let target = ancestor(of: entity, names: [step == 0 ? "Breakfast_Box" : (step == 1 ? "Breakfast_Milk" : "Breakfast_Spoon")]) else { return }
                dragged = target
                gestureFraction = 0
                if step == 2 {
                    // Cancel only a prior return-to-table animation before the
                    // next deliberate pickup; never fight two transform writers.
                    target.stopAllAnimations(recursive: false)
                    stirAngle = nil; stirDirectionSample = nil
                    spoonIsHeld = true; spoonAtBowl = false; spoonInsideBowl = false
                    spoonLiftFraction = 0
                    if !handDrivenUpdate {
                        let bounds = target.visualBounds(relativeTo: target)
                        spoonHandleLocal = [bounds.center.x, bounds.center.y, bounds.min.z + 0.025]
                        spoonTipLocal = [bounds.center.x, bounds.center.y, bounds.max.z - 0.003]
                        spoonPickupOrientation = target.orientation(relativeTo: nil)
                    }
                    spoonPickupHandleWorld = target.convert(position: spoonHandleLocal, to: nil)
                    updateBreakfastCallout()
                }
            case .christmasTree:
                guard let target = ornamentSlot(for: entity), target === preview, step % 3 == 1 else { return }
                previewTask?.cancel(); previewTask = nil
                isPlacementArmed = true; dragged = target
            case .playingBall:
                guard let target = ancestor(of: entity, names: ["Activity_Interactive_Ball"]) else { return }
                dragged = target

            }
            dragOrigin = dragged!.position(relativeTo: nil)
            if handDrivenUpdate && route == .breakfast && step == 2 {
                dragOrigin = graspOrigin
            }
            lastDelta = .zero; lastDragTime = Date()
        }
        guard let dragged else { return }
        let now = Date()
        let dt = min(now.timeIntervalSince(lastDragTime), 0.1)
        let travelled = Double(simd_length(translation - lastDelta))
        let local = viewerPose().rotation.inverse.act(translation)
        if !handDrivenUpdate && travelled > 0.001 && travelled < 0.5 { onMovement?(travelled * 100, 0, dt) }
        let inputDelta = translation - lastDelta
        lastDelta = translation; lastDragTime = now
        switch route {
        case .breakfast:
            if step < 2 {
                let tiltMovement = handDrivenUpdate ? local : local - pointerTiltOrigin
                let extent = breakfastLifted ? simd_length(tiltMovement) : max(0, handDrivenUpdate ? translation.y : local.y)
                gestureFraction = min(1, Double(extent / (breakfastLifted ? 0.10 : 0.12)))
                if step == 0 {
                    let start = breakfastLifted ? 44.0 / 232.0 : 0
                    let end = breakfastLifted ? 70.0 / 232.0 : 44.0 / 232.0
                    controllers.forEach { $0.time = min($0.duration - 0.001, (start + (end - start) * gestureFraction) * $0.duration) }
                } else if let milk = root?.findEntity(named: "Breakfast_Milk"),
                          let saved = rest.first(where: { $0.0 === milk }) {
                    let lift = Float(breakfastLifted ? 1 : gestureFraction)
                    milk.position = saved.1.translation + SIMD3<Float>(0, 0.12 * lift, 0)
                    milk.orientation = simd_quatf(angle: breakfastLifted ? Float(gestureFraction) * .pi / 3 : 0, axis: [0, 0, 1]) * saved.1.rotation
                }
                publishProgress(gestureFraction)
                feedback = breakfastLifted ? "Keep holding. Tilt toward the bowl." : "Hold and lift straight up."
                if !handDrivenUpdate && gestureFraction >= 0.96 {
                    if !breakfastLifted {
                        breakfastLifted = true
                        pointerTiltOrigin = local
                        gestureFraction = 0; interactionProgress = 0
                        updateBreakfastCallout()
                        feedback = "Keep holding. Move toward the bowl to tilt."
                    } else {
                        // The drag fallback is continuous too; do not require a
                        // second pinch when tracked grasp acquisition is unavailable.
                        dragEnded()
                    }
                }
            } else if let spoon = root?.findEntity(named: "Breakfast_Spoon"), let root {
                let previousAtBowl = spoonAtBowl
                let previousTip = spoon.convert(position: spoonTipLocal, to: root)
                // Integrate incremental hand displacement. At a collision the
                // blocked movement is discarded, so reversing the hand responds
                // immediately instead of leaving a large invisible dead zone.
                var displacement = inputDelta
                #if targetEnvironment(simulator)
                if spatialSpoonInput == false && spoonInsideBowl {
                    let screen = viewerPose().rotation.inverse.act(inputDelta)
                    displacement = viewerPose().rotation.act([screen.x, 0, -screen.y])
                }
                #endif
                let up = simd_normalize(root.convert(direction: [0, 1, 0], to: nil))
                spoonLiftFraction = max(spoonLiftFraction, min(1, max(0, simd_dot(translation, up)) / 0.08))
                let lift = spoonLiftFraction * spoonLiftFraction * (3 - 2 * spoonLiftFraction)
                let carriedRotation = root.orientation(relativeTo: nil)
                    * simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
                    * simd_quatf(angle: .pi / 4, axis: [1, 0, 0])
                let desiredRotation = simd_slerp(spoonPickupOrientation, carriedRotation, lift)
                let initialRotation = spoon.orientation(relativeTo: nil)
                // Sweep the utensil in short steps so a large input event cannot
                // tunnel through the bowl wall. There is no orbit, recentering,
                // fixed depth, entry timer, or second controller for stirring.
                let steps = max(1, min(128, Int(ceil(simd_length(displacement) / 0.003))))
                for i in 1...steps {
                    let handle = spoon.convert(position: spoonHandleLocal, to: nil) + displacement / Float(steps)
                    spoon.setOrientation(simd_slerp(initialRotation, desiredRotation, Float(i) / Float(steps)), relativeTo: nil)
                    let offset = spoon.convert(position: spoonHandleLocal, to: nil) - spoon.position(relativeTo: nil)
                    spoon.setPosition(handle - offset, relativeTo: nil)
                    let tip = spoon.convert(position: spoonTipLocal, to: root)
                    let radius = simd_length(SIMD2(tip.x, tip.z))
                    if tip.y > 0.105 { spoonInsideBowl = false }
                    if radius < 0.084 && tip.y < 0.085 { spoonInsideBowl = true }
                    if spoonInsideBowl && radius > 0.084 {
                        let bounded = SIMD2(tip.x, tip.z) * (0.084 / radius)
                        spoon.position += SIMD3(bounded.x - tip.x, 0, bounded.y - tip.z)
                    }
                    constrainSpoonAboveCeramic(spoon, in: root)
                }
                let tip = spoon.convert(position: spoonTipLocal, to: root)
                spoonAtBowl = spoonInsideBowl && tip.y < 0.095
                if previousAtBowl != spoonAtBowl { updateBreakfastCallout() }
                let actualMovement = Double(simd_distance(previousTip, tip))
                let stirring = spoonAtBowl && actualMovement > 0.001 && actualMovement < 0.06
                if stirring {
                    spoonStirDistance += actualMovement
                    stirActiveSeconds += dt
                    updateStirredContents(angle: Float(spoonStirDistance * 30), movement: actualMovement)
                    publishProgress(min(1, min(spoonStirDistance / 0.55, stirActiveSeconds / 3)))
                }
                feedback = interactionProgress >= 1 ? "Well done. Release the spoon."
                    : (spoonAtBowl ? "Move the spoon gently inside the bowl." : "Keep pinching. Bring the spoon into the bowl.")
                onSound?("Cutlery", spoon, stirring); onSound?("Mixing", spoon, stirring)
            }
        case .christmasTree:
            dragged.setPosition(dragOrigin + translation, relativeTo: nil)
            isOverPlacementTarget = isAtTreeTarget(dragged, index: selectedOrnamentIndex ?? 0)
            feedback = isOverPlacementTarget ? "Release to hang it here." : "Move the ornament or its loop into the ring."
        case .playingBall:
            dragged.setPosition(dragOrigin + translation, relativeTo: nil)
            publishProgress(min(1, Double(simd_length(local)) / 0.16))
            feedback = interactionProgress >= 1 ? "Release to pass to Dad." : "Move the ball toward Dad."
        }
    }

    #if DEBUG
    func runBreakfastRegressionReview() async -> [String: Any] {
        guard route == .breakfast, let source = root, let parent = source.parent else { return ["error": "Breakfast not ready"] }
        let testRoot = source.clone(recursive: true)
        testRoot.name = "BreakfastRegressionCopy"
        testRoot.position.y -= 20
        parent.addChild(testRoot)
        let test = ActivityInteractionController()
        test.viewerPose = { Transform(translation: testRoot.convert(position: [0, 0.8, 0.6], to: nil)) }
        test.prepare(route: .breakfast, root: testRoot, onProgress: { _, _ in }, onComplete: {})
        defer { test.cancel(); testRoot.removeFromParent() }
        guard let spoon = testRoot.findEntity(named: "Breakfast_Spoon"),
              let milk = testRoot.findEntity(named: "Breakfast_Milk") else { return ["error": "Missing real props"] }
        var result: [String: Any] = [:]
        test.step = 1
        let milkBounds = milk.visualBounds(relativeTo: milk)
        let hand = milk.convert(position: milkBounds.center + [milkBounds.extents.x / 2 + 0.14, 0, 0], to: nil)
        func sample(_ position: SIMD3<Float>, curled: Int = 3, open: Int = 0) -> HandGraspSample {
            HandGraspSample(isLeft: false, isTracked: true, palmPosition: position,
                orientation: simd_quatf(real: 1, imag: .zero), curledFingers: curled, openFingers: open,
                isPrecisionGrip: curled > 0, isPrecisionGripReleased: open > 0)
        }
        if let box = testRoot.findEntity(named: "Breakfast_Box"), let visual = box.parent {
            test.step = 0
            let boxBounds = visual.visualBounds(relativeTo: visual)
            let boxHand = visual.convert(position: boxBounds.center, to: nil)
            test.updateHandGrasp(HandGraspSample(isLeft: false, isTracked: true, palmPosition: boxHand,
                orientation: simd_quatf(real: 1, imag: .zero), curledFingers: 4, openFingers: 0))
            result["curled_fingers_without_pinch_do_not_grab_cereal"] = !test.isHandGrasping
            test.updateHandGrasp(sample(boxHand))
            result["cereal_grasp_acquired"] = test.isHandGrasping
            if let held = test.heldBreakfastVisual {
                let start = held.position(relativeTo: nil)
                test.updateHandGrasp(sample(boxHand + [0, 0.08, 0]))
                try? await Task.sleep(for: .milliseconds(25))
                result["cereal_follows_hand_error_metres"] = Double(simd_distance(held.position(relativeTo: nil), start + [0, 0.08, 0]))
            }
            test.updateHandGrasp(sample(boxHand, curled: 0, open: 4))
            try? await Task.sleep(for: .milliseconds(100))
            test.updateHandGrasp(sample(boxHand, curled: 0, open: 4))
            result["cereal_releases_on_open_hand"] = !test.isHandGrasping
            try? await Task.sleep(for: .milliseconds(300))
            test.step = 1; test.lastGraspRelease = .distantPast
        }
        test.updateHandGrasp(sample(hand, curled: 0, open: 4))
        result["open_hand_does_not_grab_milk"] = !test.isHandGrasping
        test.updateHandGrasp(HandGraspSample(isLeft: false, isTracked: true, palmPosition: hand,
            orientation: simd_quatf(real: 1, imag: .zero), curledFingers: 4, openFingers: 0))
        result["curled_fingers_without_pinch_do_not_grab_milk"] = !test.isHandGrasping
        let milkStart = milk.position(relativeTo: nil)
        test.updateHandGrasp(sample(hand))
        test.updateHandGrasp(sample(hand + [0, 0.20, 0]))
        result["untargeted_pinch_cannot_acquire_or_move_milk"] = !test.isHandGrasping
            && simd_distance(milk.position(relativeTo: nil), milkStart) < 0.00001
        test.targetedDragChanged(spoon, translation: [0, 0.2, 0])
        result["wrong_target_cannot_acquire_milk"] = test.dragged == nil
        test.targetedDragChanged(milk, translation: .zero)
        result["targeted_pinch_acquires_milk"] = test.dragged === milk
        test.targetedDragChanged(milk, translation: [0, 0.08, 0])
        result["milk_scripted_lift_error_metres"] = Double(simd_distance(milk.position(relativeTo: nil), milkStart + [0, 0.08, 0]))
        let heldPose = milk.transform
        test.updateHandGrasp(sample(hand + [1, 1, 1]))
        test.updateHandGrasp(sample(hand, curled: 0, open: 4))
        result["arkit_cannot_steal_or_release_milk"] = test.dragged === milk
            && simd_distance(milk.position, heldPose.translation) < 0.00001
        test.targetedDragEnded()
        try? await Task.sleep(for: .milliseconds(320))
        result["cancelled_milk_pinch_returns_once_to_rest"] = test.dragged == nil && !test.isBusy
            && !test.breakfastLifted && simd_distance(milk.position(relativeTo: nil), milkStart) < 0.0001
        test.targetedDragChanged(milk, translation: .zero)
        test.targetedDragChanged(milk, translation: [0, 0.12, 0])
        result["milk_lift_keeps_same_pinch"] = test.breakfastLifted && test.dragged === milk
        test.targetedDragChanged(milk, translation: [0, 0.12, -0.10])
        result["milk_tilt_starts_scripted_pour"] = test.isBusy && test.dragged == nil
        try? await Task.sleep(for: .seconds(5.2))
        result["milk_pour_finishes_at_rest"] = test.step == 2 && !test.isBusy
            && simd_distance(milk.position(relativeTo: nil), milkStart) < 0.0001
        test.step = 2; test.isBusy = false; test.dragged = nil
        let restPose = spoon.transform
        func pinch(_ position: SIMD3<Float>, tracked: Bool = true, released: Bool = false) -> HandGraspSample {
            HandGraspSample(isLeft: false, isTracked: tracked, palmPosition: position,
                orientation: simd_quatf(real: 1, imag: .zero), curledFingers: released ? 0 : 3, openFingers: released ? 4 : 0,
                pinchPosition: tracked ? position : nil, isPrecisionGrip: !released, isPrecisionGripReleased: released)
        }
        let contact = spoon.position(relativeTo: nil)
        test.updateHandGrasp(pinch(contact))
        result["spoon_pinch_without_target_does_not_grab"] = !test.spoonIsHeld
        test.targetedDragChanged(spoon, translation: .zero, handPosition: contact)
        result["spoon_targeted_pinch_acquired"] = test.spoonIsHeld
        result["spoon_pickup_jump_metres"] = Double(simd_distance(spoon.position, restPose.translation))
        var input = contact
        func move(_ delta: SIMD3<Float>) {
            input += testRoot.convert(direction: delta, to: nil)
            test.lastDragTime = Date().addingTimeInterval(-1.0 / 60)
            test.targetedDragChanged(spoon, translation: .zero, handPosition: input)
        }
        for _ in 0..<30 { move([0, 0.005, 0]) }
        result["spoon_lift_stays_carried"] = test.spoonIsHeld && !test.spoonAtBowl
        let beforeOtherHand = spoon.position(relativeTo: nil)
        test.updateHandGrasp(pinch(contact + [0.5, -0.2, 0.3], released: true))
        result["arkit_cannot_move_or_release_spoon"] = test.spoonIsHeld && simd_distance(beforeOtherHand, spoon.position(relativeTo: nil)) < 0.00001
        test.targetedDragChanged(spoon, translation: [1, 1, 1], handPosition: nil)
        result["missing_pose_freezes_spoon"] = simd_distance(beforeOtherHand, spoon.position(relativeTo: nil)) < 0.00001
        input += [0.06, 0, 0]
        test.targetedDragChanged(spoon, translation: .zero, handPosition: input)
        result["pose_recovery_jump_metres"] = Double(simd_distance(beforeOtherHand, spoon.position(relativeTo: nil)))
        var tip = spoon.convert(position: test.spoonTipLocal, to: testRoot)
        let across = SIMD3<Float>(-tip.x, 0, -tip.z)
        for _ in 0..<60 { move(across / 60) }
        for _ in 0..<50 { move([0, -0.004, 0]) }
        result["spoon_enters_bowl_without_recenter"] = test.spoonAtBowl
        var maxPenetration: Float = 0; var maxRadius: Float = 0
        var movedDistance: Float = 0
        // Free strokes of different sizes, direction reversals and pressure
        // against the ceramic. No prescribed circle or entry delay.
        for i in 0..<420 {
            tip = spoon.convert(position: test.spoonTipLocal, to: testRoot)
            let angle = Float(i) * 0.055
            move([0.003 * cos(angle), -0.0002, 0.003 * sin(angle)])
            let after = spoon.convert(position: test.spoonTipLocal, to: testRoot)
            movedDistance += simd_distance(tip, after)
            maxRadius = max(maxRadius, simd_length(SIMD2(after.x, after.z)))
            maxPenetration = max(maxPenetration, test.spoonCeramicClearance(spoon, in: testRoot))
        }
        result["free_stir_distance_metres"] = Double(movedDistance)
        result["free_stir_completes"] = test.interactionProgress >= 1
        result["spoon_max_tip_radius_metres"] = Double(maxRadius)
        result["spoon_max_ceramic_penetration_metres"] = Double(maxPenetration)
        for _ in 0..<60 { move([0.004, 0, 0]) }
        let atRim = spoon.convert(position: test.spoonTipLocal, to: testRoot)
        move([-0.005, 0, 0])
        let reversed = spoon.convert(position: test.spoonTipLocal, to: testRoot)
        result["rim_reversal_moves_immediately"] = reversed.x < atRim.x - 0.003
        for _ in 0..<60 { move([0, 0.004, 0]) }
        result["spoon_can_lift_out_without_getting_stuck"] = !test.spoonInsideBowl && !test.spoonAtBowl
        // Do not finish/persist a synthetic activity; check putting down/regrab.
        test.interactionProgress = 0
        test.targetedDragEnded()
        try? await Task.sleep(for: .milliseconds(300))
        result["spoon_release_ends_ownership"] = !test.spoonIsHeld && test.dragged == nil
        result["spoon_returns_to_original_table_pose"] = simd_distance(spoon.position, restPose.translation) < 0.001
            && abs(simd_dot(spoon.orientation.vector, restPose.rotation.vector)) > 0.9999
            && simd_distance(spoon.scale, restPose.scale) < 0.0001
        let putDown = spoon.position
        test.targetedDragChanged(spoon, translation: .zero, handPosition: input)
        result["spoon_regrab_jump_metres"] = Double(simd_distance(putDown, spoon.position))
        test.targetedDragEnded()
        try? await Task.sleep(for: .milliseconds(250))
        test.step = 1; test.isBusy = false; test.lastGraspRelease = .distantPast
        test.updateHandGrasp(pinch(hand))
        result["milk_raw_precision_pinch_still_cannot_acquire"] = !test.isHandGrasping
        test.updateHandGrasp(pinch(hand, released: true))
        try? await Task.sleep(for: .milliseconds(100))
        test.updateHandGrasp(pinch(hand, released: true))
        result["milk_precision_pinch_released"] = !test.isHandGrasping
        return result
    }
    #endif

    private func cacheSpoonSurface(_ spoon: Entity) {
        let began = CACurrentMediaTime()
        defer { print("PERF spoon surface: \(1000 * (CACurrentMediaTime() - began)) ms") }
        // Cache the actual utensil's cross-sections once, not a line down its
        // centre. That line misses the spoon head extending beyond the guide
        // point and lets its edge cross the ceramic at a 45-degree angle.
        var sections: [Int: [SIMD3<Float>]] = [:]
        func collect(_ node: Entity) {
            if let model = node.components[ModelComponent.self] {
                let contents = model.mesh.contents
                for instance in contents.instances {
                    guard let mesh = contents.models[instance.model] else { continue }
                    let transform = node.transformMatrix(relativeTo: spoon) * instance.transform
                    for part in mesh.parts {
                        for position in part.positions.elements {
                            let value = transform * SIMD4<Float>(position, 1)
                            let point = SIMD3<Float>(value.x, value.y, value.z)
                            let key = Int(floor(point.z / 0.002))
                            var extremes = sections[key] ?? Array(repeating: point, count: 4)
                            if point.x < extremes[0].x { extremes[0] = point }
                            if point.y < extremes[1].y { extremes[1] = point }
                            if point.x > extremes[2].x { extremes[2] = point }
                            if point.y > extremes[3].y { extremes[3] = point }
                            sections[key] = extremes
                        }
                    }
                }
            }
            for child in node.children { collect(child) }
        }
        collect(spoon)
        spoonSurfaceProfile = sections.keys.sorted().flatMap { sections[$0] ?? [] }
    }

    private func spoonCeramicClearance(_ spoon: Entity, in root: Entity) -> Float {
        var lift: Float = 0
        let transform = spoon.transformMatrix(relativeTo: root)
        let samples = spoonSurfaceProfile.isEmpty ? (0...8).map {
            simd_mix(spoonHandleLocal, spoonTipLocal, SIMD3(repeating: Float($0) / 8))
        } : spoonSurfaceProfile
        for sample in samples {
            let value = transform * SIMD4<Float>(sample, 1)
            let point = SIMD3<Float>(value.x, value.y, value.z)
            let radius = simd_length(SIMD2(point.x, point.z))
            let floor: Float
            if radius < 0.124 {
                let edge = min(1, max(0, (radius - 0.045) / 0.055))
                floor = 0.017 + 0.048 * edge * edge * (3 - 2 * edge)
            } else { floor = -0.0022 }
            lift = max(lift, floor + 0.0022 - point.y)
        }
        return lift
    }

    private func constrainSpoonAboveCeramic(_ spoon: Entity, in root: Entity) {
        let lift = spoonCeramicClearance(spoon, in: root)
        if lift > 0 { spoon.position.y += lift }
    }

    func targetedDragEnded() {
        guard !isHandGrasping else { return }
        dragEnded()
    }

    func dragEnded() {
        guard let target = dragged, let route else { return }
        dragged = nil
        lastTapTime = Date() // Suppress a trailing tap from the same pointer release.
        onSound?("CerealPour", target, false); onSound?("Cutlery", target, false); onSound?("Mixing", target, false)
        switch route {
        case .breakfast:
            if step < 2 {
                guard gestureFraction >= 0.96, !controllers.isEmpty else {
                    if step == 1, let saved = rest.first(where: { $0.0 === target }) {
                        // An interrupted targeted pinch releases ownership and
                        // settles the carton once. No free-hand tracker may
                        // move it or interrupt this return animation.
                        breakfastLifted = false; gestureFraction = 0; interactionProgress = 0
                        isBusy = true
                        target.stopAllAnimations(recursive: false)
                        target.move(to: saved.1, relativeTo: target.parent, duration: 0.25, timingFunction: .easeInOut)
                        task = Task { @MainActor in
                            do { try await Task.sleep(for: .milliseconds(270)) }
                            catch { return }
                            target.transform = saved.1
                            isBusy = false
                            updateBreakfastCallout()
                        }
                    }
                    if heldBreakfastVisual != nil {
                        resetHeldBreakfastVisual()
                        breakfastLifted = false; interactionProgress = 0
                        controllers.forEach { $0.time = 0 }
                        updateBreakfastCallout()
                    }
                    feedback = "Grasp and lift, then tilt toward the bowl."; return
                }
                if !breakfastLifted {
                    breakfastLifted = true; interactionProgress = 0
                    updateBreakfastCallout()
                    feedback = "Hold again and move toward the bowl to pour."
                } else if step == 0 {
                    finishCerealPour(target)
                } else {
                    finishMilkPour(target)
                }
            } else {
                spoonIsHeld = false; spoonAtBowl = false
                spoonDeviceOrigin = nil; spoonUsesDevicePose = false; spoonPoseMissing = false
                spoonInsideBowl = false
                graspHand = nil; graspEntity = nil; isHandGrasping = false
                lastGraspRelease = Date()
                stirAngle = nil; stirDirectionSample = nil
                updateBreakfastCallout()
                // Return to the authored table pose on every release, including
                // an unfinished stir. Restore orientation as well as position.
                // A fresh targeted pinch may interrupt this native animation.
                if let saved = rest.first(where: { $0.0 === target }) {
                    target.stopAllAnimations(recursive: false)
                    target.move(to: saved.1, relativeTo: target.parent, duration: 0.25, timingFunction: .easeInOut)
                }
                if interactionProgress >= 1 { onProgress?(2, 3); complete() }
                else { feedback = "Look at the spoon, pinch and hold, then bring it over the bowl." }
            }
        case .christmasTree:
            if isOverPlacementTarget { placeOrnament(target, index: selectedOrnamentIndex ?? 0) }
            else {
                target.setPosition(dragOrigin, relativeTo: nil)
                feedback = "Try again. release over the pulsing ring."
            }
            isOverPlacementTarget = false
        case .playingBall:
            if interactionProgress >= 1 { ballAction() }
            else { target.setPosition(dragOrigin, relativeTo: nil); feedback = "Move toward Dad, then release." }
        }
    }

    func placePreviewOnTree() {
        guard route == .christmasTree, isReady, !isBusy, step % 3 == 1,
              let preview else { return }
        placeOrnament(preview, index: selectedOrnamentIndex ?? 0)
    }

    private func isAtTreeTarget(_ ornament: Entity, index: Int) -> Bool {
        guard let slot = root?.findEntity(named: "OrnamentSlot_\(index + 1)") else { return false }
        let target = slot.position(relativeTo: nil)
        let hook = (ornament.findEntity(named: "OrnamentHook") ?? ornament).position(relativeTo: nil)
        let bounds = ornament.visualBounds(relativeTo: nil)
        // Accept either the loop or any part of the ornament body touching the ring.
        let closest = simd_min(simd_max(target, bounds.min), bounds.max)
        if simd_distance(target, hook) < 0.18 || simd_distance(target, closest) < 0.10 { return true }
        // Desktop drags have no depth axis. Project the visible bounds onto the
        // target's sightline, then snap the hanging loop to the branch on release.
        guard simd_length(lastDelta) > 0.04 else { return false }
        let eye = viewerPose().translation
        let direction = simd_normalize(target - eye)
        let reach = max(0, simd_dot(bounds.center - eye, direction))
        let onRay = eye + direction * reach
        let nearest = simd_min(simd_max(onRay, bounds.min), bounds.max)
        return simd_distance(onRay, nearest) < max(0.045, reach * tan(0.035)) ||
            simd_dot(direction, simd_normalize(hook - eye)) > cos(0.085)

    }

    private func complete() {
        isReady = false
        calloutTarget = nil
        controllers.forEach { $0.pause() }
        // Completed props remain visible but must not intercept gaze/pinch rays
        // aimed at the native SwiftUI revisit buttons.
        func suspendInput(_ entity: Entity) {
            if let target = entity.components[InputTargetComponent.self] {
                suspendedInputTargets.append((entity, target))
                entity.components.remove(InputTargetComponent.self)
            }
            for child in entity.children { suspendInput(child) }
        }
        if let root { suspendInput(root) }
        onComplete?()
    }

    private func remember(_ entity: Entity) { rest.append((entity, entity.transform)) }
    private func ancestor(of entity: Entity, names: Set<String>) -> Entity? {
        var next: Entity? = entity
        while let current = next {
            if names.contains(current.name) { return current }
            next = current.parent
        }
        return nil
    }

    private func clips(in entity: Entity) -> [AnimationPlaybackController] {
        // Imported root clips already bind descendants. Replaying descendant copies
        // competes for the same animation channels, so use the highest bound clips.
        if !entity.availableAnimations.isEmpty {
            return entity.availableAnimations.map { entity.playAnimation($0) }
        }
        return entity.children.flatMap { clips(in: $0) }
    }

    var breakfastCompletionBowlBounds: BoundingBox? {
        guard route == .breakfast, let bowl = root?.findEntity(named: "Breakfast_Bowl") else { return nil }
        return bowl.visualBounds(relativeTo: nil)
    }

    var breakfastCompletionClearance: Float? {
        guard route == .breakfast, let bowl = root?.findEntity(named: "Breakfast_Bowl") else { return nil }
        // The bowl target spans the ceramic and cereal. Clear its upper edge,
        // including all revisit buttons, without changing the panel's size.
        return bowl.convert(position: SIMD3<Float>(0, 0.05, 0), to: nil).y + 0.035
    }

    var spoonRestPosition: SIMD3<Float>? {
        guard let saved = rest.first(where: { $0.0.name == "Breakfast_Spoon" }) else { return nil }
        return saved.0.position(relativeTo: nil)
    }

    private func updateBreakfastCallout() {
        let name = step == 0 ? "Box_Pivot" : (step == 1 ? "Breakfast_Milk" : (spoonIsHeld ? "Breakfast_Bowl" : "Breakfast_Spoon"))
        calloutTarget = root?.findEntity(named: name)
        if step == 2 {
            calloutText = spoonIsHeld ? (spoonAtBowl ? "Stir here" : "Bring the spoon here") : "Pinch and hold the spoon"
        } else {
            calloutText = breakfastLifted ? (isHandGrasping ? "Keep holding and tilt" : "Drag toward the bowl")
                : (step == 0 ? "Lift cereal box here" : "Lift the milk here")
        }
    }

    private func beginHandControlledPour(_ target: Entity) {
        guard !handPourActive, let root else { return }
        handPourActive = true; handPourFinished = false; isBusy = true
        let pouringCereal = step == 0
        feedback = "Keep holding while it pours."
        task = Task { @MainActor in
            do {
                if pouringCereal {
                    // Only the authored cereal particles run. The displayed box
                    // remains the resource-sharing visual attached to the grasp.
                    controllers.forEach { $0.time = $0.duration * (70.0 / 232.0); $0.speed = 1; $0.resume() }
                    onSound?("CerealPour", target, true)
                    let duration = controllers.map { max(0, $0.duration - $0.time) }.max() ?? 3
                    try await animate(seconds: duration) { _ in self.settleCerealParticles() }
                    controllers.forEach { $0.pause() }
                    onSound?("CerealPour", target, false)
                } else {
                    let cap = root.findEntity(named: "Breakfast_MilkCap")
                    let start = cap?.position ?? .zero
                    try await animate(seconds: 0.3) { t in
                        cap?.position = start + simd_normalize(SIMD3<Float>(0, 0.65, 0.75)) * (0.035 * Float(t))
                    }
                    cap?.isEnabled = false
                    root.findEntity(named: "Breakfast_MilkOpening")?.isEnabled = true
                    let stream = root.findEntity(named: "Breakfast_MilkStream")
                    let nozzle = root.findEntity(named: "Breakfast_MilkNozzle")
                    stream?.isEnabled = true
                    onSound?("MilkPour", target, true)
                    try await animate(seconds: 2.8) { t in
                        let lip = nozzle?.position(relativeTo: root) ?? SIMD3<Float>(0.035, 0.17, -0.015)
                        if let flow = stream?.findEntity(named: "MilkFlow") as? ModelEntity,
                           let mesh = try? self.milkFlowMesh(lip: lip, progress: Float(t)), flow.model?.mesh !== mesh {
                            flow.model?.mesh = mesh
                        }
                    }
                    if let flow = stream?.findEntity(named: "MilkFlow") as? ModelEntity,
                       let mesh = try? self.milkFlowMesh(lip: .zero, progress: 1, includingStream: false) { flow.model?.mesh = mesh }
                    onSound?("MilkPour", target, false)
                }
                try Task.checkCancellation()
                handPourFinished = true; isBusy = false
                feedback = "All poured. Open your hand to put it down."
                calloutText = "Open your hand to put it down"
            } catch { }
        }
    }

    private func releaseHandHeldBreakfast() {
        let completedPour = handPourFinished
        let releasedStep = step
        task?.cancel()
        controllers.forEach { $0.pause() }
        if !completedPour && releasedStep == 0 { controllers.forEach { $0.time = 0 } }
        if let root {
            onSound?("CerealPour", root, false); onSound?("MilkPour", root, false)
            if !completedPour && releasedStep == 1 { root.findEntity(named: "Breakfast_MilkStream")?.isEnabled = false }
        }
        handPourActive = false; handPourFinished = false
        graspHand = nil; graspEntity = nil; isHandGrasping = false; dragged = nil
        handOpenSince = nil; lastGraspRelease = Date(); isBusy = true
        heldBreakfastVisual?.move(to: heldBreakfastStart, relativeTo: nil, duration: 0.25, timingFunction: .easeOut)
        task = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(260)); try Task.checkCancellation() } catch { return }
            resetHeldBreakfastVisual()
            if completedPour { step = releasedStep + 1; onProgress?(step, step) }
            breakfastLifted = false; interactionProgress = 0; isBusy = false
            updateBreakfastCallout()
            feedback = step == 2 ? "Grasp the spoon. Bring it into the bowl, then stir." : "Grasp and lift, then tilt toward the bowl."
        }
    }

    private func finishMilkPour(_ milk: Entity) {
        heldBreakfastVisual = nil
        guard let saved = rest.first(where: { $0.0 === milk }), let root else { return }
        isBusy = true
        feedback = "Pouring milk. The carton will return to the table."
        let start = milk.transform
        let stream = root.findEntity(named: "Breakfast_MilkStream")
        task = Task { @MainActor in
            do {
                let cap = root.findEntity(named: "Breakfast_MilkCap")
                let capStart = cap?.position ?? .zero
                try await animate(seconds: 0.4) { t in
                    cap?.position = capStart + simd_normalize(SIMD3<Float>(0, 0.65, 0.75)) * (0.035 * Float(t))
                }
                cap?.isEnabled = false
                root.findEntity(named: "Breakfast_MilkOpening")?.isEnabled = true
                // Tip sideways from the right; keep the mouth above the bowl.
                let nozzle = root.findEntity(named: "Breakfast_MilkNozzle")
                let nozzleLocal = nozzle?.position(relativeTo: milk) ?? SIMD3<Float>(0, 0.10, 0.03)
                let pourRotation = simd_quatf(angle: 78 * .pi / 180, axis: [0, 0, 1]) * saved.1.rotation
                let lipTarget = SIMD3<Float>(0.035, 0.17, -0.015)
                let pourPosition = lipTarget - pourRotation.act(nozzleLocal * milk.scale)
                try await animate(seconds: 0.75) { t in
                    milk.position = simd_mix(start.translation, pourPosition, SIMD3(repeating: Float(t * t * (3 - 2 * t))))
                    milk.orientation = simd_slerp(start.rotation, pourRotation, Float(t * t * (3 - 2 * t)))
                }
                stream?.isEnabled = true
                onSound?("MilkPour", milk, true)
                var lastFlowFrame = -1
                try await animate(seconds: 2.8) { t in
                    let frame = Int(t * 168) // Reuse one dynamic buffer at up to 60 updates/sec.
                    guard frame != lastFlowFrame else { return }
                    lastFlowFrame = frame
                    let lip = nozzle?.position(relativeTo: root) ?? lipTarget
                    if let flow = stream?.findEntity(named: "MilkFlow") as? ModelEntity,
                       let mesh = try? self.milkFlowMesh(lip: lip, progress: Float(t)) {
                        if flow.model?.mesh !== mesh { flow.model?.mesh = mesh }
                    }
                }
                if let flow = stream?.findEntity(named: "MilkFlow") as? ModelEntity,
                   let pool = try? self.milkFlowMesh(lip: lipTarget, progress: 1, includingStream: false) {
                    flow.model?.mesh = pool
                }
                self.onSound?("MilkPour", milk, false)
                let poured = milk.transform
                try await animate(seconds: 0.7) { t in
                    milk.position = simd_mix(poured.translation, saved.1.translation, SIMD3(repeating: Float(t * t * (3 - 2 * t))))
                    milk.orientation = simd_slerp(poured.rotation, saved.1.rotation, Float(t * t * (3 - 2 * t)))
                }
                milk.transform = saved.1
                step = 2; breakfastLifted = false; onProgress?(2, 2)
                interactionProgress = 0; isBusy = false
                updateBreakfastCallout()
                feedback = "Pick up the spoon, then stir in gentle circles."
            } catch { stream?.isEnabled = false }
        }
    }

    /// A connected liquid surface and contained impact ripples, rather than rigid rods.
    private func milkFlowMesh(lip: SIMD3<Float>, progress t: Float, includingStream: Bool = true, stirringPhase: Float? = nil) throws -> MeshResource {
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        func grid(rows: Int, columns: Int, vertex: (Int, Int) -> (SIMD3<Float>, SIMD3<Float>)) {
            let base = UInt32(points.count)
            for row in 0...rows {
                for column in 0...columns {
                    let (point, normal) = vertex(row, column)
                    points.append(point); normals.append(normal)
                }
            }
            for row in 0..<rows {
                for column in 0..<columns {
                    let a = base + UInt32(row * (columns + 1) + column)
                    let b = a + UInt32(columns + 1)
                    indices += [a, b, a + 1, a + 1, b, b + 1]
                }
            }
        }
        let landing = SIMD3<Float>(0.005, 0.047, -0.005)
        let growth = max(0.001, min(1, t * 12))
        let flow = max(0.001, min(1, min(t * 14, (1 - t) * 14)))
        func centre(_ fraction: Float) -> SIMD3<Float> {
            let u = fraction * growth
            let ripple = sin(t * 54 - u * 17) * 0.0015 * sin(u * .pi)
            return SIMD3(lip.x + (landing.x - lip.x) * u + ripple,
                         lip.y + (landing.y - lip.y) * (0.20 * u + 0.80 * u * u),
                         lip.z + (landing.z - lip.z) * u + ripple * 0.5)
        }
        if includingStream {
        grid(rows: 40, columns: 24) { row, column in
            let u = Float(row) / 40
            let angle = Float(column) / 24 * 2 * Float.pi
            let tangent = simd_normalize(centre(min(1, u + 0.01)) - centre(max(0, u - 0.01)))
            let side = simd_normalize(simd_cross(tangent, SIMD3<Float>(0, 0, 1)))
            let across = simd_cross(side, tangent)
            let normal = side * cos(angle) + across * sin(angle)
            let radius = 0.0075 * flow * (1 - 0.46 * u) * (1 + 0.07 * sin(t * 66 - u * 24 + angle * 3))
            return (centre(u) + normal * radius, normal)
        }
        }
        // A continuous shallow pool with an irregular impact crown. No detached
        // rings or escaping droplets: the surface remains inside the bowl wall.
        if growth >= 1 {
            let poolProgress = min(1, t * 4)
            let poolRadius = 0.025 + poolProgress * 0.047
            let poolCentre = SIMD3<Float>(landing.x, 0.039, landing.z)
            func surface(_ row: Int, _ column: Int) -> SIMD3<Float> {
                let angle = Float(column) / 72 * 2 * Float.pi
                let v = Float(row) / 40
                let edge = 1 + 0.035 * sin(angle * 5 + t * 4)
                let radius = v * poolRadius * edge
                let crownDistance = (radius - 0.022) / 0.009
                let crown = exp(-crownDistance * crownDistance) * (0.006 + 0.007 * (0.5 + 0.5 * sin(angle * 5 + t * 26))) * flow
                let wave: Float
                if let stirringPhase {
                    wave = sin(angle * 3 - stirringPhase * 2 + radius * 140) * 0.002 * (1 - v)
                } else { wave = sin(radius * 370 - t * 65) * 0.0022 * (1 - v) * flow }
                let rim = -0.014 * pow(v, 7)
                return poolCentre + SIMD3(radius * cos(angle), crown + wave + rim, radius * sin(angle))
            }
            grid(rows: 40, columns: 72) { row, column in
                let radial = surface(min(40, row + 1), column) - surface(max(0, row - 1), column)
                let around = surface(row, column + 1) - surface(row, column - 1)
                let cross = simd_cross(around, radial)
                let normal = simd_length(cross) > 0.000001 ? simd_normalize(cross) : SIMD3<Float>(0, 1, 0)
                return (surface(row, column), normal)
            }
        }
        if growth >= 1 && includingStream {
            for drop in 0..<7 {
                let phase = (t * 5 + Float(drop) / 7).truncatingRemainder(dividingBy: 1)
                let angle = Float(drop) * 2.399
                let radius = 0.018 + phase * 0.013
                let origin = landing + SIMD3<Float>(radius * cos(angle), 0.008 + 0.029 * 4 * phase * (1 - phase), radius * sin(angle))
                let size = 0.0015 * flow * sin(phase * .pi)
                grid(rows: 6, columns: 8) { row, column in
                    let latitude = Float(row) / 6 * Float.pi
                    let longitude = Float(column) / 8 * 2 * Float.pi
                    let normal = SIMD3<Float>(sin(latitude) * cos(longitude), cos(latitude), sin(latitude) * sin(longitude))
                    return (origin + normal * size, normal)
                }
            }
        }
        if fluidBuffer == nil {
            let descriptor = LowLevelMesh.Descriptor(vertexCapacity: 6000,
                vertexAttributes: [
                    .init(semantic: .position, format: .float3, offset: 0),
                    .init(semantic: .normal, format: .float3, offset: MemoryLayout<SIMD3<Float>>.stride)
                ], vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<FluidVertex>.stride)],
                indexCapacity: 36000, indexType: .uint32)
            let buffer = try LowLevelMesh(descriptor: descriptor)
            fluidBuffer = buffer
            fluidResource = try MeshResource(from: buffer)
        }
        guard let buffer = fluidBuffer, let resource = fluidResource else {
            throw NSError(domain: "MilkFluidBuffer", code: 1)
        }
        buffer.withUnsafeMutableBytes(bufferIndex: 0) { bytes in
            let vertices = bytes.bindMemory(to: FluidVertex.self)
            for index in points.indices { vertices[index] = FluidVertex(position: points[index], normal: normals[index]) }
        }
        if fluidIndexCount != indices.count {
            buffer.withUnsafeMutableIndices { bytes in
                let destination = bytes.bindMemory(to: UInt32.self)
                for index in indices.indices { destination[index] = indices[index] }
            }
            fluidIndexCount = indices.count
            buffer.parts.replaceAll([.init(indexCount: indices.count,
                bounds: BoundingBox(min: [-0.13, 0, -0.13], max: [0.13, 0.30, 0.13]))])
        }
        return resource
    }

    private func resetHeldBreakfastVisual() {
        if let source = hiddenBreakfastVisual {
            source.isEnabled = true
            heldBreakfastVisual?.removeFromParent()
        } else if let visual = heldBreakfastVisual,
                  let saved = rest.first(where: { $0.0 === visual }) {
            visual.move(to: saved.1, relativeTo: visual.parent, duration: 0.25)
        }
        hiddenBreakfastVisual = nil; heldBreakfastVisual = nil
    }

    private func finishCerealPour(_ target: Entity) {
        isBusy = true
        feedback = "Pouring cereal. The box will return to the table."
        task = Task { @MainActor in
            do {
                if let held = heldBreakfastVisual, let source = hiddenBreakfastVisual {
                    let start = Transform(matrix: held.transformMatrix(relativeTo: nil))
                    controllers.forEach { $0.time = $0.duration * (70.0 / 232.0) }
                    // Let the authored pose resolve while hidden, then join it smoothly.
                    try await Task.sleep(for: .milliseconds(32))
                    try await animate(seconds: 0.28) { t in
                        let end = Transform(matrix: source.transformMatrix(relativeTo: nil))
                        let blend = Float(t * t * (3 - 2 * t))
                        held.setTransformMatrix(Transform(scale: end.scale,
                            rotation: simd_slerp(start.rotation, end.rotation, blend),
                            translation: simd_mix(start.translation, end.translation, SIMD3(repeating: blend))).matrix, relativeTo: nil)
                    }
                    resetHeldBreakfastVisual()
                }
                let remaining = controllers.map { max(0, $0.duration - $0.time) }.max() ?? 0
                controllers.forEach { $0.speed = 1; $0.resume() }
                onSound?("CerealPour", target, true)
                try await animate(seconds: remaining) { _ in self.settleCerealParticles() }
            } catch { resetHeldBreakfastVisual(); return }
            guard !Task.isCancelled else { return }
            controllers.forEach { $0.pause() }
            onSound?("CerealPour", target, false)
            step = 1; breakfastLifted = false; onProgress?(1, 1); interactionProgress = 0
            isBusy = false
            updateBreakfastCallout()
            feedback = "Hold and lift straight up."
        }
    }

    private func previewOrnament(_ ornament: Entity, index: Int) {
        guard preview == nil, !placedOrnamentIndices.contains(index) else { return }
        isBusy = true
        if step % 3 == 0 {
            preview = ornament
            selectedOrnamentIndex = index
            let original = Transform(matrix: ornament.transformMatrix(relativeTo: nil))
            let targetPosition = viewerPose().matrix * SIMD4<Float>(0, -0.10, -0.86, 1)
            if let cratePose = ornament.findEntity(named: "OrnamentCratePose") {
                cratePose.move(to: .identity, relativeTo: ornament, duration: 0.65, timingFunction: .easeInOut)
            }
            let target = Transform(scale: original.scale * 2.6, rotation: original.rotation, translation: SIMD3(targetPosition.x, targetPosition.y, targetPosition.z))
            ornament.move(to: target, relativeTo: nil, duration: 0.65, timingFunction: .easeInOut)
            task = Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(700))
                    step += 1; onProgress?(step, step)
                    isBusy = false
                    feedback = "Tap again to hang it, or drag its hanging loop to the pulsing ring."
                    let baseRotation = ornament.orientation(relativeTo: nil)
                    previewTask = Task { @MainActor in
                        let start = Date()
                        while !Task.isCancelled {
                            let angle = Float(Date().timeIntervalSince(start)) * 0.35
                            ornament.setOrientation(simd_quatf(angle: angle, axis: [0, 1, 0]) * baseRotation, relativeTo: nil)
                            do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                        }
                    }
                } catch {}
            }
        }
    }

    private func placeOrnament(_ ornament: Entity, index: Int) {
        isBusy = true
            previewTask?.cancel(); previewTask = nil
            guard let slot = root?.findEntity(named: "OrnamentSlot_\(index + 1)"),
                  let saved = rest.first(where: { $0.0 === ornament }) else { isBusy = false; return }
            var target = saved.1
            // The tree slot is the hook location, not the ornament centre.
            let hook = ornament.findEntity(named: "OrnamentHook")?.position(relativeTo: ornament) ?? .zero
            target.translation = slot.position(relativeTo: ornament.parent) - saved.1.rotation.act(hook * saved.1.scale)
            ornament.move(to: target, relativeTo: ornament.parent, duration: 0.65, timingFunction: .easeInOut)
            onSound?("Bells", ornament, true)
            isPlacementArmed = false; feedback = nil
            task = Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(700))
                    preview = nil
                    placedOrnamentIndices.insert(index)
                    step = (placedOrnamentIndices.count - 1) * 3 + 2
                    onProgress?(step, placedOrnamentIndices.count * 3)
                    try await Task.sleep(for: .milliseconds(1500))
                    selectedOrnamentIndex = nil
                    if placedOrnamentIndices.count == 3 { complete() }
                    else { step = placedOrnamentIndices.count * 3; onProgress?(step, step) }
                    isBusy = false
                } catch {}
            }
    }


    #if DEBUG
    func runBallRegressionReview() async -> [String: Any] {
        guard route == .playingBall, let source = root, let parent = source.parent else { return ["error": "Ball not ready"] }
        let copy = source.clone(recursive: true)
        copy.name = "BallRegressionCopy"
        copy.position.y -= 30
        copy.findEntity(named: "Activity_Interactive_Ball")?.removeFromParent()
        parent.addChild(copy)
        let offset = copy.position(relativeTo: nil) - source.position(relativeTo: nil)
        let test = ActivityInteractionController()
        var fixedTestPose = viewerPose()
        fixedTestPose.translation += offset
        test.viewerPose = { fixedTestPose }
        defer { test.cancel(); copy.removeFromParent() }
        var result: [String: Any] = [:]
        var homes: [SIMD3<Float>] = []
        for visit in 0..<2 {
            test.prepare(route: .playingBall, root: copy, onProgress: { _, _ in }, onComplete: {})
            try? await Task.sleep(for: .seconds(2.8))
            guard let ball = test.ball else { result["error"] = "Missing ball"; return result }
            let catchPoint = test.viewerPoint([0, -0.10, -0.50])
            homes.append(test.ballHome)
            result["visit_\(visit)_dad_throw_reaches_user_metres"] = simd_distance(ball.position(relativeTo: nil), catchPoint)
            let forward = test.viewerPose().rotation.act(SIMD3<Float>(0, 0, -1))
            result["visit_\(visit)_dad_is_in_front_metres"] = simd_dot(test.ballHome - catchPoint, forward)
            result["visit_\(visit)_home_near_dad_metres"] = simd_distance(test.ballHome, copy.position(relativeTo: nil))
            test.task?.cancel(); test.task = nil
            try? await Task.sleep(for: .milliseconds(60))
            var mostBackward: Float = 0
            let direction = simd_normalize(test.ballHome - catchPoint)
            let probe = copy.scene?.subscribe(to: SceneEvents.Update.self) { _ in
                mostBackward = min(mostBackward, simd_dot(ball.position(relativeTo: nil) - catchPoint, direction))
            }
            try? await test.flyBall(to: test.ballHome, frames: 60...182)
            probe?.cancel()
            result["visit_\(visit)_return_reaches_dad_metres"] = simd_distance(ball.position(relativeTo: nil), test.ballHome)
            result["visit_\(visit)_maximum_backward_excursion_metres"] = -mostBackward
            test.cancel()
            // Simulate the retained far-end pose which caused a revisit to
            // derive its return destination from the previous animated mesh.
            if let motion = copy.findEntity(named: "Root") {
                let sample = AuthoredBallMotion.sample(frame: 60)
                motion.position = [sample.z, -sample.x, sample.y]
            }
        }
        result["revisit_home_drift_metres"] = simd_distance(homes[0], homes[1])
        return result
    }
    #endif

    private func prepareBall(in root: Entity) {
        guard let motionParent = ActivityPropManager.ballMotionParent(in: root),
              let startingPosition = ActivityPropManager.ballStartingPosition(in: root) else {
            feedback = "The ball's starting pose could not load. Please return Home and try again."
            return
        }
        ballHome = startingPosition
        ballLateralAxis = simd_normalize(motionParent.convert(direction: [1, 0, 0], to: nil))
        guard let wrapper = ActivityPropManager.prepareBallPresentation(in: root) else { return }
        wrapper.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.145)]))
        wrapper.components.set(InputTargetComponent(allowedInputTypes: .all))
        wrapper.setTransformMatrix(Transform(translation: ballHome).matrix, relativeTo: nil)
        ball = wrapper
        controllers = ActivityPropManager.takeBallArrivalControllers().filter { $0.isValid }
        if controllers.isEmpty { controllers = clips(in: root) }
        controllers.forEach { $0.pause(); $0.time = 0 }
        calloutTarget = wrapper; calloutText = "Grasp and throw"
        isBusy = true
        task = Task { @MainActor in
            do {
                if let ball { onSound?("BallPass", ball, true) }
                try await flyBall(to: viewerPoint([0, -0.10, -0.50]), frames: 1...60)
                controllers.forEach { $0.pause() }
                isBusy = false
            } catch {}
        }
    }

    private func ballAction() {
        guard let ball else { return }
        isBusy = true
        onSound?("BallPass", ball, true)
        interactionProgress = 0
        feedback = "Sending it back to Dad…"
        task = Task { @MainActor in
            do {
                // Repeat the original catch/return cycle at its original 24 fps.
                let returnStart = 60.0 + Double(ballReturns) * 181
                try await flyBall(to: ballHome, frames: returnStart...(returnStart + 122))
                onSound?("DadEncouragement", ball, true)
                ballReturns += 1
                onProgress?(min(ballReturns, 2), ballReturns)
                if ballReturns == 3 {
                    feedback = "Well done!"
                    try await Task.sleep(for: .seconds(1))
                    complete()
                } else {
                    step = ballReturns
                    feedback = "Dad is sending the ball back…"
                    onSound?("BallPass", ball, true)
                    try await flyBall(to: viewerPoint([ballReturns == 1 ? 0.055 : -0.055, -0.10, -0.50]), frames: (Double(ballReturns) * 181 + 1)...(Double(ballReturns) * 181 + 60))
                    controllers.forEach { $0.pause() }
                    feedback = nil
                    calloutTarget = ball; calloutText = "Grasp and throw to Dad"
                }
                isBusy = false
            } catch {}
        }
    }

    private func viewerPoint(_ local: SIMD3<Float>) -> SIMD3<Float> {
        let p = viewerPose().matrix * SIMD4(local, 1)
        return [p.x, p.y, p.z]
    }

    private func flyBall(to end: SIMD3<Float>, frames: ClosedRange<Double>) async throws {
        guard let ball else { return }
        let start = ball.position(relativeTo: nil)
        let first = AuthoredBallMotion.sample(frame: frames.lowerBound)
        let last = AuthoredBallMotion.sample(frame: frames.upperBound)
        let travel = last.x - first.x
        var catchPlayed = false
        // Let the renderer interpolate skeletal poses continuously. Repeated
        // seeks interrupt that interpolation and force animation re-evaluation.
        // Segment endpoints and source speed remain exactly the authored 24 fps.
        for controller in controllers {
            controller.time = min(controller.duration, (frames.lowerBound - 1) / 24)
            controller.speed = 1
            controller.resume()
        }
        defer { controllers.forEach { $0.pause() } }
        // Both imported character clips and the interactive ball use one 24-fps
        // source clock. Waiting for the user's gesture advances neither clock.
        // Retarget only the flight endpoints to the reachable user position.
        try await animate(seconds: (frames.upperBound - frames.lowerBound) / 24) { t in
            let frame = frames.lowerBound + t * (frames.upperBound - frames.lowerBound)
            let source = AuthoredBallMotion.sample(frame: frame)
            let f = abs(travel) > 0.0001 ? (source.x - first.x) / travel : Float(t)
            var position = simd_mix(start, end, SIMD3(repeating: f))
            position.y += source.y - (first.y + (last.y - first.y) * f)
            // Keep lateral hand movement near Dad; fade only at the user catch.
            let awayFromDad = min(1, max(0, (source.x - 0.70) / 15.24))
            position += self.ballLateralAxis * (source.z - AuthoredBallMotion.positions[0].z) * (1 - awayFromDad)
            ball.setPosition(position, relativeTo: nil)
            // The catch occurs when the ball reaches the hands, not when the
            // remaining character recovery frames have finished playing.
            if travel < 0, f >= 0.97, !catchPlayed {
                catchPlayed = true
                self.onSound?("BallCatch", ball, true)
            }
        }
        controllers.forEach { $0.time = min($0.duration, (frames.upperBound - 1) / 24) }
    }

    private func animate(seconds: Double, frame: @escaping (Double) -> Void) async throws {
        let start = Date()
        // Pose sampling belongs on RealityKit's display update, not a 16 ms
        // main-actor timer competing with rendering and hand tracking.
        if let scene = root?.scene {
            let subscription = scene.subscribe(to: SceneEvents.Update.self) { _ in
                frame(min(1, Date().timeIntervalSince(start) / max(0.001, seconds)))
            }
            defer { subscription.cancel() }
            while Date().timeIntervalSince(start) < seconds {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(30))
            }
            try Task.checkCancellation()
            frame(1)
        } else {
            while true {
                try Task.checkCancellation()
                let t = min(1, Date().timeIntervalSince(start) / max(0.001, seconds))
                frame(t)
                if t >= 1 { return }
                try await Task.sleep(for: .milliseconds(16))
            }
        }
    }

}

/// Baked from PlayingBall_ManAndBall.usdz Root translation samples, frames 1–544.
/// Source uses 24 fps; X is forward travel and Y is the authored vertical arc.
enum AuthoredBallMotion {
    static func sample(frame: Double) -> SIMD3<Float> {
        let index = min(max(frame - 1, 0), Double(positions.count - 1))
        let lower = Int(index), upper = min(lower + 1, positions.count - 1)
        return positions[lower] + (positions[upper] - positions[lower]) * Float(index - Double(lower))
    }

    static let positions: [SIMD3<Float>] = [
        [0.697214484, 1.162924170, -0.001735538],
        [0.697213113, 1.162923336, -0.001734255],
        [0.697209120, 1.162921071, -0.001730644],
        [0.697203398, 1.162917614, -0.001725371],
        [0.697198987, 1.162914991, -0.001721293],
        [0.697194397, 1.162912250, -0.001716885],
        [0.697185397, 1.162907004, -0.001708238],
        [0.697173715, 1.162899971, -0.001696952],
        [0.697167933, 1.162896395, -0.001691040],
        [0.697156549, 1.162888527, -0.001678688],
        [0.697138250, 1.162876129, -0.001658859],
        [0.697119176, 1.162863016, -0.001638133],
        [0.697113156, 1.162858129, -0.001630263],
        [0.697098672, 1.162846088, -0.001611217],
        [0.697078347, 1.162829280, -0.001584517],
        [0.697304785, 1.162671685, -0.001568156],
        [0.699139535, 1.161526322, -0.001555405],
        [0.702469945, 1.159447551, -0.001532260],
        [0.706680357, 1.156819344, -0.001503000],
        [0.708380699, 1.162753224, -0.001490967],
        [0.712287784, 1.184078097, -0.001463080],
        [0.718253374, 1.216638327, -0.001420500],
        [0.723365784, 1.245650887, -0.001383245],
        [0.722002804, 1.264187098, -0.001375038],
        [0.719067395, 1.304109812, -0.001357361],
        [0.715102017, 1.358039260, -0.001333484],
        [0.712942302, 1.383371949, -0.001322831],
        [0.709883749, 1.402644038, -0.001317415],
        [0.704685569, 1.435398221, -0.001308209],
        [0.698308647, 1.475580096, -0.001296915],
        [1.284459352, 1.498703599, -0.001296915],
        [1.870609045, 1.521426201, -0.001296915],
        [2.456759453, 1.543351769, -0.001296915],
        [3.042910099, 1.564092159, -0.001296915],
        [3.629059792, 1.583272815, -0.001296915],
        [4.215210438, 1.600536227, -0.001296915],
        [4.801361084, 1.615545511, -0.001296915],
        [5.387511730, 1.627989173, -0.001296915],
        [5.973661423, 1.637582898, -0.001296915],
        [6.559811115, 1.644074440, -0.001296915],
        [7.145961761, 1.647244930, -0.001296915],
        [7.732112408, 1.646912336, -0.001296915],
        [8.318263054, 1.642932892, -0.001296915],
        [8.904413223, 1.635202289, -0.001296915],
        [9.490563393, 1.623658299, -0.001296915],
        [10.076713562, 1.608279347, -0.001296915],
        [10.662863731, 1.589087009, -0.001296915],
        [11.249013901, 1.566143632, -0.001296915],
        [11.835165024, 1.539553285, -0.001296915],
        [12.421314240, 1.509459853, -0.001296915],
        [13.007465363, 1.476045370, -0.001296915],
        [13.593615532, 1.439528704, -0.001296915],
        [14.179765701, 1.400162220, -0.001296915],
        [14.765915871, 1.358229876, -0.001296915],
        [15.259716034, 1.316164494, -0.001296915],
        [15.590818405, 1.275918365, -0.001296915],
        [15.791725159, 1.237102389, -0.001296915],
        [15.894820213, 1.199347854, -0.001296915],
        [15.932845116, 1.162290454, -0.001296915],
        [15.938308716, 1.125580072, -0.001296915],
        [15.747174263, 1.141139150, -0.001301014],
        [15.556039810, 1.156682014, -0.001305113],
        [15.364905357, 1.172197223, -0.001309212],
        [15.173771858, 1.187673450, -0.001313311],
        [14.982636452, 1.203099012, -0.001317410],
        [14.791501045, 1.218449116, -0.001321509],
        [14.600366592, 1.233708978, -0.001325609],
        [14.409232140, 1.248875141, -0.001329708],
        [14.218098640, 1.263936877, -0.001333807],
        [14.026963234, 1.278882980, -0.001337906],
        [13.835829735, 1.293695092, -0.001342005],
        [13.644695282, 1.308330297, -0.001346104],
        [13.453559875, 1.322808981, -0.001350203],
        [13.262424469, 1.337120652, -0.001354302],
        [13.071290016, 1.351254821, -0.001358401],
        [12.880155563, 1.365201592, -0.001362500],
        [12.689022064, 1.378902793, -0.001366599],
        [12.497887611, 1.392375112, -0.001370698],
        [12.306752205, 1.405622840, -0.001374798],
        [12.115616798, 1.418636918, -0.001378897],
        [11.924483299, 1.431407928, -0.001382996],
        [11.733348846, 1.443900108, -0.001387095],
        [11.542213440, 1.456076980, -0.001391194],
        [11.351078987, 1.467978477, -0.001395293],
        [11.159945488, 1.479596615, -0.001399392],
        [10.968811989, 1.490923762, -0.001403491],
        [10.777675629, 1.501952648, -0.001407590],
        [10.586541176, 1.512587905, -0.001411689],
        [10.395407677, 1.522900105, -0.001415788],
        [10.204273224, 1.532887816, -0.001419887],
        [10.013137817, 1.542544961, -0.001423986],
        [9.822003365, 1.551865816, -0.001428085],
        [9.630868912, 1.560790539, -0.001432184],
        [9.439733505, 1.569316626, -0.001436284],
        [9.248600006, 1.577486753, -0.001440383],
        [9.057466507, 1.585296869, -0.001444482],
        [8.866332054, 1.592742682, -0.001448581],
        [8.675195694, 1.599807739, -0.001452680],
        [8.484061241, 1.606403470, -0.001456779],
        [8.292927742, 1.612622619, -0.001460878],
        [8.101793289, 1.618462443, -0.001464977],
        [7.910657883, 1.623921037, -0.001469076],
        [7.719524384, 1.628996611, -0.001473175],
        [7.528389931, 1.633607388, -0.001477274],
        [7.337254524, 1.637798667, -0.001481373],
        [7.146119595, 1.641603112, -0.001485472],
        [6.954985142, 1.645020485, -0.001489572],
        [6.763850212, 1.648050904, -0.001493671],
        [6.572715759, 1.650661826, -0.001497770],
        [6.381581783, 1.652808070, -0.001501869],
        [6.190447330, 1.654571176, -0.001505968],
        [5.999312401, 1.655952930, -0.001510067],
        [5.808177948, 1.656955719, -0.001514166],
        [5.617044449, 1.657581687, -0.001518265],
        [5.425908566, 1.657738328, -0.001522364],
        [5.234774590, 1.657514095, -0.001526463],
        [5.043640137, 1.656925797, -0.001530562],
        [4.852505684, 1.655977368, -0.001534661],
        [4.661370754, 1.654672980, -0.001538760],
        [4.470236301, 1.652970195, -0.001542859],
        [4.279102325, 1.650871038, -0.001546958],
        [4.087967396, 1.648435473, -0.001551058],
        [3.896832466, 1.645669341, -0.001555157],
        [3.705698490, 1.642578959, -0.001559256],
        [3.514563799, 1.639165521, -0.001563355],
        [3.323428869, 1.635358453, -0.001567454],
        [3.132294416, 1.631253004, -0.001571553],
        [2.941159487, 1.626856565, -0.001575652],
        [2.750024796, 1.622176766, -0.001579751],
        [2.558891058, 1.617221594, -0.001583850],
        [2.367756605, 1.611951232, -0.001587949],
        [2.176622868, 1.606401920, -0.001592048],
        [1.985488534, 1.600609660, -0.001596147],
        [1.799371839, 1.594488859, -0.001600139],
        [1.624888659, 1.587923646, -0.001603881],
        [1.469988346, 1.580759525, -0.001607203],
        [1.335920334, 1.572956443, -0.001610078],
        [1.217819929, 1.564664245, -0.001612611],
        [1.114653111, 1.555912495, -0.001614823],
        [1.025429487, 1.546730399, -0.001616737],
        [0.949238002, 1.537145376, -0.001618371],
        [0.887838840, 1.527104020, -0.001619688],
        [0.837447166, 1.516720772, -0.001620768],
        [0.796534896, 1.506042838, -0.001621646],
        [0.764220059, 1.495097995, -0.001622339],
        [0.739607871, 1.483913898, -0.001622866],
        [0.722324193, 1.472501397, -0.001623237],
        [0.711183250, 1.460897088, -0.001623476],
        [0.704167128, 1.449164152, -0.001623627],
        [0.700326443, 1.437332273, -0.001623709],
        [0.698718011, 1.425430775, -0.001623743],
        [0.698423326, 1.413488150, -0.001623750],
        [0.698723137, 1.412650228, -0.001623952],
        [0.699609339, 1.410172820, -0.001624548],
        [0.701043308, 1.406164527, -0.001625514],
        [0.702962399, 1.400800347, -0.001626807],
        [0.705282629, 1.394314647, -0.001628369],
        [0.707902610, 1.386991024, -0.001630133],
        [0.710707903, 1.379149437, -0.001632023],
        [0.712204576, 1.374682307, -0.001633151],
        [0.712702155, 1.371041894, -0.001634442],
        [0.713675499, 1.363920093, -0.001636968],
        [0.715082169, 1.353628278, -0.001640618],
        [0.716860592, 1.340616107, -0.001645233],
        [0.718933046, 1.325452447, -0.001650612],
        [0.721209049, 1.308799863, -0.001656518],
        [0.723589063, 1.291386247, -0.001662694],
        [0.723329604, 1.289492846, -0.001663683],
        [0.722562492, 1.283895612, -0.001666608],
        [0.721321285, 1.274839044, -0.001671341],
        [0.719660282, 1.262718916, -0.001677675],
        [0.717651963, 1.248065114, -0.001685333],
        [0.715384185, 1.231517911, -0.001693980],
        [0.712956071, 1.213800550, -0.001703238],
        [0.711635411, 1.204514861, -0.001708122],
        [0.711005151, 1.202697158, -0.001709320],
        [0.709772170, 1.199141145, -0.001711664],
        [0.707990348, 1.194002390, -0.001715052],
        [0.705737591, 1.187505245, -0.001719335],
        [0.703112304, 1.179933786, -0.001724326],
        [0.700229287, 1.171618938, -0.001729807],
        [0.697214484, 1.162924170, -0.001735538],
        [0.697213113, 1.162923336, 0.000100575],
        [0.697209120, 1.162921071, 0.005269517],
        [0.697203398, 1.162917614, 0.012815808],
        [0.697198987, 1.162914991, 0.018577177],
        [0.697194397, 1.162912250, 0.023972539],
        [0.697185397, 1.162907004, 0.034555092],
        [0.697173715, 1.162899971, 0.048368666],
        [0.697167933, 1.162896395, 0.054467138],
        [0.697156549, 1.162888527, 0.064768746],
        [0.697138250, 1.162876129, 0.081307329],
        [0.697119176, 1.162863135, 0.098536879],
        [0.697114587, 1.162859440, 0.100675337],
        [0.697103500, 1.162850618, 0.105850138],
        [0.697088003, 1.162838221, 0.113104731],
        [0.697316766, 1.162682891, 0.117134131],
        [0.699149311, 1.161535501, 0.117386773],
        [0.702475667, 1.159452915, 0.117845349],
        [0.706681013, 1.156819940, 0.118425094],
        [0.708380699, 1.162753224, 0.118509069],
        [0.712287784, 1.184078097, 0.118536964],
        [0.718253374, 1.216638327, 0.118579552],
        [0.723365784, 1.245650887, 0.118616819],
        [0.722002804, 1.264187098, 0.118625022],
        [0.719067395, 1.304109812, 0.118642695],
        [0.715102017, 1.358039260, 0.118666567],
        [0.712942302, 1.383371949, 0.118677214],
        [0.709883749, 1.402644038, 0.118682623],
        [0.704685569, 1.435398221, 0.118691809],
        [0.698308647, 1.475580096, 0.118703075],
        [1.284102201, 1.498703599, 0.134544075],
        [1.869894981, 1.521426201, 0.150385052],
        [2.455688477, 1.543351769, 0.166226059],
        [3.041481972, 1.564092159, 0.182067066],
        [3.627274513, 1.583272815, 0.197908044],
        [4.213068008, 1.600536227, 0.213749051],
        [4.798861504, 1.615545511, 0.229590043],
        [5.384654999, 1.627989173, 0.245431051],
        [5.970448017, 1.637582898, 0.261272013],
        [6.556240559, 1.644074440, 0.277113020],
        [7.142034054, 1.647244930, 0.292953998],
        [7.727827549, 1.646912336, 0.308795005],
        [8.313621521, 1.642932892, 0.324636012],
        [8.899414062, 1.635202289, 0.340476990],
        [9.485207558, 1.623658299, 0.356317997],
        [10.071001053, 1.608279347, 0.372158974],
        [10.656793594, 1.589087009, 0.387999952],
        [11.242587090, 1.566143632, 0.403840959],
        [11.828380585, 1.539553285, 0.419681966],
        [12.414173126, 1.509459853, 0.435522974],
        [12.999966621, 1.476045370, 0.451363981],
        [13.585760117, 1.439528704, 0.467204988],
        [14.171553612, 1.400162220, 0.483045936],
        [14.757346153, 1.358229876, 0.498886943],
        [15.250845909, 1.316164494, 0.512232125],
        [15.581746101, 1.275918365, 0.521180332],
        [15.782530785, 1.237102389, 0.526609898],
        [15.885561943, 1.199347854, 0.529396057],
        [15.923564911, 1.162290454, 0.530423760],
        [15.929024696, 1.125580072, 0.530571401],
        [15.738007545, 1.141139030, 0.525401771],
        [15.546989441, 1.156681895, 0.520232141],
        [15.355971336, 1.172197223, 0.515062511],
        [15.164951324, 1.187673569, 0.509892821],
        [14.973933220, 1.203099132, 0.504723191],
        [14.782916069, 1.218449116, 0.499553531],
        [14.591897964, 1.233708978, 0.494383901],
        [14.400880814, 1.248875141, 0.489214271],
        [14.209862709, 1.263936877, 0.484044641],
        [14.018844604, 1.278882861, 0.478875011],
        [13.827825546, 1.293695211, 0.473705292],
        [13.636807442, 1.308330417, 0.468535662],
        [13.445789337, 1.322809100, 0.463366032],
        [13.254771233, 1.337120652, 0.458196402],
        [13.063753128, 1.351254821, 0.453026772],
        [12.872733116, 1.365201712, 0.447857082],
        [12.681717873, 1.378902793, 0.442687541],
        [12.490698814, 1.392375112, 0.437517852],
        [12.299680710, 1.405622840, 0.432348222],
        [12.108663559, 1.418636680, 0.427178621],
        [11.917644501, 1.431408048, 0.422008932],
        [11.726623535, 1.443900228, 0.416839212],
        [11.535608292, 1.456076860, 0.411669672],
        [11.344589233, 1.467978477, 0.406499982],
        [11.153571129, 1.479596615, 0.401330352],
        [10.962555885, 1.490923762, 0.396160781],
        [10.771535873, 1.501952648, 0.390991092],
        [10.580519676, 1.512587786, 0.385821521],
        [10.389501572, 1.522899985, 0.380651861],
        [10.198481560, 1.532887816, 0.375482172],
        [10.007462502, 1.542545080, 0.370312512],
        [9.816446304, 1.551865697, 0.365142912],
        [9.625426292, 1.560790539, 0.359973222],
        [9.434411049, 1.569316506, 0.354803652],
        [9.243392944, 1.577486753, 0.349633992],
        [9.052372932, 1.585296869, 0.344464302],
        [8.861353874, 1.592742801, 0.339294612],
        [8.670337677, 1.599807620, 0.334125042],
        [8.479317665, 1.606403589, 0.328955352],
        [8.288301468, 1.612622619, 0.323785782],
        [8.097283363, 1.618462443, 0.318616122],
        [7.906263351, 1.623921037, 0.313446432],
        [7.715243816, 1.628996611, 0.308276743],
        [7.524228573, 1.633607388, 0.303107202],
        [7.333209038, 1.637798786, 0.297937512],
        [7.142191887, 1.641603112, 0.292767882],
        [6.951174736, 1.645020485, 0.287598282],
        [6.760155678, 1.648050904, 0.282428592],
        [6.569139957, 1.650661826, 0.277259052],
        [6.378120422, 1.652808070, 0.272089362],
        [6.187100887, 1.654571176, 0.266919672],
        [5.996083260, 1.655952930, 0.261750042],
        [5.805066109, 1.656955719, 0.256580442],
        [5.614046574, 1.657581687, 0.251410753],
        [5.423031330, 1.657738328, 0.246241182],
        [5.232012272, 1.657514095, 0.241071522],
        [5.040991783, 1.656925797, 0.235901833],
        [4.849973202, 1.655977368, 0.230732173],
        [4.658957481, 1.654672980, 0.225562602],
        [4.467936993, 1.652970195, 0.220392883],
        [4.276921272, 1.650871038, 0.215223312],
        [4.085902691, 1.648435473, 0.210053667],
        [3.894882917, 1.645669341, 0.204883963],
        [3.703864098, 1.642578959, 0.199714303],
        [3.512848377, 1.639165521, 0.194544718],
        [3.321828604, 1.635358453, 0.189375043],
        [3.130811930, 1.631253004, 0.184205443],
        [2.939794302, 1.626856565, 0.179035813],
        [2.748775959, 1.622176766, 0.173866153],
        [2.557760477, 1.617221713, 0.168696582],
        [2.366740227, 1.611951232, 0.163526893],
        [2.175720215, 1.606401801, 0.158357188],
        [1.984702945, 1.600609660, 0.153187573],
        [1.798701167, 1.594488859, 0.148153707],
        [1.624324679, 1.587923646, 0.143434435],
        [1.469520688, 1.580759645, 0.139244884],
        [1.335532427, 1.572956562, 0.135618672],
        [1.217502475, 1.564664125, 0.132424355],
        [1.114398599, 1.555912495, 0.129633993],
        [1.025230050, 1.546730280, 0.127220765],
        [0.949084342, 1.537145257, 0.125159994],
        [0.887724161, 1.527104139, 0.123499364],
        [0.837362766, 1.516720772, 0.122136399],
        [0.796475410, 1.506042957, 0.121029839],
        [0.764180243, 1.495098114, 0.120155819],
        [0.739582777, 1.483913898, 0.119490117],
        [0.722309470, 1.472501159, 0.119022638],
        [0.711175442, 1.460896969, 0.118721314],
        [0.704163671, 1.449164152, 0.118531547],
        [0.700325370, 1.437332392, 0.118427671],
        [0.698717892, 1.425430894, 0.118384168],
        [0.698423326, 1.413488150, 0.118376195],
        [0.698665679, 1.413777709, 0.116294235],
        [0.699382007, 1.414633751, 0.110139325],
        [0.700541139, 1.416018844, 0.100180492],
        [0.702092409, 1.417872429, 0.086852960],
        [0.703967929, 1.420113683, 0.070739217],
        [0.706085742, 1.422644377, 0.052543513],
        [0.708353341, 1.425354004, 0.033061080],
        [0.709589601, 1.426173806, 0.022966582],
        [0.710201442, 1.421688199, 0.021890165],
        [0.711398363, 1.412913203, 0.019784372],
        [0.713128090, 1.400232196, 0.016741242],
        [0.715315044, 1.384199381, 0.012893771],
        [0.717863619, 1.365515590, 0.008410114],
        [0.720662355, 1.344997287, 0.003486225],
        [0.723589063, 1.323541284, -0.001662694],
        [0.723269343, 1.320918918, -0.001663814],
        [0.722324073, 1.313166261, -0.001667126],
        [0.720794618, 1.300622344, -0.001672485],
        [0.718747795, 1.283835292, -0.001679657],
        [0.716273069, 1.263538837, -0.001688328],
        [0.713478625, 1.240619898, -0.001698119],
        [0.710486531, 1.216080308, -0.001708602],
        [0.708892763, 1.203313947, -0.001714080],
        [0.708382368, 1.201548696, -0.001715017],
        [0.707383871, 1.198095441, -0.001716852],
        [0.705940902, 1.193104982, -0.001719504],
        [0.704116583, 1.186795473, -0.001722856],
        [0.701990604, 1.179442644, -0.001726762],
        [0.699655890, 1.171367884, -0.001731052],
        [0.697214484, 1.162924170, -0.001735538],
        [0.697213113, 1.162923336, -0.003569085],
        [0.697209120, 1.162921071, -0.008730797],
        [0.697203398, 1.162917614, -0.016266534],
        [0.697198987, 1.162914991, -0.022019740],
        [0.697194397, 1.162912250, -0.027406292],
        [0.697185397, 1.162907004, -0.037971564],
        [0.697173715, 1.162899971, -0.051762581],
        [0.697167933, 1.162896395, -0.057849232],
        [0.697156549, 1.162888527, -0.068126127],
        [0.697138250, 1.162876129, -0.084625036],
        [0.697119176, 1.162863016, -0.101815075],
        [0.697113156, 1.162858129, -0.104090631],
        [0.697098672, 1.162846088, -0.109597206],
        [0.697078347, 1.162829280, -0.117316917],
        [0.697304785, 1.162671685, -0.121568188],
        [0.699139535, 1.161526322, -0.121555425],
        [0.702469945, 1.159447551, -0.121532254],
        [0.706680357, 1.156819344, -0.121502966],
        [0.708380699, 1.162753224, -0.121490926],
        [0.712287784, 1.184078097, -0.121463031],
        [0.718253374, 1.216638327, -0.121420436],
        [0.723365784, 1.245650887, -0.121383168],
        [0.722002804, 1.264187098, -0.121374972],
        [0.719067395, 1.304109812, -0.121357329],
        [0.715102017, 1.358039260, -0.121333495],
        [0.712942302, 1.383371949, -0.121322855],
        [0.709883749, 1.402644038, -0.121317439],
        [0.704685569, 1.435398221, -0.121308230],
        [0.698308647, 1.475580096, -0.121296927],
        [1.284102201, 1.498703599, -0.137137935],
        [1.869894981, 1.521426201, -0.152978912],
        [2.455688477, 1.543351769, -0.168819919],
        [3.041481972, 1.564092159, -0.184660912],
        [3.627274513, 1.583272815, -0.200501889],
        [4.213068008, 1.600536227, -0.216342896],
        [4.798861504, 1.615545511, -0.232183903],
        [5.384654999, 1.627989173, -0.248024911],
        [5.970448017, 1.637582898, -0.263865888],
        [6.556240559, 1.644074440, -0.279706866],
        [7.142034054, 1.647244930, -0.295547873],
        [7.727827549, 1.646912336, -0.311388880],
        [8.313621521, 1.642932892, -0.327229887],
        [8.899414062, 1.635202289, -0.343070865],
        [9.485207558, 1.623658299, -0.358911842],
        [10.071001053, 1.608279347, -0.374752879],
        [10.656793594, 1.589087009, -0.390593827],
        [11.242587090, 1.566143632, -0.406434834],
        [11.828380585, 1.539553285, -0.422275841],
        [12.414173126, 1.509459853, -0.438116819],
        [12.999966621, 1.476045370, -0.453957856],
        [13.585760117, 1.439528704, -0.469798833],
        [14.171553612, 1.400162220, -0.485639811],
        [14.757346153, 1.358229876, -0.501480818],
        [15.250845909, 1.316164494, -0.514826000],
        [15.581746101, 1.275918365, -0.523774147],
        [15.782530785, 1.237102389, -0.529203832],
        [15.885561943, 1.199347854, -0.531989932],
        [15.923564911, 1.162290454, -0.533017635],
        [15.929024696, 1.125580072, -0.533165276],
        [15.738004684, 1.141139269, -0.528003752],
        [15.546988487, 1.156682014, -0.522842348],
        [15.355971336, 1.172197223, -0.517680943],
        [15.164952278, 1.187673450, -0.512519479],
        [14.973936081, 1.203098893, -0.507358134],
        [14.782916069, 1.218448997, -0.502196610],
        [14.591896057, 1.233709097, -0.497035116],
        [14.400878906, 1.248875260, -0.491873711],
        [14.209861755, 1.263936877, -0.486712277],
        [14.018842697, 1.278883100, -0.481550813],
        [13.827827454, 1.293694973, -0.476389438],
        [13.636807442, 1.308330417, -0.471227944],
        [13.445791245, 1.322808981, -0.466066539],
        [13.254773140, 1.337120414, -0.460905105],
        [13.063753128, 1.351254821, -0.455743611],
        [12.872733116, 1.365201712, -0.450582117],
        [12.681717873, 1.378902793, -0.445420772],
        [12.490698814, 1.392375112, -0.440259308],
        [12.299680710, 1.405622840, -0.435097873],
        [12.108663559, 1.418636680, -0.429936439],
        [11.917644501, 1.431408048, -0.424774975],
        [11.726623535, 1.443900228, -0.419613481],
        [11.535608292, 1.456076860, -0.414452076],
        [11.344589233, 1.467978477, -0.409290612],
        [11.153571129, 1.479596615, -0.404129207],
        [10.962555885, 1.490923762, -0.398967832],
        [10.771535873, 1.501952648, -0.393806309],
        [10.580519676, 1.512587786, -0.388644904],
        [10.389501572, 1.522899985, -0.383483469],
        [10.198481560, 1.532887816, -0.378321975],
        [10.007462502, 1.542545080, -0.373160511],
        [9.816446304, 1.551865697, -0.367999136],
        [9.625426292, 1.560790539, -0.362837613],
        [9.434411049, 1.569316506, -0.357676268],
        [9.243392944, 1.577486753, -0.352514833],
        [9.052372932, 1.585296869, -0.347353309],
        [8.861353874, 1.592742801, -0.342191845],
        [8.670337677, 1.599807620, -0.337030441],
        [8.479317665, 1.606403589, -0.331869006],
        [8.288301468, 1.612622619, -0.326707602],
        [8.097283363, 1.618462443, -0.321546167],
        [7.906263351, 1.623921037, -0.316384673],
        [7.715243816, 1.628996611, -0.311223179],
        [7.524228573, 1.633607388, -0.306061804],
        [7.333209038, 1.637798786, -0.300900340],
        [7.142191887, 1.641603112, -0.295738906],
        [6.951174736, 1.645020485, -0.290577471],
        [6.760155678, 1.648050904, -0.285416007],
        [6.569139957, 1.650661826, -0.280254632],
        [6.378120422, 1.652808070, -0.275093168],
        [6.187100887, 1.654571176, -0.269931674],
        [5.996083260, 1.655952930, -0.264770210],
        [5.805066109, 1.656955719, -0.259608805],
        [5.614046574, 1.657581687, -0.254447341],
        [5.423031330, 1.657738328, -0.249285966],
        [5.232012272, 1.657514095, -0.244124502],
        [5.040991783, 1.656925797, -0.238962993],
        [4.849973202, 1.655977368, -0.233801544],
        [4.658957481, 1.654672980, -0.228640169],
        [4.467936993, 1.652970195, -0.223478675],
        [4.276921272, 1.650871038, -0.218317285],
        [4.085902691, 1.648435473, -0.213155836],
        [3.894882917, 1.645669341, -0.207994327],
        [3.703864098, 1.642578959, -0.202832878],
        [3.512848377, 1.639165521, -0.197671488],
        [3.321828604, 1.635358453, -0.192510009],
        [3.130811930, 1.631253004, -0.187348604],
        [2.939794302, 1.626856565, -0.182187170],
        [2.748775959, 1.622176766, -0.177025735],
        [2.557760477, 1.617221713, -0.171864361],
        [2.366740227, 1.611951232, -0.166702852],
        [2.175720215, 1.606401801, -0.161541373],
        [1.984702945, 1.600609660, -0.156379938],
        [1.798701167, 1.594488859, -0.151354030],
        [1.624324679, 1.587923646, -0.146642268],
        [1.469520688, 1.580759645, -0.142459348],
        [1.335532427, 1.572956562, -0.138838887],
        [1.217502475, 1.564664125, -0.135649636],
        [1.114398599, 1.555912495, -0.132863700],
        [1.025230050, 1.546730280, -0.130454302],
        [0.949084342, 1.537145257, -0.128396794],
        [0.887724161, 1.527104139, -0.126738802],
        [0.837362766, 1.516720772, -0.125377998],
        [0.796475410, 1.506042957, -0.124273196],
        [0.764180243, 1.495098114, -0.123400562],
        [0.739582777, 1.483913898, -0.122735925],
        [0.722309470, 1.472501159, -0.122269183],
        [0.711175442, 1.460896969, -0.121968329],
        [0.704163671, 1.449164152, -0.121778868],
        [0.700325310, 1.437332273, -0.121675156],
        [0.698717892, 1.425430655, -0.121631727],
        [0.698423326, 1.413488150, -0.121623762],
        [0.698723137, 1.413688779, -0.119252086],
        [0.699609339, 1.414282084, -0.112240694],
        [0.701043308, 1.415241957, -0.100896046],
        [0.702962399, 1.416526556, -0.085713923],
        [0.705282629, 1.418079734, -0.067357883],
        [0.707902610, 1.419833422, -0.046630166],
        [0.710707903, 1.421711326, -0.024436660],
        [0.712204576, 1.422128201, -0.013029400],
        [0.712702155, 1.417819500, -0.012532621],
        [0.713675499, 1.409390330, -0.011560773],
        [0.715082169, 1.397209167, -0.010156332],
        [0.716860592, 1.381808400, -0.008380678],
        [0.718933046, 1.363861084, -0.006311416],
        [0.721209049, 1.344151497, -0.004038982],
        [0.723589063, 1.323541284, -0.001662694],
        [0.723329604, 1.321177721, -0.001663683],
        [0.722562492, 1.314190507, -0.001666608],
        [0.721321285, 1.302884817, -0.001671341],
        [0.719660282, 1.287755013, -0.001677675],
        [0.717651963, 1.269462109, -0.001685333],
        [0.715384185, 1.248805761, -0.001693980],
        [0.712956071, 1.226688504, -0.001703238],
        [0.711635411, 1.215095520, -0.001708122],
        [0.711005151, 1.212815404, -0.001709320],
        [0.709772170, 1.208354831, -0.001711664],
        [0.707990348, 1.201908588, -0.001715052],
        [0.705737591, 1.193758607, -0.001719335],
        [0.703112304, 1.184261084, -0.001724326],
        [0.700229287, 1.173830986, -0.001729807],
        [0.697214484, 1.162924170, -0.001735538],
    ]
}
