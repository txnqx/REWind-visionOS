//
//  OutdoorLightingManager.swift
//  REWind_tanqianhui
//
//  Created by OpenAI on 5/9/26.
//

import CoreGraphics
import Foundation
import RealityKit
import simd
import UIKit

@MainActor
enum OutdoorLightingManager {
    // Bright daylight with restrained fill; room fixtures supply local light.
    private enum Constants {
        static let outdoorLightingEntityName = "OutdoorLighting"
        static let imageBasedLightEntityName = "DaytimeSkyImageBasedLight"

        static let leftLightName = "SunLight_Left"
        static let directionalLightIntensity: Float = 72_000
        static let leftLightColor = DirectionalLightComponent.Color(red: 1.0, green: 0.98, blue: 0.95, alpha: 1.0)
        static let leftLightLookFrom = SIMD3<Float>(12.0, 74.0, 24.0)
        static let leftLightLookAt = SIMD3<Float>(-6.0, 44.0, 1.0)

        static let rightLightName = "SunLight_Right"
        static let secondaryDirectionalLightIntensity: Float = 600
        static let rightLightColor = DirectionalLightComponent.Color(red: 1.0, green: 0.96, blue: 0.90, alpha: 1.0)
        static let rightLightLookFrom = SIMD3<Float>(14.0, 58.0, -4.0)
        static let rightLightLookAt = SIMD3<Float>(-8.0, 39.7, 3.2)

        static let skyFillLightName = "SkyFill_Top"
        static let skyFillLightIntensity: Float = 800
        static let skyFillLightColor = DirectionalLightComponent.Color(red: 0.92, green: 0.88, blue: 0.80, alpha: 1.0)
        static let skyFillLightLookFrom = SIMD3<Float>(-6.0, 40.0, 34.0)
        static let skyFillLightLookAt = SIMD3<Float>(-8.0, 40.0, 0.0)

        static let rimLightName = "SunLight_Rim"
        static let rimLightIntensity: Float = 1_000
        static let rimLightColor = DirectionalLightComponent.Color(red: 1.0, green: 0.88, blue: 0.70, alpha: 1.0)
        static let rimLightLookFrom = SIMD3<Float>(18.0, 66.0, 12.0)
        static let rimLightLookAt = SIMD3<Float>(-8.0, 40.0, 2.0)
        // Concentrate shadow precision on the occupied house and garden.
        static let shadowMaximumDistance: Float = 30.0
        // Rendered comparison: 0.15 produces triangular self-shadow bands
        // across the dining floor/furniture. 2 removes those bands without
        // the larger contact-shadow offset seen at 5.
        static let shadowDepthBias: Float = 2.0

        static let windowLightIntensity: Float = 1_500
        static let windowLightColor = SpotLightComponent.Color(red: 1.0, green: 0.92, blue: 0.78, alpha: 1.0)
        static let windowLightInnerAngle: Float = 18.0
        static let windowLightOuterAngle: Float = 44.0
        static let windowLightAttenuationRadius: Float = 14.0
        static let windowLightExteriorOffset: Float = 6.0
        static let windowLightTargetInteriorOffset: Float = 5.0
        static let windowLightExteriorHeightOffset: Float = 3.8
        static let windowLightTargetHeightOffset: Float = -1.0
        static let windowNameFragments = ["window", "windows"]
        static let ignoredWindowNameFragments = ["switch", "location", "camera"]
        static let minimumWindowLightSeparation: Float = 2.25
        static let maximumWindowLightCount = 8

        static let imageBasedLightIntensityExponent: Float = 0.9 + InteriorLightingManager.exposureOffset
        static let environmentExposure: Float = 0.92
        static let skyDomeEntityName = "DaytimeSkyDome"
        static let skyDomeRadius: Float = 500.0

        static let sunDiscEntityName = "SunDisc"
        static let sunDiscDistance: Float = 480.0
        static let sunDiscAngularDiameter: Float = 2.6
        static let sunHaloAngularDiameter: Float = 9.0
        static let sunDiscColor = UIColor(red: 1.0, green: 0.97, blue: 0.90, alpha: 1.0)
        static let sunHaloColor = UIColor(red: 1.0, green: 0.93, blue: 0.76, alpha: 0.16)
        static let skyTextureWidth = 1024
        static let skyTextureHeight = 512
    }

    private struct WindowFixture {
        let entity: Entity
        let path: String
    }

    struct DaytimeSkyLighting {
        let environment: EnvironmentResource?
        let skyDome: Entity?
    }

    private static var cachedDaytimeSkyImage: CGImage?
    private static var cachedDaytimeSkyEnvironment: EnvironmentResource?
    private static var cachedDaytimeSkyTexture: TextureResource?
    private static var leafPlaybackControllers: [AnimationPlaybackController] = []
    private static var leafClips: [(leaf: ModelEntity, animation: AnimationResource)] = []

