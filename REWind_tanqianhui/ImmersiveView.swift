import ImageIO
//
//  ImmersiveView.swift
//  REWind_tanqianhui
//
//  Created by Interactive 3D Design on 4/9/26.
//

import SwiftUI
import Combine
import RealityKit
import RealityKitContent
import simd
import UIKit
import AVKit
import AVFoundation
import ARKit

// Main immersive scene: loads the house, aligns the world to the bedroom start,
// adds environment lighting, ceiling lights, and the floating home interface.
struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    // Controls whether the launch UI attachment is visible.
    @State private var isHomeInterfaceVisible = true
    @State private var activeEnvironmentRoot: Entity?
    @State private var activeHouseEntity: Entity?
    @State private var homeResetID = 0
    @State private var homeUIState: HomeUIState = .launch
    @State private var homeOrbEntity: Entity?
    @State private var performanceReviewTask: Task<Void, Never>?
    @State private var lightBudgetTask: Task<Void, Never>?
    @State private var sceneLightBudget: InteriorLightingManager.LightBudget?
    @State private var worldEntranceTask: Task<Void, Never>?
    @State private var lightingTrackingSession = ARKitSession()
    @State private var lightingWorldTracking = WorldTrackingProvider()
    @State private var routeNavigationTask: Task<Void, Never>?

    // Stage machine covering Stage 1 through Stage 4.
    @State private var experienceStage: ExperienceStage = .home
    private var sessionStore: MemorySessionStore { appModel.sessionStore }
    @State private var handReachMonitor = HandReachMonitor()
    @State private var activityInteraction = ActivityInteractionController()
    @State private var soundscape = SpatialSoundscape()
    @State private var activityPropsTask: Task<Entity?, Never>?
    @State private var activitySetupTask: Task<Void, Never>?
    @State private var activityHeadAnchor = AnchorEntity(.head, trackingMode: .continuous)
    @State private var activeRoute: MemoryRoute?
    @State private var activityStepIndex = 0
    @State private var activityCompletedStepCount = 0
    @State private var sessionRecorder: MemorySessionRecorder?
    @State private var completedSession: MemorySession?
    @State private var dashboardRoute: MemoryRoute?
    @State private var shouldShowMemorySelectionOnReturn = false
    @State private var albumBookEntity: Entity? = Entity()
    @State private var albumBookFading = false
    @State private var completionPose: Transform?
    @State private var suppressStairwellDuringTravel = false
    @State private var albumMagicTask: Task<Void, Never>?
    @State private var isAlbumBookLoading = false

    // Playing ball: dad + ball animated entity and interaction state.
    @State private var playingBallPropsRoot: Entity?
    @State private var playingBallEntity: Entity?
    @State private var playingBallControllers: [AnimationPlaybackController] = []
    @State private var playingBallThrowCount = 0
    @State private var playingBallIsPaused = false
    @State private var playingBallIsReturning = false

    // Christmas ornament interaction state.
    @State private var christmasPropsRoot: Entity?
    @State private var ornamentRestWorldPositions: [String: SIMD3<Float>] = [:]
    // Tracks the slot's world-space start position so screen-space drag movement
    // can be applied from a stable baseline.
    @State private var christmasDragActive: Bool = false
    @State private var christmasDraggedEntity: Entity?
    @State private var christmasDragStartWorldPosition: SIMD3<Float> = .zero
    @State private var christmasActiveDragOrnamentIndex: Int?
    @State private var christmasIsDragWithinDropZone = false
    @State private var christmasHasDraggedForPlacement = false
    @State private var christmasPlacedOrnamentIndices: Set<Int> = []

    // Imported RealityKit content names and startup viewpoint offsets.
    private let houseEntityName = "REWind_House_Master"
    private let memoryAlbumBookName = "Memory_Album_Provided"
    private let environmentRootName = "EnvironmentRoot"
    private let startingLocationName = "Location_Bedroom"
    private let christmasDropAcceptanceRadius: Float = 1.05
    // Viewpoint offsets now live in SpawnOffsets, per marker, because a single
    // global pair cannot be right for ten markers at once: local -Y is world -Z at
    // every one of them, so the old `down: 2.0` dropped the viewer 2 m in world
    // space everywhere - head inside the bedroom ceiling, and about a metre below
    // the floor at every downstairs waypoint. See SpawnOffsets.swift for the
    // measurements. The spawn and the route read the same table, so the return walk
    // cannot finish anywhere other than the spawn.

    // Which spatial panel is on screen at any moment. Exactly one of the
    // attachments below is enabled per stage.
    private enum ExperienceStage: Equatable {
        // Stage 1: launch orb, welcome, memory cards.
        case home
        // Stage 2 travel, outbound. No UI while the world moves.
        case travellingToMemory
        // Stage 2 activity, HUD visible.
        case activity
        // Stage 2 completion panel.
        case completion
        // Stage 3 travel, back to the bedroom.
        case returningHome
        // Stage 4 album resting on the bed.
        case album
        // Stage 4 dashboard above the album.
        case dashboard
    }

    private var isRunningInXcodePreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    var body: some View {
        if isRunningInXcodePreview {
            ImmersiveViewPreviewScaffold()
        } else {
            immersiveScene
                .onDisappear {
                    routeNavigationTask?.cancel()
                    worldEntranceTask?.cancel()
                    albumMagicTask?.cancel()
                    albumBookFading = false
                    activitySetupTask?.cancel()
                    activityPropsTask?.cancel()
                    activityInteraction.cancel()
                    soundscape.stop()
                    handReachMonitor.stop()
                    lightingTrackingSession.stop()
                    lightBudgetTask?.cancel()
                    sceneLightBudget = nil
                    lightBudgetTask = nil
                }
        }
    }

    private func startWorldEntrance(_ root: Entity) {
        worldEntranceTask?.cancel()
        worldEntranceTask = Task { @MainActor in
            // Wait for RealityView to commit the fully prepared scene. The room
            // starts transparent, so neither loading nor calibration can flash it.
            while root.scene == nil {
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            let frames = (0...72).map { index -> Float in
                let t = Float(index) / 72
                return t * t * (3 - 2 * t)
            }
            if let fade = try? AnimationResource.generate(with: SampledAnimation<Float>(
                frames: frames, name: "WorldEntrance", frameInterval: 1.2 / 72,
                bindTarget: .opacity, fillMode: .forwards)) {
                root.playAnimation(fade)
            } else {
                root.components.set(OpacityComponent(opacity: 1))
            }
        }
    }

    private var immersiveScene: some View {
        RealityView { content, attachments in
            do {
                // Start tracking before calibration; a parallel SwiftUI task can
                // otherwise leave a seated wearer using the standing fallback.
                if WorldTrackingProvider.isSupported {
                    do { try await lightingTrackingSession.run([lightingWorldTracking]) }
                    catch { throw error }
                }
                // Load the imported USDZ house from the RealityKitContent package.
                ActivityPropManager.prefetch(.christmasTree)
                let houseEntity = try await loadHouseEntity()
                houseEntity.name = houseEntityName
                // Preserve imported interior lights; window and door daylight are additive.

                // Keep all house alignment contained under EnvironmentRoot.
                SceneViewerCalibration.matrix = matrix_identity_float4x4
                // Match the canonical Simulator eye pose to this seated headset pose.
                // Capture once; subsequent real head motion remains natural.
                // Do not spawn at a standing fallback while a seated device is
                // still acquiring tracking. Closing the immersive space cancels this wait.
                while !Task.isCancelled && WorldTrackingProvider.isSupported {
                    if lightingWorldTracking.state == .running, let anchor = lightingWorldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked {
                        let pose = Transform(matrix: anchor.originFromAnchorTransform)
                        let forward = pose.rotation.act(SIMD3<Float>(0, 0, -1))
                        let yaw = atan2(-forward.x, -forward.z)
                        let orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
                        SceneViewerCalibration.matrix = Transform(rotation: orientation,
                            translation: pose.translation - SIMD3<Float>(0, 1.6, 0)).matrix
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(33))
                }
                try Task.checkCancellation()
                let environmentRoot = makeAlignedEnvironmentRoot(containing: houseEntity)
                activeEnvironmentRoot = environmentRoot
                activeHouseEntity = houseEntity

                // OutdoorLightingManager owns sun, sky, and image-based daylight fill.
                let outdoorLighting = OutdoorLightingManager.makeOutdoorLighting(for: houseEntity)
                // Lights use the same Z-up local space as the imported markers.
                houseEntity.addChild(outdoorLighting)
                InteriorLightingManager.keepMainSun(in: outdoorLighting)
                await OutdoorLightingManager.addGentleFoliageMotion(to: houseEntity)
                InteriorLightingManager.applyReferenceFinish(to: houseEntity, usesContactUV: houseEntity.findEntity(named: "REWindContactUV1") != nil)
                InteriorLightingManager.addWindowDaylight(to: houseEntity)

                // CeilingLightingSystem adds indoor fill lights using imported marker positions.
                CeilingLightingSystem.addCeilingLights(to: houseEntity)
                InteriorLightingManager.auditLights(in: houseEntity)

                // Prepare the full lighting before revealing the room. Otherwise
                // startup briefly shows dark geometry followed by blue sky-only fill.
                do {
                    let daytimeSkyLighting = await OutdoorLightingManager.makeDaytimeSkyLighting()
                    if let daytimeSky = daytimeSkyLighting.environment {
                        let imageBasedLight = OutdoorLightingManager.makeImageBasedLight(for: daytimeSky)
                        outdoorLighting.addChild(imageBasedLight)
                        OutdoorLightingManager.applyImageBasedLightReceiver(
                            to: houseEntity,
                            imageBasedLight: imageBasedLight
                        )
                    }

                    await InteriorLightingManager.applyRoomProbes(to: houseEntity, daylight: daytimeSkyLighting.environment)
                    RouteNavigationSystem.cacheClearanceBounds(in: houseEntity)
                    await InteriorLightingManager.batchStaticGeometry(in: houseEntity)

                    if let skyDome = daytimeSkyLighting.skyDome {
                        environmentRoot.addChild(skyDome)
                        // Visible sun body, added alongside the dome so it sits just inside
                        // it and shares the same parent transform.
                        houseEntity.addChild(OutdoorLightingManager.makeSunDisc())
                    }
                }
                await ActivityPropManager.prepareChristmasForHome(in: houseEntity)
                try Task.checkCancellation()
                // Scene preparation can take time. Calibrate to the wearer at
                // reveal, not to a head pose sampled before loading/batching.
                // Apply one rigid correction before anything becomes visible;
                // all saved viewpoints and subsequent real head motion stay intact.
                if WorldTrackingProvider.isSupported {
                    let previousCalibration = SceneViewerCalibration.matrix
                    var samples: [SIMD3<Float>] = []
                    var latestPose: Transform?
                    while !Task.isCancelled && samples.count < 12 {
                        if lightingWorldTracking.state == .running,
                           let anchor = lightingWorldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked {
                            let pose = Transform(matrix: anchor.originFromAnchorTransform)
                            if let last = samples.last, simd_distance(last, pose.translation) > 0.03 { samples.removeAll() }
                            samples.append(pose.translation)
                            latestPose = pose
                        } else { samples.removeAll() }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    try Task.checkCancellation()
                    if let pose = latestPose, !samples.isEmpty {
                        let position = samples.reduce(SIMD3<Float>.zero, +) / Float(samples.count)
                        let forward = pose.rotation.act(SIMD3<Float>(0, 0, -1))
                        let yaw = atan2(-forward.x, -forward.z)
                        SceneViewerCalibration.matrix = Transform(
                            rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]),
                            translation: position - SIMD3<Float>(0, 1.6, 0)).matrix
                        environmentRoot.setTransformMatrix(SceneViewerCalibration.matrix * simd_inverse(previousCalibration)
                            * environmentRoot.transformMatrix(relativeTo: nil), relativeTo: nil)
                        print("REWind seated reveal calibration: head \(position), vertical correction \(SceneViewerCalibration.matrix.columns.3.y - previousCalibration.columns.3.y)")
                    }
                }
                #if DEBUG
                _ = InteriorLightingManager.configureRoomReview(house: houseEntity, environmentRoot: environmentRoot)
                #endif
                // Preserve authored lighting in mixed compositing on device and Simulator.
                environmentRoot.components.set(EnvironmentLightingConfigurationComponent(environmentLightingWeight: 0))
                environmentRoot.components.set(OpacityComponent(opacity: 0))
                content.add(environmentRoot)
                startWorldEntrance(environmentRoot)
                OutdoorLightingManager.startLeafPlayback()
                Task {
                    await soundscape.prepareOutdoorAmbience(house: houseEntity)
                    await soundscape.prepareMusic(on: activityHeadAnchor)
                    await soundscape.enter(nil, house: houseEntity, props: nil)
                }
                content.add(activityHeadAnchor)
                RouteNavigationSystem.travelHeadAnchor = activityHeadAnchor
                let lightBudget = InteriorLightingManager.LightBudget(house: houseEntity, worldTracking: lightingWorldTracking)
                sceneLightBudget = lightBudget
                lightBudgetTask?.cancel()
                lightBudgetTask = Task { @MainActor in
                    var previous = CACurrentMediaTime()
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) }
                        catch { break }
                        let now = CACurrentMediaTime()
                        if RouteNavigationSystem.isRelocatingUnderCover, experienceStage == .returningHome {
                            lightBudget.restoreBedroomLighting()
                        }
                        lightBudget.update(deltaTime: RouteNavigationSystem.isRelocatingUnderCover ? 1 : now - previous,
                            suppressStairwell: suppressStairwellDuringTravel || experienceStage == .activity || experienceStage == .completion,
                            softenPlayingBall: activeRoute == .playingBall && (experienceStage == .travellingToMemory || experienceStage == .activity || experienceStage == .completion),
                            atBallActivity: activeRoute == .playingBall && (experienceStage == .activity || experienceStage == .completion),
                            holdViewerPosition: experienceStage != .travellingToMemory && experienceStage != .returningHome)
                        RouteNavigationSystem.isRelocatingUnderCover = false
                        if experienceStage == .travellingToMemory || experienceStage == .returningHome {
                            soundscape.updateOutdoorTransition(houseY: houseEntity.convert(position: activityInteraction.viewerPose().translation, from: nil).y)
                        }
                        previous = now
                    }
                }
                HomeInterfacePlacement.addPanels(from: attachments, to: content, isInitialLoad: true)
                let spatialOrb = await HomeGlassOrb.makeEntity()
                homeOrbEntity = spatialOrb
                if let home = attachments.entity(for: HomeInterfacePlacement.attachmentID) {
                    let anchor = AnchorEntity(world: home.position)
                    anchor.name = "HomeOrbWorldAnchor"
                    anchor.scale = home.scale
                    anchor.orientation = Transform(matrix: SceneViewerCalibration.matrix).rotation
                    anchor.addChild(spatialOrb)
                    content.add(anchor)
                    HomeGlassOrb.playEntrance(spatialOrb)
                    home.position = SceneViewerCalibration.position([0, 1.66 - 0.226 * 0.90, -1.12])
                }
                addMemoryAlbumBookContainer(to: content)
                #if DEBUG && REWIND_AUTOMATED_REVIEW
                startPerformanceReview(environmentRoot)
                #endif
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--rewind-room=all") {
                    attachments.entity(for: HomeInterfacePlacement.attachmentID)?.isEnabled = false
                }
                #endif
            } catch {
                print("Error: Could not load \(houseEntityName) from RealityKitContent bundle: \(error)")

                let houseEntity = makeFallbackHouseEntity()
                let environmentRoot = makeAlignedEnvironmentRoot(containing: houseEntity)
                activeEnvironmentRoot = environmentRoot
                activeHouseEntity = houseEntity

                environmentRoot.components.set(OpacityComponent(opacity: 0))
                content.add(environmentRoot)
                startWorldEntrance(environmentRoot)
                content.add(activityHeadAnchor)
                RouteNavigationSystem.travelHeadAnchor = activityHeadAnchor
                HomeInterfacePlacement.addPanels(from: attachments, to: content, isInitialLoad: true)
                let spatialOrb = await HomeGlassOrb.makeEntity()
                homeOrbEntity = spatialOrb
                if let home = attachments.entity(for: HomeInterfacePlacement.attachmentID) {
                    let anchor = AnchorEntity(world: home.position)
                    anchor.name = "HomeOrbWorldAnchor"
                    anchor.scale = home.scale
                    anchor.orientation = Transform(matrix: SceneViewerCalibration.matrix).rotation
                    anchor.addChild(spatialOrb)
                    content.add(anchor)
                    HomeGlassOrb.playEntrance(spatialOrb)
                    home.position = SceneViewerCalibration.position([0, 1.66 - 0.226 * 0.90, -1.12])
                }
                addMemoryAlbumBookContainer(to: content)

            }
        } update: { content, attachments in
            // Panels whose SwiftUI content is conditional do not exist as entities
            // until that condition is first true, so adopt any that have appeared
            // since the last update before applying visibility.
            HomeInterfacePlacement.addPanels(from: attachments, to: content, isInitialLoad: false)
            if let spatialOrb = homeOrbEntity,
               let home = attachments.entity(for: HomeInterfacePlacement.attachmentID) {
                // Keep the orb outside the SwiftUI attachment's compositor subtree.
                spatialOrb.parent?.isEnabled = experienceStage == .home && isHomeInterfaceVisible
                // Only the compact button or actual card grid uses SwiftUI's
                // attachment surface. Empty space around the orb is native 3D.
                // AnchorEntity's tracked pose is opaque to CPU coordinate
                // conversion. Keep SwiftUI buttons at their original calibrated
                // room pose; only the native text/orb uses the world anchor.
                let buttonOffset: Float = homeUIState == .launch ? -0.226 * 0.90 : 0
                // Bring only the card grid ten centimetres closer; keep its centre stable.
                let homeDepth: Float = homeUIState == .memories ? -1.02 : -1.12
                home.position = SceneViewerCalibration.position([0, 1.66 + buttonOffset, homeDepth])
                home.orientation = Transform(matrix: SceneViewerCalibration.matrix).rotation
                home.scale = SIMD3(repeating: 0.90)
                home.components.remove(BillboardComponent.self)
                HomeGlassOrb.update(spatialOrb, state: homeUIState)
            }

            // Exactly one panel is enabled per stage; the rest stay in the scene
            // but disabled so their state survives a stage change.
            HomeInterfacePlacement.updatePanelVisibility(
                attachments: attachments,
                isHomeVisible: experienceStage == .home && isHomeInterfaceVisible,
                isActivityVisible: experienceStage == .activity,
                isCompletionVisible: experienceStage == .completion,
                isAlbumVisible: experienceStage == .album,
                isDashboardVisible: experienceStage == .dashboard,
                isAlbumPointerVisible: experienceStage == .album
            )

            // Keep the activity overlay centred in the headset view; room models
            // stay world-anchored. This also survives Simulator camera resets.
            if experienceStage == .activity,
               let hud = attachments.entity(for: HomeInterfacePlacement.activityAttachmentID) {
                if hud.parent !== activityHeadAnchor { activityHeadAnchor.addChild(hud) }
                hud.position = [0, 0.0864, -0.60]
                hud.orientation = simd_quatf()
                hud.scale = SIMD3(repeating: 0.648)
                hud.components.remove(BillboardComponent.self)
            }
            if experienceStage == .completion,
               let panel = attachments.entity(for: HomeInterfacePlacement.completionAttachmentID) {
                // A head-locked button moves under the gaze ray during a pinch.
                // Capture the panel once so it stays still while selecting a card.
                if let completionPose { panel.transform = completionPose }
                if activeRoute == .breakfast,
                   let tableClearance = activityInteraction.breakfastCompletionClearance {
                    // The entire panel, including revisit buttons, must clear the
                    // tabletop even when its footprint is in front of the bowl.
                    let bounds = panel.visualBounds(relativeTo: nil)
                    let rise = tableClearance - bounds.min.y
                    if rise.isFinite && rise > 0 {
                        var position = panel.position(relativeTo: nil)
                        position.y += rise
                        panel.setPosition(position, relativeTo: nil)
                    }
                }
                panel.components.remove(BillboardComponent.self)
            }

            // Christmas 3D guidance: slot indicators, pickup glows, and
            // world-anchored callout labels.
            let ornamentCalloutID = "ChristmasOrnamentCallout"
            let slotCalloutID = "ChristmasSlotCallout"
            let slotRimID = "ChristmasSlotRim"

            // Add callout entities to content once when they first become available.
            for calloutID in [ornamentCalloutID, slotCalloutID, slotRimID] {
                if let callout = attachments.entity(for: calloutID), callout.parent == nil {
                    callout.components.set(BillboardComponent())
                    callout.isEnabled = false
                    content.add(callout)
                }
            }

            if experienceStage == .activity, activeRoute == .christmasTree,
               let propsRoot = christmasPropsRoot {
                let ornamentIndex = activityInteraction.selectedOrnamentIndex ?? (0..<3).first(where: { !activityInteraction.placedOrnamentIndices.contains($0) }) ?? 0
                let subStep = activityStepIndex % 3
                let guidanceOrnamentIndex = christmasActiveDragOrnamentIndex ?? ornamentIndex

                // Ornament pickup callout — world-anchored near the active ornament.
                if let callout = attachments.entity(for: ornamentCalloutID) {
                    let ornSlotName = "Christmas_Ornament_\(ornamentIndex + 1)_Slot"
                    // Keep the fading label at its pickup position during the zoom.
                    if activityInteraction.selectedOrnamentIndex == nil,
                       let ornSlot = propsRoot.findEntity(named: ornSlotName) {
                        let wp = ornSlot.position(relativeTo: nil)
                        callout.position = wp + SIMD3<Float>(0.10, 0.14, 0.0)
                    }
                    HomeInterfacePlacement.setPanelVisibility(callout, isEnabled: subStep == 0 && !christmasDragActive)
                }

                // Placement callout — world-anchored near the active tree slot.
                if let callout = attachments.entity(for: slotCalloutID) {
                    let treeSlotName = "OrnamentSlot_\(guidanceOrnamentIndex + 1)"
                    if let treeSlot = propsRoot.findEntity(named: treeSlotName) {
                        let wp = treeSlot.position(relativeTo: nil)
                        // Keep the label beside the ring, with extra clearance
                        // in front of the branches. The ring itself stays put.
                        let eye = activityInteraction.viewerPose()
                        let toward = simd_normalize(eye.translation - wp)
                        let halfLabel = callout.visualBounds(relativeTo: callout).extents.x * callout.scale.x / 2
                        callout.position = wp + toward * 0.18
                            + eye.rotation.act(SIMD3<Float>(0.07 + halfLabel, 0, 0))
                    }
                    HomeInterfacePlacement.setPanelVisibility(callout, isEnabled: subStep == 1 || christmasActiveDragOrnamentIndex != nil)
                }

                // Placement rim — SwiftUI attachment, not model geometry.
                if let rim = attachments.entity(for: slotRimID) {
                    let treeSlotName = "OrnamentSlot_\(guidanceOrnamentIndex + 1)"
                    if let treeSlot = propsRoot.findEntity(named: treeSlotName) {
                        let point = treeSlot.position(relativeTo: nil)
                        let toward = activityInteraction.viewerPose().translation - point
                        rim.position = point + simd_normalize(toward) * 0.065
                    }
                    // Keep the last ring alive through the placement glow fade.
                    HomeInterfacePlacement.setPanelVisibility(rim, isEnabled: subStep == 1 || subStep == 2 || christmasActiveDragOrnamentIndex != nil)
                }
            } else {
                // Hide callouts when not in the Christmas activity.
                attachments.entity(for: ornamentCalloutID)?.isEnabled = false
                attachments.entity(for: slotCalloutID)?.isEnabled = false
                attachments.entity(for: slotRimID)?.isEnabled = false
            }

            // Playing ball: world-anchored "Reach here" callout near the paused ball.
            let ballCalloutID = "BallReachCallout"
            if let callout = attachments.entity(for: ballCalloutID), callout.parent == nil {
                callout.components.set(BillboardComponent())
                callout.isEnabled = false
                content.add(callout)
            }
            if let callout = attachments.entity(for: ballCalloutID) {
                if experienceStage == .activity, activeRoute != .christmasTree,
                   !activityInteraction.isBusy, let target = activityInteraction.calloutTarget {
                    let bounds = target.visualBounds(relativeTo: nil)
                    let anchor = activeRoute == .breakfast && activityStepIndex >= 2
                        ? target.position(relativeTo: nil) : bounds.center
                    let toward = activityInteraction.viewerPose().translation - anchor
                    let front = simd_normalize(toward) * 0.10
                    var proposed = SIMD3(anchor.x, max(bounds.max.y, anchor.y) + 0.16, anchor.z) + front
                    if activeRoute == .breakfast && activityStepIndex < 2 {
                        let side: Float = activityStepIndex == 0 ? 0.27 : 0.18
                        proposed = bounds.center + activityInteraction.viewerPose().rotation.act(SIMD3<Float>(side, 0, 0))
                            + SIMD3<Float>(0, bounds.extents.y * 0.35 + 0.025, 0) + front
                    }
                    // Keep the label in view without clamping it down into
                    // the model. A close ball uses an upper-right callout.
                    let eye = activityInteraction.viewerPose()
                    var local = eye.rotation.inverse.act(proposed - eye.translation)
                    let depth = max(0.45, -local.z)
                    if activeRoute == .playingBall {
                        local.x += 0.22
                        local.y = min(local.y, -0.03)
                    }
                    if activeRoute == .breakfast {
                        // Keep object guidance below the head-anchored title band.
                        local.y = min(local.y, -depth * 0.02)
                    }
                    local.x = min(max(local.x, -depth * 0.56), depth * 0.56)
                    if activeRoute == .breakfast && activityStepIndex == 1 {
                        let corners = [bounds.min.x, bounds.max.x].flatMap { x in
                            [bounds.min.y, bounds.max.y].flatMap { y in
                                [bounds.min.z, bounds.max.z].map { z in
                                    eye.rotation.inverse.act(SIMD3<Float>(x, y, z) - eye.translation)
                                }
                            }
                        }
                        let halfWidth = max(0.16, callout.visualBounds(relativeTo: callout).extents.x
                            * abs(callout.scale(relativeTo: nil).x) / 2)
                        local = HomeInterfacePlacement.milkCalloutPosition(
                            modelCorners: corners, preferred: local, halfLabelWidth: halfWidth)
                    }
                    callout.position = eye.translation + eye.rotation.act(local)
                    if activeRoute == .breakfast && activityStepIndex == 2 {
                        let bowl = activeHouseEntity?.findEntity(named: "Breakfast_Bowl")
                        let centre = bowl?.position(relativeTo: nil) ?? anchor
                        if activityInteraction.spoonIsHeld {
                            callout.position = centre + SIMD3<Float>(0, 0.10, 0)
                        } else {
                            // Pickup guidance belongs to the spoon; only the stir
                            // progress label belongs over the centre of the bowl.
                            callout.position = (activityInteraction.spoonRestPosition ?? bounds.center)
                                + SIMD3<Float>(0, 0.10, 0) + eye.rotation.act(SIMD3<Float>(0.08, 0, 0.04))
                        }
                    }
                    HomeInterfacePlacement.setPanelVisibility(callout, isEnabled: true)
                } else { HomeInterfacePlacement.setPanelVisibility(callout, isEnabled: false) }
            }

            let isAlbumBookVisible = sessionStore.hasCompletedAllMemories && (experienceStage == .album || albumBookFading)
            if isAlbumBookVisible, let book = albumBookEntity, !book.isEnabled {
                book.position = memoryAlbumBookPositionFromBedroomMarker()
                book.orientation = Transform(matrix: SceneViewerCalibration.matrix).rotation
                // Defer observable task state until after RealityView's update.
                Task { @MainActor in
                    guard experienceStage == .album, book.isEnabled else { return }
                    startAlbumBookMagic(book)
                }
            }
            albumBookEntity?.isEnabled = isAlbumBookVisible
            if isAlbumBookVisible, let albumBookEntity,
               let albumPointer = attachments.entity(for: HomeInterfacePlacement.albumPointerAttachmentID) {
                albumPointer.position = albumBookEntity.position + SIMD3<Float>(0.0, 0.30, 0.0)
                albumPointer.scale = SIMD3<Float>(repeating: 1.5)
            }
        } attachments: {
            // Stage 1: SwiftUI launch UI rendered as a RealityView attachment.
            Attachment(id: HomeInterfacePlacement.attachmentID) {
                HomeLaunchView(
                    uiState: $homeUIState,
                    isVisible: $isHomeInterfaceVisible,
                    shouldShowMemorySelectionOnReturn: $shouldShowMemorySelectionOnReturn,
                    completedRoutes: sessionStore.completedRoutes
                ) { route in
                    startMemory(route)
                }
                .id(homeResetID)
                #if DEBUG
                .opacity(ProcessInfo.processInfo.arguments.contains("--rewind-room=all") ? 0 : 1)
                #endif
            }

            // Stage 2: in-activity HUD.
            Attachment(id: HomeInterfacePlacement.activityAttachmentID) {
                if let activeRoute {
                    ActivityHUDView(
                        route: activeRoute,
                        steps: activeRoute.activitySteps,
                        currentStepIndex: activityStepIndex,
                        completedStepCount: activityCompletedStepCount,
                        isHandTrackingActive: handReachMonitor.availability.isTracking,
                        liveReachCentimetres: handReachMonitor.currentExtensionCentimetres,
                        isInteractionBusy: activityInteraction.isBusy || !activityInteraction.isReady,
                        feedback: activityInteraction.feedback,
                        instructionTitle: activityInteraction.instructionTitle,
                        interactionProgress: activityInteraction.interactionProgress,
                        placedOrnamentIndices: activityInteraction.placedOrnamentIndices,
                        selectedOrnamentIndex: activityInteraction.selectedOrnamentIndex,
                        onExitRequested: {
                            restartFromBedroom()
                        }
                    )
                }
            }

            // Stage 2: completion panel.
            Attachment(id: HomeInterfacePlacement.completionAttachmentID) {
                if let activeRoute, let completedSession {
                    ActivityCompletionView(
                        route: activeRoute,
                        session: completedSession,
                        completedRoutes: sessionStore.completedRoutes,
                        onRouteRequested: { route in
                            beginMemoryFromCompletion(route)
                        },
                        onReturnHome: {
                            beginReturnHome()
                        }
                    )
                }
            }

            // Christmas world-anchored callouts. These are positioned in 3D space
            // by the update closure — near the active ornament or tree slot.
            Attachment(id: "ChristmasOrnamentCallout") {
                ChristmasCalloutView(text: handReachMonitor.availability.isTracking ? "Pinch an ornament here" : "Select an ornament here", neutralBackdrop: true)
                    .opacity(activityInteraction.selectedOrnamentIndex == nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: activityInteraction.selectedOrnamentIndex != nil)
                    .allowsHitTesting(false)
            }
            Attachment(id: "ChristmasSlotCallout") {
                ChristmasCalloutView(text: "Place it here")
                    .onTapGesture { activityInteraction.placePreviewOnTree() }
            }
            Attachment(id: "ChristmasSlotRim") {
                ChristmasPlacementRimView(isActive: activityInteraction.isOverPlacementTarget,
                    isPlaced: activityInteraction.selectedOrnamentIndex.map {
                        activityInteraction.placedOrnamentIndices.contains($0)
                    } ?? false)
                    .contentShape(Circle())
                    .onTapGesture { activityInteraction.placePreviewOnTree() }
            }

            // Playing ball: world-anchored callout floating above the paused ball.
            Attachment(id: "BallReachCallout") {
                if activeRoute == .breakfast && activityStepIndex == 2 && activityInteraction.isSpoonAtBowl {
                    VStack(spacing: 12) {
                        Text(activityInteraction.interactionProgress >= 1 ? "Release the spoon" : "Stir gently inside the bowl")
                            .font(.system(size: 24)).foregroundStyle(.white)
                        ProgressView(value: activityInteraction.interactionProgress)
                            .tint(REWindPalette.accent).frame(width: 260)
                    }
                    .padding(22).glassCapsule(opacity: 0.22).allowsHitTesting(false)
                } else {
                    ChristmasCalloutView(text: activityInteraction.calloutText).allowsHitTesting(false)
                }
            }

            // Stage 4: album on the bed.
            Attachment(id: HomeInterfacePlacement.albumAttachmentID) {
                MemoryAlbumView(
                    completedCount: sessionStore.completedRoutes.count,
                    totalCount: MemoryRoute.allCases.count,
                    onOpen: {
                        openAlbumDashboard()
                    }
                )
            }

            Attachment(id: HomeInterfacePlacement.albumPointerAttachmentID) {
                MemoryAlbumPointerView()
            }

            // Stage 4: shared progress dashboard.
            Attachment(id: HomeInterfacePlacement.dashboardAttachmentID) {
                if let session = dashboardRoute.flatMap({ sessionStore.history(for: $0, limit: 1).last }) ?? completedSession ?? sessionStore.latestSession {
                    MemoryDashboardView(
                        session: session,
                        history: sessionStore.history(for: session.route, limit: 4),
                        reachChangeCentimetres: sessionStore.reachChangeCentimetres(for: session),
                        completedRoutes: sessionStore.completedRoutes,
                        onSelectRoute: { dashboardRoute = $0 },
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.4)) {
                                experienceStage = .album
                            }
                        },
                        onReturnHome: {
                            restartFromBedroom()
                        }
                    )
                }
            }
        }
        .simultaneousGesture(
            SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                if experienceStage == .home, homeUIState == .welcome, value.entity.name == "HomeGlassOrb" {
                    withAnimation(.easeInOut(duration: 0.9)) { homeUIState = .memories }
                } else if experienceStage == .activity { activityInteraction.tap(value.entity) }
                else if experienceStage == .album {
                    var target: Entity? = value.entity
                    while let entity = target {
                        if entity.name == "\(memoryAlbumBookName)_Container" {
                            openAlbumDashboard(); break
                        }
                        target = entity.parent
                    }
                }
            }, including: ((experienceStage == .home && homeUIState == .welcome) || experienceStage == .activity || experienceStage == .album) ? .all : .subviews
        )
        .onChange(of: handReachMonitor.currentExtensionCentimetres) { _, value in
            if experienceStage == .activity { sessionRecorder?.recordLiveReach(value) }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 2).targetedToAnyEntity()
                .onChanged { value in
                    guard experienceStage == .activity, !activityInteraction.isHandGrasping else { return }
                    let movement = value.convert(value.translation3D, from: .local, to: .scene)
                    let handPosition = value.inputDevicePose3D.map {
                        value.convert($0.position, from: .local, to: .scene)
                    }
                    activityInteraction.targetedDragChanged(value.entity, translation: movement, handPosition: handPosition)
                }
                .onEnded { _ in
                    if experienceStage == .activity { activityInteraction.targetedDragEnded() }
                }, including: experienceStage == .activity ? .all : .subviews
        )
    }

    private func loadHouseEntity() async throws -> Entity {
        // This asset contains the preserved materials, ceiling-bulb emission and
        // secondary UVs used by the furniture shadows and indirect-light bake.
        // Do not fall back to the original house: it cannot use those lighting maps.
        let house = try await Entity(named: "REWind_House_Preserved", in: realityKitContentBundle)
        // Remove only the dining-table crate that intersects the plant and vase.
        // Do this before static batching so its geometry/shadow cannot survive
        // in a combined mesh; the neighbouring decor remains in the house.
        house.findEntity(named: "Wooden_crate_015")?.removeFromParent()
        if house.findEntity(named: "REWindContactUV1") == nil {
            let marker = Entity()
            marker.name = "REWindContactUV1"
            house.addChild(marker)
        }
        print("✅ ACTIVE HOUSE: REWind_House_Preserved. contact UVs and baked lighting enabled")
        #if DEBUG
        let removedNames = ["Pillow_B_006", "Plant_B_006", "Shelves_006", "SHC_Old_Book_004", "Leather_chair_008", "Stool_001"]
        print("HOUSE REMOVAL CHECK: " + removedNames.map { "\($0)=\(house.findEntity(named: $0) == nil ? "absent" : "PRESENT")" }.joined(separator: ", "))
        #endif
        return house
    }

    private func openAlbumDashboard() {
        guard experienceStage == .album, !albumBookFading else { return }
        albumBookFading = true
        withAnimation(.easeInOut(duration: 0.4)) { experienceStage = .dashboard }
    }

    private func startAlbumBookMagic(_ book: Entity) {
        albumMagicTask?.cancel()
        book.components.set(OpacityComponent(opacity: 0))
        let motes: Entity
        if let existing = book.findEntity(named: "AlbumGoldenMotes") { motes = existing }
        else {
            motes = Entity(); motes.name = "AlbumGoldenMotes"
            let material = UnlitMaterial(color: UIColor(red: 1, green: 0.84, blue: 0.46, alpha: 1))
            for index in 0..<10 {
                let mote = ModelEntity(mesh: .generateSphere(radius: index % 3 == 0 ? 0.0018 : 0.0011), materials: [material])
                motes.addChild(mote)
            }
            book.addChild(motes)
        }
        albumMagicTask = Task { @MainActor in
            let start = CACurrentMediaTime()
            var fadeStart: Double?
            while !Task.isCancelled && (experienceStage == .album || albumBookFading) {
                let now = CACurrentMediaTime()
                let t = Float(now - start)
                if albumBookFading && fadeStart == nil { fadeStart = now }
                let fadeProgress = fadeStart.map { Float(min(1, (now - $0) / 0.65)) } ?? 0
                let fade = fadeProgress * fadeProgress * (3 - 2 * fadeProgress)
                book.components.set(OpacityComponent(opacity: min(1, t / 0.4) * (1 - fade)))
                for (index, mote) in motes.children.enumerated() {
                    let phase = (t * 0.17 + Float(index) / 10).truncatingRemainder(dividingBy: 1)
                    let angle = Float(index) * 2.399
                    mote.position = [cos(angle) * 0.19, 0.025 + phase * 0.085 + fade * 0.06, sin(angle) * 0.12]
                    mote.components.set(OpacityComponent(opacity: (0.20 + 0.35 * sin(phase * .pi))))
                }
                if fade >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled {
                book.isEnabled = false
                albumBookFading = false
            }
        }
    }

    private func addMemoryAlbumBookContainer(to content: RealityViewContent) {
        guard let container = albumBookEntity else { return }
        isAlbumBookLoading = true
        container.name = "\(memoryAlbumBookName)_Container"
        container.position = memoryAlbumBookPositionFromBedroomMarker()
        container.orientation = Transform(matrix: SceneViewerCalibration.matrix).rotation
        container.isEnabled = false
        container.components.set(CollisionComponent(shapes: [.generateBox(size: [0.46, 0.08, 0.34])]))
        container.components.set(InputTargetComponent(allowedInputTypes: .all))
        content.add(container)

        Task { @MainActor in
            do {
                let albumBook = try await loadMemoryAlbumBookEntity()
                // Remove placeholder boxes so only the USDZ book is visible.
                container.findEntity(named: "\(memoryAlbumBookName)_VisibleFallback")?.removeFromParent()
                container.addChild(albumBook)
                print("ALBUM BOOK: position \(container.position), bounds \(albumBook.visualBounds(relativeTo: nil))")
            } catch {
                print("❌ REQUIRED ALBUM BOOK FAILED TO LOAD: \(error)")
            }

            isAlbumBookLoading = false
        }
    }

    private func memoryAlbumBookPositionFromBedroomMarker() -> SIMD3<Float> {
        guard let house = activeHouseEntity, let bed = house.findEntity(named: "Bed_005") else {
            return SceneViewerCalibration.position([0.0, 1.05, -1.40])
        }
        // Work in the bed's house coordinates, not an axis-aligned world box
        // that changes as navigation rotates the house.
        let bounds = bed.visualBounds(relativeTo: house)
        // Use the calibrated bedroom forward direction, not the last activity's
        // head turn, so the album always rests in front on the quilt.
        let desired = SceneViewerCalibration.matrix * SIMD4<Float>(0.24, 1.08, -1.65, 1)
        var local = house.convert(position: SIMD3(desired.x, desired.y, desired.z), from: nil)
        local.x = min(max(local.x, bounds.min.x + 0.28), bounds.max.x - 0.28)
        local.y = min(max(local.y, bounds.min.y + 0.25), bounds.max.y - 0.25)
        // This is the folded Bed_blanket_002 surface, not Bed_005's sheet.
        // USD triangle intersections put the blanket top at 3.68 m here.
        // Centre the complete open cover inside the blanket's width.
        local.x = -8.30
        // Shift along the blanket to the viewer's right only. The supplied
        // open cover intersects the raised fold by 12 mm at y=48.60; its
        // lower vertices clear that fold at y=48.40 without lifting the book.
        local.y = 48.40
        local.z = 3.682
        return house.convert(position: local, to: nil)
    }

    private func loadMemoryAlbumBookEntity() async throws -> Entity {
        do {
            return prepareMemoryAlbumBook(try await Entity(named: memoryAlbumBookName, in: realityKitContentBundle))
        } catch {
            print("⚠️ ALBUM BOOK NAMED LOAD FAILED: \(memoryAlbumBookName): \(error). Trying exact USDZ URL.")
        }

        guard let url = realityKitContentBundle.url(forResource: memoryAlbumBookName, withExtension: "usdz") else {
            throw RequiredAlbumBookAssetLoadError.missingBundledUSDZ(memoryAlbumBookName)
        }

        return prepareMemoryAlbumBook(try await Entity(contentsOf: url))
    }

    private func prepareMemoryAlbumBook(_ book: Entity) -> Entity {
        book.name = memoryAlbumBookName
        let bounds = book.visualBounds(relativeTo: book)
        // Align the thinnest dimension vertically so the closed book lies flat.
        if bounds.extents.z < min(bounds.extents.x, bounds.extents.y) {
            book.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        } else if bounds.extents.x < bounds.extents.y {
            book.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        }
        let wrapper = Entity()
        wrapper.addChild(book)
        let aligned = book.visualBounds(relativeTo: wrapper)
        let factor = 0.46 / max(aligned.extents.x, aligned.extents.z)
        book.scale *= factor
        book.position = [-aligned.center.x * factor, -aligned.min.y * factor, -aligned.center.z * factor]
        book.removeFromParent()
        return book
    }

    private func makeVisibleMemoryAlbumBook() -> Entity {
        let fallbackBook = Entity()
        fallbackBook.name = "\(memoryAlbumBookName)_VisibleFallback"
        fallbackBook.orientation = simd_quatf(angle: -.pi / 7.5, axis: SIMD3<Float>(1, 0, 0))

        let pageBlock = ModelEntity(
            mesh: .generateBox(size: 1.0),
            materials: [UnlitMaterial(color: UIColor(red: 0.86, green: 0.80, blue: 0.70, alpha: 1.0))]
        )
        pageBlock.name = "\(memoryAlbumBookName)_Pages"
        pageBlock.position = SIMD3<Float>(0.0, -0.035, 0.0)
        pageBlock.scale = SIMD3<Float>(0.72, 0.075, 0.50)
        fallbackBook.addChild(pageBlock)

        let visibleAlbum = ModelEntity(
            mesh: .generateBox(size: 1.0),
            materials: [UnlitMaterial(color: UIColor(red: 0.72, green: 0.62, blue: 0.48, alpha: 1.0))]
        )
        visibleAlbum.name = "\(memoryAlbumBookName)_VisibleCover"
        visibleAlbum.position = SIMD3<Float>(0.0, 0.035, 0.0)
        visibleAlbum.scale = SIMD3<Float>(0.78, 0.045, 0.54)
        fallbackBook.addChild(visibleAlbum)

        let spine = ModelEntity(
            mesh: .generateBox(size: 1.0),
            materials: [UnlitMaterial(color: UIColor(red: 0.50, green: 0.38, blue: 0.24, alpha: 1.0))]
        )
        spine.name = "\(memoryAlbumBookName)_VisibleSpine"
        spine.position = SIMD3<Float>(-0.41, 0.055, 0.0)
        spine.scale = SIMD3<Float>(0.07, 0.07, 0.56)
        fallbackBook.addChild(spine)

        let glow = Entity()
        glow.name = "\(memoryAlbumBookName)_Glow"
        glow.position = SIMD3<Float>(0.0, 0.12, 0.0)
        glow.components.set(PointLightComponent(
            color: .init(red: 1.0, green: 0.78, blue: 0.44, alpha: 1.0),
            intensity: 260 * InteriorLightingManager.radianceScale,
            attenuationRadius: 0.55
        ))
        fallbackBook.addChild(glow)

        return fallbackBook
    }

    private enum RequiredAlbumBookAssetLoadError: LocalizedError {
        case missingBundledUSDZ(String)

        var errorDescription: String? {
            switch self {
            case .missingBundledUSDZ(let resourceName):
                "Missing required memory album USDZ asset: \(resourceName).usdz"
            }
        }
    }

    private func makeFallbackHouseEntity() -> Entity {
        let root = Entity()
        root.name = houseEntityName

        let floorMaterial = SimpleMaterial(
            color: UIColor(red: 0.44, green: 0.48, blue: 0.50, alpha: 1.0),
            roughness: 0.85,
            isMetallic: false
        )
        let wallMaterial = SimpleMaterial(
            color: UIColor(red: 0.82, green: 0.84, blue: 0.80, alpha: 1.0),
            roughness: 0.9,
            isMetallic: false
        )

        let floor = ModelEntity(mesh: .generateBox(size: 1.0), materials: [floorMaterial])
        floor.name = "Fallback_Floor"
        floor.position = SIMD3<Float>(0.0, -0.04, -0.8)
        floor.scale = SIMD3<Float>(3.2, 0.08, 2.8)
        root.addChild(floor)

        let backWall = ModelEntity(mesh: .generateBox(size: 1.0), materials: [wallMaterial])
        backWall.name = "Fallback_BackWall"
        backWall.position = SIMD3<Float>(0.0, 0.9, -2.16)
        backWall.scale = SIMD3<Float>(3.2, 1.8, 0.08)
        root.addChild(backWall)

        let sideWall = ModelEntity(mesh: .generateBox(size: 1.0), materials: [wallMaterial])
        sideWall.name = "Fallback_SideWall"
        sideWall.position = SIMD3<Float>(-1.56, 0.9, -0.8)
        sideWall.scale = SIMD3<Float>(0.08, 1.8, 2.8)
        root.addChild(sideWall)

        let marker = Entity()
        marker.name = startingLocationName
        marker.position = SIMD3<Float>(0.0, 0.0, 0.0)
        root.addChild(marker)

        print("⚠️ USING FALLBACK IMMERSIVE ROOM: real house asset did not load")
        return root
    }

    // MARK: - Stage 2: enter the memory



    #if DEBUG && REWIND_AUTOMATED_REVIEW
    /// Dedicated automated-review builds only. Normal Debug and device builds
    /// must never run this scripted navigation, even with stale launch arguments.
    private func startPerformanceReview(_ root: Entity) {
        guard ProcessInfo.processInfo.arguments.contains("--rewind-performance-run") else { return }
        performanceReviewTask?.cancel()
        performanceReviewTask = Task { @MainActor in
            // RealityView commits its content after the make closure returns.
            while root.scene == nil && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let scene = root.scene, !Task.isCancelled else { return }
            print("PERFORMANCE REVIEW: starting")
            var samples: [String: [Double]] = [:]
            var label = "warmup"
            var lastDelivery = CACurrentMediaTime()
            let reviewBegan = lastDelivery
            let subscription = scene.subscribe(to: SceneEvents.Update.self) { event in
                let now = CACurrentMediaTime()
                let deliveredInterval = (now - lastDelivery) * 1000
                lastDelivery = now
                if deliveredInterval > 33.34 && label != "warmup" {
                    print("PERF stall: \(label), \(now - reviewBegan)s, \(deliveredInterval) ms")
                }
                if label != "warmup" {
                    samples[label + "_scene", default: []].append(event.deltaTime * 1000)
                    samples[label + "_delivery", default: []].append(deliveredInterval)
                    if label == "travel" {
                        let phase = RouteNavigationSystem.isPresentingRoute ? "travel_motion" : "travel_setup"
                        samples[phase + "_delivery", default: []].append(deliveredInterval)
                    }
                }
            }
            defer { subscription.cancel() }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            label = "home"
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            label = "preparation"
            if !ProcessInfo.processInfo.arguments.contains("--rewind-performance-baseline") {
                ActivityPropManager.prefetch(.breakfast)
            }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            label = "travel"
            startMemory(.breakfast)
            let deadline = CACurrentMediaTime() + 120
            while experienceStage == .travellingToMemory && CACurrentMediaTime() < deadline && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            label = "warmup"
            try? await Task.sleep(for: .seconds(3))
            label = "breakfast"
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            label = "warmup"
            let baseline = ProcessInfo.processInfo.arguments.contains("--rewind-performance-baseline")
            var result: [String: Any] = ["baseline": baseline, "recordedAt": Date().description,
                "scope": "Scene update and app callback delivery, not GPU presentation"]
            for (stage, values) in samples where !values.isEmpty {
                let sorted = values.sorted()
                var metrics: [String: Double] = [:]
                metrics["frames"] = Double(values.count)
                metrics["mean_ms"] = values.reduce(0, +) / Double(values.count)
                metrics["median_ms"] = sorted[sorted.count / 2]
                let percentileIndex = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
                metrics["p95_ms"] = sorted[percentileIndex]
                metrics["max_ms"] = sorted.last!
                metrics["over_33ms"] = Double(values.filter { $0 > 33.34 }.count)
                result[stage] = metrics
            }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
               let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? data.write(to: documents.appendingPathComponent(baseline ? "PerformanceReview-before.json" : "PerformanceReview-after.json"))
                print("PERFORMANCE REVIEW: " + String(decoding: data, as: UTF8.self))
                if ProcessInfo.processInfo.arguments.contains("--rewind-interaction-review") {
                    let checks = await activityInteraction.runBreakfastRegressionReview()
                    if let report = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) {
                        try? report.write(to: documents.appendingPathComponent("BreakfastInteractionReview.json"))
                        print("INTERACTION REVIEW: " + String(decoding: report, as: UTF8.self))
                    }
                    if ProcessInfo.processInfo.arguments.contains("--rewind-completion-review") {
                        // Ephemeral layout preview only; never save a synthetic session.
                        completedSession = MemorySession(route: .breakfast, completedAt: Date(),
                            durationSeconds: 60, maximumReachCentimetres: 0, comfortableReachCentimetres: 0,
                            wristRotationDegrees: 0, completedInteractions: 3, totalInteractions: 3,
                            leftHandInteractions: 0, rightHandInteractions: 0)
                        completionPose = completionTransform(for: .breakfast)
                        experienceStage = .completion
                        return
                    }
                    // Exercise the real doorway transition, rather than changing
                    // a room's light in isolation or assuming the fade was visible.
                    if let house = activeHouseEntity, let sun = house.findEntity(named: "SunLight_Left") {
                        var intensities: [Float] = []
                        let fadeProbe = scene.subscribe(to: SceneEvents.Update.self) { _ in
                            if let intensity = sun.components[DirectionalLightComponent.self]?.intensity {
                                intensities.append(intensity)
                            }
                        }
                        beginMemoryFromCompletion(.playingBall)
                        let deadline = CACurrentMediaTime() + 120
                        while experienceStage == .travellingToMemory && CACurrentMediaTime() < deadline && !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                        try? await Task.sleep(for: .seconds(2))
                        fadeProbe.cancel()
                        let deltas = zip(intensities, intensities.dropFirst()).map { abs($0 - $1) }
                        let fadeResult: [String: Any] = [
                            "initial_intensity": intensities.first ?? -1,
                            "final_intensity": intensities.last ?? -1,
                            "intermediate_samples": intensities.filter { $0 > 80_000 * 0.92 * 0.44 * InteriorLightingManager.radianceScale + 1
                                && $0 < 72_000 * InteriorLightingManager.radianceScale - 1 }.count,
                            "maximum_frame_step": deltas.max() ?? -1,
                            "activity_reached": experienceStage == .activity
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: fadeResult, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: documents.appendingPathComponent("OutdoorFadeReview.json"))
                            print("OUTDOOR FADE REVIEW: " + String(decoding: data, as: UTF8.self))
                        }
                        let ballChecks = await activityInteraction.runBallRegressionReview()
                        if let data = try? JSONSerialization.data(withJSONObject: ballChecks, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: documents.appendingPathComponent("BallInteractionReview.json"))
                            print("BALL INTERACTION REVIEW: " + String(decoding: data, as: UTF8.self))
                        }
                        // Also verify the requested Home-to-Ball route from
                        // its real start, after returning with the production path.
                        beginReturnHome()
                        let returnDeadline = CACurrentMediaTime() + 120
                        while experienceStage == .returningHome && CACurrentMediaTime() < returnDeadline && !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                        guard experienceStage == .home, !Task.isCancelled else { return }
                        startMemory(.playingBall)
                        let outboundDeadline = CACurrentMediaTime() + 120
                        while experienceStage == .travellingToMemory && CACurrentMediaTime() < outboundDeadline && !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                        guard experienceStage == .activity, !Task.isCancelled else { return }
                        beginMemoryFromCompletion(.christmasTree)
                    }
                }
            }
        }
    }
    #endif

    private func startMemory(_ route: MemoryRoute) {
        activeRoute = route
        activityStepIndex = 0
        activityCompletedStepCount = 0
        completedSession = nil
        sessionRecorder = MemorySessionRecorder(route: route)
        isHomeInterfaceVisible = false
        experienceStage = .travellingToMemory

        preloadActivity(route)

        travel(markerNames: route.markerNames, label: route.title) {
            beginActivity()
        }
    }

    private func beginMemoryFromCompletion(_ nextRoute: MemoryRoute) {
        guard experienceStage == .completion,
              let session = completedSession, session.isComplete else { return }
        let currentRoute = session.route
        guard currentRoute != nextRoute,
              let markerNames = completionRouteMarkerNames(from: currentRoute, to: nextRoute) else {
            return
        }

        activityInteraction.suspendForDeparture()
        handReachMonitor.stop()
        routeNavigationTask?.cancel()

        // Retain the finished pose until travel actually starts.
        christmasPropsRoot = nil
        ornamentRestWorldPositions = [:]
        christmasDragActive = false
        christmasDraggedEntity = nil
        christmasDragStartWorldPosition = .zero
        christmasActiveDragOrnamentIndex = nil
        christmasIsDragWithinDropZone = false
        christmasHasDraggedForPlacement = false
        christmasPlacedOrnamentIndices = []

        playingBallPropsRoot = nil
        playingBallEntity = nil
        playingBallControllers = []
        playingBallThrowCount = 0
        playingBallIsPaused = false
        playingBallIsReturning = false

        activeRoute = nextRoute
        activityStepIndex = 0
        activityCompletedStepCount = 0
        completedSession = nil
        sessionRecorder = MemorySessionRecorder(route: nextRoute)
        experienceStage = .travellingToMemory

        activityPropsTask?.cancel()
        activityPropsTask = nil
        travel(markerNames: markerNames, label: "Continue to \(nextRoute.title)",
               fadeDepartingProps: true, prepareOnArrival: nextRoute) {
            beginActivity()
        }
    }

    private func completionRouteMarkerNames(from currentRoute: MemoryRoute, to nextRoute: MemoryRoute) -> [String]? {
        switch (currentRoute, nextRoute) {
        case (.christmasTree, .playingBall):
            ["Location_Living Room", "RouteMarker 6", "Location_Outdoor"]
        case (.christmasTree, .breakfast):
            ["Location_Living Room", "RouteMarker 4", "RouteMarker 5", "Location_Dining Room"]
        case (.playingBall, .christmasTree):
            ["Location_Outdoor", "RouteMarker 6", "Location_Living Room"]
        case (.playingBall, .breakfast):
            ["Location_Outdoor", "RouteMarker 6", "Location_Living Room", "RouteMarker 4", "RouteMarker 5", "Location_Dining Room"]
        case (.breakfast, .christmasTree):
            ["Location_Dining Room", "RouteMarker 5", "RouteMarker 4", "Location_Living Room"]
        case (.breakfast, .playingBall):
            ["Location_Dining Room", "RouteMarker 5", "RouteMarker 4", "RouteMarker 6", "Location_Outdoor"]
        default:
            nil
        }
    }

    private func preloadActivity(_ route: MemoryRoute) {
        activitySetupTask?.cancel()
        activityPropsTask?.cancel()
        Task {
            guard activeRoute == route, experienceStage == .travellingToMemory else { return }
            await handReachMonitor.prepareTracking()
        }
        guard let house = activeHouseEntity else { return }
        activityPropsTask = Task { @MainActor in
            // Preserve the completed pose until it is fully invisible. Resetting
            // cereal/ornaments first makes them jump back during the departure fade.
            await ActivityPropManager.finishDepartureFades()
            guard !Task.isCancelled, activeRoute == route else { return nil }
            activityInteraction.cancel()
            let isCachedChristmas = route == .christmasTree && house.findEntity(named: "REWindProps_" + route.rawValue) != nil
            let props = await ActivityPropManager.showProps(for: route, in: house)
            guard !Task.isCancelled, activeRoute == route else { return nil }
            if route == .breakfast, let props { activityInteraction.prewarmBreakfast(in: props) }
            // The first render commit of new props otherwise shares a frame
            // with departure. Let the scene consume those changes before moving.
            if !isCachedChristmas, let scene = house.scene {
                var committedUpdates = 0
                let subscription = scene.subscribe(to: SceneEvents.Update.self) { _ in committedUpdates += 1 }
                defer { subscription.cancel() }
                let deadline = CACurrentMediaTime() + 1
                while committedUpdates < 2 && CACurrentMediaTime() < deadline && !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(8)) } catch { return nil }
                }
            }
            return props
        }
    }

    private func beginActivity() {
        guard let route = activeRoute else { return }
        experienceStage = .activity
        activitySetupTask = Task { @MainActor in
            guard let props = await activityPropsTask?.value,
                  !Task.isCancelled, activeRoute == route, experienceStage == .activity else { return }
            if route == .christmasTree { christmasPropsRoot = props }
            activityInteraction.viewerPose = {
                // Head-anchor transforms are opaque; ARKit supplies the actual
                // tracked pose for moving an object into the viewer’s reach.
                if lightingWorldTracking.state == .running,
                   let device = lightingWorldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), device.isTracked {
                    return Transform(matrix: device.originFromAnchorTransform)
                }
                return Transform(translation: [0, 1.6, 0])
            }
            guard !Task.isCancelled, experienceStage == .activity, activeRoute == route else { return }
            activityInteraction.prepare(route: route, root: props, onProgress: { index, count in
                withAnimation(.easeInOut(duration: 0.32)) {
                    activityStepIndex = index
                    activityCompletedStepCount = count
                }
            }, onComplete: { finishActivity() })
            activityInteraction.onMovement = { distance, rotation, seconds in
                sessionRecorder?.recordObjectMovement(centimetres: distance, degrees: rotation, activeSeconds: seconds)
            }
            activityInteraction.onSound = { name, entity, active in
                soundscape.effect(name, on: entity, active: active)
            }
            handReachMonitor.onHandPose = { sample in
                guard experienceStage == .activity else { return }
                activityInteraction.updateHandGrasp(sample)
            }
            await handReachMonitor.start { event in
                guard experienceStage == .activity else { return }
                sessionRecorder?.recordInteraction(reachCentimetres: event.extensionCentimetres,
                    usedLeftHand: event.usedLeftHand, usedRightHand: event.usedRightHand)
            }
            // Input and hand following must be ready independently of audio decoding.
            guard !Task.isCancelled, experienceStage == .activity, activeRoute == route else { return }
            if let house = activeHouseEntity { await soundscape.enter(route, house: house, props: props) }
        }
    }

    private func finishActivity() {
        guard let sessionRecorder else {
            return
        }

        // The monitor accumulates rotation continuously, so the total is taken
        // once here rather than added per interaction.
        handReachMonitor.stop()
        sessionRecorder.recordWristRotation(degrees: handReachMonitor.wristRotationDegrees)
        sessionRecorder.recordManualCompletions(activityCompletedStepCount)

        let session = sessionRecorder.makeSession()
        guard session.isComplete, session.route == activeRoute else { return }
        sessionStore.record(session)
        dashboardRoute = session.route
        completedSession = session
        completionPose = completionTransform(for: activeRoute)
        soundscape.completeActivity(on: activityHeadAnchor)
        self.sessionRecorder = nil

        withAnimation(.easeInOut(duration: 0.5)) {
            experienceStage = .completion
        }
    }

    private func completionTransform(for route: MemoryRoute?) -> Transform {
        let eye = activityInteraction.viewerPose()
        // Finishing a stir often happens while looking down into the bowl.
        // Keep the panel upright at eye height rather than pitching it into the
        // tabletop with that last head pose. The completed panel stays fixed.
        let forward = eye.rotation.act(SIMD3<Float>(0, 0, -1))
        let horizontal = SIMD3<Float>(forward.x, 0, forward.z)
        let yaw = simd_length(horizontal) > 0.001
            ? atan2(-horizontal.x, -horizontal.z) : 0
        let upright = Transform(rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]),
                                translation: eye.translation)
        let completionEye = route == .breakfast ? upright : eye
        let completionOffset: SIMD3<Float> = route == .breakfast
            ? [0.025, 0.015, -0.82] : [0.025, -0.015, -0.60]
        return Transform(matrix: completionEye.matrix * Transform(scale: SIMD3(repeating: 0.65),
            translation: completionOffset).matrix)
    }

    // MARK: - Stage 3: return home

    private func beginReturnHome() {
        guard let activeRoute else {
            returnToHomeScreen()
            return
        }

        activitySetupTask?.cancel()
        activityPropsTask?.cancel()
        activityInteraction.suspendForDeparture()
        handReachMonitor.stop()
        experienceStage = .returningHome
        travel(markerNames: activeRoute.returnMarkerNames, label: "Return from \(activeRoute.title)",
               fadeDepartingProps: true) {
            // Their final pose was retained until the departure fade finished.
            activityInteraction.cancel()

            if let house = activeHouseEntity { Task { await soundscape.enter(nil, house: house, props: nil) } }
            sceneLightBudget?.restoreBedroomLighting()
            // Stage 4 begins on arrival back in the bedroom.
            withAnimation(.easeInOut(duration: 0.5)) {
                if completedSession != nil && sessionStore.hasCompletedAllMemories {
                    experienceStage = .album
                    isHomeInterfaceVisible = false
                    shouldShowMemorySelectionOnReturn = false
                } else {
                    experienceStage = .home
                    isHomeInterfaceVisible = true
                    shouldShowMemorySelectionOnReturn = completedSession != nil && !sessionStore.completedRoutes.isEmpty
                }
            }
        }
    }

    private func restartFromBedroom() {
        // Restore the launch layout before making it visible. A hidden orb can
        // otherwise retain the memory position and animate through the button.
        if let homeOrbEntity { HomeGlassOrb.resetToLaunch(homeOrbEntity) }
        homeResetID += 1
        homeUIState = .launch
        let alreadyInBedroom = experienceStage == .album || experienceStage == .dashboard || experienceStage == .home
        sessionStore.resetCurrentRun()
        dashboardRoute = nil
        sessionRecorder = nil
        completedSession = nil
        if alreadyInBedroom { returnToHomeScreen() }
        else { beginReturnHome() }
    }

    private func returnToHomeScreen() {
        if let house = activeHouseEntity { Task { await soundscape.enter(nil, house: house, props: nil) } }
        activitySetupTask?.cancel()
        activityPropsTask?.cancel()
        activityInteraction.cancel()
        handReachMonitor.stop()

        // Also covers the direct exits (the HUD's Home shortcut, and the guard in
        // beginReturnHome) which skip the return walk entirely.
        if let houseEntity = activeHouseEntity {
            ActivityPropManager.hideAllProps(in: houseEntity)
        }

        christmasPropsRoot = nil
        ornamentRestWorldPositions = [:]
        christmasDragActive = false
        christmasDraggedEntity = nil
        christmasDragStartWorldPosition = .zero
        christmasActiveDragOrnamentIndex = nil
        christmasIsDragWithinDropZone = false
        christmasHasDraggedForPlacement = false
        christmasPlacedOrnamentIndices = []

        playingBallPropsRoot = nil
        playingBallEntity = nil
        playingBallControllers = []
        playingBallThrowCount = 0
        playingBallIsPaused = false
        playingBallIsReturning = false

        sceneLightBudget?.restoreBedroomLighting()
        activeRoute = nil
        completedSession = nil
        activityStepIndex = 0
        activityCompletedStepCount = 0

        withAnimation(.easeInOut(duration: 0.45)) {
            experienceStage = .home
            isHomeInterfaceVisible = true
            shouldShowMemorySelectionOnReturn = false
        }
    }

    // MARK: - Shared travel

    private func travel(markerNames: [String], label: String, fadeDepartingProps: Bool = false,
                        prepareOnArrival: MemoryRoute? = nil, onArrival: @escaping () -> Void) {
        routeNavigationTask?.cancel()

        guard let environmentRoot = activeEnvironmentRoot, let houseEntity = activeHouseEntity else {
            print("❌ ROUTE ABORTED: EnvironmentRoot or REWind_House_Master is unavailable")
            return
        }

        suppressStairwellDuringTravel = !markerNames.contains {
            let name = $0.replacingOccurrences(of: "_", with: " ")
            return name == "Location Bedroom" || name == "RouteMarker 1"
        }
        soundscape.beginTravel()
        routeNavigationTask = Task { @MainActor in
            // Finish model decoding and renderer preparation before moving the
            // viewer. Loading large activity models during a turn causes hitches.
            _ = await activityPropsTask?.value
            if let next = prepareOnArrival { await ActivityPropManager.prepareForTravel(next) }
            await soundscape.prepareOutdoorAmbience(house: houseEntity)
            guard !Task.isCancelled else { return }
            await RouteNavigationSystem.navigate(
                markerNames: markerNames,
                routeLabel: label,
                environmentRoot: environmentRoot,
                houseEntity: houseEntity,
                onDeparture: {
                    if fadeDepartingProps { ActivityPropManager.hideAllProps(in: houseEntity) }
                },
                prepareArrival: {
                    guard let next = prepareOnArrival, !Task.isCancelled else { return }
                    // Decode and attach the next activity only while fully covered.
                    preloadActivity(next)
                    _ = await activityPropsTask?.value
                }
            )

            guard !Task.isCancelled else {
                return
            }

            suppressStairwellDuringTravel = false
            onArrival()
        }
    }

    private func makeAlignedEnvironmentRoot(containing houseEntity: Entity) -> Entity {
        // EnvironmentRoot is the movable parent; the imported house remains unchanged inside it.
        let environmentRoot = Entity()
        environmentRoot.name = environmentRootName
        environmentRoot.addChild(houseEntity)

        // Location_Bedroom is the camera/marker used as the starting viewpoint reference.
        guard let startingLocation = houseEntity.findEntity(named: startingLocationName) else {
            print("Error: Could not find \(startingLocationName) in \(houseEntityName). EnvironmentRoot remains at identity.")
            return environmentRoot
        }

        // Apply the bedroom viewpoint offsets, then invert the transform so the house
        // moves around the immersive origin instead of moving the viewer. The offsets
        // are applied in marker-local space and must stay in step with the ones the
        // route uses, or the return walk finishes somewhere other than the spawn.
        let markerWorldTransform = startingLocation.transformMatrix(relativeTo: nil)
        let spawnOffset = SpawnOffsets.offset(for: startingLocationName)
        let adjustedViewTransform = SpawnOffsets.viewMatrix(
            markerMatrix: markerWorldTransform,
            markerName: startingLocationName
        )
        let markerTransform = Transform(matrix: markerWorldTransform)
        environmentRoot.setTransformMatrix(SceneViewerCalibration.matrix * simd_inverse(adjustedViewTransform), relativeTo: nil)
        #if DEBUG
        // Opt-in reverse view used to validate window transmission and shadows.
        if ProcessInfo.processInfo.arguments.contains("--rewind-window-review") {
            let yaw = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
            environmentRoot.position = yaw.act(environmentRoot.position) + SIMD3<Float>(0, 0, -1.5)
            environmentRoot.orientation = yaw * environmentRoot.orientation
        }
        #endif
        let finalRootTransform = Transform(matrix: environmentRoot.transformMatrix(relativeTo: nil))

        print("""
        \(startingLocationName) world position: \(format(markerTransform.translation))
        \(startingLocationName) world orientation: \(format(markerTransform.rotation))
        Viewpoint offset: forward \(spawnOffset.forward) m, down \(spawnOffset.down) m, lateral \(spawnOffset.lateral) m
        Spawn world position: \(format(Transform(matrix: adjustedViewTransform).translation))
        Final \(environmentRootName) position: \(format(finalRootTransform.translation))
        Final \(environmentRootName) orientation: \(format(finalRootTransform.rotation))
        """)

        return environmentRoot
    }

    // Debug string helpers for readable transform logging.
    private func format(_ vector: SIMD3<Float>) -> String {
        "x=\(vector.x), y=\(vector.y), z=\(vector.z)"
    }

    private func format(_ rotation: simd_quatf) -> String {
        "ix=\(rotation.imag.x), iy=\(rotation.imag.y), iz=\(rotation.imag.z), r=\(rotation.real)"
    }
}

