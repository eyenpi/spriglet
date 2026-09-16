import AppKit
import QuartzCore
import SprigletCore

/// A small retained layer hierarchy. Only changed targets and finite phrases
/// submit animations; this scene owns no display link, timer, or event source.
@MainActor
final class RestRigScene {
    let layer = CALayer()
    private(set) var decodedBytes = 0
    private(set) var targetCommitCount: UInt64 = 0
    private(set) var finitePhraseCount: UInt64 = 0
    var onPhraseFinished: (() -> Void)?

    private let package: CharacterPackage
    private var nodes: [String: Node] = [:]
    private var targets: [String: SamplePoint] = [:]
    private var targetGenerations: [String: UInt64] = [:]
    private var targetSerial: UInt64 = 0
    private var phraseGeneration: UInt64 = 0
    private var phraseDelegate: RestPhraseDelegate?
    private(set) var isVisible = false
    private(set) var hasActivePhrase = false

    var activeAnimationCount: Int {
        (layer.animationKeys()?.count ?? 0) + nodes.values.reduce(0) {
            $0 + ($1.container.animationKeys()?.count ?? 0) + ($1.artwork.animationKeys()?.count ?? 0)
        }
    }

    init(package: CharacterPackage, resourceDirectory: URL) throws {
        try package.validate()
        self.package = package
        layer.name = "character.restRig"
        layer.isGeometryFlipped = true
        layer.anchorPoint = .zero
        layer.bounds = CGRect(x: 0, y: 0, width: package.canvasPixels.width, height: package.canvasPixels.height)
        layer.isHidden = true

        for id in package.layers.keys.sorted() {
            guard let definition = package.layers[id] else { continue }
            let size = SampleSize(width: definition.framePixels.width, height: definition.framePixels.height)
            let image = try SampleImageDecoder.decodeImage(url: resourceDirectory.appendingPathComponent(definition.file), canvas: size)
            let mask = try definition.mask.map {
                try SampleImageDecoder.decodeImage(url: resourceDirectory.appendingPathComponent($0.file), canvas: size)
            }
            decodedBytes += image.bytesPerRow * image.height + (mask.map { $0.bytesPerRow * $0.height } ?? 0)
            guard decodedBytes <= package.resourceBudget.maxDecodedLayerBytes else {
                throw CharacterPackageError.invalid("Decoded rest layers exceed the character budget.")
            }
            nodes[id] = Node(definition: definition, image: image, mask: mask)
        }
        withoutImplicitAnimation {
            for id in package.layers.keys.sorted(by: layerOrder) {
                guard let node = nodes[id], let definition = package.layers[id] else { continue }
                let parentFrame = definition.parentID.flatMap { package.layers[$0]?.framePixels }
                node.container.position = CGPoint(x: definition.pivotPixels.x - (parentFrame?.x ?? 0),
                                                  y: definition.pivotPixels.y - (parentFrame?.y ?? 0))
                let parent = definition.parentID.flatMap { nodes[$0]?.container } ?? layer
                parent.addSublayer(node.container)
            }
        }
    }

