import Foundation

/// English typing conventions applied as you type: capital letters at sentence starts,
/// the word "I", curly quotes and the double-space period.
enum Formatting {
    /// A trailing "." after these does not end a sentence ("e.g. the", "etc. and").
    static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "cf", "approx", "incl", "esp", "viz", "a.m", "p.m"]
    static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "—", "-", "/"]

    /// True if the next letter typed after `text` starts a new sentence. `text` must not be empty.
    static func atSentenceStart(_ text: String) -> Bool {
        var t = Substring(text)
        var spaces = 0
        while let c = t.last, c == " " || c == "\t" { t = t.dropLast(); spaces += 1 }
        guard let last = t.last else { return true }            // only blanks before the caret
        if last == "\n" || last == "\r" { return true }
        guard spaces > 0 else { return false }
        while let c = t.last, "\"'”’)]".contains(c) { t = t.dropLast() }   // He said "Hi." Next
        guard let p = t.last, ".!?".contains(p) else { return false }
        if t.hasSuffix("..") { return false }                     // "well... maybe"
        if p == "." {
            let word = String(t.dropLast().reversed().prefix { !$0.isWhitespace }.reversed()).lowercased()
            if abbreviations.contains(word) { return false }
        }
        return true
    }

    /// True if a letter typed now begins a new word.
    static func atWordStart(_ text: String) -> Bool {
        guard let c = text.last else { return true }
        return c.isWhitespace || openers.contains(c)
    }

    /// Keys that end a lone "i", making it the pronoun "I".
    static func endsWord(code: UInt16, chars: String) -> Bool {
        if [36, 76, 48].contains(code) { return true }           // Return, Enter, Tab
        guard let c = chars.first else { return false }
        return c.isWhitespace || ".,!?;:'’\")]}…".contains(c)
    }

    /// "hello " followed by another space becomes "hello. ".
    static func canAddPeriod(_ text: String) -> Bool {
        guard text.hasSuffix(" "), let before = text.dropLast().last else { return false }
        return before.isLetter || before.isNumber
    }

    /// Curly version of a typed ' or " given the character before it.
    static func smartQuote(_ q: Character, after prev: Character?) -> String {
        let opening = prev == nil || prev!.isWhitespace || openers.contains(prev!)
        if q == "'" {
            if let p = prev, p.isLetter || p.isNumber { return "’" }   // don’t, '90s, it’s
            return opening ? "‘" : "’"
        }
        return opening ? "“" : "”"
    }

    /// Applies the same rules to a suggestion before it is shown, so that what you see is
    /// exactly what Tab inserts: a lone "i" becomes "I", quotes become curly.
    static func prettify(_ s: String, after prev: Character?, smart: Bool, fixI: Bool) -> String {
        let chars = Array(s)
        var out = ""
        var before = prev
        for (k, c) in chars.enumerated() {
            var piece = String(c)
            if fixI, c == "i", !(before?.isLetter ?? false) {
                let next = k + 1 < chars.count ? chars[k + 1] : nil
                if next == nil || !(next!.isLetter || next!.isNumber) { piece = "I" }
            } else if smart, c == "'" || c == "\"" {
                piece = smartQuote(c, after: before)
            }
            out += piece
            before = piece.last
        }
        return out
    }
}
