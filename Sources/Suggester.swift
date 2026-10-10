import AppKit

/// The word choices for the word being typed, from the macOS English dictionary plus your
/// own words.
///
/// Everything here asks for `language: "en"` on purpose. Left to itself the system picks the
/// dictionary from the Mac's language list, and on a Chinese-region Mac that lets "teh",
/// "dont", "im" and "wich" through as if they were fine. Pinning the language is what gives
/// the typing experience of an English-region Mac.
enum Candidates {
    static let language = "en"

    struct Choices {
        var items: [String] = []       // first one is what Space commits
        var corrected = false          // item 0 differs from what you typed
        var misspelled = false
    }

    static func misspelled(_ word: String) -> Bool {
        var n = 0
        return NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: &n).location != NSNotFound
    }

    static func correction(_ word: String) -> String? {
        NSSpellChecker.shared.correction(forWordRange: NSRange(location: 0, length: word.utf16.count),
                                         in: word, language: language, inSpellDocumentWithTag: 0)
    }

    /// `raw` is what has been typed so far. `fixI` turns a lone "i" into "I" (macOS does this
    /// as part of automatic capitalization); `correct` follows the system autocorrect setting.
    static func list(for raw: String, max limit: Int, curly: Bool, fixI: Bool, correct: Bool = true,
                     learnAfter: Int, memory: UserMemory = .shared) -> Choices {
        var out = Choices()
        guard !raw.isEmpty else { return out }
        let typed = raw.replacingOccurrences(of: "\u{2019}", with: "'")
        let known = memory.isKnown(typed, learnAfter: learnAfter)
        // Digits or symbols in the word: a version or a ticker (gpt5, l2), never a typo.
        let plain = typed.allSatisfy { $0.isLetter || $0 == "'" }
        out.misspelled = plain && !known && misspelled(typed)

        var seen = Set<String>()
        func add(_ w: String) {
            var s = w
            if curly { s = s.replacingOccurrences(of: "'", with: "\u{2019}") }
            guard !s.isEmpty, seen.insert(s).inserted else { return }
            out.items.append(s)
        }

        let grows = completions(typed)
        // 1. What Space commits: your word, or the correction the system would have made.
        var best = raw
        if fixI, typed == "i" { best = "I" }
        if correct, out.misspelled, let fix = fixFor(typed), fix != typed,
           acceptable(fix, for: typed), replaceable(fix, for: typed, grows: grows) {
            best = adaptCase(fix, to: raw)
            out.corrected = true
        }
        add(best)
        // 2. Your own spelling stays one key away.
        if best != raw { add(raw) }
        // 3. Words you type often, then the dictionary's completions, then its guesses.
        memory.matches(prefix: typed, limit: 3).forEach { add(adaptCase($0, to: raw)) }
        grows.forEach { add(adaptCase($0, to: raw)) }
        // Guesses are a last resort: for a word that can still grow they are mostly noise.
        if out.misspelled, grows.count < 3 {
            guesses(typed).prefix(4).forEach { add(adaptCase($0, to: raw)) }
        }
        out.items = Array(out.items.prefix(limit))
        return out
    }

    /// May the correction take the first slot, the one Space commits?
    ///
    /// Only when what you typed cannot grow into a real word on its own. "teh" and "recieve"
    /// are nothing but typos, so they are fixed. "que" and "ques" are the beginning of
    /// "question", and replacing them with "sue" or "questions" while you are still typing
    /// would put a word you never asked for into the text; those stay, with the dictionary's
    /// idea offered as choice 2. Punctuation-only fixes ("im" -> "I'm", "dont" -> "don't",
    /// "github" -> "GitHub") are always welcome: they are the same letters.
    private static func replaceable(_ fix: String, for typed: String, grows: [String]) -> Bool {
        if grows.isEmpty { return true }
        return letters(fix) == letters(typed)
    }

    private static func letters(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Apple's autocorrect handles "Recieve" but gives up on "RECIEVE", so a word typed in
    /// capitals is looked up in lower case and put back in the case you used.
    private static func fixFor(_ typed: String) -> String? {
        if let fix = correction(typed) { return fix }
        let lower = typed.lowercased()
        guard lower != typed else { return nil }
        return correction(lower)
    }

    static func completions(_ partial: String) -> [String] {
        let lower = partial.lowercased()
        let list = NSSpellChecker.shared.completions(
            forPartialWordRange: NSRange(location: 0, length: partial.utf16.count),
            in: partial, language: language, inSpellDocumentWithTag: 0) ?? []
        return list.filter { $0.count > partial.count && $0.lowercased().hasPrefix(lower) }
    }

    static func guesses(_ word: String) -> [String] {
        NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: word.utf16.count),
                                      in: word, language: language, inSpellDocumentWithTag: 0) ?? []
    }

    /// Guards against the dictionary rewriting something it doesn't recognise into an unrelated
    /// word. Short words carry too little information ("gn", "tge"), so only their case is
    /// corrected; "macos" -> "macOS" and "github" -> "GitHub" are always welcome.
    private static func acceptable(_ fix: String, for typed: String) -> Bool {
        if fix.lowercased() == typed.lowercased() { return true }     // case only
        // A single letter carries no information at all; from two letters up the dictionary's
        // guess is worth taking ("im" -> "I'm"). The abbreviations it gets wrong (gpt, btc,
        // nft, dao) are in the built-in list, and anything else you keep with Esc once.
        return typed.count >= 2
    }

    /// "Ques" -> "Question", "QUES" -> "QUESTION"; names the dictionary capitalises ("Monday",
    /// "GitHub") keep their own case when you typed all lowercase.
    static func adaptCase(_ w: String, to typed: String) -> String {
        if typed.count > 1, typed == typed.uppercased(), typed.lowercased() != typed { return w.uppercased() }
        if let f = typed.first, f.isUppercase { return w.prefix(1).uppercased() + w.dropFirst() }
        return w
    }
}

