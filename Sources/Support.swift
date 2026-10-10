import AppKit

/// Reloads config.json whenever its modification date changes.
enum ConfigStore {
    private static var cached = Config()
    private static var mtime: Date?

    static func current() -> Config {
        let url = Paths.support.appendingPathComponent("config.json")
        let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if m != mtime {
            mtime = m
            if let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Config.self, from: data) {
                cached = c
            } else {
                cached = Config()
            }
        }
        return cached
    }
}

/// A click may move the caret: drop suggestions and re-read the text. Scrolling only moves
/// things on screen: drop the suggestions, keep the text. (Global mouse monitors need no
/// extra permission.)
final class MouseWatcher {
    static let shared = MouseWatcher()
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { event in
            guard let c = InputController.current else { return }
            if event.type == .scrollWheel { c.hideSuggestions() } else { c.reset(.focus) }
        }
    }
}
