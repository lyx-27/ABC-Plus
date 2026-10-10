// End-to-end smoke test: types into a real app with ABC+ selected, then Tab / Shift+Tab.
// Safety: before every key press it checks that the target app is still frontmost and that its
// front window is our own test window (title contains the marker); otherwise it aborts and
// restores the original input source. Return is only pressed by the {ret}/{sret} script tokens.
// Usage: swift e2e_test.swift <bundle-id> <file-to-open> <text> <out-prefix> <window-marker>
// Env: RETURN_TO=<bundle-id> re-activates that app at the end.
import AppKit
import Carbon

let args = CommandLine.arguments
let target = args[1], file = args[2], text = args[3], out = args[4], marker = args[5]
let shadowID = ProcessInfo.processInfo.environment["SOURCE"] ?? "io.github.lyx-27.inputmethod.ABCPlus"
let src = CGEventSource(stateID: .hidSystemState)
var keys: [Character: CGKeyCode] = [:]
for (i, c) in Array("asdfhgzxcv_bqweryt").enumerated() where c != "_" { keys[c] = CGKeyCode(i) }
keys.merge(["o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, "n": 45,
            "m": 46, " ": 49, ",": 43, ".": 47, ";": 41, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
            "6": 22, "7": 26, "8": 28, "9": 25, "0": 29, "-": 27, "=": 24, "/": 44, "[": 33, "]": 30]) { a, _ in a }
let shifted: [Character: CGKeyCode] = ["?": 44, "\"": 39, "!": 18, ":": 41, "@": 19, "#": 20, "_": 27,
                                       "(": 25, ")": 29]

func sourceID() -> String {
    let s = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    return Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(s, kTISPropertyInputSourceID))
        .takeUnretainedValue() as String
}

func select(_ id: String) -> Bool {
    let f = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let s = (TISCreateInputSourceList(f, false)?.takeRetainedValue() as? [TISInputSource])?.first
    else { return false }
    return TISSelectInputSource(s) == noErr
}

func run(_ path: String, _ a: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = a
    try? p.run()
    p.waitUntilExit()
}

let original = sourceID()
var started = false   // set once our test window is confirmed in front

func finish(_ code: Int32, _ msg: String) -> Never {
    print(msg)
    _ = select(original)
    print("restored input source:", sourceID())
    if let back = ProcessInfo.processInfo.environment["RETURN_TO"] { run("/usr/bin/open", ["-b", back]) }
    exit(code)
}

func front() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }

func press(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    if front() != target { finish(2, "ABORT: frontmost is \(front())") }
    // The right app is not enough: the active tab/window must still be our test page,
    // otherwise keys would land in whatever the user is looking at.
    if started, frontWindow()?.title.contains(marker) != true {
        finish(2, "ABORT: test window is no longer in front")
    }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
        usleep(12_000)
    }
}

func type(_ s: String, gapMs: UInt32 = 90) {
    for ch in s {
        if let code = shifted[ch] {
            press(code, .maskShift)
        } else if let code = keys[Character(ch.lowercased())] {
            press(code, ch.isUppercase ? .maskShift : [])
        } else {
            finish(3, "no key for \(ch)")
        }
        usleep(gapMs * 1000)
    }
}

/// Plays a script: plain text is typed; {tab} {stab} {esc} {bs} press keys; {wait} / {wait:ms}
/// pause; {shot:name} takes a screenshot; {read} prints the field's text.
func play(_ script: String) {
    var rest = Substring(script)
    while !rest.isEmpty {
        guard let open = rest.firstIndex(of: "{") else { type(String(rest)); return }
        type(String(rest[..<open]))
        guard let close = rest[open...].firstIndex(of: "}") else { finish(3, "bad script") }
        let token = String(rest[rest.index(after: open)..<close])
        rest = rest[rest.index(after: close)...]
        switch token {
        case "tab": press(48)
        case "cmdl": press(37, .maskCommand)   // focus the address bar
        case "stab": press(48, .maskShift)
        case "esc": press(53)
        case "bs": press(51)
        case "optbs": press(51, .maskAlternate)
        case "ret": press(36)
        case "sret": press(36, .maskShift)
        case "left": press(123)
        case "right": press(124)
        case "wait": usleep(1_500_000)
        case "read":
            usleep(400_000)
            print("text (AX):", readBack().map { $0.debugDescription } ?? "n/a",
                  "| title:", frontWindow()?.title ?? "?")
        case "ruler":
            // What the page itself says about its font, vs what we measure for the ghost.
            let probe = "message"
            for size in [18.0] {
                let f = NSFont.systemFont(ofSize: size)
                print("NSFont systemFont(\(size)) '\(probe)' =",
                      (probe as NSString).size(withAttributes: [.font: f]).width)
            }
        default:
            if token.hasPrefix("wait:"), let ms = UInt32(token.dropFirst(5)) { usleep(ms * 1000) }
            else if token.hasPrefix("shot:") { screenshot(String(token.dropFirst(5))) }
            else { finish(3, "unknown token \(token)") }
        }
        usleep(150_000)
    }
}