/// Talks to the local llama-server (127.0.0.1 only, bearer-token protected).
/// All mutable state is touched on the main thread only, hence @unchecked Sendable.
final class LLMClient: @unchecked Sendable {
    static let shared = LLMClient()
    private var task: Task<Void, Never>?
    private var downUntil = Date.distantPast
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.connectionProxyDictionary = [:]   // never route localhost traffic through a system proxy
        return URLSession(configuration: c)
    }()
    private lazy var apiKey: String? = {
        let url = Paths.support.appendingPathComponent("api_key")
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    func cancel() { task?.cancel(); task = nil }

    /// Streams the generated text. `update(textSoFar, finished)` runs on the main thread after
    /// every token, so the first words can be shown before generation ends.
    func complete(_ parts: PromptParts, config: Config, update: @escaping (String, Bool) -> Void) {
        cancel()
        guard Date() >= downUntil, let url = URL(string: config.serverURL + "/completion") else { return }
        let body: [String: Any] = [
            "stream": true,
            "prompt": config.promptHeader + parts.base,
            "grammar": parts.grammar,
            "n_predict": config.nPredict,
            "temperature": 0, "top_k": 1,
            "cache_prompt": true,
            "stop": ["\n"],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let session = self.session
        task = Task { [self] in   // singleton: a strong capture is fine
            var text = ""
            do {
                let (bytes, resp) = try await session.bytes(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard line.hasPrefix("data: "), let d = line.dropFirst(6).data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    text += obj["content"] as? String ?? ""
                    let stop = obj["stop"] as? Bool ?? false
                    // Hitting the token limit can cut a word in half: report that as unfinished.
                    let finished = stop && (obj["stop_type"] as? String) != "limit"
                    let snapshot = text
                    await MainActor.run { update(snapshot, finished) }
                    if stop { return }
                }
            } catch {
                // Server not running: back off so we don't retry on every keystroke.
                if !Task.isCancelled && (error as? URLError)?.code != .cancelled {
                    await MainActor.run { self.downUntil = Date().addingTimeInterval(10) }
                }
            }
        }
    }
}

enum Paths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ABCPlus", isDirectory: true)
}