// MemoryRoute, its marker lists and its activity step scripts live in
// MemoryExperience.swift so the HUD, dashboard and navigation share one source.

private enum ImmersiveContentLoadError: LocalizedError {
    case missingHouseInScene(String)

    var errorDescription: String? {
        switch self {
        case .missingHouseInScene(let name):
            "Scene loaded, but \(name) was not found inside it."
        }
    }
}

@MainActor
private enum RouteNavigationSystem {
    private(set) static var isPresentingRoute = false
    static weak var travelHeadAnchor: AnchorEntity?
    static var isRelocatingUnderCover = false
    // Shorten visible travel and its duration together to preserve the pace.
    private static let visibleTravelScale: Double = 0.8
    private struct ClearanceBounds: Component {
        var bounds: BoundingBox
    }

    // Batching moves render meshes out of their authored parents. Keep the
    // measured navigation bounds before that happens, without adding draw calls.
    static func cacheClearanceBounds(in house: Entity) {
        for name in ["Stair_fence", "Counter_top_001", "Couch"] {
            guard let entity = house.findEntity(named: name) else { continue }
            entity.components.set(ClearanceBounds(bounds: entity.visualBounds(relativeTo: house)))
        }
    }
    private enum Constants {
        static let minimumSegmentDuration: TimeInterval = 1.2
        static let maximumSegmentDuration: TimeInterval = 3.0
        static let secondsPerMeter: Float = 0.75
        static let animationFrameDurationNanoseconds: UInt64 = 16_000_000
        static let movementEpsilon: Float = 0.001
    }

