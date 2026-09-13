import AppKit
import SpriteKit
import SprigletCore

@MainActor
final class PrototypePetScene: SKScene {
    var onClipFinished: ((Bool) -> Void)?
    private(set) var sceneUpdateCount: UInt64 = 0
    var hasPendingRequest: Bool { resetRequested || pendingAction != nil }

    private let character = SKNode()
    private let face = SKNode()
    private let openEyes = SKNode()
    private let closedEyes = SKNode()
    private let leaves = SKNode()
    private var hitShapes: [SKShapeNode] = []
    private var pendingAction: PetAction?
    private var activeAction: PetAction?
    private var resetRequested = true
    private var isSleeping = false
    private let restPosition = CGPoint(x: 110, y: 84)

    override init(size: CGSize) {
        super.init(size: size)
        configureScene()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureScene()
    }

    private func configureScene() {
        backgroundColor = .clear
        // Authored content has padding for the square host's vertical crop.
        scaleMode = .aspectFill
        buildPrototypeCharacter()
    }

    /// Requests change Swift state; presented nodes mutate inside callbacks.
    func request(_ action: PetAction) { pendingAction = action }

    func requestReset() {
        resetRequested = true
        pendingAction = nil
    }

    override func update(_ currentTime: TimeInterval) {
        if resetRequested {
            restorePose()
            resetRequested = false
        }
        guard activeAction == nil, let action = pendingAction else { return }
        pendingAction = nil
        activeAction = action
        var clips: [Clip] = []
        if isSleeping, action != .wakeUp, action != .fallAsleep {
            clips.append(clip(for: .wakeUp))
        }
        clips.append(clip(for: action))
        run(clips)
    }

    override func didFinishUpdate() {
        sceneUpdateCount &+= 1
        guard let action = activeAction, animatedNodes.allSatisfy({ !$0.hasActions() }) else { return }
        isSleeping = action == .fallAsleep
        activeAction = nil
        onClipFinished?(isSleeping)
    }

    func containsPet(at point: CGPoint) -> Bool {
        hitShapes.contains { shape in
            shape.path?.contains(shape.convert(point, from: self)) == true
        }
    }

    private var animatedNodes: [SKNode] { [character, face, openEyes, closedEyes, leaves] }

    private func restorePose() {
        for node in animatedNodes { node.removeAllActions() }
        character.position = restPosition
        character.setScale(1)
        character.zRotation = 0
        face.position = .zero
        openEyes.setScale(1)
        openEyes.alpha = 1
        closedEyes.alpha = 0
        leaves.zRotation = 0
        activeAction = nil
        isSleeping = false
    }

    /// Pad each track to its clip boundary so a child cannot spill into a later
    /// clip, including the transition from an authored wake to another action.
    private func run(_ clips: [Clip]) {
        let tracks: [(SKNode, KeyPath<Clip, SKAction?>)] = [
            (character, \.body), (face, \.face), (openEyes, \.eyes),
            (closedEyes, \.eyelids), (leaves, \.leaves)
        ]
        for (node, track) in tracks {
            let actions = clips.flatMap { clip -> [SKAction] in
                guard let action = clip[keyPath: track] else { return [.wait(forDuration: clip.duration)] }
                return [action, .wait(forDuration: max(0, clip.duration - action.duration))]
            }
            node.run(.sequence(actions), withKey: "authoredClip")
        }
    }

    private struct Clip {
        var body: SKAction?
        var face: SKAction?
        var eyes: SKAction?
        var eyelids: SKAction?
        var leaves: SKAction?

        var duration: TimeInterval {
            [body, face, eyes, eyelids, leaves].compactMap { $0?.duration }.max() ?? 0
        }
    }

    private func eased(_ action: SKAction) -> SKAction {
        action.timingMode = .easeInEaseOut
        return action
    }

    private func pose(x: CGFloat = 1, y: CGFloat = 1, lift: CGFloat = 0,
                      tilt: CGFloat = 0, duration: TimeInterval) -> SKAction {
        eased(.group([
            .scaleX(to: x, y: y, duration: duration),
            .move(to: CGPoint(x: restPosition.x, y: restPosition.y + lift), duration: duration),
            .rotate(toAngle: tilt, duration: duration)
        ]))
    }

