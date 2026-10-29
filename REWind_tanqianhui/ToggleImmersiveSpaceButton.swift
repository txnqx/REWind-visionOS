//
//  ToggleImmersiveSpaceButton.swift
//  REWind_tanqianhui
//
//  Created by Interactive 3D Design on 4/9/26.
//

import SwiftUI

struct ToggleImmersiveSpaceButton: View {

    @Environment(AppModel.self) private var appModel
    @State private var statusMessage: String?

    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        VStack(spacing: 12) {
            Button {
                statusMessage = nil

                Task { @MainActor in
                    switch appModel.immersiveSpaceState {
                        case .open:
                            appModel.immersiveSpaceState = .inTransition
                            await dismissImmersiveSpace()
                            // Don't set immersiveSpaceState to .closed because there
                            // are multiple paths to ImmersiveView.onDisappear().
                            // Only set .closed in ImmersiveView.onDisappear().

                        case .closed:
                            appModel.immersiveSpaceState = .inTransition
                            await HandReachMonitor.requestStartupAuthorization()
                            switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
                                case .opened:
                                    // Don't set immersiveSpaceState to .open because there
                                    // may be multiple paths to ImmersiveView.onAppear().
                                    // Only set .open in ImmersiveView.onAppear().
                                    break

                                case .userCancelled:
                                    statusMessage = "Immersive space opening was cancelled."
                                    appModel.immersiveSpaceState = .closed

                                case .error:
                                    statusMessage = "Immersive space failed to open."
                                    appModel.immersiveSpaceState = .closed

                                @unknown default:
                                    statusMessage = "Immersive space did not open."
                                    appModel.immersiveSpaceState = .closed
                            }

                        case .inTransition:
                            // This case should not ever happen because button is disabled for this case.
                            break
                    }
                }
            } label: {
                Text(appModel.immersiveSpaceState == .open ? "Hide Immersive Space" : "Show Immersive Space")
            }
            .disabled(appModel.immersiveSpaceState == .inTransition)
            .animation(.none, value: 0)
            .fontWeight(.semibold)

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