    static func startLeafPlayback() {
        guard leafPlaybackControllers.isEmpty else { return }
        for clip in leafClips where clip.leaf.scene != nil {
            leafPlaybackControllers.append(clip.leaf.playAnimation(clip.animation))
        }
    }

    static func auditLeafPlayback() {
        startLeafPlayback()
        #if DEBUG
        let playing = leafPlaybackControllers.filter(\.isPlaying).count
        print("Foliage playback: \(playing)/\(leafPlaybackControllers.count) running; times \(leafPlaybackControllers.prefix(3).map(\.time))")
        let leaves = leafClips.map(\.leaf)
        let before = leaves.map { $0.transform.matrix }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let moved = zip(leaves, before).filter { leaf, prior in
                simd_length(leaf.transform.matrix.columns.0 - prior.columns.0) > 0.001
            }.count
            print("Foliage measured motion: \(moved)/\(leaves.count) leaf transforms changed in 1 second")
        }
        #endif
    }

    /// Keep plant assemblies static. Only a few connected leaf pieces near the
    /// outdoor seat flutter, each around its own stem and on a separate phase.
    static func addGentleFoliageMotion(to house: Entity) async {
        leafPlaybackControllers.forEach { $0.stop() }
        leafPlaybackControllers.removeAll()
        leafClips.removeAll()
        guard let marker = house.findEntity(named: "Location_Outdoor") else { return }
        let view = SpawnOffsets.viewMatrix(markerMatrix: marker.transformMatrix(relativeTo: house), markerName: marker.name)
        let seatedEye = view * SIMD4<Float>(0, 1.6, 0, 1)
        let eye = SIMD3<Float>(seatedEye.x, seatedEye.y, seatedEye.z)
        let houseToView = simd_inverse(view)
        var targets: [Entity] = []
        func visit(_ entity: Entity, nearPlant: Bool = false) {
            let near = nearPlant || ["Node_0_001", "Node_0_002", "Node_0_009"].contains(entity.name)
            if near, let model = entity.components[ModelComponent.self], model.materials.contains(where: {
                let name = (($0 as? PhysicallyBasedMaterial)?.name ?? "").lowercased()
                return name.contains("lemontreeleaf") || name.contains("azalealeaf")
            }) { targets.append(entity) }
            for child in entity.children { visit(child, nearPlant: near) }
        }
        visit(house)
        var animatedCount = 0
        for entity in targets {
            guard var model = entity.components[ModelComponent.self] else { continue }
            let original = model.mesh.contents
            guard original.skeletons.isEmpty, original.instances.count == 1,
                  let instance = original.instances.first,
                  let mesh = original.models[instance.model], mesh.parts.count == 1,
                  let part = mesh.parts.first,
                  let indices = part.buffers[.triangleIndices]?.get(UInt32.self)?.elements
                    ?? part.buffers[.triangleIndices]?.get(UInt16.self)?.elements.map(UInt32.init) else { continue }
            let positions = part.positions.elements
            guard !positions.isEmpty, part.buffers.allSatisfy({ id, buffer in
                id == .triangleIndices || id.name.hasPrefix("original") ||
                (buffer.rate == .vertex && buffer.count == positions.count &&
                 (buffer.get(SIMD2<Float>.self) != nil || buffer.get(SIMD3<Float>.self) != nil))
            }) else { continue }
            var parent = Array(positions.indices)
            func root(_ i: Int) -> Int {
                var index = i
                while parent[index] != index { parent[index] = parent[parent[index]]; index = parent[index] }
                return index
            }
            // Import may split vertices at UV/normal seams. Reconnect coincident
            // positions for component discovery, without welding the actual mesh.
            var coincident: [SIMD3<Int32>: Int] = [:]
            for i in positions.indices {
                let p = positions[i] * 100_000
                let key = SIMD3<Int32>(Int32(p.x.rounded()), Int32(p.y.rounded()), Int32(p.z.rounded()))
                if let first = coincident[key] { parent[root(i)] = root(first) }
                else { coincident[key] = i }
            }
            for i in stride(from: 0, to: indices.count, by: 3) {
                let a = root(Int(indices[i]))
                parent[root(Int(indices[i + 1]))] = a; parent[root(Int(indices[i + 2]))] = a
            }
            var pieces: [Int: [UInt32]] = [:]
            for i in stride(from: 0, to: indices.count, by: 3) {
                pieces[root(Int(indices[i])), default: []].append(contentsOf: indices[i...i + 2])
            }
            let entityToHouse = entity.transformMatrix(relativeTo: house)
            var pieceCentres: [Int: SIMD3<Float>] = [:]
            let candidates = pieces.compactMap { key, values -> (Int, Float, SIMD3<Float>)? in
                guard values.count >= 6, values.count <= 150 else { return nil }
                let vertices = Array(Set(values)).map { positions[Int($0)] }
                var low = vertices[0], high = low
                for vertex in vertices { low = simd_min(low, vertex); high = simd_max(high, vertex) }
                let point = instance.transform * SIMD4((low + high) / 2, 1)
                let centre = entity.convert(position: SIMD3(point.x, point.y, point.z), to: house)
                let distance = simd_distance(centre, eye)
                guard distance < 7, centre.z > -0.25, centre.z < eye.z + 3.5 else { return nil }
                pieceCentres[key] = centre
                // Hinge at an end of the leaf card instead of spinning its
                // centre. The tip then moves visibly while the stem stays put.
                let hinge = instance.transform * SIMD4(low.x, (low.y + high.y) / 2, (low.z + high.z) / 2, 1)
                return (key, distance, SIMD3(hinge.x, hinge.y, hinge.z))
            }.sorted { $0.1 < $1.1 }
            // Spread the selected leaves over the visible plant instead of
            // animating a single rigid crown or a tiny adjacent clump.
            let isTree = model.materials.contains {
                (($0 as? PhysicallyBasedMaterial)?.name ?? "").lowercased().contains("lemontreeleaf")
            }
            let budget = 24
            var selected: [(Int, Float, SIMD3<Float>)] = []
            // Animate only the visible outer shell. Interior leaf cards are
            // intentionally retained in the static mesh, even if they are near
            // the viewer. Normalize the crown so tall trees and low bushes use
            // the same exposed-surface test.
            guard let firstCentre = pieceCentres.values.first else { continue }
            var crownMin = firstCentre, crownMax = firstCentre
            for centre in pieceCentres.values {
                crownMin = simd_min(crownMin, centre); crownMax = simd_max(crownMax, centre)
            }
            let crownCentre = (crownMin + crownMax) / 2
            let crownRadius = simd_max((crownMax - crownMin) / 2, SIMD3<Float>(repeating: 0.1))
            var shell: [SIMD2<Int>: Float] = [:]
            func shellCell(_ direction: SIMD3<Float>) -> SIMD2<Int> {
                let azimuth = atan2(direction.y, direction.x)
                let elevation = asin(min(1, max(-1, direction.z)))
                return SIMD2(Int(floor((azimuth + .pi) / (2 * .pi) * 20)),
                             Int(floor((elevation + .pi / 2) / .pi * 10)))
            }
            for centre in pieceCentres.values {
                let radial = (centre - crownCentre) / crownRadius
                let radius = simd_length(radial)
                guard radius > 0.001 else { continue }
                let cell = shellCell(radial / radius)
                shell[cell] = max(shell[cell] ?? 0, radius)
            }
            let towardEye = simd_normalize((eye - crownCentre) / crownRadius)
            var nearby = candidates.filter { item in
                guard let centre = pieceCentres[item.0] else { return false }
                // The closest crown can extend behind the seat. Select the
                // exposed leaves in front of the activity view, not the nearer
                // leaves behind the wearer that made tree motion invisible.
                let inView = houseToView * SIMD4<Float>(centre, 1)
                guard inView.z < -0.5,
                      abs(inView.x) < -inView.z * 1.1,
                      abs(inView.y - 1.6) < -inView.z * 0.9 else { return false }
                let radial = (centre - crownCentre) / crownRadius
                let radius = simd_length(radial)
                guard radius > 0.001 else { return false }
                let direction = radial / radius
                return radius >= 0.90 * (shell[shellCell(direction)] ?? radius)
                    && simd_dot(direction, towardEye) > 0.05
            }
            while !nearby.isEmpty && selected.count < budget {
                let next: Int
                if selected.isEmpty { next = 0 }
                else {
                    next = nearby.indices.max { a, b in
                        func spread(_ item: (Int, Float, SIMD3<Float>)) -> Float {
                            func position(_ point: SIMD3<Float>) -> SIMD3<Float> {
                                let value = entityToHouse * SIMD4<Float>(point, 1)
                                return SIMD3<Float>(value.x, value.y, value.z)
                            }
                            let world = position(item.2)
                            let separation = selected.map { simd_distance(world, position($0.2)) }.min() ?? 0
                            return separation - 0.25 * (item.1 - (candidates.first?.1 ?? 0))
                        }
                        return spread(nearby[a]) < spread(nearby[b])
                    }!
                }
                selected.append(nearby.remove(at: next))
            }
            guard !selected.isEmpty else { continue }
            print("Foliage exposed selection: \(entity.name), \(isTree ? "tree" : "bush"), \(selected.count) leaves")
            let selectedKeys = Set(selected.map { $0.0 })
            var retained = part
            retained.triangleIndices = MeshBuffer(pieces.filter { !selectedKeys.contains($0.key) }.values.flatMap { $0 })
            var staticContents = original
            staticContents.models = .init([.init(id: instance.model, parts: [retained])])
            do {
                let staticMesh = try await MeshResource(from: staticContents)
                var leafModels: [(ModelEntity, SIMD3<Float>)] = []
                for item in selected {
                    let leafIndices = pieces[item.0]!
                    let unique = Array(Set(leafIndices)).sorted()
                    let remap = Dictionary(uniqueKeysWithValues: unique.enumerated().map { ($0.element, UInt32($0.offset)) })
                    var leafPart = MeshResource.Part(id: "leaf", materialIndex: part.materialIndex)
                    for id in part.buffers.keys where id != .triangleIndices && !id.name.hasPrefix("original") {
                        if let values = part.buffers[id]?.get(SIMD2<Float>.self)?.elements {
                            leafPart[LeafSemantic<SIMD2<Float>>(id: id)] = MeshBuffer(unique.map { values[Int($0)] })
                        } else if let values = part.buffers[id]?.get(SIMD3<Float>.self)?.elements {
                            leafPart[LeafSemantic<SIMD3<Float>>(id: id)] = MeshBuffer(unique.map { values[Int($0)] })
                        }
                    }
                    leafPart.triangleIndices = MeshBuffer(leafIndices.map { remap[$0]! })
                    var contents = original
                    contents.models = .init([.init(id: instance.model, parts: [leafPart])])
                    let leaf = ModelEntity(mesh: try await MeshResource(from: contents), materials: model.materials)
                    leaf.name = "IndividualLeaf_\(animatedCount + leafModels.count)"
                    leaf.components.set(DynamicLightShadowComponent(castsShadow: false))
                    leafModels.append((leaf, item.2))
                }
                model.mesh = staticMesh
                entity.components.set(model)
                // Thin alpha foliage keeps a stable shadow from the unmoving
                // branches. Avoid a flickering dynamic shadow per leaf card.
                entity.components.set(DynamicLightShadowComponent(castsShadow: false))
                for (leaf, centre) in leafModels {
                    entity.addChild(leaf)
                    let seed = Float(animatedCount)
                    let leafCentre = leaf.visualBounds(relativeTo: entity).center
                    let stem = simd_normalize(leafCentre - centre)
                    let across = simd_cross(stem, SIMD3<Float>(0, 0, 1))
                    let axis = simd_length(across) > 0.01 ? simd_normalize(across) : SIMD3<Float>(1, 0, 0)
                    let frames = (0...120).map { frame -> Transform in
                        let phase = Float(frame) / 120 * 2 * Float.pi
                        let angle = (0.32 + 0.04 * sin(seed)) * (0.72 * sin(phase + seed) + 0.28 * sin(phase * 2 + seed * 0.7))
                        let rotation = simd_quatf(angle: angle, axis: axis)
                        return Transform(rotation: rotation, translation: centre - rotation.act(centre))
                    }
                    if let animation = try? AnimationResource.generate(with: SampledAnimation<Transform>(frames: frames,
                        name: "IndividualLeafBreeze", frameInterval: (4.8 + seed.truncatingRemainder(dividingBy: 4) * 0.6) / 120,
                        bindTarget: .transform, repeatMode: .repeat)) {
                        leaf.transform = frames[0]
                        leafClips.append((leaf, animation))
                    }
                    animatedCount += 1
                }
            } catch { print("Leaf split retained original: \(error)") }
            await Task.yield()
        }
        print("Foliage breeze: \(animatedCount) individual leaves; plant assemblies stationary")
    }

    private struct LeafSemantic<T>: MeshBufferSemantic {
        typealias Element = T
        let id: MeshBuffers.Identifier
        init(id: MeshBuffers.Identifier) { self.id = id }
    }

    static func makeOutdoorLighting(for houseEntity: Entity? = nil) -> Entity {
        let outdoorLighting = Entity()
        outdoorLighting.name = Constants.outdoorLightingEntityName
        outdoorLighting.addChild(makeDirectionalLight(
            name: Constants.leftLightName,
            color: Constants.leftLightColor,
            intensity: Constants.directionalLightIntensity,
            lookFrom: Constants.leftLightLookFrom,
            lookAt: Constants.leftLightLookAt
        ))
        outdoorLighting.addChild(makeDirectionalLight(
            name: Constants.rightLightName,
            color: Constants.rightLightColor,
            intensity: Constants.secondaryDirectionalLightIntensity,
            lookFrom: Constants.rightLightLookFrom,
            lookAt: Constants.rightLightLookAt,
            castsShadow: false
        ))
        outdoorLighting.addChild(makeDirectionalLight(
            name: Constants.skyFillLightName,
            color: Constants.skyFillLightColor,
            intensity: Constants.skyFillLightIntensity,
            lookFrom: Constants.skyFillLightLookFrom,
            lookAt: Constants.skyFillLightLookAt,
            castsShadow: false
        ))
        outdoorLighting.addChild(makeDirectionalLight(
            name: Constants.rimLightName,
            color: Constants.rimLightColor,
            intensity: Constants.rimLightIntensity,
            lookFrom: Constants.rimLightLookFrom,
            lookAt: Constants.rimLightLookAt,
            castsShadow: false
        ))

        if let houseEntity {
            let windowFixtures = findWindowFixtures(in: houseEntity)
            if windowFixtures.isEmpty {
                print("Warning: Could not find imported window entities for direct window lights.")
            }

            let buildingCenter = horizontalCenter(of: windowFixtures, in: houseEntity)

            for (index, fixture) in windowFixtures.enumerated() {
                let placement = windowLightPlacement(
                    for: fixture,
                    in: houseEntity,
                    around: buildingCenter
                )
                outdoorLighting.addChild(makeWindowSpotLight(
                    name: "WindowLight_\(index + 1)",
                    intensity: Constants.windowLightIntensity,
                    lookFrom: placement.lookFrom,
                    lookAt: placement.lookAt
                ))
            }

            if let entranceDoor = houseEntity.findEntity(named: "Front_door") {
                let entranceFixture = WindowFixture(entity: entranceDoor, path: "Front_door")
                let placement = windowLightPlacement(
                    for: entranceFixture,
                    in: houseEntity,
                    around: buildingCenter
                )
                outdoorLighting.addChild(makeWindowSpotLight(
                    name: "EntranceSunlight",
                    intensity: Constants.windowLightIntensity,
                    lookFrom: placement.lookFrom,
                    lookAt: placement.lookAt
                ))
            } else {
                print("Warning: Could not find Front_door for entrance sunlight.")
            }
        }

        return outdoorLighting
    }

    static func makeDaytimeSkyEnvironment() async -> EnvironmentResource? {
        guard let skyImage = daytimeSkyEquirectangularImage() else {
            return nil
        }

        return await makeDaytimeSkyEnvironment(from: skyImage)
    }

    static func makeDaytimeSkyLighting() async -> DaytimeSkyLighting {
        guard let skyImage = daytimeSkyEquirectangularImage() else {
            return DaytimeSkyLighting(environment: nil, skyDome: nil)
        }

        let environment = await makeDaytimeSkyEnvironment(from: skyImage)
        let skyDome = await makeDaytimeSkyDome(from: skyImage)

        return DaytimeSkyLighting(
            environment: environment,
            skyDome: skyDome
        )
    }

    private static func makeDaytimeSkyEnvironment(from skyImage: CGImage) async -> EnvironmentResource? {
        if let cachedDaytimeSkyEnvironment {
            return cachedDaytimeSkyEnvironment
        }

        do {
            let environment = try await EnvironmentResource(
                equirectangular: skyImage,
                withName: "SoftDaytimeSky"
            )
            cachedDaytimeSkyEnvironment = environment
            return environment
        } catch {
            return nil
        }
    }

    static func makeImageBasedLight(for environment: EnvironmentResource) -> Entity {
        let imageBasedLight = Entity()
        imageBasedLight.name = Constants.imageBasedLightEntityName
        imageBasedLight.components.set(ImageBasedLightComponent(
            source: .single(environment),
            intensityExponent: Constants.imageBasedLightIntensityExponent
        ))

        return imageBasedLight
    }

    static func makeDaytimeSkyDome() async -> Entity? {
        guard let skyImage = daytimeSkyEquirectangularImage() else {
            return nil
        }

        return await makeDaytimeSkyDome(from: skyImage)
    }

    private static func makeDaytimeSkyDome(from skyImage: CGImage) async -> Entity? {
        do {
            let skyTexture: TextureResource
            if let cachedDaytimeSkyTexture {
                skyTexture = cachedDaytimeSkyTexture
            } else {
                skyTexture = try await TextureResource(
                    image: skyImage,
                    withName: "SoftDaytimeSkyTexture",
                    options: TextureResource.CreateOptions(semantic: .color)
                )
                cachedDaytimeSkyTexture = skyTexture
            }
            // Keep visible exterior sky brighter than indoor diffuse surfaces.
            var skyMaterial = PhysicallyBasedMaterial()
            skyMaterial.baseColor = .init(tint: .black)
            skyMaterial.emissiveColor = .init(color: .white, texture: .init(skyTexture))
            skyMaterial.emissiveIntensity = 3.0 * InteriorLightingManager.radianceScale
            skyMaterial.roughness = .init(floatLiteral: 1.0)
            skyMaterial.faceCulling = .front

            let skyDome = ModelEntity(
                mesh: .generateSphere(radius: Constants.skyDomeRadius),
                materials: [skyMaterial]
            )
            skyDome.name = Constants.skyDomeEntityName
            skyDome.components.set(DynamicLightShadowComponent(castsShadow: false))

            return skyDome
        } catch {
            return nil
        }
    }

    /// Visible sun body, aligned to the key light so the disc, the specular highlights and
    /// the cast shadows all point the same way.
    ///
    /// Unlit so it reads as a light source rather than a lit sphere, and billboarded as a
    /// flat disc rather than a sphere because a sphere at this distance shades across its
    /// face and looks like a moon.
    static func makeSunDisc() -> Entity {
        let sunRoot = Entity()
        sunRoot.name = Constants.sunDiscEntityName

        // Direction the key light travels FROM, expressed in the same Z-up house space
        // the other lights use.
        let toSun = simd_normalize(Constants.leftLightLookFrom - Constants.leftLightLookAt)
        let sunPosition = Constants.leftLightLookAt + (toSun * Constants.sunDiscDistance)

        func discRadius(_ angularDiameter: Float) -> Float {
            Constants.sunDiscDistance * tan((angularDiameter * .pi / 180.0) / 2.0)
        }

        // Soft halo first so the bright core draws over it.
        var haloMaterial = UnlitMaterial(color: Constants.sunHaloColor)
        haloMaterial.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        let halo = ModelEntity(
            mesh: .generatePlane(
                width: discRadius(Constants.sunHaloAngularDiameter) * 2.0,
                height: discRadius(Constants.sunHaloAngularDiameter) * 2.0,
                cornerRadius: discRadius(Constants.sunHaloAngularDiameter)
            ),
            materials: [haloMaterial]
        )
        halo.name = "SunHalo"
        halo.components.set(DynamicLightShadowComponent(castsShadow: false))

        let core = ModelEntity(
            mesh: .generatePlane(
                width: discRadius(Constants.sunDiscAngularDiameter) * 2.0,
                height: discRadius(Constants.sunDiscAngularDiameter) * 2.0,
                cornerRadius: discRadius(Constants.sunDiscAngularDiameter)
            ),
            materials: [UnlitMaterial(color: Constants.sunDiscColor)]
        )
        core.name = "SunCore"
        core.components.set(DynamicLightShadowComponent(castsShadow: false))
        // Nudge the core toward the viewer so it draws in front of the halo.
        core.position = SIMD3<Float>(0.0, 0.0, -0.1)

        sunRoot.addChild(halo)
        sunRoot.addChild(core)
        sunRoot.position = sunPosition

        // `look(at:)` aims the entity's -Z at the target, while `generatePlane` lies in the
        // XY plane facing +Z. Aiming at a point reflected through the sun therefore turns
        // the plane's visible face back toward the house.
        let awayFromHouse = sunPosition + (toSun * Constants.sunDiscDistance)
        sunRoot.look(at: awayFromHouse, from: sunPosition, relativeTo: nil)

        // The sun must not receive or occlude scene lighting.
        sunRoot.components.set(OpacityComponent(opacity: 1.0))

        return sunRoot
    }

    private static func daytimeSkyEquirectangularImage() -> CGImage? {
        if let cachedDaytimeSkyImage {
            return cachedDaytimeSkyImage
        }

        let skyImage = makeDaytimeSkyEquirectangularImage()
        cachedDaytimeSkyImage = skyImage
        return skyImage
    }

    static func applyImageBasedLightReceiver(to entity: Entity, imageBasedLight: Entity) {
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: imageBasedLight))

        for child in entity.children {
            applyImageBasedLightReceiver(to: child, imageBasedLight: imageBasedLight)
        }
    }

    private static func makeDirectionalLight(
        name: String,
        color: DirectionalLightComponent.Color,
        intensity: Float,
        lookFrom: SIMD3<Float>,
        lookAt: SIMD3<Float>,
        castsShadow: Bool = true
    ) -> Entity {
        let light = Entity()
        light.name = name
        light.position = lookFrom
        light.look(at: lookAt, from: lookFrom, relativeTo: nil)
        light.components.set(DirectionalLightComponent(color: color, intensity: intensity))

        // Fill and rim lights deliberately do not cast shadows: overlapping shadow sets
        // from multiple directions read as mud, and each caster costs a depth pass.
        if castsShadow {
            light.components.set(DirectionalLightComponent.Shadow(
                maximumDistance: Constants.shadowMaximumDistance,
                depthBias: Constants.shadowDepthBias
            ))
        }

        return light
    }

    private static func makeWindowSpotLight(
        name: String,
        intensity: Float,
        lookFrom: SIMD3<Float>,
        lookAt: SIMD3<Float>
    ) -> Entity {
        let light = Entity()
        light.name = name
        light.position = lookFrom
        light.look(at: lookAt, from: lookFrom, relativeTo: nil)
        light.components.set([
            SpotLightComponent(
                color: Constants.windowLightColor,
                intensity: intensity,
                innerAngleInDegrees: Constants.windowLightInnerAngle,
                outerAngleInDegrees: Constants.windowLightOuterAngle,
                attenuationRadius: Constants.windowLightAttenuationRadius
            ),
            SpotLightComponent.Shadow()
        ])

        return light
    }

    private static func makeFoliageShadowCaster(
        name: String,
        lookFrom: SIMD3<Float>,
        lookAt: SIMD3<Float>
    ) -> Entity {
        let cluster = Entity()
        cluster.name = name

        let beamDirection = simd_normalize(lookAt - lookFrom)
        let horizontalBeam = simd_normalize(SIMD3<Float>(beamDirection.x, beamDirection.y, 0.0))
        let up = SIMD3<Float>(0.0, 0.0, 1.0)
        let lateral = simd_normalize(simd_cross(up, horizontalBeam))
        cluster.position = lookFrom + (beamDirection * 5.4)

        let leafMesh = MeshResource.generateSphere(radius: 0.42)
        let leafMaterial = SimpleMaterial(
            color: UIColor(red: 0.14, green: 0.24, blue: 0.08, alpha: 1.0),
            roughness: 0.9,
            isMetallic: false
        )
        let leafOffsets: [(Float, Float, Float, Float)] = [
            (-1.05, 0.18, 0.00, 0.88),
            (-0.52, 0.82, 0.10, 1.12),
            (0.02, 0.24, -0.08, 0.80),
            (0.58, 0.94, 0.08, 1.04),
            (1.08, 0.28, -0.04, 0.86)
        ]

        let normalAlongX = abs(horizontalBeam.x) > abs(horizontalBeam.y)
        for (index, offset) in leafOffsets.enumerated() {
            let leaf = ModelEntity(mesh: leafMesh, materials: [leafMaterial])
            leaf.name = "LeafShadow_\(index + 1)"
            leaf.position = (lateral * offset.0) + (up * offset.1) + (horizontalBeam * offset.2)
            let size = offset.3
            leaf.scale = normalAlongX
                ? SIMD3<Float>(0.34 * size, 1.45 * size, 0.62 * size)
                : SIMD3<Float>(1.45 * size, 0.34 * size, 0.62 * size)
            cluster.addChild(leaf)
        }

        return cluster
    }

    private static func findWindowFixtures(in houseEntity: Entity) -> [WindowFixture] {
        var fixtures: [WindowFixture] = []
        collectWindowFixtures(in: houseEntity, path: houseEntity.name, fixtures: &fixtures)

        // Imported windows contain several frame, cover, and glass entities at nearly
        // identical positions. Keep one light per physical window so daylight remains
        // bright without stacking dozens of spotlights into overexposed circles.
        var selectedFixtures: [WindowFixture] = []
        var selectedPositions: [SIMD3<Float>] = []

        for fixture in fixtures.sorted(by: { $0.path < $1.path }) {
            let position = Transform(
                matrix: fixture.entity.transformMatrix(relativeTo: houseEntity)
            ).translation

            guard !selectedPositions.contains(where: {
                simd_distance($0, position) < Constants.minimumWindowLightSeparation
            }) else {
                continue
            }

            selectedFixtures.append(fixture)
            selectedPositions.append(position)

            if selectedFixtures.count == Constants.maximumWindowLightCount {
                break
            }
        }

        return selectedFixtures
    }

    private static func collectWindowFixtures(
        in entity: Entity,
        path: String,
        fixtures: inout [WindowFixture]
    ) {
        let lowercasedName = entity.name.lowercased()
        let lowercasedPath = path.lowercased()

        if isWindowFixture(name: lowercasedName, path: lowercasedPath) {
            fixtures.append(WindowFixture(entity: entity, path: path))
        }

        for child in entity.children {
            let childPath = child.name.isEmpty ? path : "\(path)/\(child.name)"
            collectWindowFixtures(in: child, path: childPath, fixtures: &fixtures)
        }
    }

    private static func isWindowFixture(name: String, path: String) -> Bool {
        guard !name.isEmpty,
              !Constants.ignoredWindowNameFragments.contains(where: { path.contains($0) }),
              Constants.windowNameFragments.contains(where: { name.contains($0) || path.contains($0) })
        else {
            return false
        }

        return true
    }

    private static func horizontalCenter(
        of fixtures: [WindowFixture],
        in houseEntity: Entity
    ) -> SIMD3<Float> {
        guard !fixtures.isEmpty else {
            return .zero
        }

        let total = fixtures.reduce(SIMD3<Float>.zero) { partial, fixture in
            partial + Transform(
                matrix: fixture.entity.transformMatrix(relativeTo: houseEntity)
            ).translation
        }
        let average = total / Float(fixtures.count)
        return SIMD3<Float>(average.x, average.y, 0.0)
    }

    private static func windowLightPlacement(
        for fixture: WindowFixture,
        in houseEntity: Entity,
        around buildingCenter: SIMD3<Float>
    ) -> (lookFrom: SIMD3<Float>, lookAt: SIMD3<Float>) {
        let windowPosition = Transform(matrix: fixture.entity.transformMatrix(relativeTo: houseEntity)).translation
        let outwardDirection = horizontalDirection(from: windowPosition, around: buildingCenter)
        let lookFrom = windowPosition
            + (outwardDirection * Constants.windowLightExteriorOffset)
            + SIMD3<Float>(0.0, 0.0, Constants.windowLightExteriorHeightOffset)
        let lookAt = windowPosition
            - (outwardDirection * Constants.windowLightTargetInteriorOffset)
            + SIMD3<Float>(0.0, 0.0, Constants.windowLightTargetHeightOffset)

        print("Window light aimed through imported fixture '\(fixture.path)' from \(lookFrom) toward \(lookAt).")

        return (lookFrom, lookAt)
    }

    private static func horizontalDirection(
        from position: SIMD3<Float>,
        around buildingCenter: SIMD3<Float>
    ) -> SIMD3<Float> {
        let offset = SIMD2<Float>(position.x - buildingCenter.x, position.y - buildingCenter.y)

        if abs(offset.x) > abs(offset.y) {
            return SIMD3<Float>(offset.x >= 0.0 ? 1.0 : -1.0, 0.0, 0.0)
        }

        return SIMD3<Float>(0.0, offset.y >= 0.0 ? 1.0 : -1.0, 0.0)
    }

    private static func makeDaytimeSkyEquirectangularImage() -> CGImage? {
        let width = Constants.skyTextureWidth
        let height = Constants.skyTextureHeight
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        for y in 0..<height {
            let verticalPosition = Float(y) / Float(height - 1)
            // 0 at the horizon line, 1 straight overhead — measured against the same 0.54
            // horizon the ground blend uses, so the ramp lands pale where the sky meets
            // the ground rather than partway up.
            let zenithBlend = min(1.0, max(0.0, (0.54 - verticalPosition) / 0.54))

            // Below the horizon line the environment reads as ground bounce, not sky. A
            // dimmer, warmer lower hemisphere is what gives glossy surfaces a light/dark
            // axis to reflect instead of a uniform white dome.
            let groundBlend = max(0.0, (verticalPosition - 0.54) / 0.46)

            // The painted glow is centred on the key light's own elevation (32 degrees,
            // v = 0.348) rather than on the horizon. Previously the sky's bright patch sat
            // at the horizon while the key light came from well above it, so the brightest
            // part of the sky did not agree with the direction the shadows fell.
            let sunElevationBand = exp(-pow((verticalPosition - 0.348) / 0.16, 2.0))

            for x in 0..<width {
                let longitude = Float(x) / Float(width - 1)
                let wrappedDistance = min(abs(longitude - 0.72), 1.0 - abs(longitude - 0.72))
                let sunGlow = exp(-(wrappedDistance * wrappedDistance) / 0.005) * sunElevationBand

                // A tight, bright sun disc on top of the broad glow. The disc is what a
                // glossy surface actually resolves as a highlight, so without it the sky
                // reads as a flat gradient no matter how saturated it is.
                let sunDisc = exp(-(wrappedDistance * wrappedDistance) / 0.00035) * sunElevationBand

                // Neutral bright sky avoids a blue cast on indoor trim and shared meshes.
                var red = lerp(0.94, 0.78, zenithBlend) + (0.30 * sunGlow) + (0.75 * sunDisc)
                var green = lerp(0.94, 0.77, zenithBlend) + (0.22 * sunGlow) + (0.72 * sunDisc)
                var blue = lerp(0.91, 0.74, zenithBlend) + (0.08 * sunGlow) + (0.62 * sunDisc)

                if groundBlend > 0.0 {
                    red = lerp(red, 0.33, groundBlend)
                    green = lerp(green, 0.30, groundBlend)
                    blue = lerp(blue, 0.26, groundBlend)
                }

                let index = (y * bytesPerRow) + (x * bytesPerPixel)
                pixels[index] = colorChannel(red)
                pixels[index + 1] = colorChannel(green)
                pixels[index + 2] = colorChannel(blue)
                pixels[index + 3] = 255
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let data = Data(pixels) as CFData

        guard
            let colorSpace,
            let provider = CGDataProvider(data: data)
        else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func lerp(_ start: Float, _ end: Float, _ amount: Float) -> Float {
        start + (end - start) * amount
    }

    private static func colorChannel(_ value: Float) -> UInt8 {
        UInt8(clamping: Int(min(value * Constants.environmentExposure, 1.0) * 255.0))
    }
}