    // `markerNames` is the ordered path to walk. Stage 2 passes the outbound
    // list, Stage 3 passes the reversed list, so both directions share this code.
    static func navigate(
        markerNames: [String],
        routeLabel: String,
        environmentRoot: Entity,
        houseEntity: Entity,
        onDeparture: () -> Void = {},
        prepareArrival: () async -> Void = {}
    ) async {
        guard validateSceneReferences(environmentRoot: environmentRoot, houseEntity: houseEntity) else {
            return
        }

        guard let waypoints = resolveWaypoints(
            markerNames: markerNames,
            environmentRoot: environmentRoot,
            houseEntity: houseEntity
        ) else {
            return
        }

        print("🚶 ROUTE START: \(routeLabel)")
        verifyStartingTarget(waypoints: waypoints, environmentRoot: environmentRoot)

        for waypoint in waypoints {
            print("➡️ ROUTE WAYPOINT: \(waypoint.requestedMarkerName)")
            print("Target EnvironmentRoot transform: position \(format(waypoint.environmentTransform.translation)), orientation \(format(waypoint.environmentTransform.rotation))")
        }

        await animateContinuousRoute(waypoints, environmentRoot: environmentRoot,
                                     onDeparture: onDeparture, prepareArrival: prepareArrival)
        guard !Task.isCancelled else { return }

        if let destination = waypoints.last {
            environmentRoot.setTransformMatrix(destination.environmentMatrix, relativeTo: nil)
            print("✅ ROUTE COMPLETE: \(destination.requestedMarkerName)")
        }
    }

