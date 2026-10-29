//
//  HandReachMonitor.swift
//  REWind_tanqianhui
//
//  ARKit hand tracking used to measure reach extension and wrist rotation, so
//  the activity steps advance on real movement and the dashboard shows real
//  numbers. Falls back to a manual advance when hand tracking is unavailable
//  (Simulator, or authorization declined), and reports that it did.
//

import ARKit
import Foundation
import simd

// A single reach event: the furthest extension reached in one push, and which
// hands were involved.
struct ReachEvent {
    let extensionCentimetres: Double
    let usedLeftHand: Bool
    let usedRightHand: Bool
}

struct HandGraspSample {
    let isLeft: Bool
    let isTracked: Bool
    let palmPosition: SIMD3<Float>
    let orientation: simd_quatf
    let curledFingers: Int
    let openFingers: Int
    var pinchPosition: SIMD3<Float>? = nil
    var isPrecisionGrip: Bool = false
    var isPrecisionGripReleased: Bool = false
}

@MainActor
@Observable
final class HandReachMonitor {
    enum Availability {
        case unknown
        // Hand tracking is running and measurements are real.
        case tracking
        // Hand tracking is not usable; step advance falls back to a manual tap.
        case unavailable(reason: String)

        var isTracking: Bool {
            if case .tracking = self {
                return true
            }

            return false
        }
    }

    private enum Constants {
        // Extension past this, from the resting baseline, counts as a reach.
        static let reachTriggerCentimetres: Double = 14.0
        // The hand must come back inside this before another reach can be counted,
        // so one slow push does not register repeatedly.
        static let reachResetCentimetres: Double = 7.0
        // Samples collected at rest to establish the neutral hand position.
        static let baselineSampleCount = 45
        // Per-update wrist rotation above this is treated as tracking noise or a
        // re-acquisition jump rather than real movement.
        static let maximumRotationStepDegrees: Double = 25.0
        // Rotation below this is drift, not intent.
        static let minimumRotationStepDegrees: Double = 1.5
    }

    private(set) var availability: Availability = .unknown
    // Live extension of the furthest-forward hand, in centimetres from rest.
    private(set) var currentExtensionCentimetres: Double = 0
    // Total wrist rotation swept since monitoring started, in degrees.
    private(set) var wristRotationDegrees: Double = 0

    // Local hand key. ARKit's own chirality type is not relied on for Hashable
    // conformance, so state is keyed by this instead.
    private enum Hand: Hashable {
        case left
        case right

        init(_ chirality: HandAnchor.Chirality) {
            switch chirality {
            case .left:
                self = .left
            case .right:
                self = .right
            @unknown default:
                self = .right
            }
        }
    }

    var onHandPose: ((HandGraspSample) -> Void)?
    private var session: ARKitSession?
    private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var trackingPreparation: Task<Void, Never>?
    @ObservationIgnored private var trackingGeneration = 0
    private var onReach: ((ReachEvent) -> Void)?

    // Per-hand state.
    private var baselineSamples: [Hand: [SIMD3<Float>]] = [:]
    private var baselines: [Hand: SIMD3<Float>] = [:]
    private var extensions: [Hand: Double] = [:]
    private var isArmed: [Hand: Bool] = [.left: true, .right: true]
    private var peakExtensionThisReach: Double = 0
    private var handsUsedThisReach: Set<Hand> = []
    private var lastWristOrientation: [Hand: simd_quatf] = [:]

    /// Resolve the system prompt before presenting the home experience.
    static func requestStartupAuthorization() async {
        guard HandTrackingProvider.isSupported else { return }
        _ = await ARKitSession().requestAuthorization(for: [.handTracking])
    }

    @ObservationIgnored private var lastMetricPublish = Date.distantPast
    @ObservationIgnored private var measuredRotation: Double = 0

    // Starts hand tracking. `onReach` fires once per completed reach gesture.
    func start(onReach: @escaping (ReachEvent) -> Void) async {
        self.onReach = onReach
        resetMeasurements()
        await prepareTracking()
    }

