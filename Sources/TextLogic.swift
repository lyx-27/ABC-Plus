import AppKit

/// How the text before the caret is turned into a model request.
/// `base` is sent as the prompt; the model's output is forced (via grammar) to start with `forced`.
/// Ending the prompt on a word boundary and forcing " recei" lets the model pick the natural
/// " receive" token instead of being confused by a half-typed word ("token healing").
struct PromptParts {
    let base: String
    let forced: String
    var grammar: String { TextLogic.grammar(for: forced, after: base.last) }
}

enum TextLogic {
    static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "’"
    }

    /// The half-typed word at the end of `text` ("" after a space or punctuation).
    static func partialWord(_ text: String) -> String {
        String(text.reversed().prefix(while: isWordChar).reversed())
    }

    static func split(_ ctx: String) -> PromptParts {
        let partial = partialWord(ctx)
        var before = String(ctx.dropLast(partial.count))
        if !partial.isEmpty {
            if before.hasSuffix(" ") && !before.hasSuffix("  ") {
                before.removeLast()
                return PromptParts(base: before, forced: " " + partial)
            }
            return PromptParts(base: before, forced: partial)
        }
        if ctx.hasSuffix(" ") && !ctx.hasSuffix("  ") {
            return PromptParts(base: String(ctx.dropLast()), forced: " ")
        }
        return PromptParts(base: ctx, forced: "")
    }

    /// GBNF grammar: output starts with `forced`, then printable ASCII only (English, one line).
    /// Right after punctuation it must continue with exactly one space and a word; after a
    /// sentence end that word starts with a capital. Without this, small base models like to
    /// continue "...report." with list numbering ("  1.  2.").
    static func grammar(for forced: String, after last: Character?) -> String {
        let sentenceEnd = last.map { ".!?".contains($0) } ?? false
        if forced == " " || (forced.isEmpty && last.map { ".!?,;:".contains($0) } == true) {
            return sentenceEnd ? #"root ::= " " [A-Z"'(] [ -~]*"# : #"root ::= " " [!-~] [ -~]*"#
        }
        let esc = forced.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return forced.isEmpty ? "root ::= [ -~]*" : "root ::= \"\(esc)\" [ -~]*"
    }
}

extension TextLogic {
    /// A word typed right after one of these is part of something else: a handle (@name), a tag
    /// (#solana), a path or address (site.com/page), a compound or identifier (well-known,
    /// user_name, 5min), a LaTeX argument (\cite{smith2024}, \ref[fig1]). Such words are kept
    /// exactly as typed, and digits after them stay digits.
    static func gluesToNext(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || "@#/\\_-.:~+=*&%$|<>^`{[".contains(c)
    }

    /// "teh." -> ("teh", "."), "well..." -> ("well", "..."). A dot inside the word
    /// ("github.com", "e.g", "v1.2") means an address or abbreviation: nil.
    static func sentenceWord(_ s: String) -> (core: String, dots: String)? {
        let dots = String(s.reversed().prefix { $0 == "." })
        let core = String(s.dropLast(dots.count))
        guard !core.isEmpty, !core.contains(".") else { return nil }
        return (core, dots)
    }

    /// Splits a suggestion into acceptance chunks: optional leading spaces + one word.
    /// Chunks shorter than 2 characters are merged forward (Chrome forwards the original
    /// key to the page when an IME commits a single character).
    static func chunks(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var seenWord = false
        for ch in s {
            if ch == " " && seenWord {
                out.append(cur); cur = ""; seenWord = false
            }
            cur.append(ch)
            if ch != " " { seenWord = true }
        }
        if !cur.isEmpty { out.append(cur) }
        var merged: [String] = []
        for c in out {
            if let last = merged.last, last.count < 2 { merged[merged.count - 1] = last + c } else { merged.append(c) }
        }
        if merged.count > 1, let last = merged.last, last.count < 2 {
            merged.removeLast(); merged[merged.count - 1] += last
        }
        return merged
    }

    /// Cleans raw model output (with the already-typed `forced` prefix removed) into a ghost.
    static func clean(_ raw: String, maxWords: Int) -> String? {
        let line = raw.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var kept: [String] = []
        for c in chunks(line) {
            kept.append(c)
            if kept.count >= maxWords { break }
            if let last = c.last, ".!?".contains(last) { break }
        }
        var s = kept.joined()
        while s.hasSuffix(" ") { s.removeLast() }
        // Drop junk such as "  1." (list numbering) or bare punctuation.
        guard s.count >= 2, s.contains(where: { $0.isLetter }), !s.hasPrefix("  ") else { return nil }
        return s
    }
}