    private struct RouteWaypoint {
        let requestedMarkerName: String
        let actualMarkerName: String
        let markerHouseMatrix: simd_float4x4
        // Where the viewer stands at this marker, in EnvironmentRoot-local space.
        // This is the pose that gets interpolated; the root matrix below is simply
        // its inverse, and inverses must never be blended directly (see
        // interpolateEnvironmentRoot).
        let viewMatrix: simd_float4x4
        let viewTransform: Transform
        let environmentMatrix: simd_float4x4
        let environmentTransform: Transform
    }

    private static func resolveWaypoints(
        markerNames: [String],
        environmentRoot: Entity,
        houseEntity: Entity
    ) -> [RouteWaypoint]? {
        var waypoints: [RouteWaypoint] = []
        let houseLocalMatrix = houseEntity.transformMatrix(relativeTo: environmentRoot)
        let lookup = makeEntityLookup(from: houseEntity)
        let normalizedLookup = makeNormalizedEntityLookup(from: lookup)

        for markerName in markerNames {
            guard let resolvedMarker = resolveMarker(
                requestedName: markerName,
                exactLookup: lookup,
                normalizedLookup: normalizedLookup,
                houseEntity: houseEntity
            ) else {
                print("❌ ROUTE MARKER NOT FOUND: \(markerName)")
                printAvailableNavigationEntities(from: lookup)
                return nil
            }

            print("""
            ✅ ROUTE MARKER RESOLVED
            requested: [\(markerName)]
            actual: [\(resolvedMarker.name)]
            """)

            let markerHouseMatrix = resolvedMarker.transformMatrix(relativeTo: houseEntity)
            let viewMatrix = targetViewMatrix(
                houseLocalMatrix: houseLocalMatrix,
                markerHouseMatrix: markerHouseMatrix,
                markerName: markerName
            )
            let targetMatrix = SceneViewerCalibration.matrix * simd_inverse(viewMatrix)

            waypoints.append(RouteWaypoint(
                requestedMarkerName: markerName,
                actualMarkerName: resolvedMarker.name,
                markerHouseMatrix: markerHouseMatrix,
                viewMatrix: viewMatrix,
                viewTransform: Transform(matrix: viewMatrix),
                environmentMatrix: targetMatrix,
                environmentTransform: Transform(matrix: targetMatrix)
            ))
        }

        // Enter the bedroom doorway through its clear centre. The direct diagonal
        // clips the jamb; this bend passes the measured opening in both directions.
        var bedroomSafe: [RouteWaypoint] = []
        for waypoint in waypoints {
            if let previous = bedroomSafe.last,
               Set([previous.actualMarkerName, waypoint.actualMarkerName]) == Set(["Location_Bedroom", "RouteMarker_1"]) {
                let start = simd_inverse(houseLocalMatrix) * SIMD4<Float>(previous.viewTransform.translation, 1)
                let end = simd_inverse(houseLocalMatrix) * SIMD4<Float>(waypoint.viewTransform.translation, 1)
                let point = houseLocalMatrix * SIMD4<Float>(-6.45, 47.25, (start.z + end.z) / 2, 1)
                var view = previous.viewTransform
                view.translation = [point.x, point.y, point.z]
                view.rotation = simd_slerp(previous.viewTransform.rotation, waypoint.viewTransform.rotation, 0.5)
                let matrix = SceneViewerCalibration.matrix * simd_inverse(view.matrix)
                bedroomSafe.append(RouteWaypoint(requestedMarkerName: "Bedroom clearance", actualMarkerName: "Bedroom clearance",
                    markerHouseMatrix: matrix_identity_float4x4, viewMatrix: view.matrix, viewTransform: view,
                    environmentMatrix: matrix, environmentTransform: Transform(matrix: matrix)))
            }
            bedroomSafe.append(waypoint)
        }
        waypoints = bedroomSafe

        // The direct outdoor-marker/stair-marker diagonal cuts the living-room
        // partition. Pass through its measured opening (x -4.0 ... -2.1), then
        // round into the stair corridor. Use the same clearance in reverse.
        var doorwaySafe: [RouteWaypoint] = []
        for waypoint in waypoints {
            if let previous = doorwaySafe.last,
               Set([previous.actualMarkerName, waypoint.actualMarkerName]) == Set(["RouteMarker_6", "RouteMarker_3"]) {
                let start = simd_inverse(houseLocalMatrix) * SIMD4<Float>(previous.viewTransform.translation, 1)
                let end = simd_inverse(houseLocalMatrix) * SIMD4<Float>(waypoint.viewTransform.translation, 1)
                let point = houseLocalMatrix * SIMD4<Float>(-3.0, 41.54, min(start.z, end.z), 1)
                var view = previous.viewTransform
                view.translation = [point.x, point.y, point.z]
                view.rotation = simd_slerp(previous.viewTransform.rotation, waypoint.viewTransform.rotation, 0.5)
                let matrix = SceneViewerCalibration.matrix * simd_inverse(view.matrix)
                doorwaySafe.append(RouteWaypoint(requestedMarkerName: "Stair doorway clearance", actualMarkerName: "Stair doorway clearance",
                    markerHouseMatrix: matrix_identity_float4x4, viewMatrix: view.matrix, viewTransform: view,
                    environmentMatrix: matrix, environmentTransform: Transform(matrix: matrix)))
            }
            doorwaySafe.append(waypoint)
        }
        waypoints = doorwaySafe

        // Pass through the living-room porch doorway before turning outside.
        // A sofa-only clearance point cut through the projecting exterior wall.
        // These two points keep the curve inside the measured door opening and
        // delay the westward bend until beyond the wall, in both directions.
        if let sofa = houseEntity.findEntity(named: "Couch") {
            let bounds = sofa.components[ClearanceBounds.self]?.bounds
                ?? sofa.visualBounds(relativeTo: houseEntity)
            var sofaSafe: [RouteWaypoint] = []
            for waypoint in waypoints {
                if let previous = sofaSafe.last,
                   Set([previous.actualMarkerName, waypoint.actualMarkerName]) == Set(["RouteMarker_6", "Location_Outdoor"]) {
                    let start = simd_inverse(houseLocalMatrix) * SIMD4<Float>(previous.viewTransform.translation, 1)
                    let end = simd_inverse(houseLocalMatrix) * SIMD4<Float>(waypoint.viewTransform.translation, 1)
                    let corridorX = max(bounds.max.x + 1.65, -3.10)
                    var points: [SIMD2<Float>] = [[corridorX, 36.55], [corridorX, 34.15]]
                    if previous.actualMarkerName == "Location_Outdoor" { points.reverse() }
                    for (index, coordinate) in points.enumerated() {
                        let fraction = Float(index + 1) / 3
                        let point = houseLocalMatrix * SIMD4<Float>(coordinate.x, coordinate.y,
                            start.z + (end.z - start.z) * fraction, 1)
                        var view = previous.viewTransform
                        view.translation = [point.x, point.y, point.z]
                        view.rotation = simd_slerp(previous.viewTransform.rotation, waypoint.viewTransform.rotation, fraction)
                        let matrix = SceneViewerCalibration.matrix * simd_inverse(view.matrix)
                        sofaSafe.append(RouteWaypoint(requestedMarkerName: "Sofa clearance", actualMarkerName: "Sofa clearance",
                            markerHouseMatrix: matrix_identity_float4x4, viewMatrix: view.matrix, viewTransform: view,
                            environmentMatrix: matrix, environmentTransform: Transform(matrix: matrix)))
                    }
                }
                sofaSafe.append(waypoint)
            }
            waypoints = sofaSafe
        }

        // Round the west end of the retained railing before descending. The
        // old diagonal crossed within a few centimetres of the rail end.
        if let railing = houseEntity.findEntity(named: "Stair_fence") {
            let bounds = railing.components[ClearanceBounds.self]?.bounds
                ?? railing.visualBounds(relativeTo: houseEntity)
            var safe: [RouteWaypoint] = []
            for waypoint in waypoints {
                if let previous = safe.last,
                   Set([previous.actualMarkerName, waypoint.actualMarkerName]) == Set(["RouteMarker_1", "RouteMarker_2"]) {
                    let start = simd_inverse(houseLocalMatrix) * SIMD4<Float>(previous.viewTransform.translation, 1)
                    let end = simd_inverse(houseLocalMatrix) * SIMD4<Float>(waypoint.viewTransform.translation, 1)
                    let point = houseLocalMatrix * SIMD4<Float>(bounds.min.x - 0.75, bounds.max.y + 0.70, (start.z + end.z) / 2, 1)
                    var view = previous.viewTransform
                    view.translation = [point.x, point.y, point.z]
                    view.rotation = simd_slerp(previous.viewTransform.rotation, waypoint.viewTransform.rotation, 0.5)
                    let matrix = SceneViewerCalibration.matrix * simd_inverse(view.matrix)
                    safe.append(RouteWaypoint(requestedMarkerName: "Stair clearance", actualMarkerName: "Stair clearance",
                        markerHouseMatrix: matrix_identity_float4x4, viewMatrix: view.matrix, viewTransform: view,
                        environmentMatrix: matrix, environmentTransform: Transform(matrix: matrix)))
                }
                safe.append(waypoint)
            }
            waypoints = safe
        }

        // The direct 4→5 segment crosses the kitchen peninsula. Walk around
        // its west edge into the open kitchen, not the wall on the east.
        // The entry bend also clears the end of the L-shaped counter.
        if let counter = houseEntity.findEntity(named: "Counter_top_001") {
            let bounds = counter.components[ClearanceBounds.self]?.bounds
                ?? counter.visualBounds(relativeTo: houseEntity)
            var safe: [RouteWaypoint] = []
            for waypoint in waypoints {
                if let previous = safe.last,
                   Set([previous.actualMarkerName, waypoint.actualMarkerName]) == Set(["RouteMarker_4", "RouteMarker_5"]) {
                    let forward = previous.actualMarkerName == "RouteMarker_4"
                    let kitchenPath: [SIMD2<Float>] = [
                        [bounds.min.x - 0.80, bounds.min.y - 0.80],
                        [bounds.min.x - 0.80, bounds.max.y + 0.80]
                    ]
                    let clearancePoints = forward ? kitchenPath : Array(kitchenPath.reversed())
                    let start = simd_inverse(houseLocalMatrix) * SIMD4<Float>(previous.viewTransform.translation, 1)
                    let end = simd_inverse(houseLocalMatrix) * SIMD4<Float>(waypoint.viewTransform.translation, 1)
                    for (index, clearance) in clearancePoints.enumerated() {
                        let t = Float(index + 1) / Float(clearancePoints.count + 1)
                        let point = houseLocalMatrix * SIMD4<Float>(clearance.x, clearance.y, start.z + (end.z - start.z) * t, 1)
                        var view = previous.viewTransform
                        view.translation = [point.x, point.y, point.z]
                        view.rotation = simd_slerp(previous.viewTransform.rotation, waypoint.viewTransform.rotation, t)
                        let matrix = SceneViewerCalibration.matrix * simd_inverse(view.matrix)
                        safe.append(RouteWaypoint(requestedMarkerName: "Kitchen clearance", actualMarkerName: "Kitchen clearance",
                            markerHouseMatrix: matrix_identity_float4x4, viewMatrix: view.matrix, viewTransform: view,
                            environmentMatrix: matrix, environmentTransform: Transform(matrix: matrix)))
                    }
                }
                safe.append(waypoint)
            }
            waypoints = safe
        }
        return waypoints
    }

    // The viewer pose at a marker, expressed in EnvironmentRoot-local space. The
    // root transform that puts the viewer there is its inverse, taken by the caller.
    private static func targetViewMatrix(
        houseLocalMatrix: simd_float4x4,
        markerHouseMatrix: simd_float4x4,
        markerName: String
    ) -> simd_float4x4 {
        let markerRootLocalMatrix = houseLocalMatrix * markerHouseMatrix

        return SpawnOffsets.viewMatrix(
            markerMatrix: markerRootLocalMatrix,
            markerName: markerName
        )
    }

    private static func validateSceneReferences(environmentRoot: Entity, houseEntity: Entity) -> Bool {
        let rootTransform = Transform(matrix: environmentRoot.transformMatrix(relativeTo: nil))
        print("""
        ✅ NAVIGATION ENVIRONMENT ROOT:
        name: \(environmentRoot.name)
        parent: \(environmentRoot.parent?.name ?? "nil")
        current position: \(format(rootTransform.translation))
        current orientation: \(format(rootTransform.rotation))
        """)

        guard houseEntity.parent === environmentRoot else {
            print("❌ ROUTE ABORTED: REWind_House_Master parent is not EnvironmentRoot")
            return false
        }

        print("✅ REWind_House_Master parent matches EnvironmentRoot")
        return true
    }

    private static func verifyStartingTarget(waypoints: [RouteWaypoint], environmentRoot: Entity) {
        guard let bedroomWaypoint = waypoints.first else {
            return
        }

        let currentRootTransform = Transform(matrix: environmentRoot.transformMatrix(relativeTo: nil))
        print("""
        CURRENT ROOT:
        position: \(format(currentRootTransform.translation))
        orientation: \(format(currentRootTransform.rotation))

        BEDROOM TARGET:
        position: \(format(bedroomWaypoint.environmentTransform.translation))
        orientation: \(format(bedroomWaypoint.environmentTransform.rotation))
        """)

        let positionDelta = simd_distance(currentRootTransform.translation, bedroomWaypoint.environmentTransform.translation)
        let rotationDelta = abs(simd_dot(currentRootTransform.rotation.vector, bedroomWaypoint.environmentTransform.rotation.vector))
        if positionDelta <= Constants.movementEpsilon && rotationDelta > 0.999 {
            print("✅ CURRENT ROOT MATCHES BEDROOM TARGET")
        } else {
            print("❌ CURRENT ROOT DOES NOT MATCH BEDROOM TARGET: position delta \(positionDelta), rotation dot \(rotationDelta)")
        }
    }

