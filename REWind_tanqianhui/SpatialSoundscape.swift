import Foundation
import AVFAudio
import RealityKit

/// Quiet positional sources stay attached to the room or object that makes them.
@MainActor
final class SpatialSoundscape {
    private var resources: [String: AudioFileResource] = [:]
    private var ambience: [AudioPlaybackController] = []
    private var emitters: [Entity] = []
    private var effects: [String: AudioPlaybackController] = [:]
    private var releaseTasks: [String: Task<Void, Never>] = [:]
    private var oneShots: [UUID: AudioPlaybackController] = [:]
    private var generation = 0
    private var musicEmitter: Entity?
    private var musicController: AudioPlaybackController?
    private var musicResource: AudioFileResource?
    private var dadEncouragementPlayed = false
    private var conversationController: AudioPlaybackController?
    private var outdoorEmitter: Entity?
    private var outdoorController: AudioPlaybackController?
    private var outdoorResource: AudioFileResource?
    private var outdoorBlend: Float = 0
    private var pianoPaused = false
    private var bellsTask: Task<Void, Never>?

    // A persistent source keeps its playback cursor while the house moves.
    // Stream the full recorded performance instead of decoding it at each doorway.
    func prepareMusic(on listenerAnchor: Entity) async {
        guard musicController == nil,
              let url = Bundle.main.url(forResource: "ChristmasPiano", withExtension: "m4a") else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let resource = try await AudioFileResource(contentsOf: url,
                configuration: .init(loadingStrategy: .stream, shouldLoop: true))
            guard musicController == nil else { return }
            let source = Entity()
            source.name = "REWindBackgroundPiano"
            source.position = [1.2, 0.1, -1.5]
            // Preserve the recorded stereo piano as a quiet surrounding bed.
            // Physical effects below remain localized to their world sources.
            source.components.set(AmbientAudioComponent(gain: -12))
            listenerAnchor.addChild(source)
            let playback = source.prepareAudio(resource)
            playback.gain = -60
            playback.play()
            playback.fade(to: 0, duration: 1.5)
            musicResource = resource; musicEmitter = source; musicController = playback
        } catch { print("Background piano: \(error)") }
    }

    func beginTravel() {
        generation += 1
        stopPlayback()
        updateOutdoorBlend(outdoorBlend, force: true)
    }


    func enter(_ route: MemoryRoute?, house: Entity, props: Entity?) async {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("Spatial audio session: \(error)") }
        generation += 1
        let ticket = generation
        stopPlayback()
        dadEncouragementPlayed = false
        let names: [String] = ["Twinkle", "CompletionArrival"] + (route == .breakfast ? ["CerealPour", "MilkPour", "Cutlery", "Mixing", "KitchenConversation"] :
            route == .christmasTree ? ["Bells"] : route == .playingBall ? ["BallPass", "BallCatch", "DadEncouragement"] : [])
        // Retain only the active room's decoded audio, not every previous room.
        resources = resources.filter { names.contains($0.key) }
        for name in names {
            guard resources[name] == nil,
                  let url = Bundle.main.url(forResource: name, withExtension: "m4a") ?? Bundle.main.url(forResource: name, withExtension: "wav") else { continue }
            // A speech exporter can leave a header-only file when its voice is
            // unavailable. Do not hand an empty media container to RealityKit.
            guard ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1024 else { continue }
            do {
                let resource = try await AudioFileResource(contentsOf: url, configuration: .init(
                    shouldLoop: !["KitchenConversation", "Bells", "BallPass", "BallCatch", "DadEncouragement", "Twinkle", "CompletionArrival"].contains(name)))
                guard !Task.isCancelled, ticket == generation else { return }
                resources[name] = resource
            } catch { print("Audio resource \(name): \(error)") }
        }
        guard !Task.isCancelled, ticket == generation else { return }
        let markerName = route?.destinationName ?? "Location_Bedroom"
        let marker = house.findEntity(named: markerName) ?? house.findEntity(named: markerName.replacingOccurrences(of: " ", with: "_")) ?? house
        if route == .playingBall { await prepareOutdoorAmbience(house: house) }
        updateOutdoorBlend(route == .playingBall ? 1 : 0, force: true)
        // Restart the existing natural conversation once per Breakfast visit.
        if route == .breakfast, resources["KitchenConversation"] != nil, let props {
            loop("KitchenConversation", parent: props, position: [-1.2, 0.6, -0.8], gain: -15)

        }
        if route == .christmasTree, let resource = resources["Bells"] {
            let source = Entity()
            source.name = "ChristmasBackgroundBells"
            marker.addChild(source)
            let pose = Transform(matrix: marker.transformMatrix(relativeTo: nil))
            source.setTransformMatrix(Transform(translation: pose.translation + pose.rotation.act(SIMD3<Float>(1.2, 0.3, -1.0))).matrix, relativeTo: nil)
            source.components.set(SpatialAudioComponent(gain: -16, reverbLevel: -12, distanceAttenuation: .rolloff(factor: 0.25)))
            emitters.append(source)
            bellsTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(14)) } catch { return }
                    guard let self, self.generation == ticket else { return }
                    let controller = source.prepareAudio(resource)
                    controller.play()
                    self.ambience.append(controller)
                    do { try await Task.sleep(for: .seconds(6)) } catch { return }
                    controller.stop()
                    self.ambience.removeAll { $0 === controller }
                }
            }
        }
        print("Spatial audio: \(resources.count) resources; \(ambience.count) room sources")
    }

    func prepareOutdoorAmbience(house: Entity) async {
        guard outdoorController == nil,
              let url = Bundle.main.url(forResource: "Leaves", withExtension: "m4a") else { return }
        do {
            let resource = try await AudioFileResource(contentsOf: url,
                configuration: .init(loadingStrategy: .stream, shouldLoop: true))
            guard outdoorController == nil else { return }
            let marker = house.findEntity(named: "Location_Outdoor") ?? house
            let source = Entity()
            source.name = "OutdoorWindAndLeaves"
            marker.addChild(source)
            let pose = Transform(matrix: marker.transformMatrix(relativeTo: nil))
            source.setTransformMatrix(Transform(translation: pose.translation + pose.rotation.act(SIMD3<Float>(-2, 0.4, -2))).matrix, relativeTo: nil)
            source.components.set(SpatialAudioComponent(gain: -2, reverbLevel: -18, distanceAttenuation: .rolloff(factor: 0.25)))
            let playback = source.prepareAudio(resource)
            playback.gain = -60
            playback.play()
            outdoorResource = resource; outdoorEmitter = source; outdoorController = playback
        } catch { print("Outdoor wind: \(error)") }
    }

    func updateOutdoorTransition(houseY: Float) {
        // Crossfade at the porch doorway, not after the outdoor activity starts.
        let t = min(1, max(0, (37.7 - houseY) / 1.5))
        updateOutdoorBlend(t * t * (3 - 2 * t))
    }

    private func updateOutdoorBlend(_ blend: Float, force: Bool = false) {
        guard force || abs(blend - outdoorBlend) > 0.025 || (blend != outdoorBlend && (blend == 0 || blend == 1)) else { return }
        outdoorBlend = blend
        outdoorController?.fade(to: blend > 0 ? max(-60, 20 * log10(Double(blend))) : -60, duration: 0.3)
        if blend >= 1 {
            musicController?.pause()
            pianoPaused = true
        } else {
            if pianoPaused { musicController?.gain = -60; musicController?.play(); pianoPaused = false }
            musicController?.fade(to: max(-60, 20 * log10(Double(max(0.001, 1 - blend)))), duration: 0.3)
        }
    }

    private func loop(_ name: String, parent: Entity, position: SIMD3<Float>, gain: Double) {
        guard let resource = resources[name] else { return }
        let emitter = Entity()
        emitter.name = "REWindAudio_\(name)"
        emitter.position = position
        emitter.components.set(SpatialAudioComponent(gain: gain, reverbLevel: -12, distanceAttenuation: .rolloff(factor: 0.25)))
        parent.addChild(emitter)
        // Imported marker scale must not multiply a two-metre sound offset.
        let pose = Transform(matrix: parent.transformMatrix(relativeTo: nil))
        emitter.setTransformMatrix(Transform(translation: pose.translation + pose.rotation.act(position)).matrix, relativeTo: nil)
        emitters.append(emitter)
        let controller = emitter.prepareAudio(resource)
        controller.gain = -60
        controller.play()
        controller.fade(to: 0, duration: name == "KitchenConversation" ? 1.1 : 0.8)
        if name == "KitchenConversation" { conversationController = controller }
        ambience.append(controller)
    }

    func completeActivity(on anchor: Entity) {
        if let conversation = conversationController {
            conversationController = nil
            ambience.removeAll { $0 === conversation }
            conversation.fade(to: -60, duration: 0.85)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                conversation.stop()
            }
        }
        guard let resource = resources["CompletionArrival"] else {
            effect("Twinkle", on: anchor, active: true)
            return
        }
        let source = Entity()
        source.name = "CompletionArrivalAudio"
        source.components.set(AmbientAudioComponent(gain: -12))
        anchor.addChild(source)
        emitters.append(source)
        let controller = source.prepareAudio(resource)
        controller.gain = -60
        controller.play()
        controller.fade(to: 0, duration: 0.06)
        let id = UUID()
        oneShots[id] = controller
        controller.completionHandler = { [weak self, weak source] in
            self?.oneShots.removeValue(forKey: id)
            if let source {
                self?.emitters.removeAll { $0 === source }
                source.removeFromParent()
            }
        }
    }

    func effect(_ name: String, on entity: Entity, active: Bool) {
        if !active {
            guard releaseTasks[name] == nil, let controller = effects[name] else { return }
            // Tiny pauses in a circular gesture must not restart the audio file.
            releaseTasks[name] = Task { @MainActor [weak self] in
                do {
                    if name == "Mixing" || name == "Cutlery" {
                        try await Task.sleep(for: .milliseconds(160))
                    }
                    try Task.checkCancellation()
                    controller.fade(to: -60, duration: 0.08)
                    try await Task.sleep(for: .milliseconds(80))
                    try Task.checkCancellation()
                    controller.stop()
                    self?.effects.removeValue(forKey: name)
                    self?.releaseTasks.removeValue(forKey: name)
                } catch { }
            }
            return
        }
        if let pending = releaseTasks.removeValue(forKey: name) {
            pending.cancel()
            effects[name]?.fade(to: 0, duration: 0.04)
        }
        guard effects[name] == nil, let resource = resources[name] else { return }
        // One quiet encouragement per activity; catches keep their own sound.
        if name == "DadEncouragement" {
            guard !dadEncouragementPlayed else { return }
            dadEncouragementPlayed = true
        }
        let source: Entity
        if ["DadEncouragement", "BallCatch"].contains(name), let parent = entity.parent {
            // A catch/voice stays at Dad, even when the ball departs again.
            let sourceName = name == "DadEncouragement" ? "DadVoiceSource" : "DadCatchSource"
            if let existing = parent.findEntity(named: sourceName) { source = existing }
            else { source = Entity(); source.name = sourceName; parent.addChild(source); emitters.append(source) }
            source.setPosition(entity.position(relativeTo: nil), relativeTo: nil)
        } else {
            let sourceName = "REWindEffect_" + name
            if let existing = entity.findEntity(named: sourceName) { source = existing }
            else {
                source = Entity(); source.name = sourceName
                entity.addChild(source); emitters.append(source)
            }
        }
        source.components.set(SpatialAudioComponent(gain: name == "Cutlery" ? -16 : (name == "Mixing" ? 7 : (name == "MilkPour" || name == "BallPass" ? 0 : (name == "BallCatch" ? -3 : (name == "DadEncouragement" ? -12 : (name == "Twinkle" ? -16 : -3))))), reverbLevel: outdoorBlend > 0.5 ? -24 : -14, distanceAttenuation: .rolloff(factor: 0.35)))
        let controller = source.prepareAudio(resource)
        controller.gain = -60
        controller.play()
        controller.fade(to: 0, duration: 0.06)
        if ["CerealPour", "MilkPour", "Cutlery", "Mixing"].contains(name) {
            effects[name] = controller
        } else {
            let id = UUID()
            oneShots[id] = controller
            controller.completionHandler = { [weak self] in
                self?.oneShots.removeValue(forKey: id)
            }
        }
    }

    func stop() {
        generation += 1; stopPlayback()
        outdoorController?.stop(); outdoorController = nil
        outdoorEmitter?.removeFromParent(); outdoorEmitter = nil; outdoorResource = nil
        outdoorBlend = 0; pianoPaused = false
        musicController?.stop(); musicController = nil
        musicEmitter?.removeFromParent(); musicEmitter = nil; musicResource = nil
    }
    private func stopPlayback() {
        conversationController = nil
        bellsTask?.cancel(); bellsTask = nil
        releaseTasks.values.forEach { $0.cancel() }; releaseTasks.removeAll()
        let retiringControllers = ambience + Array(effects.values) + Array(oneShots.values)
        let retiringEmitters = emitters
        ambience.removeAll(); effects.removeAll(); oneShots.removeAll(); emitters.removeAll()
        retiringControllers.forEach { $0.fade(to: -60, duration: 0.2) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            retiringControllers.forEach { $0.stop() }
            retiringEmitters.forEach { $0.removeFromParent() }
        }
    }
}
