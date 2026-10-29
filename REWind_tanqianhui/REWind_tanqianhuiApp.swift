//
//  REWind_tanqianhuiApp.swift
//  REWind_tanqianhui
//
//  Created by Interactive 3D Design on 4/9/26.
//

import SwiftUI

@main
struct REWind_tanqianhuiApp: App {

    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup(id: appModel.mainWindowID) {
            ContentView()
                .environment(appModel)
        }

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        // Use the same native glass compositing path on device and Simulator.
        // The enclosing authored environment remains visible in this mixed space.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