    private static func animateContinuousRoute(_ waypoints: [RouteWaypoint], environmentRoot: Entity,
                                               onDeparture: () -> Void, prepareArrival: () async -> Void) async {
        guard waypoints.count > 1 else { return }
        let routePreparationBegan = CACurrentMediaTime()
        var poses = waypoints.map(\.viewTransform)
        poses[0] = Transform(matrix: simd_inverse(simd_inverse(SceneViewerCalibration.matrix) * environmentRoot.transformMatrix(relativeTo: nil)))
        var samples = [poses[0]]
        for index in 1..<(poses.count - 1) {
            let before = poses[index - 1], corner = poses[index], after = poses[index + 1]
            let incoming = simd_distance(before.translation, corner.translation)
            let outgoing = simd_distance(corner.translation, after.translation)
            // Two broad bends replace the short dogleg around the counter.
            // Use the same clearance and zero-curvature joins in both directions.
            let isKitchenCorner = waypoints[index].actualMarkerName == "Kitchen clearance"
                || (["RouteMarker_4", "RouteMarker_5"].contains(waypoints[index].actualMarkerName)
                    && (waypoints[index - 1].actualMarkerName == "Kitchen clearance"
                        || waypoints[index + 1].actualMarkerName == "Kitchen clearance"))
            let entersKitchen = waypoints[index].actualMarkerName == "RouteMarker_4"
                && waypoints[index + 1].actualMarkerName == "Kitchen clearance"
            let leavesKitchen = waypoints[index].actualMarkerName == "RouteMarker_4"
                && waypoints[index - 1].actualMarkerName == "Kitchen clearance"
            let approachesKitchen = waypoints[index].actualMarkerName == "RouteMarker_3"
                && waypoints[index + 1].actualMarkerName == "RouteMarker_4"
            let firstClearance = waypoints[index].actualMarkerName == "Kitchen clearance"
                && waypoints[index - 1].actualMarkerName == "RouteMarker_4"
            let secondClearance = waypoints[index].actualMarkerName == "Kitchen clearance"
                && waypoints[index - 1].actualMarkerName == "Kitchen clearance"
                && waypoints[index + 1].actualMarkerName == "RouteMarker_5"
            let diningApproach = waypoints[index].actualMarkerName == "RouteMarker_5"
                && waypoints[index - 1].actualMarkerName == "Kitchen clearance"
            let stairDoorway = ["Stair doorway clearance", "Sofa clearance"].contains(waypoints[index].actualMarkerName)
            let isStairCorner = stairDoorway || ["Stair clearance", "RouteMarker_2"].contains(waypoints[index].actualMarkerName)
            let broadBend = isKitchenCorner || isStairCorner || approachesKitchen
            let radius: Float = isKitchenCorner ? 1.35 : (stairDoorway ? 1.10 : (isStairCorner ? 0.70 : 0.12))
            let fraction: Float = broadBend ? 0.48 : 0.20
            // Start rounding at marker 3, before the old first kitchen bend.
            // Adjacent trim fractions leave a positive connecting straight.
            let approachBeforeEntry = entersKitchen && waypoints[index - 1].actualMarkerName == "RouteMarker_3"
            var entryLimit = radius, exitLimit = radius
            var entryShare = fraction, exitShare = fraction
            if approachesKitchen {
                entryLimit = 1.60; entryShare = 0.42
                exitLimit = 1.60; exitShare = 0.35
            } else if entersKitchen {
                entryLimit = 2.95; entryShare = approachBeforeEntry ? 0.59 : 0.86
                exitLimit = 1.80; exitShare = 0.65
            } else if leavesKitchen {
                exitLimit = 2.35; exitShare = 0.84
            } else if firstClearance {
                entryShare = 0.30; exitShare = 0.37
            } else if secondClearance {
                // Begin the dining-side bend earlier, allocating more of the
                // shared straight to it without overlapping the previous bend.
                entryLimit = 2.05; entryShare = 0.60
                exitLimit = 1.50; exitShare = 0.72
            } else if diningApproach {
                entryShare = 0.25
            }
            let entryRadius = min(entryLimit, incoming * entryShare)
            let exitRadius = min(exitLimit, outgoing * exitShare)
            guard min(entryRadius, exitRadius) > 0.002 else { samples.append(corner); continue }
            let enterFraction = entryRadius / incoming, exitFraction = exitRadius / outgoing
            var entry = corner, exit = corner
            entry.translation = simd_mix(corner.translation, before.translation, SIMD3(repeating: enterFraction))
            entry.rotation = simd_slerp(corner.rotation, before.rotation, enterFraction)
            exit.translation = simd_mix(corner.translation, after.translation, SIMD3(repeating: exitFraction))
            exit.rotation = simd_slerp(corner.rotation, after.rotation, exitFraction)
            samples.append(entry)
            let bendSamples = broadBend ? 96 : 12
            for j in 1...bendSamples {
                let t = Float(j) / Float(bendSamples), u = 1 - t
                var pose = corner
                if broadBend {
                    // Zero curvature at each straight/curve join avoids a sudden
                    // sideways acceleration while rounding the kitchen counter.
                    let p0 = entry.translation, p5 = exit.translation
                    let p1 = simd_mix(p0, corner.translation, SIMD3(repeating: 0.25))
                    let p2 = simd_mix(p0, corner.translation, SIMD3(repeating: 0.50))
                    let p4 = simd_mix(p5, corner.translation, SIMD3(repeating: 0.25))
                    let p3 = simd_mix(p5, corner.translation, SIMD3(repeating: 0.50))
                    let first = (u*u*u*u*u) * p0 + (5*u*u*u*u*t) * p1
                    let middle = (10*u*u*u*t*t) * p2 + (10*u*u*t*t*t) * p3
                    let last = (5*u*t*t*t*t) * p4 + (t*t*t*t*t) * p5
                    pose.translation = first + middle + last
                } else {
                    pose.translation = u * u * entry.translation + 2 * u * t * corner.translation + t * t * exit.translation
                }
                pose.rotation = simd_slerp(entry.rotation, exit.rotation, t)
                samples.append(pose)
            }
        }
        samples.append(poses.last!)
        var cumulative: [Float] = [0]
        for i in 1..<samples.count { cumulative.append(cumulative.last! + simd_distance(samples[i-1].translation, samples[i].translation)) }
        let length = cumulative.last!
        guard length > 0.001 else { return }
        // Only the route's endpoints ease to a stop. No stop at kitchen markers.
        var duration = max(1.2, Double(length) * 0.78)
        let ramp = min(0.85, duration / 4)
        let speed = Double(length) / (duration - ramp)
        // Bake the existing viewer path, then let RealityKit interpolate at the
        // display refresh rate. A main-actor sleep loop can miss frames while
        // activity assets are being prepared, especially on the headset.
        let calibration = SceneViewerCalibration.matrix
        let parentFromWorld = environmentRoot.parent.map {
            simd_inverse($0.transformMatrix(relativeTo: nil))
        } ?? matrix_identity_float4x4
        var segment = 1
        func viewerPose(at elapsed: Double) -> Transform {
            let distance: Double
            if elapsed < ramp { distance = speed * ramp * (pow(elapsed / ramp, 3) - 0.5 * pow(elapsed / ramp, 4)) }
            else if elapsed > duration - ramp { distance = Double(length) - speed * ramp * (pow((duration - elapsed) / ramp, 3) - 0.5 * pow((duration - elapsed) / ramp, 4)) }
            else { distance = speed * (elapsed - ramp / 2) }
            while segment < samples.count - 1 && cumulative[segment] < Float(distance) { segment += 1 }
            let span = max(0.0001, cumulative[segment] - cumulative[segment - 1])
            let t = min(1, max(0, (Float(distance) - cumulative[segment - 1]) / span))
            let a = samples[segment-1], b = samples[segment]
            let pose = Transform(scale: a.scale, rotation: simd_slerp(a.rotation, b.rotation, t),
                                 translation: simd_mix(a.translation, b.translation, SIMD3(repeating: t)))
            return pose
        }
        // Dense samples preserve the inverse-viewer path around doorways rather
        // than interpolating inverse matrices across whole route segments.
        var frameCount = max(2, Int(ceil(duration * 120)))
        var frames = (0...frameCount).map { viewerPose(at: duration * Double($0) / Double(frameCount)) }
        // Smooth only orientation in viewer space. Smoothing the inverse root
        // directly would swing the viewpoint away from the cleared route.
        // Keep the sampled viewer poses directly. Repeatedly inverting a root
        // tens of metres from the asset origin magnifies quaternion rounding
        // into tiny sideways position errors during every turn.
        let viewerFrames = frames
        let kitchenCorners = zip(waypoints, poses).compactMap { waypoint, pose in
            (waypoint.actualMarkerName == "Kitchen clearance" || waypoint.actualMarkerName == "RouteMarker_4") ? pose.translation : nil
        }
        for i in 1..<frameCount {
            let kitchenDistance = kitchenCorners.map {
                simd_distance($0, viewerFrames[i].translation)
            }.min() ?? .greatestFiniteMagnitude
            let blend = min(1, max(0, (3.1 - kitchenDistance) / 1.65))
            let kitchenBlend = blend * blend * (3 - 2 * blend)
            // Blend the turn earlier within the kitchen, without changing the
            // saved room viewpoints, other route turns, or route speed.
            func averagedRotation(window: Int) -> simd_quatf {
                let radius = min(window, min(i, frameCount - i))
                let reference = viewerFrames[i].rotation.vector
                var sum = SIMD4<Float>.zero
                var weightSum: Float = 0
                for j in (i - radius)...(i + radius) {
                    let x = Float(j - i) / Float(max(1, radius))
                    let weight = exp(-3 * x * x)
                    var quaternion = viewerFrames[j].rotation.vector
                    if simd_dot(reference, quaternion) < 0 { quaternion = -quaternion }
                    sum += quaternion * weight
                    weightSum += weight
                }
                return simd_quatf(vector: simd_normalize(sum / weightSum))
            }
            var pose = viewerFrames[i]
            let standardRotation = averagedRotation(window: 60)
            pose.rotation = kitchenBlend > 0
                ? simd_slerp(standardRotation, averagedRotation(window: 240), kitchenBlend)
                : standardRotation
            frames[i] = pose
        }
        // Retime the same cleared spatial path instead of forcing every bend
        // through at straight-line speed. Spread slowing before/after the turn.
        let sourceFrames = frames
        let sourceStep = duration / Double(frameCount)
        var turnFactors = Array(repeating: 1.0, count: frameCount)
        var beforePeak = 0.0
        for i in 0..<frameCount {
            let delta = sourceFrames[i].rotation.inverse * sourceFrames[i+1].rotation
            let degreesPerSecond = 2 * atan2(Double(simd_length(delta.imag)), abs(Double(delta.real))) * 180 / .pi / sourceStep
            beforePeak = max(beforePeak, degreesPerSecond)
            turnFactors[i] = max(1, degreesPerSecond / 22.5)
            // Translation can whip around a small corner even while looking
            // forward. Bound lateral acceleration as well as angular speed.
            let lo = max(0, i - 6), hi = min(frameCount, i + 6)
            if lo < i && hi > i {
                let incomingTime = Double(i-lo) * sourceStep
                let outgoingTime = Double(hi-i) * sourceStep
                let incomingVelocity = (sourceFrames[i].translation-sourceFrames[lo].translation) / Float(incomingTime)
                let outgoingVelocity = (sourceFrames[hi].translation-sourceFrames[i].translation) / Float(outgoingTime)
                let acceleration = Double(simd_length(outgoingVelocity-incomingVelocity)) / ((incomingTime+outgoingTime)*0.5)
                turnFactors[i] = max(turnFactors[i], sqrt(acceleration / 0.85))
            }
        }
        var pacedTimes = [0.0]
        for i in 0..<frameCount {
            var factor = turnFactors[i]
            let window = min(120, frameCount)
            for j in max(0, i-window)...min(frameCount-1, i+window) where turnFactors[j] > 1 {
                let t = 1 - Double(abs(j-i)) / Double(window)
                let influence = t*t*(3-2*t)
                factor = max(factor, 1 + (turnFactors[j]-1)*influence)
            }
            pacedTimes.append(pacedTimes.last! + sourceStep * factor)
        }
        // Keep the earlier, wider curves and their gradual speed changes, but
        // use the same faster pace on every route in both directions. A single
        // time scale preserves the joins and gradual easing through turns.
        let travelPlaybackRate = 1.4
        let pacedDuration = pacedTimes.last!
        duration = pacedDuration / travelPlaybackRate
        frameCount = max(2, Int(ceil(duration * 120)))
        var paced: [Transform] = []; paced.reserveCapacity(frameCount + 1)
        var cursor = 1
        for i in 0...frameCount {
            let time = pacedDuration * Double(i) / Double(frameCount)
            while cursor < sourceFrames.count - 1 && pacedTimes[cursor] < time { cursor += 1 }
            let t = Float(min(1, max(0, (time-pacedTimes[cursor-1]) / max(0.000001, pacedTimes[cursor]-pacedTimes[cursor-1]))))
            let a = sourceFrames[cursor-1], b = sourceFrames[cursor]
            paced.append(Transform(scale: a.scale, rotation: simd_slerp(a.rotation, b.rotation, t),
                translation: simd_mix(a.translation, b.translation, SIMD3(repeating: t))))
        }
        frames = paced
        print("ROUTE TURN PACING: peak before retiming \(beforePeak) degrees/s; target \(22.5 * travelPlaybackRate) degrees/s; duration \(duration)s")
        let visibleRanges = shortTravelRanges(waypoints: waypoints, frames: frames, duration: duration)
        // Keep the visible bedroom lane level and straight in both directions.
        // All doorway rotation remains inside the existing covered relocation.
        let bedroomTravelDistance: Float = 0.65 * Float(visibleTravelScale)
        if waypoints.first?.actualMarkerName == "Location_Bedroom", visibleRanges.count > 1,
           let departure = visibleRanges.first, let start = frames.first {
            var forward = start.rotation.act(SIMD3<Float>(0, 0, -1))
            forward.y = 0
            forward = simd_normalize(forward)
            for i in departure {
                let t = Float(i - departure.lowerBound) / Float(departure.count - 1)
                let smooth = t * t * (3 - 2 * t)
                frames[i] = Transform(scale: start.scale, rotation: start.rotation,
                    translation: start.translation + forward * (bedroomTravelDistance * smooth))
            }
        }
        if waypoints.last?.actualMarkerName == "Location_Bedroom", visibleRanges.count > 1,
           let arrival = visibleRanges.last, let destination = frames.last {
            var forward = destination.rotation.act(SIMD3<Float>(0, 0, -1))
            forward.y = 0
            forward = simd_normalize(forward)
            for i in arrival {
                let t = Float(i - arrival.lowerBound) / Float(arrival.count - 1)
                let smooth = t * t * (3 - 2 * t)
                frames[i] = Transform(scale: destination.scale, rotation: destination.rotation,
                    translation: destination.translation + forward * (bedroomTravelDistance * (1 - smooth)))
            }
        }
        if waypoints.first?.actualMarkerName == "Location_Living_Room", visibleRanges.count > 1,
           let departure = visibleRanges.first, let start = frames.first {
            // Every departure from Christmas uses the same level forward lane,
            // regardless of the next activity or a return to the bedroom.
            var forward = start.rotation.act(SIMD3<Float>(0, 0, -1))
            forward.y = 0
            forward = simd_normalize(forward)
            for i in departure {
                let t = Float(i - departure.lowerBound) / Float(departure.count - 1)
                let smooth = t * t * (3 - 2 * t)
                frames[i] = Transform(scale: start.scale, rotation: start.rotation,
                    translation: start.translation + forward * (0.45 * Float(visibleTravelScale) * smooth))
            }
        }
        if ["Location_Outdoor", "Location_Dining_Room"].contains(waypoints.first?.actualMarkerName ?? ""), visibleRanges.count > 1,
           let departure = visibleRanges.first, let start = frames.first {
            // Back out along the same level lane used on arrival.
            let distance: Float = (waypoints.first?.actualMarkerName == "Location_Outdoor" ? 0.90 : 0.55) * Float(visibleTravelScale)
            var backward = start.rotation.act(SIMD3<Float>(0, 0, 1))
            backward.y = 0
            backward = simd_normalize(backward)
            for i in departure {
                let t = Float(i - departure.lowerBound) / Float(departure.count - 1)
                let smooth = t * t * (3 - 2 * t)
                frames[i] = Transform(scale: start.scale, rotation: start.rotation,
                    translation: start.translation + backward * (distance * smooth))
            }
        }
        let arrivalMarker = waypoints.last?.actualMarkerName
        if ["Location_Living_Room", "Location_Outdoor", "Location_Dining_Room"].contains(arrivalMarker ?? ""), visibleRanges.count > 1,
           let arrival = visibleRanges.last, let destination = frames.last {
            // Christmas reveals at its final viewpoint without forward motion.
            // Other arrivals retain their short approach after the hidden turn.
            let approachDistance: Float = (arrivalMarker == "Location_Outdoor" ? 0.90 : (arrivalMarker == "Location_Dining_Room" ? 0.40 : 0)) * Float(visibleTravelScale)
            var backward = destination.rotation.act(SIMD3<Float>(0, 0, 1))
            backward.y = 0
            backward = simd_normalize(backward)
            for i in arrival {
                let t = Float(i - arrival.lowerBound) / Float(arrival.count - 1)
                let smooth = t * t * (3 - 2 * t)
                frames[i] = Transform(scale: destination.scale, rotation: destination.rotation,
                    translation: destination.translation + backward * (approachDistance * (1 - smooth)))
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--rewind-performance-run"),
           let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let report: [String: Any] = ["duration": duration, "frame_interval": duration / Double(frameCount),
                "visible_ranges": visibleRanges.map { [$0.lowerBound, $0.upperBound] },
                "rendered_travel_seconds": visibleRanges.reduce(0) { $0 + Double($1.count - 1) * duration / Double(frameCount) },
                "markers": waypoints.map(\.actualMarkerName),
                "frames": frames.map { frame -> [Float] in
                    let view = frame
                    return [view.translation.x, view.translation.y, view.translation.z,
                            view.rotation.vector.x, view.rotation.vector.y, view.rotation.vector.z, view.rotation.vector.w]
                }]
            if let data = try? JSONSerialization.data(withJSONObject: report) {
                try? data.write(to: folder.appendingPathComponent("RouteMotion-" + (waypoints.first?.actualMarkerName ?? "start") + "-to-" + (waypoints.last?.actualMarkerName ?? "route") + ".json"))
            }
        }
        #endif
        if waypoints.first?.actualMarkerName == "Location_Bedroom", visibleRanges.count == 3,
           let top = waypoints.first(where: { $0.actualMarkerName == "RouteMarker_2" }),
           let bottom = waypoints.first(where: { $0.actualMarkerName == "RouteMarker_3" }) {
            straightenStairDescent(&frames, range: visibleRanges[1],
                top: top.viewTransform, bottom: bottom.viewTransform)
        }
        // Convert each final pose once, after smoothing and speed control.
        frames = frames.map { pose in
            Transform(matrix: parentFromWorld * calibration * simd_inverse(pose.matrix))
        }
        print("PERF route sampling: \(1000 * (CACurrentMediaTime() - routePreparationBegan)) ms")
        if visibleRanges.count > 1, let anchor = travelHeadAnchor, anchor.scene != nil {
            // One unlit cover avoids making every house material transparent.
            // It is removed entirely after travel, with no activity render cost.
            var material = UnlitMaterial(color: UIColor(red: 0.85, green: 0.80, blue: 0.73, alpha: 1), applyPostProcessToneMap: false)
            material.blending = .transparent(opacity: .init(floatLiteral: 1))
            material.faceCulling = .front
            material.readsDepth = false
            material.writesDepth = false
            let cover = ModelEntity(mesh: .generateSphere(radius: 1), materials: [material])
            cover.name = "TravelFadeCover"
            cover.components.set(OpacityComponent(opacity: 0))
            cover.isEnabled = false
            anchor.addChild(cover)
            defer {
                isRelocatingUnderCover = false
                cover.removeFromParent()
            }
            let interval = duration / Double(frameCount) / 1.10 * visibleTravelScale
            // Compile both clips before departure. Creating the arrival
            // animation under the cover would prolong its solid hold.
            let clips = visibleRanges.map { Array(frames[$0]) }
            let clipIntervals = clips.enumerated().map { index, clip in
                // Keep the brief descent readable: the reveal starts while
                // at the top of the stairs, with a proportionally shorter descent.
                if waypoints.first?.actualMarkerName == "Location_Bedroom",
                   clips.count == 3, index == 1 {
                    return 1.5 * visibleTravelScale / Double(clip.count - 1)
                }
                return interval
            }
            let animations = clips.enumerated().map { index, clip in
                try? AnimationResource.generate(with: SampledAnimation<Transform>(
                    frames: clip, name: "HouseTravelClip", frameInterval: Float(clipIntervals[index]),
                    bindTarget: .transform, fillMode: .forwards))
            }
            onDeparture()
            for (index, range) in visibleRanges.enumerated() {
                guard !Task.isCancelled else { return }
                if index > 0 {
                    // The preceding clip ended fully covered. Do not animate
                    // or render the omitted corridor; reposition once, hidden.
                    cover.isEnabled = true
                    cover.components.set(OpacityComponent(opacity: 1))
                    if index == visibleRanges.count - 1 {
                        await prepareArrival()
                        guard !Task.isCancelled else { return }
                    }
                    isRelocatingUnderCover = true
                    environmentRoot.transform = frames[range.lowerBound]
                    // Apply the destination light budget under the cover without
                    // disabling/re-enabling every house entity and light slot.
                    // The gradual reveal then hides the remaining light blend.
                    // Reveal immediately; the relocation is already covered.
                    // The light-budget task consumes the relocation flag on its
                    // next tick, independently of this brief visual cover.
                    guard !Task.isCancelled else { return }
                }
                if index == visibleRanges.count - 1, arrivalMarker == "Location_Outdoor" {
                    ActivityPropManager.beginBallArrivalGreeting()
                }
                await playTravelClip(clips[index],
                    duration: Double(range.count - 1) * clipIntervals[index], root: environmentRoot,
                    cover: cover, fadeIn: index > 0, fadeOut: index < visibleRanges.count - 1,
                    preparedAnimation: animations[index], animationPrepared: true)
            }
        } else {
            onDeparture()
            await ActivityPropManager.finishDepartureFades()
            await prepareArrival()
            guard !Task.isCancelled else { return }
            await playTravelClip(frames, duration: duration / 1.10, root: environmentRoot)
        }
    }

    /// Bedroom departures also show one brief stairway interlude; returns skip it.
    /// Omitted route samples are never played; reposition only under the cover.
    private static func straightenStairDescent(_ frames: inout [Transform], range: ClosedRange<Int>,
                                               top: Transform, bottom: Transform) {
        guard range.count > 1 else { return }
        let direction = bottom.translation - top.translation
        guard simd_length(SIMD2<Float>(direction.x, direction.z)) > 0.001 else { return }
        let yaw = simd_quatf(angle: atan2(-direction.x, -direction.z), axis: [0, 1, 0])
        let topForward = top.rotation.act(SIMD3<Float>(0, 0, -1))
        let pitch = asin(min(1, max(-1, topForward.y))) - 5 * Float.pi / 180
        let heading = yaw * simd_quatf(angle: pitch, axis: [1, 0, 0])
        for i in range {
            let t = Float(i - range.lowerBound) / Float(range.count - 1)
            // Keep a steady descent until fully covered. Easing to a stop
            // here exposes a slowdown while the stairway is still visible.
            // Scale the distance and playback time together so the shorter
            // descent retains the accepted speed and ends earlier on the stairs.
            frames[i] = Transform(scale: top.scale, rotation: heading,
                translation: top.translation + direction * (0.25 * Float(visibleTravelScale) * t))
        }
    }

    private static func shortTravelRanges(waypoints: [RouteWaypoint], frames: [Transform], duration: Double) -> [ClosedRange<Int>] {
        let last = frames.count - 1
        guard duration > 0.1, last > 4, !ProcessInfo.processInfo.arguments.contains("--rewind-performance-baseline") else { return [0...last] }
        func index(_ time: Double) -> Int { min(last, max(0, Int((time / duration * Double(last)).rounded()))) }
        let from = waypoints.first?.actualMarkerName
        let to = waypoints.last?.actualMarkerName
        let departureLimit = from == "Location_Bedroom" ? 2.1
            : (from == "Location_Living_Room" ? 2.2 : 3.0)
        let departure = min(departureLimit, duration * 0.28)
        // Reveal the short backward bedroom lane only after the covered cut;
        // its fixed heading eliminates the visible doorway turn.
        let arrival = min(to == "Location_Bedroom" ? 1.5 : (to == "Location_Dining_Room" ? 2.0 : (to == "Location_Living_Room" ? 2.1 : 3.4)), duration * 0.32)
        var arrivalStart = duration - arrival
        if to == "Location_Outdoor" {
            // Begin revealing at the doorway, not deep inside the house or
            // already at Dad. Keep the original continuous doorway motion.
            let doorway = SIMD3<Float>(-3.10, 0, -36.0)
            let horizontal = frames.indices.min {
                simd_length(SIMD2(frames[$0].translation.x - doorway.x, frames[$0].translation.z - doorway.z)) <
                simd_length(SIMD2(frames[$1].translation.x - doorway.x, frames[$1].translation.z - doorway.z))
            } ?? last
            arrivalStart = max(departure + 0.7, Double(horizontal) / Double(last) * duration)
        }
        // Keep a real reveal interval even when the nearest doorway sample is
        // the final pose (otherwise the last clip has only one frame).
        arrivalStart = min(arrivalStart, duration - min(0.75, duration * 0.2))
        var ranges = [0...index(departure)]
        if from == "Location_Bedroom",
           let stairTop = waypoints.first(where: { $0.actualMarkerName == "RouteMarker_2" }),
           let stairBottom = waypoints.first(where: { $0.actualMarkerName == "RouteMarker_3" }) {
            // Marker 2 is the upper landing; marker 3 is on the stairs below.
            // Reveal at the top of the descent and finish covered halfway down.
            // Marker 1 -> 2 is the upstairs hallway, not the stair descent.
            func nearest(_ point: SIMD3<Float>) -> Int {
                frames.indices.min { simd_distance(frames[$0].translation, point) <
                    simd_distance(frames[$1].translation, point) } ?? 0
            }
            let top = nearest(stairTop.viewTransform.translation)
            let bottom = nearest(stairBottom.viewTransform.translation)
            let topTime = Double(top) / Double(last) * duration
            let bottomTime = Double(bottom) / Double(last) * duration
            let descent = bottomTime - topTime
            let start = max(departure + 0.25, topTime)
            let end = min(arrivalStart - 0.25, topTime + descent * 0.50)
            if end - start > 0.4 { ranges.append(index(start)...index(end)) }
        }
        ranges.append(index(arrivalStart)...last)
        return ranges
    }

    private static func playTravelClip(_ frames: [Transform], duration: Double, root: Entity,
                                      cover: ModelEntity? = nil, fadeIn: Bool = false, fadeOut: Bool = false,
                                      preparedAnimation: AnimationResource? = nil, animationPrepared: Bool = false) async {
        guard frames.count > 1, duration > 0 else { return }
        let frameCount = frames.count - 1
        let fadeDuration = min(1.20285 * visibleTravelScale, duration * 0.5832)
        var lastOpacity: Float = -1
        func updateCover(_ time: Double) {
            guard let cover else { return }
            func eased(_ t: Double) -> Float {
                let x = Float(min(1, max(0, t)))
                // Ease at the visible ends, without lingering near full cover.
                return x * x * (2 - x)
            }
            let opacity = max(fadeIn ? eased(1 - time / fadeDuration) : 0,
                              fadeOut ? eased((time - duration + fadeDuration) / fadeDuration) : 0)
            guard opacity != lastOpacity else { return }
            lastOpacity = opacity
            cover.isEnabled = opacity > 0
            cover.components.set(OpacityComponent(opacity: opacity))
        }
        updateCover(0)
        isPresentingRoute = true
        defer { isPresentingRoute = false }
        let animation = animationPrepared ? preparedAnimation : try? AnimationResource.generate(with: SampledAnimation<Transform>(
            frames: frames, name: "HouseTravelClip", frameInterval: Float(duration / Double(frameCount)),
            bindTarget: .transform, fillMode: .forwards))
        if !ProcessInfo.processInfo.arguments.contains("--rewind-performance-baseline"), let animation {
            let controller = root.playAnimation(animation)
            // Fade against the animation clock, not a wall-clock delay, so a
            // paused or delayed render cannot expose the hidden reposition.
            let fadeSubscription = cover == nil ? nil : root.scene?.subscribe(to: SceneEvents.Update.self) { _ in
                updateCover(controller.time)
            }
            defer { fadeSubscription?.cancel() }
            let initial = root.transform
            var observedMotion = false
            var previousTime: TimeInterval = -1
            var stalledSince = CACurrentMediaTime()
            print("ROUTE CLIP: native \(duration)s, \(frameCount) samples, fade in \(fadeIn), fade out \(fadeOut)")
            while !Task.isCancelled && !controller.isComplete && controller.time < duration {
                if controller.time > previousTime + 0.001 {
                    previousTime = controller.time
                    stalledSince = CACurrentMediaTime()
                }
                observedMotion = observedMotion || simd_distance(root.position, initial.translation) > 0.001
                if !controller.isValid || controller.isStopped || CACurrentMediaTime() - stalledSince > 2 { break }
                do { try await Task.sleep(for: .milliseconds(8)) }
                catch { controller.stop(); return }
            }
            if Task.isCancelled { controller.stop(); return }
            if (controller.isComplete || controller.time >= duration) && previousTime > 0 {
                controller.stop()
                root.transform = frames[frameCount]
                updateCover(duration)
                return
            }
            let resume = observedMotion ? min(duration, max(0, controller.time)) : 0
            controller.stop()
            fadeSubscription?.cancel()
            await presentRouteFallback(frames, duration: duration, from: resume, root: root, onProgress: updateCover)
        } else {
            await presentRouteFallback(frames, duration: duration, from: 0, root: root, onProgress: updateCover)
        }
        if !Task.isCancelled { updateCover(duration) }
    }

    private static func presentRouteFallback(_ frames: [Transform], duration: Double, from start: Double, root: Entity, onProgress: ((Double) -> Void)? = nil) async {
        guard let scene = root.scene else { return }
        var elapsed = start
        let frameCount = frames.count - 1
        let subscription = scene.subscribe(to: SceneEvents.Update.self) { event in
            let dt = ProcessInfo.processInfo.arguments.contains("--rewind-performance-baseline") ? min(event.deltaTime, 1.0 / 30.0) : event.deltaTime
            elapsed = min(duration, elapsed + dt)
            onProgress?(elapsed)
            let sample = elapsed / duration * Double(frameCount)
            let lower = min(frameCount, Int(sample)), upper = min(frameCount, lower + 1)
            let fraction = Float(sample - Double(lower))
            let a = frames[lower], b = frames[upper]
            root.transform = Transform(scale: a.scale,
                rotation: simd_slerp(a.rotation, b.rotation, fraction),
                translation: simd_mix(a.translation, b.translation, SIMD3(repeating: fraction)))
        }
        defer { subscription.cancel() }
        print("ROUTE PLAYBACK: scene-update fallback at \(start)s")
        while elapsed < duration && !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        if !Task.isCancelled { root.transform = frames[frameCount] }

    }

    private static func animateSegment(
        from startWaypoint: RouteWaypoint,
        to endWaypoint: RouteWaypoint,
        environmentRoot: Entity
    ) async {
        let rootBeforeMatrix = environmentRoot.transformMatrix(relativeTo: nil)
        let rootBefore = Transform(matrix: rootBeforeMatrix)
        // The viewer pose the root is currently expressing. Starting from this
        // rather than from startWaypoint keeps a segment continuous even if the
        // previous one was interrupted.
        let viewBefore = Transform(matrix: simd_inverse(simd_inverse(SceneViewerCalibration.matrix) * rootBeforeMatrix))
        // Pace the walk on how far the viewer actually travels through the house.
        let duration = segmentDuration(from: viewBefore.translation, to: endWaypoint.viewTransform.translation)

        print("""
        🎬 MOVING:
        \(startWaypoint.requestedMarkerName) → \(endWaypoint.requestedMarkerName)

        ROOT BEFORE:
        position: \(format(rootBefore.translation))
        orientation: \(format(rootBefore.rotation))

        EXPECTED ROOT AFTER:
        position: \(format(endWaypoint.environmentTransform.translation))
        orientation: \(format(endWaypoint.environmentTransform.rotation))
        duration: \(duration)
        """)

        if simd_distance(viewBefore.translation, endWaypoint.viewTransform.translation) <= Constants.movementEpsilon {
            print("❌ NAVIGATION TARGETS IDENTICAL: \(startWaypoint.requestedMarkerName) → \(endWaypoint.requestedMarkerName)")
        }

        await interpolateEnvironmentRoot(
            environmentRoot,
            fromView: viewBefore,
            toView: endWaypoint.viewTransform,
            exactTargetMatrix: endWaypoint.environmentMatrix,
            duration: duration,
            easeStart: !startWaypoint.actualMarkerName.hasSuffix("clearance"),
            easeEnd: !endWaypoint.actualMarkerName.hasSuffix("clearance")
        )

        let rootAfter = Transform(matrix: environmentRoot.transformMatrix(relativeTo: nil))
        print("""
        ROOT ACTUAL AFTER:
        position: \(format(rootAfter.translation))
        orientation: \(format(rootAfter.rotation))
        """)

        let positionDelta = simd_distance(rootAfter.translation, endWaypoint.environmentTransform.translation)
        if positionDelta > Constants.movementEpsilon {
            print("❌ ENVIRONMENTROOT MISSED TARGET: \(endWaypoint.requestedMarkerName), delta \(positionDelta)")
        } else {
            print("✅ ENVIRONMENTROOT REACHED TARGET: \(endWaypoint.requestedMarkerName)")
        }
    }

    // Walks the VIEWER from one marker pose to the next and re-derives the root
    // transform each frame.
    //
    // The root transform is the inverse of the viewer pose, and inverses cannot be
    // blended: lerp(A⁻¹, B⁻¹) != lerp(A, B)⁻¹ whenever the two poses differ in
    // rotation. Blending the root matrices directly is what threw the camera on a
    // wide arc out through the walls and back — simulated against the real marker
    // transforms, mid-segment excursions reached 21.98 m (Bedroom → RouteMarker 1)
    // and 29.17 m (RouteMarker 3 → Living Room), which is also why it looked like a
    // reset to a far-off origin partway through. Interpolating the viewer pose and
    // inverting per frame holds the path on the straight marker-to-marker line.
    private static func interpolateEnvironmentRoot(
        _ environmentRoot: Entity,
        fromView start: Transform,
        toView end: Transform,
        exactTargetMatrix: simd_float4x4,
        duration: TimeInterval,
        easeStart: Bool = true,
        easeEnd: Bool = true
    ) async {
        let startTime = Date()

        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(startTime)
            let rawProgress = min(1.0, max(0.0, elapsed / duration))
            let t = Float(rawProgress)
            // Keep moving through aisle bends; only stop at actual destinations.
            let m0: Float = easeStart ? 0 : 1
            let m1: Float = easeEnd ? 0 : 1
            let easedT = (-2 * t * t * t + 3 * t * t)
                + (t * t * t - 2 * t * t + t) * m0
                + (t * t * t - t * t) * m1

            // Interpolate in viewer space: a straight walk between the two markers
            // with a steady turn, matching the route authored in Blender.
            let translation = simd_mix(start.translation, end.translation, SIMD3<Float>(repeating: easedT))
            let scale = simd_mix(start.scale, end.scale, SIMD3<Float>(repeating: easedT))
            let rotation = simd_slerp(start.rotation, end.rotation, easedT)

            let viewMatrix = Transform(
                scale: scale,
                rotation: rotation,
                translation: translation
            ).matrix

            // Invert per frame, never between frames.
            environmentRoot.setTransformMatrix(SceneViewerCalibration.matrix * simd_inverse(viewMatrix), relativeTo: nil)

            if rawProgress >= 1.0 {
                break
            }

            try? await Task.sleep(nanoseconds: Constants.animationFrameDurationNanoseconds)
        }

        environmentRoot.setTransformMatrix(exactTargetMatrix, relativeTo: nil)
    }