    private func clip(for action: PetAction) -> Clip {
        switch action {
        case .blink:
            Clip(eyes: .sequence([.scaleY(to: 0.08, duration: 0.07), .wait(forDuration: 0.05),
                                  .scaleY(to: 1, duration: 0.12)]),
                 eyelids: .sequence([.fadeIn(withDuration: 0.07), .wait(forDuration: 0.05),
                                     .fadeOut(withDuration: 0.12)]))
        case .lookAround:
            Clip(body: .sequence([pose(tilt: 0.025, duration: 0.30), .wait(forDuration: 0.33),
                                  pose(tilt: -0.02, duration: 0.37), .wait(forDuration: 0.30), pose(duration: 0.30)]),
                 face: .sequence([eased(.move(to: CGPoint(x: -5, y: 1), duration: 0.24)), .wait(forDuration: 0.36),
                                  eased(.move(to: CGPoint(x: 5, y: 2), duration: 0.38)), .wait(forDuration: 0.32),
                                  eased(.move(to: .zero, duration: 0.30))]),
                 leaves: .sequence([eased(.rotate(toAngle: -0.06, duration: 0.4)),
                                    eased(.rotate(toAngle: 0.05, duration: 0.7)),
                                    eased(.rotate(toAngle: 0, duration: 0.5))]))
        case .stretch:
            Clip(body: .sequence([pose(x: 1.04, y: 0.94, lift: -2, duration: 0.22),
                                  pose(x: 0.95, y: 1.10, lift: 5, duration: 0.4), .wait(forDuration: 0.2),
                                  pose(x: 1.02, y: 0.97, lift: -1, duration: 0.26), pose(duration: 0.28)]),
                 eyes: .sequence([eased(.scaleY(to: 0.35, duration: 0.35)), .wait(forDuration: 0.4),
                                  eased(.scaleY(to: 1, duration: 0.45))]),
                 leaves: .sequence([eased(.rotate(toAngle: 0.08, duration: 0.55)),
                                    eased(.rotate(toAngle: 0, duration: 0.8))]))
        case .fallAsleep:
            Clip(body: .sequence([pose(x: 1.02, y: 0.96, lift: -2, tilt: 0.015, duration: 0.42),
                                  pose(x: 1.04, y: 0.91, lift: -4, tilt: 0.025, duration: 0.63)]),
                 face: eased(.move(to: CGPoint(x: 0, y: -2), duration: 0.7)),
                 eyes: .sequence([eased(.scaleY(to: 0.45, duration: 0.42)),
                                  .group([.scaleY(to: 0.08, duration: 0.42), .fadeOut(withDuration: 0.42)])]),
                 eyelids: .sequence([.wait(forDuration: 0.4), .fadeIn(withDuration: 0.44)]),
                 leaves: eased(.rotate(toAngle: -0.10, duration: 1.05)))
        case .wakeUp:
            Clip(body: .sequence([pose(x: 1.04, y: 0.9, lift: -4, tilt: 0.01, duration: 0.2),
                                  pose(x: 0.98, y: 1.05, lift: 3, tilt: -0.01, duration: 0.4), pose(duration: 0.34)]),
                 face: eased(.move(to: .zero, duration: 0.72)),
                 eyes: .sequence([.wait(forDuration: 0.16),
                                  .group([.fadeIn(withDuration: 0.34), .scaleY(to: 0.7, duration: 0.34)]),
                                  .scaleY(to: 1, duration: 0.2)]),
                 eyelids: .sequence([.wait(forDuration: 0.16), .fadeOut(withDuration: 0.26)]),
                 leaves: .sequence([eased(.rotate(toAngle: 0.06, duration: 0.38)),
                                    eased(.rotate(toAngle: 0, duration: 0.56))]))
        case .react:
            Clip(body: .sequence([pose(x: 1.07, y: 0.91, lift: -3, tilt: -0.05, duration: 0.12),
                                  pose(x: 0.96, y: 1.06, lift: 24, tilt: 0.05, duration: 0.2),
                                  pose(x: 1.03, y: 0.95, lift: -2, tilt: -0.025, duration: 0.24), pose(duration: 0.22)]),
                 face: .sequence([eased(.move(to: CGPoint(x: 0, y: 2), duration: 0.28)),
                                  eased(.move(to: .zero, duration: 0.5))]),
                 leaves: .sequence([eased(.rotate(toAngle: 0.1, duration: 0.28)),
                                    eased(.rotate(toAngle: 0, duration: 0.5))]))
        }
    }

