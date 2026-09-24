import AppKit

/// A borderless, transparent, always-on-top window that hosts nothing but
/// the pet sprite — mirrors the visual shape of Orca's own PetOverlay
/// (fixed, pointer-events only on the sprite itself, floats above everything).
final class PetWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { true }
}
