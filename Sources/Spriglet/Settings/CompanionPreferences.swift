import Foundation
import CompanionCore

enum CharacterSize: String, CaseIterable {
    case small, medium, large
    var scale: Double {
        switch self { case .small, .medium: 0.8; case .large: 1 }
    }
    var form: MallowForm { self == .small ? .fingertipGrip : .standard }
}

enum MovementIntensity: String, CaseIterable {
    case gentle, standard, lively
    var amount: Double {
        switch self { case .gentle: 0.35; case .standard: 1; case .lively: 1.35 }
    }
}

enum HomeLocation: String, CaseIterable { case automatic, left, center, right }

/// Saved choices stay in the native layer. The runtime translates these into
/// scene measurements and a numeric motion amount before reaching the engine.
struct CompanionPreferences: Equatable {
    var characterSize = CharacterSize.medium
    var movementIntensity = MovementIntensity.standard
    var homeDisplayID: String?
    var homeLocation = HomeLocation.automatic
}

struct HomeDisplay: Equatable {
    let id: String
    let name: String
}
