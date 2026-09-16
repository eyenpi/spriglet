import SprigletCore

extension PetRenderView: PetSceneRenderer {
    var sceneState: PetSceneState {
        PetSceneState(isAnimating: isAnimating, isSleeping: isSleeping,
                      hasActiveFrameClock: hasActiveDisplayLink, bufferedFrameCount: bufferedFrameCount)
    }

    @discardableResult
    func perform(_ command: PetSceneCommand) -> Bool {
        switch command {
        case .action(let action): return play(action)
        case .transition(let intent): return transition(to: intent)
        case .routine(let routine, let direction, let stationary):
            return transitionRoutine(routine, direction: direction, stationary: stationary)
        case .sample(let direction):
            return playSample(walk: direction)
        case .resetPose: resetPose()
        case .suspended(let value): setSuspended(value)
        case .interactionHeld(let value): setInteractionHeld(value)
        case .preferredFramesPerSecond(let value): setPreferredFramesPerSecond(value)
        }
        return true
    }
}