    private func buildPrototypeCharacter() {
        let ink = NSColor(srgbRed: 0.13, green: 0.24, blue: 0.19, alpha: 1)
        let bodyColor = NSColor(srgbRed: 0.67, green: 0.82, blue: 0.59, alpha: 1)
        let leafColor = NSColor(srgbRed: 0.35, green: 0.62, blue: 0.36, alpha: 1)
        let shadow = SKShapeNode(ellipseOf: CGSize(width: 105, height: 14))
        shadow.position = CGPoint(x: restPosition.x, y: 31)
        shadow.fillColor = NSColor.black.withAlphaComponent(0.12)
        shadow.strokeColor = .clear
        addChild(shadow)
        character.position = restPosition
        addChild(character)

        func addShape(_ shape: SKShapeNode, to parent: SKNode, color: NSColor,
                      position: CGPoint = .zero, hit: Bool = false) {
            shape.fillColor = color
            shape.strokeColor = .clear
            shape.position = position
            parent.addChild(shape)
            if hit { hitShapes.append(shape) }
        }
        for x: CGFloat in [-31, 31] {
            addShape(SKShapeNode(ellipseOf: CGSize(width: 32, height: 19)), to: character,
                     color: leafColor, position: CGPoint(x: x, y: -43), hit: true)
        }
        leaves.position = CGPoint(x: 0, y: 64)
        character.addChild(leaves)
        let leftLeaf = SKShapeNode(ellipseOf: CGSize(width: 26, height: 48))
        leftLeaf.zRotation = 0.63
        addShape(leftLeaf, to: leaves, color: leafColor, position: CGPoint(x: -13, y: 10), hit: true)
        let rightLeaf = SKShapeNode(ellipseOf: CGSize(width: 23, height: 35))
        rightLeaf.zRotation = -0.76
        addShape(rightLeaf, to: leaves, color: NSColor(srgbRed: 0.50, green: 0.73, blue: 0.43, alpha: 1),
                 position: CGPoint(x: 10, y: 6), hit: true)
        addShape(SKShapeNode(rect: CGRect(x: -60, y: -46, width: 120, height: 111), cornerRadius: 48),
                 to: character, color: bodyColor, hit: true)
        addShape(SKShapeNode(ellipseOf: CGSize(width: 83, height: 43)), to: character,
                 color: NSColor.white.withAlphaComponent(0.15), position: CGPoint(x: -10, y: 35))

        character.addChild(face)
        openEyes.position = CGPoint(x: 0, y: 14)
        closedEyes.position = openEyes.position
        closedEyes.alpha = 0
        face.addChild(openEyes)
        face.addChild(closedEyes)
        for x: CGFloat in [-23, 23] {
            addShape(SKShapeNode(ellipseOf: CGSize(width: 10, height: 14)), to: openEyes,
                     color: ink, position: CGPoint(x: x, y: 0))
            addShape(SKShapeNode(circleOfRadius: 1.6), to: openEyes, color: .white,
                     position: CGPoint(x: x - 1.1, y: 3.2))
            addShape(SKShapeNode(ellipseOf: CGSize(width: 15, height: 8)), to: face,
                     color: NSColor(srgbRed: 0.92, green: 0.64, blue: 0.57, alpha: 0.55),
                     position: CGPoint(x: x * 1.5, y: 0))
            let lidPath = CGMutablePath()
            lidPath.move(to: CGPoint(x: x - 5, y: 1))
            lidPath.addQuadCurve(to: CGPoint(x: x + 5, y: 1), control: CGPoint(x: x, y: -3))
            let eyelid = SKShapeNode(path: lidPath)
            eyelid.strokeColor = ink
            eyelid.lineWidth = 1.8
            closedEyes.addChild(eyelid)
        }
        let mouthPath = CGMutablePath()
        mouthPath.move(to: CGPoint(x: -6, y: 1))
        mouthPath.addQuadCurve(to: CGPoint(x: 6, y: 1), control: CGPoint(x: 0, y: -6))
        let mouth = SKShapeNode(path: mouthPath)
        mouth.strokeColor = ink
        mouth.lineWidth = 1.8
        face.addChild(mouth)
    }
}