    private static func segmentDuration(from start: SIMD3<Float>, to end: SIMD3<Float>) -> TimeInterval {
        let distance = simd_distance(start, end)
        let unclampedDuration = TimeInterval(distance * Constants.secondsPerMeter)
        return min(Constants.maximumSegmentDuration, max(Constants.minimumSegmentDuration, unclampedDuration))
    }

    private static func makeEntityLookup(from rootEntity: Entity) -> [String: Entity] {
        var lookup: [String: Entity] = [:]
        collectEntities(from: rootEntity, into: &lookup)
        return lookup
    }

    private static func collectEntities(from entity: Entity, into lookup: inout [String: Entity]) {
        if !entity.name.isEmpty {
            lookup[entity.name] = entity
        }

        for child in entity.children {
            collectEntities(from: child, into: &lookup)
        }
    }

    private static func makeNormalizedEntityLookup(from exactLookup: [String: Entity]) -> [String: [Entity]] {
        var normalizedLookup: [String: [Entity]] = [:]

        for (name, entity) in exactLookup {
            normalizedLookup[normalizedName(name), default: []].append(entity)
        }

        return normalizedLookup
    }

    private static func resolveMarker(
        requestedName: String,
        exactLookup: [String: Entity],
        normalizedLookup: [String: [Entity]],
        houseEntity: Entity
    ) -> Entity? {
        if let exactMatch = exactLookup[requestedName] {
            return exactMatch
        }

        let normalizedRequestedName = normalizedName(requestedName)
        let matches = normalizedLookup[normalizedRequestedName] ?? []

        if matches.count == 1 {
            return matches[0]
        }

        if matches.count > 1 {
            print("❌ ROUTE MARKER AMBIGUOUS: \(requestedName)")
            for match in matches {
                print("ambiguous match: \(match.name)")
            }
        }

        return nil
    }

    private static func normalizedName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { character in
                character != " " && character != "_" && character != "-"
            }
    }

    private static func printAvailableNavigationEntities(from lookup: [String: Entity]) {
        print("Available imported navigation-like entities:")

        let navigationNames = lookup.keys
            .filter { name in
                let normalized = normalizedName(name)
                return normalized.contains("routemarker") || normalized.contains("location")
            }
            .sorted()

        for name in navigationNames {
            print("- \(name)")
        }
    }

    private static func format(_ vector: SIMD3<Float>) -> String {
        "x=\(vector.x), y=\(vector.y), z=\(vector.z)"
    }

    private static func format(_ rotation: simd_quatf) -> String {
        "ix=\(rotation.imag.x), iy=\(rotation.imag.y), iz=\(rotation.imag.z), r=\(rotation.real)"
    }
}

@MainActor
// Places and shows/hides every floating SwiftUI panel in the experience.
private enum HomeInterfacePlacement {
    static let attachmentID = "HomeLaunchInterface"
    static let activityAttachmentID = "ActivityHUD"
    static let completionAttachmentID = "ActivityCompletion"
    static let albumAttachmentID = "MemoryAlbum"
    static let albumPointerAttachmentID = "MemoryAlbumPointer"
    static let dashboardAttachmentID = "MemoryDashboard"

    // Panel placement, in metres, in RealityView content coordinates.
    private struct PanelPlacement {
        let attachmentID: String
        let position: SIMD3<Float>
        // Billboarded panels always face the viewer. The HUD is deliberately not
        // billboarded so its left checklist stays on the left of the field of view.
        let isBillboarded: Bool
    }

    // The panels were enlarged along with their type, so the two that grew most —
    // the HUD and the dashboard — sit slightly further out to stay inside a
    // comfortable field of view. Both still subtend more than before, and their
    // text grew faster than the panel did, so everything reads distinctly larger.
    private static let placements: [PanelPlacement] = [
        // Home UI, comfortably ahead and slightly above eye level.
        PanelPlacement(attachmentID: attachmentID, position: SIMD3<Float>(0.0, 1.66, -1.12), isBillboarded: false),
        // HUD sits further out so it frames the activity rather than crowding it.
        PanelPlacement(attachmentID: activityAttachmentID, position: SIMD3<Float>(0.0, 1.82, -0.85), isBillboarded: false),
        PanelPlacement(attachmentID: completionAttachmentID, position: SIMD3<Float>(-0.55, 1.82, -1.12), isBillboarded: true),
        // Album guidance sits above the bed/book foreground without filling the whole view.
        PanelPlacement(attachmentID: albumAttachmentID, position: SIMD3<Float>(-0.10, 1.58, -1.05), isBillboarded: false),
        PanelPlacement(attachmentID: albumPointerAttachmentID, position: SIMD3<Float>(0.38, 1.18, -0.62), isBillboarded: true),
        // The dashboard appears above the album.
        PanelPlacement(attachmentID: dashboardAttachmentID, position: SIMD3<Float>(0.0, 1.66, -1.35), isBillboarded: true)
    ]

    // SwiftUI can recreate an attachment after a run reset while retaining its
    // name. Track the actual entity so the replacement is added and positioned.
    private static var placedAttachments: [String: ObjectIdentifier] = [:]

    // Adds panel entities to content, disabled apart from the home UI. Safe to
    // call on every update: already-placed panels are skipped.
    static func addPanels(
        from attachments: RealityViewAttachments,
        to content: RealityViewContent,
        isInitialLoad: Bool
    ) {
        if isInitialLoad {
            // A fresh RealityView means a fresh scene; forget the previous run.
            placedAttachments = [:]
        }

        for placement in placements {
            guard let panel = attachments.entity(for: placement.attachmentID) else {
                // Expected for panels whose SwiftUI body is still nil, e.g. the
                // dashboard before any session exists. Only worth reporting on the
                // initial load, where the home UI genuinely must be present.
                if isInitialLoad {
                    print("ℹ️ ATTACHMENT NOT READY: \(placement.attachmentID)")
                }

                continue
            }

            let identity = ObjectIdentifier(panel)
            guard placedAttachments[placement.attachmentID] != identity else { continue }
            panel.name = placement.attachmentID
            panel.position = SceneViewerCalibration.position(placement.position)
            panel.scale = SIMD3<Float>(repeating: placement.attachmentID == attachmentID ? 0.90 : 1.0)

            if placement.isBillboarded {
                panel.components.set(BillboardComponent())
            } else {
                panel.orientation = Transform(matrix: SceneViewerCalibration.matrix).rotation
            }

            // Only the launch UI starts visible; the rest are enabled per stage.
            panel.isEnabled = placement.attachmentID == attachmentID
            content.add(panel)
            placedAttachments[placement.attachmentID] = identity

            print("""
            ✅ PANEL ADDED: \(placement.attachmentID)
            position: \(format(panel.position))
            billboarded: \(placement.isBillboarded)
            isEnabled: \(panel.isEnabled)
            """)
        }
    }

    static func updatePanelVisibility(
        attachments: RealityViewAttachments,
        isHomeVisible: Bool,
        isActivityVisible: Bool,
        isCompletionVisible: Bool,
        isAlbumVisible: Bool,
        isDashboardVisible: Bool,
        isAlbumPointerVisible: Bool
    ) {
        setEnabled(isHomeVisible, for: attachmentID, in: attachments)
        setEnabled(isActivityVisible, for: activityAttachmentID, in: attachments)
        setEnabled(isCompletionVisible, for: completionAttachmentID, in: attachments)
        setEnabled(isAlbumVisible, for: albumAttachmentID, in: attachments)
        setEnabled(isAlbumPointerVisible, for: albumPointerAttachmentID, in: attachments)
        setEnabled(isDashboardVisible, for: dashboardAttachmentID, in: attachments)
    }

    private static func setEnabled(
        _ isEnabled: Bool,
        for attachmentID: String,
        in attachments: RealityViewAttachments
    ) {
        guard let panel = attachments.entity(for: attachmentID) else {
            return
        }

        setPanelVisibility(panel, isEnabled: isEnabled, fadesIn: attachmentID != self.attachmentID)
    }

    // Compare the carton silhouette and the entire label at the same depth.
    // Apply this after the general view clamp so it cannot push the label back
    // into the carton. Use the side nearest the centre when space is tight.
    static func milkCalloutPosition(
        modelCorners: [SIMD3<Float>], preferred: SIMD3<Float>, halfLabelWidth: Float
    ) -> SIMD3<Float> {
        guard !modelCorners.isEmpty else { return preferred }
        let nearestDepth = modelCorners.map { -$0.z }.min() ?? 0.45
        let labelDepth = max(0.25, nearestDepth - 0.06)
        let projectedX = modelCorners.map { $0.x * labelDepth / max(0.05, -$0.z) }
        let clearance = halfLabelWidth + 0.05
        let right = (projectedX.max() ?? 0) + clearance
        let left = (projectedX.min() ?? 0) - clearance
        let x = right + halfLabelWidth <= labelDepth * 0.70 || abs(right) <= abs(left)
            ? right : left
        return SIMD3<Float>(x, preferred.y, -labelDepth)
    }

    // Reveal the whole attachment in place. Repeated RealityView updates must
    // not restart the fade while a gesture or progress value is changing.
    static func setPanelVisibility(_ panel: Entity, isEnabled: Bool, fadesIn: Bool = true) {
        guard panel.isEnabled != isEnabled else { return }
        if fadesIn {
            panel.stopAllAnimations(recursive: false)
            panel.components.set(OpacityComponent(opacity: isEnabled ? 0 : 1))
        }
        panel.isEnabled = isEnabled
        if isEnabled && fadesIn {
            let frames = (0...30).map { index -> Float in
                let t = Float(index) / 30
                return t * t * (3 - 2 * t)
            }
            if let fade = try? AnimationResource.generate(with: SampledAnimation<Float>(
                frames: frames, name: "PanelFadeIn", frameInterval: 0.5 / 30,
                bindTarget: .opacity, fillMode: .forwards)) {
                panel.playAnimation(fade)
            } else {
                panel.components.set(OpacityComponent(opacity: 1))
            }
        }
    }

    private static func format(_ vector: SIMD3<Float>) -> String {
        "x=\(vector.x), y=\(vector.y), z=\(vector.z)"
    }
}

@MainActor
private enum SceneViewerCalibration {
    static var matrix = matrix_identity_float4x4
    static func position(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let value = matrix * SIMD4<Float>(point, 1)
        return [value.x, value.y, value.z]
    }
}

@MainActor
private enum CeilingLightingSystem {
    // Per-marker offsets keep ceiling light positions easy to tune without changing logic.
    private struct MarkerCeilingConfiguration {
        let markerName: String
        let lightName: String
        let verticalOffset: Float
        let forwardOffset: Float
        let lateralOffset: Float
        let createsLight: Bool
    }

    private enum Constants {
        // Shared light parent and visual marker settings.
        static let parentName = "CeilingLights"
        // House-local coordinate basis: imported REWind_House_Master uses +Z as physical up.
        static let localUp = SIMD3<Float>(0.0, 0.0, 1.0)
        static let defaultHorizontalForward = SIMD3<Float>(0.0, 1.0, 0.0)

        // Ceiling fixtures remain on: useful warm room illumination.
        // The environment light lifts corners beyond each fixture’s falloff.
        static let indoorLightColor = PointLightComponent.Color(red: 1.0, green: 0.93, blue: 0.83, alpha: 1.0)
        static let lightIntensity: Float = 3_000
        static let attenuationRadius: Float = 6.5

        // Retain room-light placement after the decorative hanging fixtures are removed.
        // These bounds come from the last approved house; recessed lights are unchanged.
        static let removedFixtureLocations: [(center: SIMD3<Float>, lowerZ: Float)] = [
            (center: SIMD3<Float>(-6.5794241, 38.2949908, 2.3414300), lowerZ: 1.7829486),
            (center: SIMD3<Float>(1.5918964, 47.5140593, 2.3414300), lowerZ: 1.7829486),
            (center: SIMD3<Float>(1.5918964, 47.5140593, 5.4657977), lowerZ: 4.9073163),
            (center: SIMD3<Float>(-8.9330699, 48.8816149, 5.4659055), lowerZ: 4.9074241),
        ]

        // Imported marker names and per-marker ceiling offsets.
        static let markerConfigurations = [
            MarkerCeilingConfiguration(
                markerName: "RouteMarker_1",
                lightName: "CeilingLight_RouteMarker1",
                verticalOffset: 1.2,
                forwardOffset: 0.8,
                lateralOffset: 0.0,
                createsLight: false
            ),
            MarkerCeilingConfiguration(
                markerName: "RouteMarker_2",
                lightName: "CeilingLight_RouteMarker2",
                verticalOffset: 1.2,
                forwardOffset: 0.8,
                lateralOffset: 0.0,
                createsLight: false
            ),
            MarkerCeilingConfiguration(
                markerName: "RouteMarker_3",
                lightName: "CeilingLight_RouteMarker3",
                verticalOffset: 1.2,
                forwardOffset: 0.8,
                lateralOffset: 0.0,
                createsLight: false
            ),
            MarkerCeilingConfiguration(
                markerName: "RouteMarker_4",
                lightName: "CeilingLight_RouteMarker4",
                verticalOffset: 1.2,
                forwardOffset: 0.8,
                lateralOffset: 0.0,
                createsLight: true
            ),
            MarkerCeilingConfiguration(
                markerName: "RouteMarker_5",
                lightName: "CeilingLight_RouteMarker5",
                verticalOffset: 1.4,
                forwardOffset: 0.8,
                lateralOffset: 0.0,
                createsLight: true
            ),
            MarkerCeilingConfiguration(
                markerName: "RouteMarker_6",
                lightName: "CeilingLight_RouteMarker6",
                verticalOffset: 1.2,
                forwardOffset: 0.8,
                lateralOffset: 0.0,
                createsLight: false
            ),
            MarkerCeilingConfiguration(
                markerName: "Location_Bedroom",
                lightName: "CeilingLight_LocationBedroom",
                verticalOffset: 1.1,
                forwardOffset: 1.4,
                lateralOffset: 0.0,
                createsLight: true
            ),
            MarkerCeilingConfiguration(
                markerName: "Location_Dining_Room",
                lightName: "CeilingLight_LocationDiningRoom",
                verticalOffset: 1.4,
                forwardOffset: 0.8,
                lateralOffset: 0.0,
                createsLight: true
            ),
            MarkerCeilingConfiguration(
                markerName: "Location_Living_Room",
                lightName: "CeilingLight_LocationLivingRoom",
                verticalOffset: 1.2,
                forwardOffset: 0.8,
                lateralOffset: 0.0,
                createsLight: true
            ),
            MarkerCeilingConfiguration(
                markerName: "Location_Outdoor",
                lightName: "CeilingLight_LocationOutdoor",
                verticalOffset: 1.2,
                forwardOffset: 0.8,
                lateralOffset: 0.0,
                createsLight: false
            )
        ]
    }

    static func addCeilingLights(to houseEntity: Entity) {
        // Clean up temporary debug lighting from earlier test passes before adding final lights.
        removeOldDebugEntities(from: houseEntity)

        let ceilingLights = Entity()
        ceilingLights.name = Constants.parentName
        houseEntity.addChild(ceilingLights)

        // Build one lookup so exact-name marker searches are cheap and deterministic.
        let entityLookup = makeEntityLookup(from: houseEntity)

        for configuration in Constants.markerConfigurations {
            guard let marker = entityLookup[configuration.markerName] else {
                print("⚠️ CEILING LIGHT MARKER NOT FOUND: \(configuration.markerName)")
                continue
            }

            let markerTransform = Transform(matrix: marker.transformMatrix(relativeTo: houseEntity))
            let markerPosition = markerTransform.translation

            // Blender cameras face local -Z; flatten that direction against house-local +Z.
            let horizontalForward = horizontalForwardVector(from: markerTransform)
            let horizontalRight = normalized(
                simd_cross(horizontalForward, Constants.localUp),
                fallback: SIMD3<Float>(1.0, 0.0, 0.0)
            )

            // Final ceiling position stays in REWind_House_Master local coordinates.
            var ceilingPosition = markerPosition
                + (Constants.localUp * configuration.verticalOffset)
                + (horizontalForward * configuration.forwardOffset)
                + (horizontalRight * configuration.lateralOffset)

            // Use the actual fixture when available, rather than putting a light
            // inside the roof above it. Bounds are measured in the house's Z-up space.
            let visibleFixtures = entityLookup.values
                .filter { $0.name.lowercased().hasPrefix("ceiling_lamp") }
                .map { $0.visualBounds(relativeTo: houseEntity) }
                .map { (center: $0.center, lowerZ: $0.min.z) }
            let fixture = (visibleFixtures + Constants.removedFixtureLocations)
                .filter { $0.center.z > markerPosition.z && $0.center.z < markerPosition.z + 2.0 }
                .min { simd_distance($0.center, ceilingPosition) < simd_distance($1.center, ceilingPosition) }
            if let fixture, simd_distance(fixture.center, ceilingPosition) < 3.5 {
                ceilingPosition = SIMD3<Float>(fixture.center.x, fixture.center.y, fixture.lowerZ - 0.12)
            }

            print("""
            marker name: \(configuration.markerName)
            marker house-local position: \(format(markerPosition))
            calculated horizontal forward: \(format(horizontalForward))
            vertical offset: \(configuration.verticalOffset)
            forward offset: \(configuration.forwardOffset)
            lateral offset: \(configuration.lateralOffset)
            final ceilingPosition: \(format(ceilingPosition))
            """)

            guard configuration.createsLight else {
                continue
            }

            // Warm fixture illumination supplements daylight from the room windows.
            let downlight = Entity()
            downlight.name = configuration.lightName + "_Downlight"
            downlight.look(
                at: ceilingPosition - Constants.localUp,
                from: ceilingPosition,
                upVector: SIMD3<Float>(0, 1, 0),
                relativeTo: nil
            )
            downlight.components.set(SpotLightComponent(
                color: Constants.indoorLightColor,
                intensity: Constants.lightIntensity,
                innerAngleInDegrees: 20,
                outerAngleInDegrees: 89,
                attenuationRadius: Constants.attenuationRadius
            ))
            downlight.components.set(SpotLightComponent.Shadow())
            ceilingLights.addChild(downlight)
        }
    }

    // Recursively index imported entities by name so marker lookup does not depend on hierarchy depth.
    private static func makeEntityLookup(from rootEntity: Entity) -> [String: Entity] {
        var lookup: [String: Entity] = [:]
        collectEntities(from: rootEntity, into: &lookup)
        return lookup
    }

    // Depth-first entity collection for the exact-name lookup table.
    private static func collectEntities(from entity: Entity, into lookup: inout [String: Entity]) {
        if !entity.name.isEmpty {
            lookup[entity.name] = entity
        }

        for child in entity.children {
            collectEntities(from: child, into: &lookup)
        }
    }

    // Removes older temporary debug entities so only the current ceiling-light system remains.
    private static func removeOldDebugEntities(from entity: Entity) {
        for child in Array(entity.children) {
            removeOldDebugEntities(from: child)

            if shouldRemoveEntity(named: child.name) {
                child.removeFromParent()
            }
        }
    }

    // Names and prefixes from previous debug experiments that should not remain in the scene.
    private static func shouldRemoveEntity(named name: String) -> Bool {
        name == "DebugBedroomSphere"
            || name == "DebugBedroomLight"
            || name == "CeilingLightDebugMarkers"
            || name == Constants.parentName
            || name.hasPrefix("DebugAxis_")
            || name.hasPrefix("DebugCeiling_")
    }

