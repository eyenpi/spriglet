import SprigletConversation

extension PetRuntime: CompanionPresence {
    var conversationSnapshot: CompanionSnapshot {
        CompanionSnapshot(profile: profile, isSleeping: renderer.isSleeping,
                          recentAffection: interactionMemory.values().affection)
    }

    func conversationAttentionBegan() {
        setConversing(true) { GesturePolicy.attentionCommand(in: $0) }
    }

    func conversationAttentionEnded(with gesture: CompanionGesture) {
        setConversing(false) { GesturePolicy.command(for: gesture, in: $0) }
    }
}
