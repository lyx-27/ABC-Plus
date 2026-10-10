import AppKit
import Carbon
import InputMethodKit
import os

let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.lyx-27.inputmethod.ABCPlus", category: "ime")
typealias Client = IMKTextInput & NSObjectProtocol
let notFound = NSRange(location: NSNotFound, length: 0)

/// Why we last lost track of the text. Decides whether an empty box we can't read
/// (WeChat) may be treated as the start of a new sentence.
enum ResetReason { case focus, submit, navigation, other }

/// One instance per text client.
///
/// Each word is typed into the input method first and shown underlined in the app, with its
/// choices listed below, exactly the way the system pinyin input method works. That mechanism
/// is what every Mac app already supports, so the word list, the spelling fix and the
/// capitalization work in apps that don't let anyone read or rewrite their text (WeChat),
/// and it needs no permissions at all.
@objc(ABCPlusInputController)
final class InputController: IMKInputController {
    static weak var current: InputController?
    static var paused = false
    private static var exitHooked = false

    private var cfg = ConfigStore.current()
    private var buffer = ""            // committed text before the composition, as far as we know
    private var dirty = true           // re-read the buffer from the client before using it
    private var resetReason = ResetReason.focus
    private var readable = false       // this app lets us read the text before the caret
    private var midLine = false        // text after the caret -> don't draw the ghost over it
    private var startSelected = false  // the box had selected text when we started typing

    // The word being typed. While this is non-empty it lives in the app as marked text.
    private var composing = ""
    private var glued = false          // stuck to what came before it: @name, #tag, site.com/page
    private var typedHere = false      // we put the character before the caret there ourselves
    private var submitted: String?     // text before the caret when Return was pressed
    private var items: [String] = []   // word choices; Space commits items[selected]
    private var selected = 0
    private var ghost: String?         // inline suggestion drawn after the composition
    /// The word we just changed for you, so Backspace can put your spelling back.
    private var undoWord: (inserted: String, typed: String)?

    private var lastSpaceAt = Date.distantPast
    private var generation = 0         // bumps on every edit; stale async results are dropped
    private var debounce: DispatchWorkItem?
    private var active = false
    private var blocked = false
    private var lastEditAt = Date.distantPast
    // Settled caret position the visible suggestion belongs to. If the caret moves without a
    // key reaching us (another tool inserted text), the suggestion is stale.
    private var baseline: NSRect?
    private var watchdog: Timer?