    // Converts a marker's camera-facing direction into a horizontal house-local vector.
    private static func horizontalForwardVector(from transform: Transform) -> SIMD3<Float> {
        let orientedForward = transform.rotation.act(SIMD3<Float>(0.0, 0.0, -1.0))
        let verticalComponent = Constants.localUp * simd_dot(orientedForward, Constants.localUp)
        let flattenedForward = orientedForward - verticalComponent

        return normalized(
            flattenedForward,
            fallback: Constants.defaultHorizontalForward
        )
    }

    // Normalizes vectors while providing a stable fallback for near-zero values.
    private static func normalized(
        _ vector: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let length = simd_length(vector)

        guard length > 0.001 else {
            return fallback
        }

        return vector / length
    }

    // Debug string helper for ceiling-light placement logging.
    private static func format(_ vector: SIMD3<Float>) -> String {
        "x=\(vector.x), y=\(vector.y), z=\(vector.z)"
    }
}

private enum HomeUIState {
    case launch, welcome, memories
}

private struct MemoryCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct HomeLaunchView: View {
    @Binding var uiState: HomeUIState

    @Binding var isVisible: Bool
    @Binding var shouldShowMemorySelectionOnReturn: Bool
    let completedRoutes: Set<MemoryRoute>
    let onRouteRequested: (MemoryRoute) -> Void

    // Local UI animation state for entrance, hover, press, dismissal, and gentle floating.
    @State private var hasAppeared = false
    @State private var isDismissing = false
    @State private var isButtonFocused = false
    @State private var isButtonPressed = false
    @State private var isMemoryFocused = false
    @State private var floatPhase = false
    @State private var shouldLockCompletedCards = false
    @State private var selectionAcceptsInput = false
    @State private var cardsHaveAppeared = false

    var body: some View {
        ZStack {
            if uiState == .launch {
                launchContent
                    .transition(.opacity)
            }

            if uiState == .welcome {
                Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
            }

            if uiState == .memories {
                MemorySelectionView(
                    completedRoutes: completedRoutes,
                    shouldLockCompletedCards: shouldLockCompletedCards,
                    isPresented: isVisible,
                    onRouteRequested: onRouteRequested
                )
                    .transition(.identity)
                    .opacity(cardsHaveAppeared ? 1 : 0)
                    .allowsHitTesting(selectionAcceptsInput)
                    .task {
                        selectionAcceptsInput = false
                        cardsHaveAppeared = false
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.4)) { cardsHaveAppeared = true }
                        // Ignore only the tail of the opening pinch; don't keep
                        // the cards inert for their entire entrance animation.
                        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                        selectionAcceptsInput = true
                    }
                    .onDisappear { selectionAcceptsInput = false; cardsHaveAppeared = false }
            }
        }
        // Keep the attachment's centre and render-surface dimensions stable.
        // Resizing from a 1-point welcome view shifts the incoming card surface.
        .frame(width: 1220, height: 820, alignment: .center)
        // Resize the attachment immediately, then fade its contents. Animating
        // the render surface from 1 point to 1220 points stretches the cards.
        .animation(nil, value: uiState)
        .opacity(isDismissing ? 0 : 1)
        .scaleEffect(isDismissing ? 0.92 : 1)
        .animation(.easeInOut(duration: 0.75), value: isDismissing)
        .task {
            // Entrance fade/scale animation.
            withAnimation(.easeOut(duration: 1.1)) {
                hasAppeared = true
            }

            // Slow comfort-safe floating/breathing loop for the orb.
            withAnimation(.easeInOut(duration: 6.2).repeatForever(autoreverses: true)) {
                floatPhase = true
            }
        }
        // The attachment is disabled rather than destroyed while the child is away,
        // so this view keeps its state. Rewind to the welcome step on return so
        // Home does not reappear stuck on the card grid.
        .onChange(of: isVisible) { _, isNowVisible in
            guard isNowVisible else {
                return
            }

            withAnimation(.easeInOut(duration: 0.45)) {
                if shouldShowMemorySelectionOnReturn {
                    shouldLockCompletedCards = true
                    uiState = .memories
                    shouldShowMemorySelectionOnReturn = false
                } else if uiState == .memories {
                    uiState = .welcome
                }
            }
        }
    }

    private var launchContent: some View {
            // Start button advances from launch to welcome without hiding the attachment.
            Button {
                showWelcomeState()
            } label: {
                Text("Tap to begin")
                    .font(.system(size: 34, weight: .regular, design: .default))
                    .foregroundStyle(.white)
                    .glassLegibleText()
                    .frame(width: 460, height: 92)
                    .background { glassButtonBackground }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.begin")
            .hoverEffect(.highlight)
            .scaleEffect(isButtonPressed ? 0.975 : (isButtonFocused ? 1.02 : 1.0))
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 14)
            // Gaze/hover focus gently brightens the glass button.
            .onHover { isHovering in
                withAnimation(.easeInOut(duration: 0.24)) {
                    isButtonFocused = isHovering
                }
            }
            // Let Button own the click/pinch. A zero-distance drag recognizer
            // competed with activation in the visionOS Simulator.

    }

    private var glassButtonBackground: some View {
        // Liquid-glass backing for the Tap to begin button. The system material is
        // is deliberately faint so the button reads as mostly clear glass.
        ZStack {
            Capsule()
                .fill(.clear)
                .glassCapsule(opacity: isButtonFocused ? 0.46 : 0.34)

            Capsule()
                .fill(.white.opacity(isButtonPressed ? 0.008 : (isButtonFocused ? 0.024 : 0.010)))

            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(isButtonFocused ? 0.42 : 0.30),
                            .white.opacity(0.07),
                            .white.opacity(isButtonFocused ? 0.24 : 0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )

            VStack {
                Capsule()
                    .fill(.white.opacity(isButtonFocused ? 0.10 : 0.06))
                    .frame(height: 9)
                    .blur(radius: 7)
                    .padding(.horizontal, 30)

                Spacer()
            }
            .padding(.top, 7)
        }
    }

    private func showWelcomeState() {
        // Ignore repeated taps once the welcome transition has started.
        guard uiState == .launch else {
            return
        }

        // Transition only the SwiftUI content; the attachment and orb remain active.
        withAnimation(.easeInOut(duration: 0.22)) {
            isButtonPressed = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            withAnimation(.easeInOut(duration: 0.9)) {
                uiState = .welcome
                isButtonPressed = false
            }
        }
    }

    private func showMemoriesState() {
        // Transition from the welcome orb menu into the memory card selection UI.
        guard uiState == .welcome else {
            return
        }

        withAnimation(.easeInOut(duration: 0.9)) {
            shouldLockCompletedCards = false
            uiState = .memories
        }
    }
}

// Card presentation is derived from MemoryRoute so titles, artwork and video
// names cannot drift from the route definitions.
private struct MemoryCardItem: Identifiable, Hashable {
    let route: MemoryRoute

    var id: String { route.rawValue }
    var title: String { route.title }
    var displayTitle: String { route.cardTitle }
    var imageName: String { route.cardImageName }
    var videoName: String { route.cardVideoName }
}

private struct MemorySelectionView: View {
    let completedRoutes: Set<MemoryRoute>
    let shouldLockCompletedCards: Bool
    let isPresented: Bool
    let onRouteRequested: (MemoryRoute) -> Void

    private let items = MemoryRoute.allCases.map { MemoryCardItem(route: $0) }

    @State private var focusedMemoryID: MemoryCardItem.ID?
    @State private var selectedMemoryID: MemoryCardItem.ID?
    @State private var hasAppeared = false
    @State private var isRouteTransitioning = false
    @State private var committedPreviewToken = 0
    @State private var routeCommitTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text("Moments I want to visit")
                    .font(.system(size: 52, weight: .regular, design: .default))
                    .foregroundStyle(.white)

                Text("Complete 3 for this week")
                    .font(.system(size: 28, weight: .regular, design: .default))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .glassLegibleText()
            .multilineTextAlignment(.center)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 8)

            Spacer()
                .frame(height: 48)

            HStack(spacing: 54) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let isCompleted = shouldLockCompletedCards && completedRoutes.contains(item.route)

                    MemoryCardView(
                        item: item,
                        isCompleted: isCompleted,
                        isFocused: focusedMemoryID == item.id,
                        isSelected: selectedMemoryID == item.id,
                        isPreviewActive: activePreviewMemoryID == item.id,
                        isPlaybackAllowed: isPresented && (selectedMemoryID == nil || selectedMemoryID == item.id),
                        previewRestartToken: committedPreviewToken,
                        shouldRequestRouteAfterPreview: isRouteTransitioning && selectedMemoryID == item.id,
                        onFocusChanged: { isFocused in
                            guard !isRouteTransitioning, !isCompleted else {
                                return
                            }

                            withAnimation(.easeInOut(duration: 0.28)) {
                                focusedMemoryID = isFocused ? item.id : (focusedMemoryID == item.id ? nil : focusedMemoryID)
                            }
                        },
                        onToggleSelected: {
                            toggleSelection(for: item)
                        },
                        onSelectedPreviewFinished: {
                            finishCommittedRoutePreview(for: item)
                        }
                    )
                    .opacity(hasAppeared ? 1 : 0)
                    .disabled(isCompleted)
                    .scaleEffect(hasAppeared ? 1 : 0.96)
                    .offset(y: hasAppeared ? 0 : 10)
                    .animation(.easeOut(duration: 0.55).delay(Double(index) * 0.1), value: hasAppeared)
                }
            }

            Spacer()
                .frame(height: 44)

            selectionCounter
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 8)
                .animation(.easeOut(duration: 0.45).delay(0.34), value: hasAppeared)

            Spacer()
        }
        .frame(width: 1220.0, height: 820)
        .task {
            withAnimation(.easeOut(duration: 0.5)) {
                hasAppeared = true
            }

            logMediaResources()
        }
        .onDisappear {
            routeCommitTask?.cancel()
            focusedMemoryID = nil
        }
    }

    private var selectionCounter: some View {
        HStack(spacing: 16) {
            Text("\(selectedMemoryID == nil ? 0 : 1) of 1 chosen")
                .font(.system(size: 24, weight: .regular, design: .default))
                .foregroundStyle(.white)
                .glassLegibleText()

            if selectedMemoryID != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(REWindPalette.accentDeep, REWindPalette.accent)
            }
        }
        .frame(minWidth: 240)
        .padding(.horizontal, 30)
        .frame(height: 72)
        .glassCapsule(opacity: 0.40)
    }

    private var activePreviewMemoryID: MemoryCardItem.ID? {
        if isRouteTransitioning {
            return selectedMemoryID
        }

        return focusedMemoryID ?? selectedMemoryID
    }

    private func toggleSelection(for item: MemoryCardItem) {
        guard !isRouteTransitioning, !(shouldLockCompletedCards && completedRoutes.contains(item.route)) else {
            return
        }

        ActivityPropManager.prefetch(item.route)
        selectedMemoryID = item.id
        focusedMemoryID = nil
        isRouteTransitioning = true
        // Keep the selected memory visible until its video finishes.
        committedPreviewToken += 1
    }

    private func finishCommittedRoutePreview(for item: MemoryCardItem) {
        guard isRouteTransitioning, selectedMemoryID == item.id else {
            return
        }

        routeCommitTask?.cancel()
        routeCommitTask = Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.15)) {
                hasAppeared = false
            }

            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            onRouteRequested(item.route)
        }
    }

    private func logMediaResources() {
        for item in items {
            if let imageURL = Bundle.main.url(forResource: item.imageName, withExtension: "png") {
                print("✅ FOUND IMAGE:", imageURL)
            } else {
                print("❌ IMAGE NOT IN APP BUNDLE: \(item.imageName).png")
            }

            guard let videoURL = videoURL(for: item.videoName) else {
                print("❌ VIDEO RESOURCE MISSING: \(item.videoName)")
                continue
            }

            print("✅ VIDEO RESOURCE FOUND: \(item.videoName)", videoURL)

            Task {
                let asset = AVURLAsset(url: videoURL)
                do {
                    let isPlayable = try await asset.load(.isPlayable)
                    print(isPlayable ? "✅ ASSET PLAYABLE: \(item.videoName)" : "❌ ASSET NOT PLAYABLE: \(item.videoName)")

                    let videoTracks = try await asset.loadTracks(withMediaType: .video)
                    if videoTracks.isEmpty {
                        print("❌ VIDEO TRACK MISSING: \(item.videoName)")
                    } else {
                        print("✅ VIDEO TRACK FOUND: \(item.videoName)")
                    }

                    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                    if audioTracks.isEmpty {
                        print("❌ AUDIO TRACK MISSING: \(item.videoName)")
                    } else {
                        print("✅ AUDIO TRACK FOUND: \(item.videoName)")
                    }
                } catch {
                    print("❌ AUDIO TRACK CHECK FAILED: \(item.videoName) \(error)")
                }
            }
        }
    }

    private func videoURL(for filename: String) -> URL? {
        let resourceName = (filename as NSString).deletingPathExtension
        let fileExtension = (filename as NSString).pathExtension
        return Bundle.main.url(forResource: resourceName, withExtension: fileExtension)
    }
}

private struct MemoryCardView: View {
    let item: MemoryCardItem
    let isCompleted: Bool
    let isFocused: Bool
    let isSelected: Bool
    let isPreviewActive: Bool
    let isPlaybackAllowed: Bool
    let previewRestartToken: Int
    let shouldRequestRouteAfterPreview: Bool
    let onFocusChanged: (Bool) -> Void
    let onToggleSelected: () -> Void
    let onSelectedPreviewFinished: () -> Void

    @State private var player = AVPlayer()
    @State private var isVideoVisible = false
    @State private var hasPreparedPlayer = false
    @State private var stopPreviewTask: Task<Void, Never>?
    @State private var audioFadeTask: Task<Void, Never>?
    @State private var playerPreparationTask: Task<Void, Never>?
    @State private var previewGeneration = 0
    @State private var isPointerHovering = false
    @State private var isVisionFocused = false
    @FocusState private var isCardFocused: Bool

    var body: some View {
        Button {
            onToggleSelected()
        } label: {
            cardContent
        }
        .buttonStyle(MemoryCardButtonStyle())
        .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 32, style: .continuous))
        .defaultHoverEffect(.hoverEffect { effect, _, _ in effect })
        .focusEffectDisabled()
        .hoverEffectGroup()
        .hoverEffect { effect, _, _ in effect }
        .scaleEffect(!isCompleted && isFocused ? 1.045 : 1.0)
        .offset(y: !isCompleted && isFocused ? -6 : 0)
        .animation(.easeInOut(duration: 0.28), value: isFocused)
        .animation(.easeInOut(duration: 0.28), value: isSelected)
        .onChange(of: isCardFocused) { _, newValue in
            isVisionFocused = newValue
            setPreviewFocused()
        }
        .onChange(of: isPreviewActive) { _, newValue in
            guard isPlaybackAllowed else { return }
            if newValue {
                startPreview()
            } else if !isSelected {
                player.isMuted = true
                player.volume = 0
            }
        }
        .onChange(of: previewRestartToken) { _, _ in
            if isPlaybackAllowed && isPreviewActive {
                startPreview()
            }
        }
        .onChange(of: isPlaybackAllowed) { _, allowed in
            if !allowed {
                // RealityKit disables this attachment without removing its
                // SwiftUI view. Stop decoding explicitly during house travel
                // and activities, rather than waiting for onDisappear.
                stopPreview(resetToStart: false)
            }
        }
        .onDisappear {
            stopPreview(resetToStart: true)
        }
        .task(id: isPlaybackAllowed) {
            guard isPlaybackAllowed, !isCompleted else { return }
            if isPreviewActive { startPreview(); return }
            previewGeneration += 1
            let generation = previewGeneration
            audioFadeTask?.cancel()
            stopPreviewTask?.cancel()
            guard await preparePlayerIfNeeded(), !Task.isCancelled,
                  generation == previewGeneration else { return }
            player.isMuted = true
            player.volume = 0
            player.play()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard isPlaybackAllowed, let ended = notification.object as? AVPlayerItem,
                  ended === player.currentItem else { return }
            if shouldRequestRouteAfterPreview {
                onSelectedPreviewFinished()
            } else if !isCompleted {
                player.seek(to: .zero)
                player.isMuted = true
                player.play()
            }
        }
    }

    private var cardContent: some View {
        ZStack(alignment: .bottom) {
            mediaLayer

            titlePanel
                .offset(z: 3)
        }
        .frame(width: 310, height: 510)
        .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(selectionBadge, alignment: .topTrailing)
        .overlay(cardGlassHighlights)
        .overlay(cardBorder)
        .opacity(isCompleted ? 0.46 : 1.0)
        .shadow(color: .white.opacity(isSelected ? 0.34 : 0.0), radius: isSelected ? 18 : 0)
        .shadow(color: .clear, radius: 0, y: 0)
        .onHover { isHovering in
            guard !isCompleted else {
                return
            }

            print(isHovering ? "🖱️ CARD MOUSE ENTER:" : "🖱️ CARD MOUSE EXIT:", item.title)
            updatePointerHover(isHovering)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                updatePointerHover(true)
            case .ended:
                updatePointerHover(false)
            }
        }
    }

    private var mediaLayer: some View {
        ZStack {
            MemoryBundleImage(name: item.imageName)
                .frame(width: 310, height: 510)

            PlayerLayerView(player: player)
                .frame(width: 310, height: 510)
                .allowsHitTesting(false)
                // The system reveals this muted preview without disclosing gaze
                // to app code. Only a deliberate selection enables its sound.
                .hoverEffect { effect, isActive, _ in
                    effect.opacity((isSelected || isActive || isFocused) && !isCompleted ? 1 : 0)
                }
        }
    }

    private var titlePanel: some View {
        Text(item.displayTitle)
            .font(.system(size: 28, weight: .regular, design: .default))
            .multilineTextAlignment(.center)
            .lineSpacing(7)
            .foregroundStyle(.white)
            .glassLegibleText()
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .glassPanel(cornerRadius: 26, opacity: isFocused ? 0.38 : 0.32)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.white.opacity(0.26))
                    .frame(height: 1)
            }
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected || isCompleted {
            Image(systemName: isCompleted ? "checkmark.circle.fill" : "checkmark")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(isCompleted ? .white.opacity(0.82) : Color(red: 0.62, green: 0.36, blue: 0.04))
                .frame(width: 48, height: 48)
                .background {
                    Circle()
                        .fill(.white.opacity(isCompleted ? 0.18 : 0.86))
                        .glassBackgroundEffect(in: Circle())
                }
                .padding(14)
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
            .strokeBorder(
                Color.white.opacity(isSelected ? 0.95 : (isFocused ? 0.75 : 0.14)),
                lineWidth: isSelected ? 2.2 : (isFocused ? 1.8 : 0.8)
            )
    }

    private var cardGlassHighlights: some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)

        return shape
            .fill(.clear)
            .overlay(alignment: .top) {
                Capsule()
                    .fill(.white.opacity(isFocused ? 0.12 : 0.07))
                    .frame(height: 10)
                    .blur(radius: 8)
                    .padding(.horizontal, 26)
                    .offset(y: 8)
            }
            .allowsHitTesting(false)
    }

    private func startPreview() {
        guard isPlaybackAllowed, !isCompleted else { return }
        previewGeneration += 1
        let generation = previewGeneration
        stopPreviewTask?.cancel()
        audioFadeTask?.cancel()
        playerPreparationTask?.cancel()

        print("👁️ PREVIEW ENTER:", item.title)

        playerPreparationTask = Task { @MainActor in
            let isPrepared = await preparePlayerIfNeeded()
            guard !Task.isCancelled, generation == previewGeneration else {
                return
            }

            guard isPrepared, player.currentItem != nil else {
                print("❌ PLAYER ITEM MISSING:", item.title)
                return
            }

            print("✅ PLAYER ITEM EXISTS")
            print("✅ PLAYER ITEM READY")

            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor in
                    guard generation == previewGeneration, isPreviewActive, isPlaybackAllowed else {
                        return
                    }

                    player.volume = 0
                    player.isMuted = !isSelected

                    withAnimation(.easeInOut(duration: 0.34)) {
                        isVideoVisible = true
                    }

                    configureAudioSessionIfNeeded()
                    player.playImmediately(atRate: 1.0)
                    print("▶️ PLAY REQUESTED:", item.title)
                    print("player item:", player.currentItem != nil)
                    print("timeControlStatus:", player.timeControlStatus.rawValue)

                    // The item's media-time audio mix supplies the start/end
                    // fades. Keep player volume for the user's existing balance.
                    player.volume = isSelected ? 0.75 : 0
                }
            }
        }
    }

    private func pausePreviewAtFiveSeconds(generation: Int) {
        stopPreviewTask?.cancel()
        audioFadeTask?.cancel()

        fadeAudio(to: 0, duration: 0.28, generation: generation) {
            player.pause()
            print("⏸️ PREVIEW PAUSED AT 5S:", item.title)

            if shouldRequestRouteAfterPreview {
                onSelectedPreviewFinished()
            }
        }
    }

    private func stopPreview(resetToStart: Bool) {
        previewGeneration += 1
        let generation = previewGeneration
        stopPreviewTask?.cancel()
        audioFadeTask?.cancel()
        playerPreparationTask?.cancel()

        print("👁️ PREVIEW EXIT:", item.title)

        fadeAudio(to: 0, duration: 0.28, generation: generation) {
            player.pause()
            if resetToStart {
                player.seek(to: .zero)
            }

            print("⏹️ PREVIEW STOPPED:", item.title)
        }

        withAnimation(.easeInOut(duration: 0.32)) {
            isVideoVisible = false
        }
    }

    private func preparePlayerIfNeeded() async -> Bool {
        if hasPreparedPlayer {
            return true
        }

        guard let videoURL = videoURL(for: item.videoName) else {
            print("❌ PLAYER PREPARATION FAILED: VIDEO RESOURCE MISSING: \(item.videoName)")
            return false
        }

        do {
            let asset = AVURLAsset(url: videoURL)
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else {
                print("❌ PLAYER PREPARATION FAILED: ASSET NOT PLAYABLE: \(item.videoName)")
                return false
            }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard !videoTracks.isEmpty else {
                print("❌ PLAYER PREPARATION FAILED: VIDEO TRACK MISSING: \(item.videoName)")
                return false
            }
            print("✅ VIDEO TRACK FOUND: \(item.videoName)")

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if audioTracks.isEmpty {
                print("❌ AUDIO TRACK MISSING: \(item.videoName)")
            } else {
                print("✅ AUDIO TRACK FOUND: \(item.videoName)")
            }

            let playerItem = AVPlayerItem(asset: asset)
            let duration = try await asset.load(.duration)
            let seconds = duration.seconds
            if seconds.isFinite, seconds > 0, !audioTracks.isEmpty {
                // Media-timed ramps stay smooth even if a scene frame is late.
                // Fade the soundtrack only; the entire video still plays to its end.
                let fadeIn = CMTime(seconds: min(0.45, seconds / 3), preferredTimescale: 600)
                let fadeOut = CMTime(seconds: min(0.60, seconds / 3), preferredTimescale: 600)
                let fadeOutStart = duration - fadeOut
                let mix = AVMutableAudioMix()
                mix.inputParameters = audioTracks.map { track in
                    let input = AVMutableAudioMixInputParameters(track: track)
                    input.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                        timeRange: CMTimeRange(start: .zero, duration: fadeIn))
                    input.setVolume(1, at: fadeIn)
                    input.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                        timeRange: CMTimeRange(start: fadeOutStart, duration: fadeOut))
                    return input
                }
                playerItem.audioMix = mix
            }
            // A card can be hidden or another preview can start while these
            // asset loads suspend. A cancelled load must not replace the item
            // used by the newer preview or restart an off-screen decoder.
            guard !Task.isCancelled else { return false }
            if hasPreparedPlayer { return true }
            player.replaceCurrentItem(with: playerItem)
            hasPreparedPlayer = true
            print("✅ PLAYER PREPARED:", item.title)
            return true
        } catch {
            print("❌ PLAYER PREPARATION FAILED: \(item.videoName) \(error)")
            return false
        }
    }

    private func fadeAudio(
        to targetVolume: Float,
        duration: TimeInterval,
        generation: Int,
        completion: (() -> Void)? = nil
    ) {
        let startVolume = player.volume
        let steps = 10

        audioFadeTask = Task { @MainActor in
            for step in 1...steps {
                guard !Task.isCancelled, generation == previewGeneration else {
                    return
                }

                let progress = Float(step) / Float(steps)
                player.volume = startVolume + ((targetVolume - startVolume) * progress)
                try? await Task.sleep(for: .milliseconds(Int((duration / Double(steps)) * 1000)))
            }

            guard generation == previewGeneration else {
                return
            }

            player.volume = targetVolume
            completion?()
        }
    }

    private func setPreviewFocused() {
        let shouldPreview = isPointerHovering || isVisionFocused
        onFocusChanged(shouldPreview)
    }

    private func updatePointerHover(_ isHovering: Bool) {
        guard isPointerHovering != isHovering else {
            return
        }

        isPointerHovering = isHovering
        setPreviewFocused()
    }

    private func configureAudioSessionIfNeeded() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setIntendedSpatialExperience(
                .headTracked(soundStageSize: .medium, anchoringStrategy: .automatic))
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("❌ AUDIO SESSION CONFIG FAILED:", item.title, error)
        }
    }

    private func videoURL(for filename: String) -> URL? {
        let resourceName = (filename as NSString).deletingPathExtension
        let fileExtension = (filename as NSString).pathExtension
        return Bundle.main.url(forResource: resourceName, withExtension: fileExtension)
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerContainerView {
        let view = PlayerLayerContainerView()
        view.clipsToBounds = true
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerLayerContainerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = .resizeAspectFill
    }
}

