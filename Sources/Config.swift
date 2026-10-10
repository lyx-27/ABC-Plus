import AppKit

/// User-editable settings, read from
/// ~/Library/Application Support/ABCPlus/config.json (missing keys fall back to defaults).
struct Config: Codable {
    var serverURL = "http://127.0.0.1:39281"
    var llmEnabled = true          // phrase/sentence completion via the local model
    var maxWords = 6               // longest suggestion, in words
    var nPredict = 16              // max tokens the model may generate per request
    var debounceMs = 40            // wait this long after the last key before asking the model
    var contextChars = 600         // how much text before the caret is sent to the model
    var ghostAlpha = 0.85
    // Prepended to every prompt. Framing the text as a message makes the base model's
    // continuations noticeably more natural (tested against no header).
    var promptHeader = "The following message is written in clear, natural English.\n\n"
    var debug = false              // log prompts/suggestions (keep off: it records what you type)

    // Each word is typed into the input method first (underlined), with its choices listed
    // below, the way the system pinyin input method works. Off = letters go straight to the app.
    var compositionEnabled = true
    var candidateCount = 5         // words in the list
    var candidateDigits = true     // 1-5 pick a word while the list shows numbers
    var autocorrect: Bool? = nil   // null = follow "Correct spelling automatically"
    var rememberWords = true       // keep a local list of the words you type
    var learnAfter = 2             // times a word must be typed before it is left alone

    // English formatting. null = follow the matching macOS setting (Keyboard › Text Input › Edit).
    var autoCapitalize: Bool? = nil     // sentence starts and the word "I"
    var smartQuotes: Bool? = nil        // "..." -> “...”, don't -> don’t
    var doubleSpacePeriod: Bool? = nil  // two spaces -> ". "
    // In apps that hide the text before the caret (WeChat), treat an empty box after
    // switching to it or after sending a message as the start of a sentence.
    var capitalizeNewMessage = true
    var blockedApps = [
        // terminals and code editors (Tab means something else there)
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty",
        "com.github.wez.wezterm", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "dev.kiro.desktop", "com.apple.dt.Xcode", "com.jetbrains.intellij",
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? d.serverURL
        llmEnabled = try c.decodeIfPresent(Bool.self, forKey: .llmEnabled) ?? d.llmEnabled
        maxWords = try c.decodeIfPresent(Int.self, forKey: .maxWords) ?? d.maxWords
        nPredict = try c.decodeIfPresent(Int.self, forKey: .nPredict) ?? d.nPredict
        debounceMs = try c.decodeIfPresent(Int.self, forKey: .debounceMs) ?? d.debounceMs
        contextChars = try c.decodeIfPresent(Int.self, forKey: .contextChars) ?? d.contextChars
        ghostAlpha = try c.decodeIfPresent(Double.self, forKey: .ghostAlpha) ?? d.ghostAlpha
        promptHeader = try c.decodeIfPresent(String.self, forKey: .promptHeader) ?? d.promptHeader
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? d.debug
        blockedApps = try c.decodeIfPresent([String].self, forKey: .blockedApps) ?? d.blockedApps
        compositionEnabled = try c.decodeIfPresent(Bool.self, forKey: .compositionEnabled) ?? d.compositionEnabled
        candidateCount = try c.decodeIfPresent(Int.self, forKey: .candidateCount) ?? d.candidateCount
        candidateDigits = try c.decodeIfPresent(Bool.self, forKey: .candidateDigits) ?? d.candidateDigits
        autocorrect = try c.decodeIfPresent(Bool.self, forKey: .autocorrect)
        rememberWords = try c.decodeIfPresent(Bool.self, forKey: .rememberWords) ?? d.rememberWords
        learnAfter = try c.decodeIfPresent(Int.self, forKey: .learnAfter) ?? d.learnAfter
        autoCapitalize = try c.decodeIfPresent(Bool.self, forKey: .autoCapitalize)
        smartQuotes = try c.decodeIfPresent(Bool.self, forKey: .smartQuotes)
        doubleSpacePeriod = try c.decodeIfPresent(Bool.self, forKey: .doubleSpacePeriod)
        capitalizeNewMessage = try c.decodeIfPresent(Bool.self, forKey: .capitalizeNewMessage) ?? d.capitalizeNewMessage
    }
}

extension Config {
    var capitalizeOn: Bool { autoCapitalize ?? NSSpellChecker.isAutomaticCapitalizationEnabled }
    var smartQuotesOn: Bool { smartQuotes ?? NSSpellChecker.isAutomaticQuoteSubstitutionEnabled }
    var periodOn: Bool { doubleSpacePeriod ?? NSSpellChecker.isAutomaticPeriodSubstitutionEnabled }
    var autocorrectOn: Bool { autocorrect ?? NSSpellChecker.isAutomaticSpellingCorrectionEnabled }
}
