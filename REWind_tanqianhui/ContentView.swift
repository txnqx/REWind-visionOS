import SwiftUI

/// Launch the real experience instead of presenting Scene as an unlit model preview.
struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var hasAttemptedLaunch = false

    var body: some View {
        VStack(spacing: 20) {
            Text("REWind")
                .font(.largeTitle)
            ToggleImmersiveSpaceButton()
        }
        .padding(40)
        .task {
            guard !hasAttemptedLaunch,
                  ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
                  appModel.immersiveSpaceState == .closed else { return }
            hasAttemptedLaunch = true
            appModel.immersiveSpaceState = .inTransition
            await HandReachMonitor.requestStartupAuthorization()
            switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
            case .opened:
                dismissWindow(id: appModel.mainWindowID)
            default:
                appModel.immersiveSpaceState = .closed
            }
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