private final class PlayerLayerContainerView: UIView {
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

private struct MemoryBundleImage: View {
    let name: String

    var body: some View {
        GeometryReader { proxy in
            if let image = image(named: name) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else {
                ZStack {
                    Rectangle()
                        .fill(.black.opacity(0.18))

                    Text("Missing image\n\(name)")
                        .font(.system(size: 18, weight: .regular, design: .default))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding()
                }
                .onAppear {
                    print("❌ MEMORY IMAGE NOT FOUND: \(name)")
                }
            }
        }
    }

    private func image(named name: String) -> UIImage? {
        if let assetImage = UIImage(named: name) {
            return assetImage
        }

        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            return nil
        }

        return UIImage(contentsOfFile: url.path)
    }
}

@MainActor
private enum HomeGlassOrb {
    private struct Presentation: Component { var isMemory: Bool; var isHidden = false }

    static func makeEntity() async -> Entity {
        let root = Entity()
        root.name = "HomeOrbSpatialRoot"
        root.components.set(Presentation(isMemory: false))
        let placement = Entity()
        placement.name = "OrbPlacement"
        placement.position.y = 0.088
        root.addChild(placement)
        let entrance = Entity()
        entrance.name = "OrbEntrance"
        placement.addChild(entrance)
        let floating = Entity()
        entrance.addChild(floating)
        if let tagline = makeHomeText(memory: false) {
            tagline.name = "HomeTagline"
            tagline.position.y = -0.1235
            root.addChild(tagline)
        }
        if let welcome = makeHomeText(memory: true) {
            welcome.name = "HomeWelcomeTitle"
            welcome.position.y = 0.163
            welcome.isEnabled = false
            root.addChild(welcome)
        }
        let frames = (0...192).map { index -> Transform in
            let t = Float(index) / 192 * 2 * .pi
            let blend = (1 - cos(t)) * 0.5
            return Transform(scale: SIMD3(repeating: 0.995 + 0.015 * blend),
                             translation: [0, -0.006 + 0.012 * blend, 0])
        }
        if !UIAccessibility.isReduceMotionEnabled,
           let animation = try? AnimationResource.generate(with: SampledAnimation<Transform>(
            frames: frames, name: "OrbFloat", frameInterval: 12.4 / 192,
            bindTarget: .transform, repeatMode: .repeat)) { floating.playAnimation(animation) }
            // Transparent PBR sphere used as the visible glass orb.
            let orb = ModelEntity(
                mesh: .generateSphere(radius: 0.175),
                materials: [Self.makeGlassMaterial()]
            )
            orb.name = "HomeGlassOrb"
            // Keep explicit colour ordering without an extra depth-only pass
            // over the transparent rectangular inscription/halo planes.
            let inscriptionGroup = ModelSortGroup()
            orb.components.set(ModelSortGroupComponent(group: inscriptionGroup, order: 0))
            orb.components.set(BillboardComponent())
            orb.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.175)]))
            orb.components.set(InputTargetComponent(allowedInputTypes: .all))
            orb.components.set(HoverEffectComponent(.highlight(.init(
                color: UIColor(red: 1, green: 0.83, blue: 0.48, alpha: 1), strength: 0.22,
                opacityFunction: .mask))))
            floating.addChild(orb)

            if let rim = makeEntranceRim() {
                rim.components.set(ModelSortGroupComponent(group: inscriptionGroup, order: 2))
                orb.addChild(rim)
            }

            // Labels share the sphere's actual 3D origin. No SwiftUI overlay
            // depth or seated-view compensation can displace them from the orb.
            for memory in [false, true] {
                if let label = Self.makeInscription(memory: memory) {
                    label.components.set(ModelSortGroupComponent(group: inscriptionGroup, order: 3))
                    label.findEntity(named: "InscriptionHalo")?.components.set(ModelSortGroupComponent(group: inscriptionGroup, order: 1))
                    label.name = memory ? "MemoryInscription" : "HomeInscription"
                    label.isEnabled = !memory
                    orb.addChild(label)
                }
            }
            let wave = Entity()
            wave.name = "OrbWave"
            wave.isEnabled = true
            orb.addChild(wave)
            let segmentMesh = MeshResource.generateBox(size: [1, 0.0019, 0.0002])
            let waveGlow = Self.makeWaveGlowMaterial()
            let segments = (0..<48).map { _ in
                var ink = UnlitMaterial(color: .white, applyPostProcessToneMap: false)
                ink.blending = .transparent(opacity: .init(floatLiteral: 0.90))
                ink.readsDepth = false
                ink.writesDepth = false
                let segment = ModelEntity(mesh: segmentMesh, materials: [ink])
                segment.components.set(ModelSortGroupComponent(group: inscriptionGroup, order: 2))
                if let waveGlow {
                    let halo = ModelEntity(mesh: .generatePlane(width: 1, height: 0.012), materials: [waveGlow])
                    halo.position.z = -0.0001
                    halo.components.set(ModelSortGroupComponent(group: inscriptionGroup, order: 1))
                    segment.addChild(halo)
                }
                wave.addChild(segment)
                return segment
            }
            for (index, segment) in segments.enumerated() {
                let frames: [Transform] = (0...192).map { frame in
                    let phase = UIAccessibility.isReduceMotionEnabled ? 0 : Float(frame) / 192 * 2 * .pi
                    func point(_ i: Int) -> SIMD3<Float> {
                        let t = Float(i) / 48
                        let envelope = pow(max(0, sin(.pi * t)), 0.7)
                        return [(t - 0.5) * 0.115, -0.050 + sin(t * 2 * .pi - phase) * 0.008 * envelope, 0.002]
                    }
                    let a = point(index), b = point(index + 1), delta = b - a
                    let t = (Float(index) + 0.5) / 48
                    return Transform(scale: [simd_length(delta) + 0.0004,
                        0.65 + 0.70 * (0.5 - 0.5 * cos(t * 4 * .pi - phase)), 1],
                        rotation: simd_quatf(angle: atan2(delta.y, delta.x), axis: [0, 0, 1]),
                        translation: (a + b) / 2)
                }
                segment.transform = frames[0]
                if !UIAccessibility.isReduceMotionEnabled,
                   let animation = try? AnimationResource.generate(with: SampledAnimation<Transform>(
                    frames: frames, name: "OrbWave", frameInterval: 3.2 / 192,
                    bindTarget: .transform, repeatMode: .repeat)) { segment.playAnimation(animation) }
            }

            // Room reflections give the original 3D orb curved highlights without
            // taking dynamic-light slots away from the house ceiling lights.
            if let url = Bundle.main.url(forResource: "REWindBedroom", withExtension: "hdr"),
               let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
               let environment = try? await EnvironmentResource(equirectangular: image, withName: "HomeOrbBedroomReflection") {
                let reflection = Entity()
                reflection.name = "HomeOrbReflection"
                reflection.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: -1.10 + InteriorLightingManager.exposureOffset))
                root.addChild(reflection)
                orb.components.set(ImageBasedLightReceiverComponent(imageBasedLight: reflection))
            }

        return root
    }

    static func resetToLaunch(_ root: Entity) {
        root.stopAllAnimations(recursive: false)
        root.components.set(OpacityComponent(opacity: 1))
        root.findEntity(named: "HomeGlassOrb")?.components.set(InputTargetComponent(allowedInputTypes: .all))
        root.components.set(Presentation(isMemory: false))
        if let placement = root.findEntity(named: "OrbPlacement") {
            placement.stopAllAnimations(recursive: false)
            placement.position = [0, 0.088, 0]
        }
        root.findEntity(named: "HomeTagline")?.isEnabled = true
        root.findEntity(named: "HomeWelcomeTitle")?.isEnabled = false
        root.findEntity(named: "HomeInscription")?.isEnabled = true
        root.findEntity(named: "MemoryInscription")?.isEnabled = false
        root.findEntity(named: "OrbWave")?.isEnabled = true
        playEntrance(root)
    }

    private static func makeEntranceRim() -> ModelEntity? {
        // One small annular mesh: no extra light, texture, or per-frame task.
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let segments = 128
        for i in 0...segments {
            let angle = Float(i) / Float(segments) * 2 * Float.pi
            for radius in [Float(0.1725), Float(0.1755)] {
                positions.append([cos(angle) * radius, sin(angle) * radius, 0.035])
            }
            if i < segments {
                let j = UInt32(i * 2)
                indices += [j, j + 1, j + 2, j + 1, j + 3, j + 2]
            }
        }
        var descriptor = MeshDescriptor(name: "HomeOrbEntranceRim")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }
        var material = UnlitMaterial(color: UIColor(red: 1, green: 0.9, blue: 0.73, alpha: 1))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.32))
        material.readsDepth = false
        material.writesDepth = false
        material.faceCulling = .none
        let rim = ModelEntity(mesh: mesh, materials: [material])
        rim.name = "HomeOrbEntranceRim"
        rim.components.set(OpacityComponent(opacity: 0))
        return rim
    }

    static func playEntrance(_ root: Entity) {
        guard let entrance = root.findEntity(named: "OrbEntrance") else { return }
        entrance.stopAllAnimations(recursive: false)
        if let rim = root.findEntity(named: "HomeOrbEntranceRim") {
            rim.stopAllAnimations(recursive: false)
            rim.components.set(OpacityComponent(opacity: 0))
            let frames = (0...72).map { index -> Float in
                let t = Float(index) / 72
                return index == 72 ? 0 : 0.55 * pow(sin(Float.pi * t), 2)
            }
            if let reveal = try? AnimationResource.generate(with: SampledAnimation<Float>(
                frames: frames, name: "HomeOrbRimReveal", frameInterval: 1.1 / 72,
                bindTarget: .opacity, fillMode: .forwards)) { rim.playAnimation(reveal) }
        }
        let reducedMotion = UIAccessibility.isReduceMotionEnabled
        let transforms = (0...72).map { index -> Transform in
            let t = Float(index) / 72
            // Three-centimetre descent with a single, softly damped overshoot.
            let displacement = reducedMotion ? 0 : 0.03 * exp(-7 * t) * cos(2 * .pi * t)
            return Transform(translation: [0, index == 72 ? 0 : displacement, 0])
        }
        let opacity = (0...72).map { index -> Float in
            let t = min(1, Float(index) / 48)
            return t * t * (3 - 2 * t)
        }
        entrance.transform = transforms[0]
        entrance.components.set(OpacityComponent(opacity: 0))
        if let slide = try? AnimationResource.generate(with: SampledAnimation<Transform>(
            frames: transforms, name: "HomeOrbEntrance", frameInterval: 0.8 / 72,
            bindTarget: .transform, fillMode: .forwards)) { entrance.playAnimation(slide) }
        else { entrance.transform = Transform() }
        if let fade = try? AnimationResource.generate(with: SampledAnimation<Float>(
            frames: opacity, name: "HomeOrbEntranceFade", frameInterval: 0.8 / 72,
            bindTarget: .opacity, fillMode: .forwards)) { entrance.playAnimation(fade) }
        else { entrance.components.set(OpacityComponent(opacity: 1)) }
    }

    static func update(_ root: Entity, state: HomeUIState) {
        root.isEnabled = true
        guard let orb = root.findEntity(named: "HomeGlassOrb") else { return }
        let hidden = state == .memories
        if var presentation = root.components[Presentation.self], presentation.isHidden != hidden {
            presentation.isHidden = hidden
            root.components.set(presentation)
            root.stopAllAnimations(recursive: false)
            root.components.set(OpacityComponent(opacity: hidden ? 1 : 0))
            let frames = (0...24).map { index -> Float in
                let t = Float(index) / 24
                let eased = t * t * (3 - 2 * t)
                return hidden ? 1 - eased : eased
            }
            if let fade = try? AnimationResource.generate(with: SampledAnimation<Float>(
                frames: frames, name: "HomeToCardsFade", frameInterval: 0.4 / 24,
                bindTarget: .opacity, fillMode: .forwards)) { root.playAnimation(fade) }
            else { root.components.set(OpacityComponent(opacity: hidden ? 0 : 1)) }
            if hidden { orb.components.remove(InputTargetComponent.self) }
            else { orb.components.set(InputTargetComponent(allowedInputTypes: .all)) }
        }
        // Keep the memory inscription unchanged while the orb fades away.
        guard !hidden else { return }
        let memory = state == .welcome
        guard root.components[Presentation.self]?.isMemory != memory else { return }
        root.components.set(Presentation(isMemory: memory))
        if let placement = root.findEntity(named: "OrbPlacement") {
            var target = placement.transform
            target.translation.y = memory ? -0.118 : 0.088
            placement.move(to: target, relativeTo: root, duration: 0.9, timingFunction: .easeInOut)
        }
        root.findEntity(named: "HomeTagline")?.isEnabled = !memory
        root.findEntity(named: "HomeWelcomeTitle")?.isEnabled = memory
        orb.findEntity(named: "MemoryInscription")?.isEnabled = memory
        orb.findEntity(named: "HomeInscription")?.isEnabled = !memory
        orb.findEntity(named: "OrbWave")?.isEnabled = !memory
    }

    private static func makeHomeText(memory: Bool) -> ModelEntity? {
        // Actual glyph geometry has no rectangular transparent surface for the
        // compositor to depth-sort against the room. Preserve the original font
        // and physical layout of these lines outside the orb.
        let container = ModelEntity()
        let height: CGFloat = memory ? 138 : 50
        func addLine(_ value: String, size: CGFloat, y: CGFloat) {
            let font = UIFont.systemFont(ofSize: size, weight: .regular)
            let measured = (value as NSString).size(withAttributes: [.font: font])
            let mesh = MeshResource.generateText(value, extrusionDepth: 0.00001,
                font: font, containerFrame: .zero, alignment: .center, lineBreakMode: .byClipping)
            var ink = UnlitMaterial(color: .white, applyPostProcessToneMap: false)
            // These are opaque glyph meshes, not a transparent overlay. Write
            // their real depth so headset reprojection keeps each letter at its
            // room position instead of using the distant wall behind it.
            ink.readsDepth = true
            ink.writesDepth = true
            ink.blending = .opaque
            ink.faceCulling = .none
            let glyphs = ModelEntity(mesh: mesh, materials: [ink])
            let bounds = glyphs.visualBounds(relativeTo: glyphs)
            let scale = Float(measured.width / 1000) / max(bounds.extents.x, 0.00001)
            glyphs.scale = SIMD3(repeating: scale)
            glyphs.position = [-bounds.center.x * scale,
                Float((height / 2 - y - measured.height / 2) / 1000) - bounds.center.y * scale, 0.004]
            container.addChild(glyphs)
        }
        if memory {
            addLine("Welcome back.", size: 60, y: 0)
            addLine("Where would you like to go today?", size: 30, y: 102)
        } else { addLine("Memories move you forward.", size: 38, y: 2) }
        return container
    }

    private static func makeInscription(memory: Bool) -> ModelEntity? {
        // Keep the readable glyphs separate from the halo. A higher-resolution,
        // full-opacity foreground keeps the soft light from washing out edges.
        func drawGlyphs() {
            func text(_ value: String, size: CGFloat, centreY: CGFloat) {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: size, weight: .regular),
                    .foregroundColor: UIColor.white
                ]
                let measured = (value as NSString).size(withAttributes: attributes)
                (value as NSString).draw(at: CGPoint(x: (310 - measured.width) / 2, y: centreY - measured.height / 2), withAttributes: attributes)
            }
            if memory {
                let config = UIImage.SymbolConfiguration(pointSize: 82, weight: .light)
                if let icon = UIImage(systemName: "photo.on.rectangle.angled", withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                    let width: CGFloat = 117
                    let height = width * icon.size.height / icon.size.width
                    icon.draw(in: CGRect(x: (310 - width) / 2, y: 126 - height / 2, width: width, height: height))
                }
                text("My Memories", size: 41, centreY: 206)
            } else {
                text("RE.Wind", size: 66, centreY: 126)
            }
        }
        func layer(halo: Bool) -> ModelEntity? {
            let format = UIGraphicsImageRendererFormat()
            format.scale = halo ? 2 : 4
            format.opaque = false
            let image = UIGraphicsImageRenderer(size: CGSize(width: 310, height: 310), format: format).image { renderer in
                if halo {
                    renderer.cgContext.setShadow(offset: .zero, blur: 6, color: UIColor.white.withAlphaComponent(0.20).cgColor)
                    drawGlyphs()
                    renderer.cgContext.setShadow(offset: .zero, blur: 2, color: UIColor.white.withAlphaComponent(0.48).cgColor)
                    drawGlyphs()
                } else {
                    drawGlyphs()
                }
            }
            guard let cgImage = image.cgImage,
                  let texture = try? TextureResource(image: cgImage, options: .init(semantic: .color)) else { return nil }
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(tint: .white, texture: .init(texture))
            material.blending = .transparent(opacity: .init(floatLiteral: 1))
            // Discard the empty texels instead of shading a transparent rectangle.
            material.opacityThreshold = halo ? 0.008 : 0.035
            material.readsDepth = false
            material.writesDepth = false
            return ModelEntity(mesh: .generatePlane(width: 0.31, height: 0.31), materials: [material])
        }
        guard let entity = layer(halo: false) else { return nil }
        entity.position.z = 0.001
        if let halo = layer(halo: true) {
            halo.name = "InscriptionHalo"
            halo.position.z = -0.0001
            entity.addChild(halo)
        }
        return entity
    }

    private static func makeWaveGlowMaterial() -> UnlitMaterial? {
        // One small shared gradient gives the moving line a soft halo without a light source.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 64), format: format).image { renderer in
            for row in 0..<64 {
                let distance = abs(CGFloat(row) - 31.5) / 31.5
                UIColor.white.withAlphaComponent(0.48 * exp(-distance * distance * 7)).setFill()
                renderer.fill(CGRect(x: 0, y: row, width: 8, height: 1))
            }
        }
        guard let cgImage = image.cgImage,
              let texture = try? TextureResource(image: cgImage, options: .init(semantic: .color)) else { return nil }
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
            material.readsDepth = false
            material.writesDepth = false
        return material
    }

    private static func makeGlassMaterial() -> PhysicallyBasedMaterial {
        // Clear glass-like material: transparent body with softened specular and clearcoat response.
        var material = PhysicallyBasedMaterial()
        // Warm the shared Home/memory glass by reducing cool channels, without extra light.
        material.baseColor = .init(tint: UIColor(red: 1.0, green: 0.92, blue: 0.76, alpha: 1.0))
        material.roughness = .init(floatLiteral: 0.055)
        material.metallic = .init(floatLiteral: 0.0)
        material.specular = .init(floatLiteral: 0.72)
        material.clearcoat = .init(floatLiteral: 0.70)
        material.clearcoatRoughness = .init(floatLiteral: 0.06)
        material.blending = .transparent(opacity: .init(floatLiteral: 0.08))
        return material
    }
}

private struct RotatingOrbRimLight: View {
    var diameter: CGFloat = 250
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            // Diffused underlay for the primary travelling rim reflection.
            Circle()
                .trim(from: 0.0, to: 0.16)
                .stroke(
                    LinearGradient(
                            colors: [
                                .clear,
                                .white.opacity(0.12),
                                Color(red: 1.0, green: 0.98, blue: 0.94).opacity(0.52),
                                .white.opacity(0.16),
                                .clear
                            ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round)
                )
                .blur(radius: 16)
                .rotationEffect(.degrees(rotation))

            // Sharper center of the primary rim reflection.
            Circle()
                .trim(from: 0.0, to: 0.16)
                .stroke(
                    LinearGradient(
                            colors: [
                                .clear,
                                .white.opacity(0.26),
                                Color(red: 1.0, green: 0.985, blue: 0.96).opacity(0.68),
                                .white.opacity(0.28),
                                .clear
                            ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
                )
                .blur(radius: 0.6)
                .rotationEffect(.degrees(rotation))

            // Softer secondary reflection on the opposite side of the orb.
            Circle()
                .trim(from: 0.0, to: 0.24)
                .stroke(
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.10),
                            .white.opacity(0.24),
                            .white.opacity(0.10),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )
                .blur(radius: 6)
                .rotationEffect(.degrees(rotation + 180))
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            print("✅ ROTATING ORB RIM STARTED")
            rotation = 0
            // Continuous one-way 360-degree rim reflection loop.
            withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

private struct AnimatedWaveView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breath: CGFloat = 0

    var body: some View {
        ReferenceOrbWave(breath: breath)
            .stroke(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.95), location: 0),
                        .init(color: .white.opacity(0.90), location: 0.40),
                        .init(color: .white.opacity(0.46), location: 0.76),
                        .init(color: .white.opacity(0.02), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
            .frame(width: 88, height: 18)
            .offset(y: 12)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                    breath = 2 * .pi
                }
            }
    }
}

/// A shallow, continuous crest and trough with stationary ends, as in Home Welcome 1.
private struct ReferenceOrbWave: Shape {
    var breath: CGFloat
    var animatableData: CGFloat {
        get { breath }
        set { breath = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 0...96 {
            let t = CGFloat(i) / 96
            let envelope = pow(sin(.pi * t), 0.7)
            let y = rect.midY - sin(t * 2 * .pi - breath) * rect.height * 0.35 * envelope
            let point = CGPoint(x: rect.minX + t * rect.width, y: y)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

private struct ImmersiveViewPreviewScaffold: View {
    @State private var homeUIState: HomeUIState = .launch
    @State private var isHomeInterfaceVisible = true
    @State private var shouldShowMemorySelectionOnReturn = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.36, green: 0.24, blue: 0.16),
                    Color(red: 0.12, green: 0.09, blue: 0.08)
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
            .ignoresSafeArea()

            HomeLaunchView(
                uiState: $homeUIState,
                isVisible: $isHomeInterfaceVisible,
                shouldShowMemorySelectionOnReturn: $shouldShowMemorySelectionOnReturn,
                completedRoutes: []
            ) { route in
                print("Preview route requested: \(route.title)")
            }
        }
    }
}

#Preview("Home UI Preview") {
    ImmersiveViewPreviewScaffold()
}