    func layout(in bounds: CGRect, contentsScale: CGFloat) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        withoutImplicitAnimation {
            layer.position = bounds.origin
            layer.setAffineTransform(CGAffineTransform(scaleX: bounds.width / package.canvasPixels.width,
                                                       y: bounds.height / package.canvasPixels.height))
            for node in nodes.values {
                node.container.contentsScale = contentsScale
                node.artwork.contentsScale = contentsScale
            }
        }
    }

    /// Pose ownership changes atomically with the host's baked-layer visibility.
    @discardableResult
    func enter(poseID: String) -> Bool {
        guard let pose = package.poses[poseID], !pose.layerIDs.isEmpty else {
            hide()
            return false
        }
        stop()
        let visibleLayers = Set(pose.layerIDs)
        withoutImplicitAnimation {
            for (id, node) in nodes {
                node.container.isHidden = !visibleLayers.contains(id)
            }
            layer.isHidden = false
        }
        isVisible = true
        return true
    }

    func hide() {
        stop()
        withoutImplicitAnimation { layer.isHidden = true }
        isVisible = false
    }

    /// Reset model values as well as animations; a later pose never inherits a
    /// half-finished blink or a target from an old pointer lifetime.
    func stop() {
        phraseGeneration &+= 1
        phraseDelegate = nil
        hasActivePhrase = false
        targets.removeAll(keepingCapacity: true)
        targetGenerations.removeAll(keepingCapacity: true)
        withoutImplicitAnimation {
            layer.removeAllAnimations()
            for node in nodes.values {
                node.container.removeAllAnimations()
                node.artwork.removeAllAnimations()
                node.container.transform = CATransform3DIdentity
                node.container.opacity = Float(node.definition.defaultOpacity)
                node.artwork.position = CGPoint(x: node.artwork.bounds.midX, y: node.artwork.bounds.midY)
                node.container.mask = nil
            }
        }
    }

    /// Values are normalized semantic targets. The character owns every range,
    /// pivot, lag, and target layer; Acorn-specific geometry never lives here.
    @discardableResult
    func retarget(semanticID: String, value: SamplePoint, animated: Bool = true) -> Bool {
        guard isVisible, !hasActivePhrase, value.x.isFinite, value.y.isFinite else { return false }
        let target = SamplePoint(x: min(1, max(-1, value.x)), y: min(1, max(-1, value.y)))
        guard targets[semanticID] != target else { return false }
        targetSerial &+= 1
        let targetGeneration = targetSerial
        var changed = false
        withoutImplicitAnimation {
            for (id, channel) in package.proceduralChannels where channel.semanticID == semanticID {
                for layerID in channel.layerIDs {
                    guard let node = nodes[layerID] else { continue }
                    let duration = animated ? min(0.5, channel.durationSeconds ?? 0.18) : 0
                    let delay = animated ? channel.delaySeconds : 0
                    switch channel.kind {
                    case .translation(let limit):
                        let moving = target != .zero
                        let masked = node.definition.mask?.activationChannelID == id
                        if masked, moving {
                            node.container.mask = node.mask
                        } else if masked, duration == 0 {
                            node.container.mask = nil
                        }
                        let maskCompletion: (@MainActor @Sendable () -> Void)?
                        if masked, !moving, duration > 0 {
                            maskCompletion = { [weak self, weak node] in
                                guard let self, self.targetGenerations[semanticID] == targetGeneration else { return }
                                self.withoutImplicitAnimation { node?.container.mask = nil }
                            }
                        } else { maskCompletion = nil }
                        animate(node.artwork, keyPath: "position.x", to: node.artwork.bounds.midX + limit.x * target.x,
                                duration: duration, delay: delay)
                        animate(node.artwork, keyPath: "position.y", to: node.artwork.bounds.midY + limit.y * target.y,
                                duration: duration, delay: delay,
                                completion: maskCompletion)
                    case .rotation(let degrees):
                        animate(node.container, keyPath: "transform.rotation.z", to: degrees * .pi / 180 * target.x,
                                duration: duration, delay: delay)
                    case .scale(let delta):
                        animate(node.container, keyPath: "transform.scale.x", to: 1 + delta.x * target.x,
                                duration: duration, delay: delay)
                        animate(node.container, keyPath: "transform.scale.y", to: 1 + delta.y * target.y,
                                duration: duration, delay: delay)
                    case .discreteReplacement: continue
                    }
                    changed = true
                }
            }
        }
        if changed {
            targets[semanticID] = target
            targetGenerations[semanticID] = targetGeneration
            targetCommitCount &+= 1
        }
        return changed
    }

    /// One finite phrase, including both eyes for a blink. Completion comes
    /// from Core Animation, so the application does not run a micro-motion clock.
    @discardableResult
    func playPhrase(semanticID: String) -> Bool {
        guard isVisible, !hasActivePhrase else { return false }
        let channels = package.proceduralChannels.filter {
            $0.value.semanticID == semanticID || $0.value.semanticID?.hasPrefix(semanticID + ".") == true
        }
        guard !channels.isEmpty else { return false }
        stop()
        var longestDuration = 0.0
        withoutImplicitAnimation {
            for (id, channel) in channels {
                let duration = max(0.01, channel.durationSeconds ?? 0.16)
                longestDuration = max(longestDuration, duration + channel.delaySeconds)
                switch channel.kind {
                case .discreteReplacement(let sequence, let originals):
                    let states = [Set(originals)] + sequence.map { Set([$0]) } + [Set(originals)]
                    for layerID in Set(sequence + originals) {
                        guard let node = nodes[layerID] else { continue }
                        let values = states.map { $0.contains(layerID) ? 1.0 : 0.0 }
                        addPhrase(node.container, key: "phrase." + id, keyPath: "opacity", values: values,
                                  duration: duration, delay: channel.delaySeconds, discrete: true)
                    }
                case .scale(let delta):
                    for layerID in channel.layerIDs {
                        guard let node = nodes[layerID] else { continue }
                        addPhrase(node.container, key: "phrase." + id + ".x", keyPath: "transform.scale.x",
                                  values: [1, 1 + delta.x, 1], duration: duration, delay: channel.delaySeconds)
                        addPhrase(node.container, key: "phrase." + id + ".y", keyPath: "transform.scale.y",
                                  values: [1, 1 + delta.y, 1], duration: duration, delay: channel.delaySeconds)
                    }
                case .rotation(let degrees):
                    for layerID in channel.layerIDs {
                        guard let node = nodes[layerID] else { continue }
                        addPhrase(node.container, key: "phrase." + id, keyPath: "transform.rotation.z",
                                  values: [0, degrees * .pi / 180, 0], duration: duration, delay: channel.delaySeconds)
                    }
                case .translation(let limit):
                    for layerID in channel.layerIDs {
                        guard let node = nodes[layerID] else { continue }
                        let x = node.artwork.bounds.midX
                        addPhrase(node.artwork, key: "phrase." + id, keyPath: "position.x",
                                  values: [x, x + limit.x, x], duration: duration, delay: channel.delaySeconds)
                    }
                }
            }
            let completion = CABasicAnimation(keyPath: "opacity")
            completion.fromValue = 1
            completion.toValue = 1
            completion.duration = longestDuration
            let generation = phraseGeneration
            let delegate = RestPhraseDelegate { [weak self] in
                guard let self, isVisible, generation == phraseGeneration, hasActivePhrase else { return }
                hasActivePhrase = false
                phraseDelegate = nil
                onPhraseFinished?()
            }
            phraseDelegate = delegate
            completion.delegate = delegate
            hasActivePhrase = true
            layer.add(completion, forKey: "phrase.completion")
        }
        finitePhraseCount &+= 1
        return true
    }

    private func layerOrder(_ lhs: String, _ rhs: String) -> Bool {
        let a = package.layers[lhs]?.zIndex ?? 0
        let b = package.layers[rhs]?.zIndex ?? 0
        return a == b ? lhs < rhs : a < b
    }

    private func animate(_ target: CALayer, keyPath: String, to value: Double, duration: Double, delay: Double,
                         completion: (@MainActor @Sendable () -> Void)? = nil) {
        let previous = target.presentation()?.value(forKeyPath: keyPath) ?? target.value(forKeyPath: keyPath)
        target.setValue(value, forKeyPath: keyPath)
        target.removeAnimation(forKey: keyPath)
        guard duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = previous
        animation.toValue = value
        animation.duration = duration
        animation.beginTime = target.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let beginTime = animation.beginTime
        animation.delegate = RestPhraseDelegate { [weak target] in
            if let active = target?.animation(forKey: keyPath), active.beginTime != beginTime { return }
            target?.removeAnimation(forKey: keyPath)
            completion?()
        }
        target.add(animation, forKey: keyPath)
    }

    private func addPhrase(_ target: CALayer, key: String, keyPath: String, values: [Double],
                           duration: Double, delay: Double, discrete: Bool = false) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values.map { NSNumber(value: $0) }
        animation.keyTimes = values.indices.map { NSNumber(value: Double($0) / Double(values.count - 1)) }
        animation.duration = duration
        animation.beginTime = target.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.fillMode = .backwards
        animation.calculationMode = discrete ? .discrete : .linear
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: values.count - 1)
        target.add(animation, forKey: key)
    }

    private func withoutImplicitAnimation(_ work: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        work()
        CATransaction.commit()
    }

    @MainActor private final class Node {
        let definition: CharacterPackage.Layer
        let container = CALayer()
        let artwork = CALayer()
        let mask: CALayer?

        init(definition: CharacterPackage.Layer, image: CGImage, mask maskImage: CGImage?) {
            self.definition = definition
            let frame = definition.framePixels
            container.bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            container.anchorPoint = CGPoint(x: (definition.pivotPixels.x - frame.x) / frame.width,
                                            y: (definition.pivotPixels.y - frame.y) / frame.height)
            container.opacity = Float(definition.defaultOpacity)
            artwork.frame = container.bounds
            artwork.contents = image
            artwork.contentsGravity = .resize
            artwork.minificationFilter = .linear
            artwork.magnificationFilter = .linear
            container.addSublayer(artwork)
            if let maskImage {
                let mask = CALayer()
                mask.frame = container.bounds
                mask.contents = maskImage
                self.mask = mask
            } else { mask = nil }
        }
    }
}

private final class RestPhraseDelegate: NSObject, CAAnimationDelegate {
    private let completion: @MainActor @Sendable () -> Void

    init(completion: @escaping @MainActor @Sendable () -> Void) { self.completion = completion }

    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        guard finished else { return }
        let completion = completion
        Task { @MainActor in completion() }
    }
}