    /// Start the provider during the journey. Arrival only attaches the activity
    /// callbacks, so a first grasp need not wait for a new ARKit session to start.
    func prepareTracking() async {
        if updateTask != nil { return }
        if let trackingPreparation { await trackingPreparation.value; return }
        trackingGeneration += 1
        let generation = trackingGeneration
        let preparation = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.startProvider()
        }
        trackingPreparation = preparation
        await preparation.value
        if generation == trackingGeneration { trackingPreparation = nil }
    }

    private func startProvider() async {
        guard !Task.isCancelled else { return }
        guard HandTrackingProvider.isSupported else {
            availability = .unavailable(reason: "Hand tracking is not supported on this device")
            print("ℹ️ HAND TRACKING: unsupported, using manual advance")
            return
        }

        let session = ARKitSession()
        self.session = session

        let authorization = await session.requestAuthorization(for: [.handTracking])
        guard !Task.isCancelled, self.session === session else { return }
        guard authorization[.handTracking] == .allowed else {
            availability = .unavailable(reason: "Hand tracking permission was not granted")
            print("ℹ️ HAND TRACKING: not authorized, using manual advance")
            return
        }

        let provider = HandTrackingProvider()

        do {
            try await session.run([provider])
        } catch {
            availability = .unavailable(reason: "Hand tracking could not start")
            print("❌ HAND TRACKING: run failed: \(error)")
            return
        }

        guard !Task.isCancelled, self.session === session else { session.stop(); return }
        availability = .tracking
        print("✅ HAND TRACKING: running")

        updateTask = Task { @MainActor [weak self] in
            for await update in provider.anchorUpdates {
                guard !Task.isCancelled else {
                    return
                }

                self?.handle(update.anchor)
            }
        }
    }

    func stop() {
        wristRotationDegrees = measuredRotation
        trackingGeneration += 1
        trackingPreparation?.cancel(); trackingPreparation = nil
        updateTask?.cancel()
        updateTask = nil
        session?.stop()
        session = nil
        onReach = nil
        onHandPose = nil
    }

    // Used by the manual fallback so a reach is still recorded, flagged as
    // unmeasured rather than given an invented distance.
    func recordManualAdvance() {
        onReach?(ReachEvent(extensionCentimetres: 0, usedLeftHand: false, usedRightHand: false))
    }

    private func resetMeasurements() {
        baselineSamples = [:]
        baselines = [:]
        extensions = [:]
        isArmed = [.left: true, .right: true]
        peakExtensionThisReach = 0
        handsUsedThisReach = []
        lastWristOrientation = [:]
        currentExtensionCentimetres = 0
        wristRotationDegrees = 0
        measuredRotation = 0
        lastMetricPublish = .distantPast
    }

    private func handle(_ anchor: HandAnchor) {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
            onHandPose?(HandGraspSample(isLeft: anchor.chirality == .left, isTracked: false,
                palmPosition: .zero, orientation: simd_quatf(), curledFingers: 0, openFingers: 0))
            let hand = Hand(anchor.chirality)
            lastWristOrientation[hand] = nil
            extensions[hand] = nil
            currentExtensionCentimetres = extensions.values.max() ?? 0
            return
        }

        let hand = Hand(anchor.chirality)
        let originFromAnchor = anchor.originFromAnchorTransform

        let fingers: [[HandSkeleton.JointName]] = [
            [.indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip],
            [.middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip],
            [.ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip],
            [.littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip]
        ]
        let metacarpals: [HandSkeleton.JointName] = [
            .indexFingerMetacarpal, .middleFingerMetacarpal,
            .ringFingerMetacarpal, .littleFingerMetacarpal
        ]
        var curled = 0, open = 0
        for (finger, metacarpalName) in zip(fingers, metacarpals) {
            let joints = finger.map { skeleton.joint($0) }
            let points = joints.map { position(of: $0.anchorFromJointTransform) }
            // A carton grasp can bend at the knuckle while the finger's other
            // joints stay fairly straight. Tip-to-knuckle distance misses it.
            let metacarpal = skeleton.joint(metacarpalName)
            var knuckleBent = false
            if metacarpal.isTracked, joints[0].isTracked, joints[1].isTracked {
                let palmBone = points[0] - position(of: metacarpal.anchorFromJointTransform)
                let proximal = points[1] - points[0]
                if simd_length(palmBone) > 0.005, simd_length(proximal) > 0.005 {
                    knuckleBent = simd_dot(simd_normalize(palmBone), simd_normalize(proximal)) < 0.70
                }
            }
            if knuckleBent {
                curled += 1
                continue
            }
            if joints.allSatisfy(\.isTracked) {
                let length = zip(points, points.dropFirst()).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) }
                let ratio = simd_distance(points[0], points[3]) / max(0.001, length)
                if ratio < 0.86 { curled += 1 }
                if ratio > 0.90 { open += 1 }
            } else if joints.prefix(3).allSatisfy(\.isTracked) {
                // In a whole-hand grasp the fingertip can be hidden by the
                // palm. A tracked bend at the proximal joint still establishes
                // curl; never infer an open/release from an occluded tip.
                let proximal = points[1] - points[0]
                let middle = points[2] - points[1]
                if simd_length(proximal) > 0.005, simd_length(middle) > 0.005,
                   simd_dot(simd_normalize(proximal), simd_normalize(middle)) < 0.75 {
                    curled += 1
                }
            }
        }

        let palm = skeleton.joint(.middleFingerKnuckle)
        let wristJoint = skeleton.joint(.wrist)
        // Keep a closed hand tracked when the middle knuckle is briefly occluded.
        // Prefer another tracked knuckle; the wrist remains the stable pose source.
        let knuckle = [palm, skeleton.joint(.indexFingerKnuckle), skeleton.joint(.ringFingerKnuckle)]
            .first(where: \.isTracked)
        if let knuckle, wristJoint.isTracked {
            let wristWorld = originFromAnchor * wristJoint.anchorFromJointTransform
            let palmWorld = originFromAnchor * knuckle.anchorFromJointTransform
            let thumb = skeleton.joint(.thumbTip)
            let index = skeleton.joint(.indexFingerTip)
            let precisionGrip = thumb.isTracked && index.isTracked &&
                simd_distance(position(of: thumb.anchorFromJointTransform), position(of: index.anchorFromJointTransform)) < 0.035
            onHandPose?(HandGraspSample(isLeft: anchor.chirality == .left, isTracked: true,
                palmPosition: (position(of: wristWorld) + position(of: palmWorld)) * 0.5,
                orientation: orientation(of: wristWorld), curledFingers: curled, openFingers: open,
                pinchPosition: thumb.isTracked && index.isTracked
                    ? position(of: originFromAnchor * thumb.anchorFromJointTransform) * 0.5
                      + position(of: originFromAnchor * index.anchorFromJointTransform) * 0.5 : nil,
                isPrecisionGrip: precisionGrip,
                isPrecisionGripReleased: thumb.isTracked && index.isTracked &&
                    simd_distance(position(of: thumb.anchorFromJointTransform), position(of: index.anchorFromJointTransform)) > 0.055))
        } else {
            onHandPose?(HandGraspSample(isLeft: anchor.chirality == .left, isTracked: false,
                palmPosition: .zero, orientation: simd_quatf(), curledFingers: 0, openFingers: 0))
        }

        // Fingertip position drives reach; it is the furthest-travelling joint and
        // is what actually arrives at the target.
        let fingertip = skeleton.joint(.indexFingerTip)
        if fingertip.isTracked {
            let world = originFromAnchor * fingertip.anchorFromJointTransform
            updateReach(hand: hand, fingertipPosition: position(of: world))
        }

        // Wrist orientation drives the rotation measurement.
        let wrist = skeleton.joint(.wrist)
        if wrist.isTracked {
            let world = originFromAnchor * wrist.anchorFromJointTransform
            updateWristRotation(hand: hand, orientation: orientation(of: world))
        }
    }

    private func updateReach(hand: Hand, fingertipPosition: SIMD3<Float>) {
        // Establish the resting position from the first samples of the activity.
        guard let baseline = baselines[hand] else {
            var samples = baselineSamples[hand] ?? []
            samples.append(fingertipPosition)
            baselineSamples[hand] = samples

            if samples.count >= Constants.baselineSampleCount {
                let sum = samples.reduce(SIMD3<Float>.zero, +)
                baselines[hand] = sum / Float(samples.count)
                baselineSamples[hand] = nil
                print("✅ HAND TRACKING: \(hand) rest position captured")
            }

            return
        }

        let extensionMetres = Double(simd_distance(fingertipPosition, baseline))
        let extensionCentimetres = extensionMetres * 100.0
        extensions[hand] = extensionCentimetres
        // Hand control stays at tracking frequency; SwiftUI telemetry does not.
        if Date().timeIntervalSince(lastMetricPublish) >= 0.1 {
            currentExtensionCentimetres = extensions.values.max() ?? 0
            wristRotationDegrees = measuredRotation
            lastMetricPublish = Date()
        }

        let armed = isArmed[hand] ?? true

        if extensionCentimetres >= Constants.reachTriggerCentimetres {
            // Track the peak and which hands contributed while extended.
            peakExtensionThisReach = max(peakExtensionThisReach, extensionCentimetres)
            handsUsedThisReach.insert(hand)
            isArmed[hand] = false
            return
        }

        // The hand has come back to rest. If it had been out past the trigger,
        // that completes one reach.
        if !armed && extensionCentimetres <= Constants.reachResetCentimetres {
            isArmed[hand] = true

            // Only emit once both hands are back inside the reset band, so a
            // two-handed push counts as a single interaction.
            let stillExtended = extensions.contains { key, value in
                key != hand && value > Constants.reachResetCentimetres
            }

            guard !stillExtended, peakExtensionThisReach > 0 else {
                return
            }

            let event = ReachEvent(
                extensionCentimetres: peakExtensionThisReach,
                usedLeftHand: handsUsedThisReach.contains(.left),
                usedRightHand: handsUsedThisReach.contains(.right)
            )
            print("✅ REACH RECORDED: \(Int(event.extensionCentimetres.rounded())) cm, left \(event.usedLeftHand), right \(event.usedRightHand)")

            peakExtensionThisReach = 0
            handsUsedThisReach = []
            onReach?(event)
        }
    }

    private func updateWristRotation(hand: Hand, orientation: simd_quatf) {
        guard let previous = lastWristOrientation[hand] else {
            lastWristOrientation[hand] = orientation
            return
        }

        // Angle of the shortest rotation between the two orientations.
        let relative = simd_normalize(orientation * previous.inverse)
        let clampedReal = min(1.0, max(-1.0, abs(relative.real)))
        let degrees = Double(2.0 * acos(clampedReal)) * 180.0 / .pi

        if degrees > Constants.maximumRotationStepDegrees {
            lastWristOrientation[hand] = orientation
            return
        }
        // Compare against the last accepted sample, so slow deliberate wrist
        // turns accumulate instead of every sub-threshold frame being discarded.
        guard degrees >= Constants.minimumRotationStepDegrees else { return }
        lastWristOrientation[hand] = orientation
        measuredRotation += degrees
    }

    private func position(of matrix: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }

    private func orientation(of matrix: simd_float4x4) -> simd_quatf {
        // Strip scale before reading rotation so a non-unit basis cannot skew the
        // quaternion.
        let x = simd_normalize(SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z))
        let y = simd_normalize(SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z))
        let z = simd_normalize(SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
        return simd_quatf(simd_float3x3(x, y, z))
    }
}
