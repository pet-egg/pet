import AppKit
import CoreGraphics
import Foundation

/// One playable animation: its frames (already-cropped images) and the
/// per-frame hold durations to play them at (mirrors Orca's SpriteAnimation).
struct SpriteAnimationFrames {
    let images: [NSImage]
    let durationsMs: [Double]
}

/// Loads `spritesheet.png` + `pet.json` and pre-slices every declared
/// animation into individual frame images, so the pet view just indexes an
/// array on each timer tick instead of doing CSS-style background-position math.
final class SpriteSheet {
    let manifest: PetManifest
    private var animationCache: [String: SpriteAnimationFrames] = [:]
    private let cgImage: CGImage

    init(manifestURL: URL, spritesheetURL: URL) throws {
        manifest = try PetManifest.load(from: manifestURL)
        let data = try Data(contentsOf: spritesheetURL)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "SpriteSheet", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not decode spritesheet.png"])
        }
        cgImage = image

        let expectedW = manifest.frame.width * (image.width / manifest.frame.width)
        let expectedH = manifest.frame.height * (image.height / manifest.frame.height)
        guard image.width == expectedW, image.height == expectedH else {
            throw NSError(domain: "SpriteSheet", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "spritesheet \(image.width)x\(image.height) is not a clean multiple of frame \(manifest.frame.width)x\(manifest.frame.height)"
            ])
        }
    }

    /// Loads a bundled pet by slug from `Resources/pets/<slug>/`. Shared by the
    /// menu-bar picker and the battle screen so both resolve characters the same way.
    static func bundled(slug: String) throws -> SpriteSheet {
        guard
            let spritesheetURL = AppDelegate.resourceBundle.url(forResource: "spritesheet", withExtension: "png", subdirectory: "pets/\(slug)"),
            let manifestURL = AppDelegate.resourceBundle.url(forResource: "pet", withExtension: "json", subdirectory: "pets/\(slug)")
        else {
            throw NSError(domain: "ConnorPet", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing bundled resources for pet '\(slug)'"])
        }
        return try SpriteSheet(manifestURL: manifestURL, spritesheetURL: spritesheetURL)
    }

    func animation(named name: String) -> SpriteAnimationFrames? {
        if let cached = animationCache[name] {
            return cached
        }
        guard let anim = manifest.animations[name] else { return nil }
        let frameW = manifest.frame.width
        let frameH = manifest.frame.height

        var images: [NSImage] = []
        images.reserveCapacity(anim.frames)
        for col in 0..<anim.frames {
            // Verified empirically: row index maps directly to y = row*frameHeight
            // for a CGImage decoded from this PNG via CGImageSource — see
            // scripts note in README. No vertical flip needed.
            let rect = CGRect(x: col * frameW, y: anim.row * frameH, width: frameW, height: frameH)
            guard let cropped = cgImage.cropping(to: rect) else { continue }
            images.append(NSImage(cgImage: cropped, size: NSSize(width: frameW, height: frameH)))
        }

        let durations = anim.frameDurationsMs ?? Array(repeating: 1000.0 / manifest.fps, count: anim.frames)
        let frames = SpriteAnimationFrames(images: images, durationsMs: durations)
        animationCache[name] = frames
        return frames
    }

    /// Resolves a live `PetAnimationName` to a manifest animation key,
    /// mirroring `SpriteFrame`'s fallback chain in `PetOverlay.tsx`:
    /// exact name -> defaultAnimation -> first declared animation.
    func resolvedAnimation(for name: PetAnimationName) -> SpriteAnimationFrames? {
        if let exact = animation(named: name.rawValue) {
            return exact
        }
        if let def = manifest.defaultAnimation, let fallback = animation(named: def) {
            return fallback
        }
        if let firstKey = manifest.animations.keys.first {
            return animation(named: firstKey)
        }
        return nil
    }
}
