#if DEBUG
import CompanionCore

@MainActor enum DebugIdleMomentValidation {
    static func run() throws {
        for moment in IdleMoment.allCases {
            let parsed = DebugIdleMomentArgument.parse(arguments: ["Spriglet", "-SprigletDebugIdleMoment", name(of: moment)])
            try LifecycleValidation.require(parsed == moment, "Debug idle argument did not parse \(name(of: moment))")
        }
        for arguments in [
            ["Spriglet"],
            ["Spriglet", "-SprigletDebugIdleMoment"],
            ["Spriglet", "-SprigletDebugIdleMoment", "unknown"],
        ] {
            try LifecycleValidation.require(DebugIdleMomentArgument.parse(arguments: arguments) == nil,
                                            "Invalid debug idle argument was accepted")
        }
        print("Debug idle launch argument parsing passed for all moments and invalid inputs.")
    }

    private static func name(of moment: IdleMoment) -> String {
        switch moment {
        case .wander: "wander"
        case .nap: "nap"
        case .doodle: "doodle"
        case .fidget: "fidget"
        }
    }
}
#endif