/// Title and bounds of the frontmost app's front window (needs Screen Recording for titles).
func frontWindow() -> (title: String, bounds: CGRect)? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    // Front-most *document* window: skip small helper windows (correction bubbles) and
    // untitled popups (the address bar's suggestion list).
    guard let w = info.first(where: {
        guard ($0[kCGWindowOwnerPID as String] as? Int32) == pid, ($0[kCGWindowLayer as String] as? Int) == 0,
              let b = $0[kCGWindowBounds as String] as? [String: CGFloat],
              !(($0[kCGWindowName as String] as? String) ?? "").isEmpty else { return false }
        return b["Width"]! > 200 && b["Height"]! > 150
    }), let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
    return (w[kCGWindowName as String] as? String ?? "",
            CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!))
}

func screenshot(_ name: String) {
    guard let b = frontWindow()?.bounds else { print("no window to capture"); return }
    let r = "\(Int(b.minX)),\(Int(b.minY)),\(Int(min(b.width, 1000))),\(Int(min(b.height, 360)))"
    run("/usr/sbin/screencapture", ["-x", "-R", r, "\(out)_\(name).png"])
}

/// The focused field's text via Accessibility (works for native Cocoa text views).
func readBack() -> String? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    var focused: CFTypeRef?, value: CFTypeRef?
    let app = AXUIElementCreateApplication(pid)
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &value) == .success
    else { return nil }
    return value as? String
}

// MARK: main

let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: target).isEmpty
// An input method switched by a background process only attaches to an app when that app is
// (re)activated, so: leave the target first, switch, then activate the target.
if front() == target, let back = ProcessInfo.processInfo.environment["RETURN_TO"] {
    run("/usr/bin/open", ["-b", back]); usleep(800_000)
}
guard select(shadowID) else { finish(4, "ABORT: ABC+ is not enabled") }
if ProcessInfo.processInfo.environment["NEW_WINDOW"] != nil {   // own window, away from the user's tabs
    run("/usr/bin/open", ["-na", "Google Chrome", "--args", "--new-window", URL(fileURLWithPath: file).absoluteString])
}
for attempt in 0..<3 where front() != target {
    run("/usr/bin/open", attempt == 0 && ProcessInfo.processInfo.environment["NEW_WINDOW"] == nil
        ? ["-b", target, file] : ["-b", target])
    var waited = 0
    while front() != target && waited < 25 { usleep(100_000); waited += 1 }
}
usleep(1_200_000)
// A freshly opened document window can take a moment to appear and be titled.
for _ in 0..<30 where frontWindow()?.title.contains(marker) != true { usleep(200_000) }
print("frontmost:", front(), "| source:", sourceID(), "| window:", frontWindow()?.title ?? "?")
guard sourceID() == shadowID else { finish(5, "ABORT: input source did not switch") }
guard frontWindow()?.title.contains(marker) == true else { finish(6, "ABORT: test window not in front") }
started = true

type(String(text.prefix(2)))
usleep(300_000)
if shadowID.contains("ABCPlus"),
   NSRunningApplication.runningApplications(withBundleIdentifier: shadowID).isEmpty {
    finish(7, "ABORT: ABC+ did not attach to \(target)")
}
if text.contains("{") {          // scripted run
    play(String(text.dropFirst(2)))
    if frontWindow()?.title.contains(marker) == true {
        if target == "com.apple.TextEdit" { press(1, .maskCommand); usleep(500_000) }   // Cmd+S
        press(13, .maskCommand)                                                           // Cmd+W
        usleep(700_000)
    }
    if !wasRunning { NSRunningApplication.runningApplications(withBundleIdentifier: target).first?.terminate() }
    finish(0, "done")
}
type(String(text.dropFirst(2)))
usleep(1_500_000)               // give the model time to answer
screenshot("1_typed")
print("text before Tab (AX):", readBack().map { $0.debugDescription } ?? "n/a")
press(48)                       // Tab: accept the next word
usleep(400_000)
print("text after Tab (AX):", readBack().map { $0.debugDescription } ?? "n/a")
usleep(500_000)
screenshot("2_tab")
press(48, .maskShift)           // Shift+Tab: accept the whole suggestion
usleep(900_000)
screenshot("3_shifttab")
print("final text (AX):", readBack().map { $0.debugDescription } ?? "n/a")
print("window title:", frontWindow()?.title ?? "?")

// Close only our own test window/tab. Save first so TextEdit doesn't ask about changes.
if frontWindow()?.title.contains(marker) == true {
    if target == "com.apple.TextEdit" { press(1, .maskCommand); usleep(500_000) }   // Cmd+S
    press(13, .maskCommand)                                                           // Cmd+W
    usleep(700_000)
}
if !wasRunning { NSRunningApplication.runningApplications(withBundleIdentifier: target).first?.terminate() }
finish(0, "done")
