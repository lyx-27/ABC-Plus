import AppKit

/// Draws the suggestion with its line box starting exactly at the view origin.
private final class GhostView: NSView {
    var text = NSAttributedString()
    override func draw(_ dirtyRect: NSRect) { text.draw(at: .zero) }
}

/// A click-through, non-activating overlay that draws the gray suggestion right after the caret.
final class GhostPanel {
    static let shared = GhostPanel()
    private let panel: NSPanel
    private let view = GhostView()
    private(set) var isVisible = false
    var frame: NSRect { panel.frame }

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
    }

    /// `caret` is in Cocoa screen coordinates (origin bottom-left), as IMK reports it.
    func show(_ text: String, caret: NSRect, font: NSFont?, alpha: Double, level: Int) {
        // No font from the app: estimate from the caret (Chrome: 25 pt caret for 18 px text).
        let size = font?.pointSize ?? max(10, min(40, (caret.height / 1.38).rounded()))
        let f = font.flatMap { NSFont(descriptor: $0.fontDescriptor, size: size) } ?? .systemFont(ofSize: size)
        let str = NSAttributedString(string: text, attributes: [
            .font: f, .foregroundColor: NSColor.systemGray.withAlphaComponent(alpha),
        ])
        view.text = str
        let x = caret.maxX
        var w = ceil(str.size().width) + 2
        let h = ceil(str.size().height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: caret.minX, y: caret.midY)) }) {
            w = max(0, min(w, screen.frame.maxX - x))
        }
        let y = (caret.minY + (caret.height - h) / 2).rounded()
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
        view.needsDisplay = true
        panel.level = NSWindow.Level(rawValue: max(level + 1, NSWindow.Level.popUpMenu.rawValue))
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        isVisible = false
    }
}