    private static let settleDelay = 0.12   // Chrome/Electron report the caret asynchronously
    /// Zero-width and placeholder characters editors put around the caret.
    private static let invisible: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0xFFFC]
    private static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]   // 1...9
    /// Characters that end a word *without* touching it: addresses, emails, file paths and
    /// identifiers run through them, and "correcting" a user name or a path breaks it.
    private static let rawEnders: Set<Character> = [
        "@", "/", ":", "_", "-", "#", "\\", "~", "+", "=", "*", "&", "%", "$", "|", "<", ">", "^", "`",
    ]

    // MARK: lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        cfg = ConfigStore.current()
        let bid = (sender as? Client)?.bundleIdentifier() ?? ""
        blocked = cfg.blockedApps.contains(bid)
        if cfg.debug { log.debug("activate: \(bid, privacy: .public) blocked=\(self.blocked)") }
        active = true
        Self.current = self
        MouseWatcher.shared.start()
        // An input method can be killed at any time; make sure learned words reach the disk.
        if !Self.exitHooked {
            Self.exitHooked = true
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                   object: nil, queue: .main) { _ in
                UserMemory.shared.flush()
            }
        }
        reset(.focus)
    }

    override func deactivateServer(_ sender: Any!) {
        if let client = sender as? Client { commitRaw(client) }
        active = false
        reset(.focus)
        UserMemory.shared.flush()
        if Self.current === self { Self.current = nil }
        super.deactivateServer(sender)
    }

    /// Called by the system when the app wants our marked text committed (click, focus change).
    override func commitComposition(_ sender: Any!) {
        if let client = sender as? Client { commitRaw(client) }
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    func reset(_ reason: ResetReason) {
        if !composing.isEmpty, let c = client() as Client? { commitRaw(c) }
        dirty = true
        resetReason = reason
        // Chromium reports the text asynchronously: right after Return it still hands back the
        // line we just sent. Remember it so the next read can be recognised as out of date.
        submitted = reason == .submit ? buffer : nil
        typedHere = false
        undoWord = nil
        dismiss()
    }

    /// Hides the ghost and the word list; the text we know about stays valid.
    private func dismiss() {
        hideGhost()
        items = []
        selected = 0
        CandidatePanel.shared.hide()
    }

    func hideSuggestions() { dismiss() }

    // MARK: keys

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown, let client = sender as? Client else { return false }
        if blocked || Self.paused || IsSecureEventInputEnabled() {
            commitRaw(client)
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let code = event.keyCode
        let chars = event.characters ?? ""

        // Shortcuts belong to the app. Hand over whatever is half-typed first.
        if !flags.isDisjoint(with: [.command, .control]) {
            commitRaw(client)
            reset(.other)
            return false
        }
        if flags.contains(.option) {
            if !composing.isEmpty, code == 51 {        // ⌥Delete: drop the whole word, as macOS does
                setComposition("", client)
                return true
            }
            commitRaw(client)                           // ⌥letter is an accent, ⌥digit a symbol
            reset(.other)
            return false
        }

        if !composing.isEmpty { return composingKey(code: code, chars: chars, shift: flags == [.shift], client) }

        // Nothing half-typed: the ghost still owns Tab and Esc.
        if code == 53, ghost != nil || CandidatePanel.shared.isVisible {
            dismiss()
            return true
        }
        if code == 48, flags == [] || flags == [.shift], ghost != nil, GhostPanel.shared.isVisible {
            if isStale(client) { reset(.other); return false }
            acceptGhost(all: flags == [.shift], client)
            return true
        }

        generation += 1
        lastEditAt = Date()
        baseline = nil
        switch code {
        case 51:                                        // Backspace
            if undoAutocorrect(client) { return true }
            dismiss()
            if dirty || buffer.isEmpty {
                dirty = true
            } else {
                buffer.removeLast()
                scheduleSuggest()
            }
            return false
        case 36, 76: reset(.submit); return false       // Return / Enter
        case 48, 53, 117: reset(.other); return false   // Tab, Esc, Forward Delete
        case 115, 116, 119, 121, 123, 124, 125, 126:    // Home, PgUp, End, PgDn, arrows
            reset(.navigation); return false
        default: break
        }
        guard !chars.isEmpty, chars.unicodeScalars.allSatisfy({
            $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
        }) else { reset(.other); return false }

        if dirty { seed(client) }
        undoWord = nil
        // A letter starts a new word in the input method; everything else is plain typing.
        if cfg.compositionEnabled, let c = chars.first, chars.count == 1, c.isLetter {
            // Only a character we put there ourselves proves the word continues something:
            // "github" "." "com", "@" "name". Text merely read back from the app may be stale
            // or may sit behind a caret the user moved, and guessing wrong there switches off
            // the spelling fix and the word numbers.
            glued = typedHere && (buffer.last.map(TextLogic.gluesToNext) ?? false)
            setComposition(chars, client)
            return true
        }
        return type(chars, client)
    }

    /// Keys while a word is half-typed. Everything here returns a decision for that word.
    private func composingKey(code: UInt16, chars: String, shift: Bool, _ client: Client) -> Bool {
        switch code {
        case 51:                                        // Backspace edits the word
            setComposition(String(composing.dropLast()), client)
            return true
        case 53:                                        // Esc keeps your spelling, and remembers it
            commit(composing, trailing: "", capitalize: false, keep: true, client)
            return true
        case 49:                                        // Space takes the highlighted word
            commit(choice(), trailing: " ", capitalize: true, auto: selected == 0, client)
            return true
        case 36, 76:                                    // Return: take the word, then send / new line
            commit(choice(), trailing: "", capitalize: true, client)
            reset(.submit)
            return false
        case 48:                                        // Tab takes the ghost, or moves on
            if ghost != nil, GhostPanel.shared.isVisible {
                acceptGhost(all: shift, client)
                return true
            }
            commit(choice(), trailing: "", capitalize: true, client)
            reset(.other)
            return false
        case 123, 124:                                  // ← → move the highlight
            guard items.count > 1 else { return true }
            selected = (selected + (code == 124 ? 1 : items.count - 1)) % items.count
            render()
            return true
        case 125, 126, 115, 116, 119, 121, 117:         // ↑ ↓ Home End PgUp PgDn ForwardDelete
            commitRaw(client)
            reset(.navigation)
            return false
        default: break
        }
        guard let c = chars.first, chars.count == 1, chars.unicodeScalars.allSatisfy({
            $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
        }) else {
            commitRaw(client)
            reset(.other)
            return false
        }
        // Digits pick a word once the list is numbered. On the first letter they are still
        // digits, so "v2", "m5" and "l2" type straight through.
        if numbered, cfg.candidateDigits, let i = Self.digitKeys.firstIndex(of: code), i < items.count {
            commit(items[i], trailing: " ", capitalize: true, client)
            return true
        }
        // A dot stays in the word until the next key says what it is: a space or Return makes it
        // the end of a sentence ("teh." -> "the."), a letter makes it an address ("github.com").
        if c.isLetter || c.isNumber || c == "'" || c == "." {
            setComposition(composing + chars, client)
            return true
        }
        // Other punctuation ends the word. Before the characters that run through addresses and
        // identifiers keep it as typed, otherwise take the highlighted word.
        if Self.rawEnders.contains(c) {
            commit(composing, trailing: "", capitalize: !buffer.isEmpty, learn: false, client)
        } else {
            commit(choice(), trailing: "", capitalize: true, auto: selected == 0, client)
        }
        return type(chars, client)
    }

    /// The composition drawn with a plain underline, like the system pinyin input method.
    /// (Handed over as a bare string, Chrome paints it like selected text: a blue background.)
    private static func marked(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .markedClauseSegment: 0,
        ])
    }

    /// The word Space would commit.
    private func choice() -> String {
        items.indices.contains(selected) ? items[selected] : composing
    }

    /// Numbers show from the second letter of a plain word on, which is when digits start
    /// picking words. Handles, tags and addresses keep their digits (@lyx27, v1.2).
    private var numbered: Bool {
        composing.count >= 2 && !glued && TextLogic.sentenceWord(composing)?.dots.isEmpty == true
    }

    // MARK: composition

    /// Puts `text` in the app as marked text (underlined) and refreshes the word list.
    private func setComposition(_ text: String, _ client: Client) {
        generation += 1
        lastEditAt = Date()
        baseline = nil
        undoWord = nil
        composing = text
        client.setMarkedText(Self.marked(text), selectionRange: NSRange(location: text.utf16.count, length: 0),
                             replacementRange: notFound)
        guard !text.isEmpty else {
            dismiss()
            scheduleSuggest()
            return
        }
        refreshItems()
        hideGhost()
        // Instant completion from the dictionary while the model thinks.
        if let suffix = completionSuffix(), suffix.count >= 2 { ghost = suffix }
        scheduleRender(0.02)
        scheduleSuggest()
    }

    private func refreshItems() {
        selected = 0
        defer {
            if cfg.debug {
                log.debug("items '\(self.composing, privacy: .public)' glued=\(self.glued): \(self.items.joined(separator: " | "), privacy: .public)")
            }
        }
        // An address or abbreviation (github.com, e.g, v1.2): exactly as typed.
        guard let t = TextLogic.sentenceWord(composing) else {
            items = [composing]
            return
        }
        let c = Candidates.list(for: t.core, max: cfg.candidateCount, curly: cfg.smartQuotesOn,
                                fixI: cfg.capitalizeOn && !glued, correct: cfg.autocorrectOn && !glued,
                                learnAfter: cfg.learnAfter)
        if t.dots.isEmpty {
            items = c.items
        } else {
            // "teh." waits for the next key: offer the corrected sentence end and your spelling.
            let best = (c.items.first ?? t.core) + t.dots
            items = Self.norm(best) == Self.norm(composing) ? [best] : [best, composing]
        }
    }

    /// The letters the first choice would add to what you typed ("tion" for "ques").
    private func completionSuffix() -> String? {
        guard let first = items.first, first.count > composing.count,
              first.lowercased().hasPrefix(composing.lowercased()) else { return nil }
        return String(first.dropFirst(composing.count))
    }

    /// Hands the half-typed word to the app exactly as typed. Used whenever something outside
    /// our control happens: a click, a shortcut, switching apps.
    private func commitRaw(_ client: Client) {
        guard !composing.isEmpty else { return }
        commit(composing, trailing: "", capitalize: false, learn: false, client)
    }

    /// Replaces the marked text with the finished word.
    /// - auto: we chose it for you (Space, punctuation). Backspace right after brings back
    ///   your spelling, like an autocorrection anywhere else on macOS.
    /// - keep: you asked for your own spelling (Esc): remember it and stop correcting it.
    /// - learn: count the word in your memory. Not for words handed over without your say.
    private func commit(_ word: String, trailing: String, capitalize: Bool, auto: Bool = false,
                        keep: Bool = false, learn: Bool = true, _ client: Client) {
        let typed = composing
        var out = word
        if cfg.smartQuotesOn { out = out.replacingOccurrences(of: "'", with: "\u{2019}") }
        // Never capitalize part of an address or a handle (github.com, @name).
        if capitalize, !glued, TextLogic.sentenceWord(typed) != nil, shouldCapitalize(),
           let f = out.first, f.isLowercase {
            out = out.prefix(1).uppercased() + out.dropFirst()
        }
        out += trailing
        composing = ""
        items = []
        selected = 0
        CandidatePanel.shared.hide()
        guard !out.isEmpty else { return }
        client.insertText(out, replacementRange: notFound)   // replaces the marked text
        generation += 1
        lastEditAt = Date()
        baseline = nil
        if trailing == " " { lastSpaceAt = Date() }
        // What you meant, not how it was formatted: a capital at the start of a sentence is not
        // part of the word.
        if cfg.rememberWords, learn || keep {
            let first = (keep ? typed : word).split(separator: " ").first.map(String.init) ?? ""
            UserMemory.shared.note(TextLogic.sentenceWord(first)?.core ?? first, kept: keep)
        }
        // Keep the rest of the suggestion if it went on from what was committed.
        let full = typed + (ghost ?? "")
        if ghost != nil, Self.norm(full).hasPrefix(Self.norm(out)), full.count - out.count >= 2 {
            ghost = String(full.dropFirst(out.count))
        } else {
            hideGhost()
        }
        undoWord = auto && Self.norm(word) != Self.norm(typed) ? (inserted: out, typed: typed) : nil
        buffer += out
        typedHere = true
        if buffer.count > 4000 { buffer = String(buffer.suffix(2000)) }
        if cfg.debug {
            log.debug("commit '\(out, privacy: .public)' (typed '\(typed, privacy: .public)')")
        }
        if ghost != nil { scheduleRender(0.02) } else { scheduleSuggest() }
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// Backspace right after a word was changed puts your spelling back and reopens it for
    /// editing, the way an underlined autocorrection works elsewhere on macOS.
    private func undoAutocorrect(_ client: Client) -> Bool {
        guard let u = undoWord, !u.typed.isEmpty else { return false }
        undoWord = nil
        let n = u.inserted.utf16.count
        let sel = client.selectedRange()
        guard sel.location != NSNotFound, sel.length == 0, sel.location >= n, sel.location < Int.max / 4,
              let have = client.attributedSubstring(from: NSRange(location: sel.location - n, length: n))?.string,
              have == u.inserted else { return false }
        buffer = String(buffer.dropLast(u.inserted.count))
        composing = u.typed
        client.setMarkedText(Self.marked(u.typed), selectionRange: NSRange(location: u.typed.utf16.count, length: 0),
                             replacementRange: NSRange(location: sel.location - n, length: n))
        if cfg.rememberWords { UserMemory.shared.note(u.typed, kept: true) }
        generation += 1
        lastEditAt = Date()
        baseline = nil
        refreshItems()
        selected = items.firstIndex(of: u.typed) ?? 0
        hideGhost()
        scheduleRender(0.02)
        if cfg.debug { log.debug("undo autocorrect -> '\(u.typed, privacy: .public)'") }
        return true
    }

    /// Should the word being committed start with a capital?
    private func shouldCapitalize() -> Bool {
        guard cfg.capitalizeOn else { return false }
        if !buffer.isEmpty { return Formatting.atSentenceStart(buffer) }
        if midLine { return false }
        // Start of a box: in one we can read this is a document or a field, and the word is only
        // committed with a space or sentence punctuation, so capitalizing is safe here.
        if readable || startSelected { return true }
        // A box we can't read (WeChat): after switching to it or sending, it's a new message.
        let fresh = resetReason == .focus || resetReason == .submit
        return cfg.capitalizeNewMessage && fresh
    }

    // MARK: plain typing (spaces, digits and punctuation)

    /// A printable key outside a word. Returns true if we inserted it ourselves.
    private func type(_ chars: String, _ client: Client) -> Bool {
        if chars == " ", cfg.periodOn, Date().timeIntervalSince(lastSpaceAt) < 0.8,
           Formatting.canAddPeriod(buffer), replaceBeforeCaret(" ", with: ". ", client) {
            buffer.removeLast()
            buffer += ". "
            undoWord = nil
            lastSpaceAt = .distantPast
            afterTyping(" ")
            return true
        }
        var out = chars
        if cfg.smartQuotesOn, chars.count == 1, let c = chars.first, c == "'" || c == "\"" {
            out = Formatting.smartQuote(c, after: buffer.last)
        }
        let consumed = out != chars
        if consumed { client.insertText(out, replacementRange: notFound) }
        if chars == " " { lastSpaceAt = Date() }
        buffer += out
        typedHere = true
        if buffer.count > 4000 { buffer = String(buffer.suffix(2000)) }
        afterTyping(out)
        return consumed
    }

    /// Replaces the characters right before the caret, but only after the app confirms they
    /// are `expected`. Apps that can't report or replace text (WeChat) simply return false.
    private func replaceBeforeCaret(_ expected: String, with text: String, _ client: Client) -> Bool {
        let n = expected.utf16.count
        let sel = client.selectedRange()
        guard sel.location != NSNotFound, sel.length == 0, sel.location >= n, sel.location < Int.max / 4 else { return false }
        let range = NSRange(location: sel.location - n, length: n)
        guard client.attributedSubstring(from: range)?.string == expected else { return false }
        client.insertText(text, replacementRange: range)
        return true
    }

    private func afterTyping(_ out: String) {
        if let g = ghost, g.hasPrefix(out), g.count - out.count >= 2 {   // typing what the ghost shows
            ghost = String(g.dropFirst(out.count))
            scheduleRender(0.02)
            if TextLogic.chunks(ghost!).count < 2 { scheduleSuggest() }
            return
        }
        hideGhost()
        scheduleRender(0.025)
        scheduleSuggest()
    }

    // MARK: ghost

    /// Tab takes the next word of the suggestion, ⇧Tab all of it. A word that is still being
    /// typed is finished off by it.
    private func acceptGhost(all: Bool, _ client: Client) {
        guard let g = ghost else { return }
        let full = composing + g
        let parts = TextLogic.chunks(full)
        let take = all || parts.count < 2 ? full : parts[0]
        if !composing.isEmpty {
            commit(take, trailing: "", capitalize: true, client)   // keeps what's left of the ghost
            return
        }
        client.insertText(take, replacementRange: notFound)
        generation += 1
        lastEditAt = Date()
        baseline = nil
        buffer += take
        typedHere = true
        if cfg.debug { log.debug("accept '\(take, privacy: .public)'") }
        let rest = String(full.dropFirst(take.count))
        if rest.count >= 2 {
            ghost = rest
            scheduleRender(0.02)
        } else {
            hideGhost()
            scheduleSuggest()
        }
    }

    private func hideGhost() {
        ghost = nil
        debounce?.cancel()
        LLMClient.shared.cancel()
        GhostPanel.shared.hide()
        if composing.isEmpty { stopTracking() }
    }

    // MARK: staleness

    private func stopTracking() {
        baseline = nil
        watchdog?.invalidate()
        watchdog = nil
    }

    private static func moved(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) > 1 || abs(a.minY - b.minY) > 1
    }

    private enum CaretChange { case same, shifted, edited }

    /// Did the caret move without a key reaching us? Search boxes that grow or open a list
    /// (Google, Grok) only shift the layout: the text is unchanged, so we just redraw there.
    /// Another tool inserting text changes it, and then the suggestions are stale.
    private func caretChange(_ client: Client, at cur: NSRect) -> CaretChange {
        guard let b = baseline, Self.moved(cur, b) else { return .same }
        // A composition is ours: no app changes the text under it, so movement is only layout.
        if !composing.isEmpty { return .shifted }
        let ns = buffer as NSString
        if readable, ns.length > 0 {
            let n = min(ns.length, 24)
            let sel = client.selectedRange()
            if sel.location != NSNotFound, sel.location >= n, sel.location < Int.max / 4,
               let s = client.attributedSubstring(from: NSRange(location: sel.location - n, length: n))?.string {
                return s == ns.substring(from: ns.length - n) ? .shifted : .edited
            }
        }
        // Can't read the text (WeChat): small moves are layout jitter, a character or more is an edit.
        let dx = abs(cur.minX - b.minX), dy = abs(cur.minY - b.minY)
        return dx < max(4, b.height * 0.4) && dy < b.height * 0.5 ? .shifted : .edited
    }

    private func isStale(_ client: Client) -> Bool {
        guard let r = caretRects(client) else { return false }
        return caretChange(client, at: r.start) == .edited
    }

    /// While something is on screen, notice text changes that did not come through us and
    /// follow layout shifts.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let showing = GhostPanel.shared.isVisible || CandidatePanel.shared.isVisible
            guard self.active, showing, let client = self.client() as Client? else {
                self.stopTracking()
                return
            }
            guard Date().timeIntervalSince(self.lastEditAt) >= Self.settleDelay,
                  let cur = self.caretRects(client)?.start else { return }
            if self.baseline == nil {
                self.baseline = cur
                return
            }
            switch self.caretChange(client, at: cur) {
            case .same: break
            case .shifted: self.render()              // moved with the box: redraw at the new spot
            case .edited:
                if self.cfg.debug { log.debug("text changed without a key: dropping suggestions") }
                self.reset(.other)
            }
        }
    }

    // MARK: context

    /// Reads the text before the caret from the app. Called *before* the current key is
    /// applied, so the app's state is settled and consistent with what we append next.
    private func seed(_ client: Client) {
        dirty = false
        buffer = ""
        midLine = false
        typedHere = false
        // Apps that can replace text say so (Cocoa, Chrome, Electron); Qt 5 apps like WeChat don't.
        if !readable, let attrs = client.validAttributesForMarkedText() as? [String],
           attrs.contains("NSTextInputReplacementRangeAttributeName") {
            readable = true
        }
        let sel = client.selectedRange()
        guard sel.location != NSNotFound, sel.location < Int.max / 4 else { return }
        // Text selected on focus (address bar, form fields) is about to be replaced.
        startSelected = sel.length > 0
        if startSelected, client.attributedSubstring(from: sel) != nil { readable = true }
        let n = min(sel.location, cfg.contextChars)
        if n > 0, let s = client.attributedSubstring(from: NSRange(location: sel.location - n, length: n))?.string {
            buffer = s
            readable = true
        }
        // Unchanged since Return: the app hasn't caught up. Whatever it did with that key, the
        // caret is now on a new line or in an emptied box, so treat it as the start of one.
        if let before = submitted, buffer == before {
            buffer += "\n"
            if cfg.debug { log.debug("stale text after Return: treating it as a new line") }
        }
        submitted = nil
        // Text after the caret on the same line -> don't draw over it. Editors (Grok, Obsidian…)
        // often keep invisible characters or spaces there; those don't count.
        let after = client.attributedSubstring(from: NSRange(location: sel.location + sel.length, length: 4))?.string ?? ""
        midLine = after.unicodeScalars
            .prefix { !CharacterSet.newlines.contains($0) }
            .contains { !CharacterSet.whitespaces.contains($0) && !Self.invisible.contains($0.value) }
        if cfg.debug {
            log.debug("seed(\(String(describing: self.resetReason), privacy: .public)): sel=\(sel.location),\(sel.length) \(self.buffer.count) chars, readable=\(self.readable) midLine=\(self.midLine)")
        }
    }

    // MARK: model suggestions

    private func scheduleSuggest() {
        debounce?.cancel()
        guard cfg.llmEnabled, !midLine else { return }
        let gen = generation
        let item = DispatchWorkItem { [weak self] in self?.requestSuggestion(gen) }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(cfg.debounceMs), execute: item)
    }

    private func requestSuggestion(_ gen: Int) {
        guard gen == generation, active else { return }
        let ctx = String((buffer + composing).suffix(cfg.contextChars))
        guard let last = ctx.last, last != "\n", ctx.contains(where: { $0.isLetter && $0.isASCII }) else { return }
        let parts = TextLogic.split(ctx)
        let started = Date()
        LLMClient.shared.complete(parts, config: cfg) { [weak self] raw, done in
            guard let self, gen == self.generation, self.active, raw.hasPrefix(parts.forced) else { return }
            var rest = String(raw.dropFirst(parts.forced.count))
            if !done {   // the last word may still be growing: show whole words only
                guard let cut = rest.lastIndex(of: " ") else { return }
                rest = String(rest[..<cut])
            }
            guard let cleaned = TextLogic.clean(rest, maxWords: self.cfg.maxWords) else {
                if done, self.cfg.debug { log.debug("model gave nothing usable: '\(rest, privacy: .public)'") }
                return
            }
            if !done, TextLogic.chunks(cleaned).count >= self.cfg.maxWords || ".!?".contains(cleaned.last ?? " ") {
                LLMClient.shared.cancel()   // long enough: free the model for the next keystroke
            }
            let g = Formatting.prettify(cleaned, after: (self.buffer + self.composing).last,
                                        smart: self.cfg.smartQuotesOn, fixI: self.cfg.capitalizeOn)
            if self.cfg.debug {
                log.debug("llm \(Int(Date().timeIntervalSince(started) * 1000))ms: \(g, privacy: .public)")
            }
            guard g != self.ghost else { return }
            self.ghost = g
            self.mergeModelWord()
            self.scheduleRender(0)
        }
    }

    /// The model's guess for the word being typed joins the end of the list.
    ///
    /// It arrives while you are already looking at the numbers, so it may only ever be
    /// appended into a free slot: inserting it would renumber the words under your finger and
    /// the digit you press would commit something else than what you read.
    private func mergeModelWord() {
        guard !composing.isEmpty, !items.isEmpty, !glued, items.count < cfg.candidateCount,
              let g = ghost, TextLogic.sentenceWord(composing)?.dots.isEmpty == true else { return }
        let letters = g.prefix { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
        guard !letters.isEmpty else { return }
        let word = composing + letters
        guard !items.contains(where: { Self.norm($0) == Self.norm(word) }),
              !Candidates.misspelled(word.replacingOccurrences(of: "\u{2019}", with: "'")) else { return }
        items.append(word)
        if cfg.debug { log.debug("items +model: \(self.items.joined(separator: " | "), privacy: .public)") }
    }

    // MARK: drawing

    /// Chrome/Electron/Lark update the caret asynchronously, so draw once now-ish and once
    /// more a moment later.
    private func scheduleRender(_ delay: Double) {
        let gen = generation
        let recent = Date().timeIntervalSince(lastEditAt) < 0.15
        for d in recent ? [delay, delay + 0.07] : [delay] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let self, gen == self.generation, self.active else { return }
                self.render()
            }
        }
    }

    private func render() {
        guard !composing.isEmpty || ghost != nil else { return }
        guard let client = client() as Client?, let r = caretRects(client) else {
            GhostPanel.shared.hide()   // caret unknown (yet): hidden suggestions never take keys
            CandidatePanel.shared.hide()
            return
        }
        switch caretChange(client, at: r.start) {
        case .edited:
            if cfg.debug { log.debug("text changed without a key: dropping suggestions") }
            reset(.other)              // the text changed behind our back: suggestions are stale
            return
        case .shifted:
            baseline = r.start         // the box moved (layout), the text didn't: draw at the new spot
        case .same:
            break
        }
        let level = Int(client.windowLevel())
        if let g = ghost, !midLine {
            GhostPanel.shared.show(g, caret: r.end, font: r.font, alpha: cfg.ghostAlpha, level: level)
        } else {
            GhostPanel.shared.hide()
        }
        if items.isEmpty {
            CandidatePanel.shared.hide()
        } else {
            CandidatePanel.shared.show(items, selected: selected, numbered: numbered && cfg.candidateDigits,
                                       caret: r.start, level: level)
        }
        if Date().timeIntervalSince(lastEditAt) >= Self.settleDelay { baseline = r.start }
        startWatchdog()
    }

    /// Where the composition starts and ends, in screen coordinates. IMK's line-height
    /// rectangle (the one candidate windows use) was correct in TextEdit and Chrome;
    /// firstRect is only a fallback because TextEdit returns it one line too high for an
    /// empty range and Chrome returns garbage.
    private func caretRects(_ client: Client) -> (start: NSRect, end: NSRect, font: NSFont?)? {
        var lineRect = NSRect.zero
        let attrs = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineRect)
        var start = lineRect
        if !Self.valid(start) {
            let sel = client.selectedRange()
            if sel.location != NSNotFound {
                var actual = notFound
                start = client.firstRect(forCharacterRange: NSRange(location: sel.location + sel.length, length: 0),
                                         actualRange: &actual)
            }
        }
        guard Self.valid(start) else {
            if cfg.debug {
                log.debug("no caret: line=\(NSStringFromRect(lineRect), privacy: .public)")
            }
            return nil
        }
        var font = attrs?.first(where: { "\($0.key)" == NSAttributedString.Key.font.rawValue })?.value as? NSFont
        // Some apps report a generic default font; only trust it if it fits the caret height.
        if let f = font, f.pointSize < start.height * 0.6 || f.pointSize > start.height * 1.0 { font = nil }
        let end = composing.isEmpty ? start : compositionEnd(client, start: start, font: font)
        return (start, end, font)
    }

    /// Right edge of the composition, where the ghost goes: the app's own answer when it is a
    /// sensible one (same line, to the right of the start), otherwise measured with the font.
    private func compositionEnd(_ client: Client, start: NSRect, font: NSFont?) -> NSRect {
        func onLine(_ r: NSRect) -> Bool {
            Self.valid(r) && abs(r.minY - start.minY) < start.height * 0.6
        }
        let f = font ?? .systemFont(ofSize: max(10, min(40, (start.height / 1.38).rounded())))
        let measured = (composing as NSString).size(withAttributes: [.font: f]).width
        var tail = NSRect.zero
        _ = client.attributes(forCharacterIndex: composing.utf16.count, lineHeightRectangle: &tail)
        var marked = NSRect.zero
        let range = client.markedRange()
        if range.location != NSNotFound, range.length > 0, range.location < Int.max / 4 {
            var actual = notFound
            marked = client.firstRect(forCharacterRange: NSRange(location: range.location + range.length - 1, length: 1),
                                      actualRange: &actual)
        }
        if cfg.debug {
            log.debug("""
                end '\(self.composing, privacy: .public)': start=\(Int(start.minX)) \
                tail=\(Self.valid(tail) ? Int(tail.minX) : -1) lastChar=\(Self.valid(marked) ? Int(marked.maxX) : -1) \
                measured=\(Int(start.minX + measured)) font=\(f.pointSize)/\(Int(start.height))
                """)
        }
        func at(_ x: CGFloat) -> NSRect { NSRect(x: x, y: start.minY, width: 0, height: start.height) }
        // The app's own answer when it has one. Chrome and other Chromium apps report nothing
        // for a position inside marked text, so there we measure the word ourselves.
        if onLine(tail), tail.minX > start.minX + 1 { return at(tail.minX) }
        if onLine(marked), marked.maxX > start.minX + 1 { return at(marked.maxX) }
        return at((start.minX + measured).rounded())
    }

    private static func valid(_ r: NSRect) -> Bool {
        r.height > 4 && r.height < 300 && NSScreen.screens.contains {
            $0.frame.insetBy(dx: -2, dy: -2).contains(NSPoint(x: r.minX, y: r.minY))
        }
    }

    // MARK: menu (input menu in the menu bar)

    override func menu() -> NSMenu! {
        let m = NSMenu()
        m.addItem(withTitle: Self.paused ? "恢复联想" : "暂停联想", action: #selector(togglePause(_:)), keyEquivalent: "")
        m.addItem(withTitle: "清除学过的词（\(UserMemory.shared.wordCount)）",
                  action: #selector(forgetWords(_:)), keyEquivalent: "")
        m.addItem(withTitle: "打开设置文件夹", action: #selector(openSettings(_:)), keyEquivalent: "")
        return m
    }

    @objc func togglePause(_ sender: Any?) {
        Self.paused.toggle()
        reset(.other)
    }

    @objc func forgetWords(_ sender: Any?) {
        UserMemory.shared.forget()
        reset(.other)
    }

    @objc func openSettings(_ sender: Any?) {
        NSWorkspace.shared.open(Paths.support)
    }
}
