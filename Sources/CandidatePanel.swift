import AppKit

/// One drawn entry: its number, the word, and where they go.
private struct Entry {
    let num: NSAttributedString?
    let word: NSAttributedString
    let pill: NSRect
    let numAt: NSPoint
    let wordAt: NSPoint
    let on: Bool
}

private final class CandidateView: NSView {
    var entries: [Entry] = []

    override func draw(_ dirtyRect: NSRect) {
        for e in entries where e.on {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: e.pill, xRadius: 5, yRadius: 5).fill()
        }
        for e in entries {
            e.num?.draw(at: e.numAt)
            e.word.draw(at: e.wordAt)
        }
    }
}

/// The word choices under the composition, laid out like the candidate window of the system
/// pinyin input method: numbers, and the selected word on a filled pill.
final class CandidatePanel {
    static let shared = CandidatePanel()
    private let panel: NSPanel
    private let view = CandidateView()
    private let box = NSVisualEffectView()
    private(set) var isVisible = false

    private static let wordFont = NSFont.systemFont(ofSize: 14)
    private static let onFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    private static let numFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        box.material = .popover
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.masksToBounds = true
        box.addSubview(view)
        panel.contentView = box
    }

    /// `numbered` is false while the first letter is being typed, when digits still type digits.
    func show(_ words: [String], selected: Int, numbered: Bool, caret: NSRect, level: Int) {
        guard !words.isEmpty else { hide(); return }
        let padX: CGFloat = 7, gap: CGFloat = 5, inset: CGFloat = 5
        var entries: [Entry] = []
        var x = inset
        for (i, w) in words.enumerated() {
            let on = i == selected
            let num = numbered ? NSAttributedString(string: "\(i + 1)", attributes: [
                .font: Self.numFont,
                .foregroundColor: on ? NSColor.white.withAlphaComponent(0.75) : NSColor.tertiaryLabelColor,
            ]) : nil
            let word = NSAttributedString(string: w, attributes: [
                .font: on ? Self.onFont : Self.wordFont,
                .foregroundColor: on ? NSColor.white : NSColor.labelColor,
            ])
            let numW = num.map { ceil($0.size().width) + 4 } ?? 0
            let wordW = ceil(word.size().width)
            let pill = NSRect(x: x, y: inset, width: numW + wordW + padX * 2, height: 22)
            entries.append(Entry(num: num, word: word, pill: pill,
                                 numAt: NSPoint(x: x + padX, y: inset + 6),
                                 wordAt: NSPoint(x: x + padX + numW, y: inset + 3), on: on))
            x = pill.maxX + gap
        }
        let w = x - gap + inset, h = 22 + inset * 2
        view.entries = entries
        view.frame = NSRect(x: 0, y: 0, width: w, height: h)
        view.needsDisplay = true

        // Under the line the composition sits on; flipped above it near the bottom of a screen.
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: caret.minX, y: caret.midY)) }
            ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero
        var y = caret.minY - h - 4
        if y < vis.minY { y = caret.maxY + 4 }
        let x0 = min(max(caret.minX - inset, vis.minX + 4), max(vis.minX + 4, vis.maxX - w - 4))
        panel.setFrame(NSRect(x: x0, y: y, width: w, height: h), display: true)
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
