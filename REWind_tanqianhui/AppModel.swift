//
//  AppModel.swift
//  REWind_tanqianhui
//
//  Created by Interactive 3D Design on 4/9/26.
//

import SwiftUI

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let sessionStore = MemorySessionStore()
    let mainWindowID = "MainWindow"
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed
}
