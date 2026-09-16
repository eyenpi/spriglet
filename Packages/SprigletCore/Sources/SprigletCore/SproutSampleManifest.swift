import Foundation

public struct SamplePoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public static let zero = Self(x: 0, y: 0)
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct SampleSize: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// Source-compatible name for the original sample APIs. The underlying value is
/// now open so character packages can add clips without adding Swift enum cases.
public typealias SampleClipID = CharacterClipID

/// Local, versioned metadata for the bundled Blender renders. Paths are relative
/// to one resource directory; this format cannot request a network or parent file.
public struct SproutSampleManifest: Codable, Sendable {
    public struct Frame: Codable, Equatable, Sendable {
        public let file: String
        public let rootOffsetPoints: SamplePoint
        public init(file: String, rootOffsetPoints: SamplePoint) {
            self.file = file; self.rootOffsetPoints = rootOffsetPoints
        }
    }

    public struct Clip: Codable, Sendable {
        public let frames: [Frame]
        public init(frames: [Frame]) { self.frames = frames }
    }

    public let schemaVersion: Int
    public let canvasPixels: SampleSize
    public let displaySizePoints: SampleSize
    public let framesPerSecond: Double
    public let groundAnchorPixels: SamplePoint
    public let restFrame: String
    public let sleepFrame: String
    public let clips: [String: Clip]

    public var supportsAnimatedSleep: Bool { schemaVersion == 2 }

    public init(schemaVersion: Int, canvasPixels: SampleSize, displaySizePoints: SampleSize,
                framesPerSecond: Double, groundAnchorPixels: SamplePoint,
                restFrame: String, sleepFrame: String, clips: [String: Clip]) {
        self.schemaVersion = schemaVersion
        self.canvasPixels = canvasPixels
        self.displaySizePoints = displaySizePoints
        self.framesPerSecond = framesPerSecond
        self.groundAnchorPixels = groundAnchorPixels
        self.restFrame = restFrame
        self.sleepFrame = sleepFrame
        self.clips = clips
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2_000_000 else { throw SampleManifestError.invalid("Manifest is too large.") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }

    public func validate() throws {
        guard schemaVersion == 1 || schemaVersion == 2 else {
            throw SampleManifestError.invalid("Unsupported character sample version.")
        }
        let requiredClips = schemaVersion == 1 ? SampleClipID.versionOneCases : SampleClipID.allCases
        guard canvasPixels.width.isFinite, canvasPixels.height.isFinite,
              (64...2_048).contains(canvasPixels.width), (64...2_048).contains(canvasPixels.height),
              canvasPixels.width.rounded() == canvasPixels.width,
              canvasPixels.height.rounded() == canvasPixels.height,
              displaySizePoints.width.isFinite, displaySizePoints.height.isFinite,
              (32...512).contains(displaySizePoints.width), (32...512).contains(displaySizePoints.height),
              framesPerSecond.isFinite, (1...120).contains(framesPerSecond) else {
            throw SampleManifestError.invalid("Invalid character canvas, display size, or frame rate.")
        }
        guard groundAnchorPixels.x.isFinite, groundAnchorPixels.y.isFinite,
              (0...canvasPixels.width).contains(groundAnchorPixels.x),
              (0...canvasPixels.height).contains(groundAnchorPixels.y),
              Self.isSafePNGPath(restFrame), Self.isSafePNGPath(sleepFrame),
              clips.count == requiredClips.count else {
            throw SampleManifestError.invalid("Invalid character anchor, frame path, or clip list.")
        }
        var total = 0
        for id in requiredClips {
            guard let clip = clips[id.rawValue], (1...600).contains(clip.frames.count),
                  clip.frames.first?.rootOffsetPoints == .zero else {
                throw SampleManifestError.invalid("Missing or invalid \(id.rawValue) clip.")
            }
            total += clip.frames.count
            for frame in clip.frames {
                guard Self.isSafePNGPath(frame.file), frame.rootOffsetPoints.x.isFinite,
                      frame.rootOffsetPoints.y.isFinite,
                      abs(frame.rootOffsetPoints.x) <= 4_096, abs(frame.rootOffsetPoints.y) <= 4_096 else {
                    throw SampleManifestError.invalid("Invalid path or movement in \(id.rawValue).")
                }
            }
        }
        guard total <= 1_500 else { throw SampleManifestError.invalid("Character sample has too many frames.") }
    }

    private static func isSafePNGPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.utf8.count <= 240 && path.hasSuffix(".png") && !path.contains("\\")
            && !path.contains(":") && !path.contains("\0")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public enum SampleManifestError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}
