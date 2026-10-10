import Foundation

/// The words you actually type. Kept in a plain JSON file next to the settings
/// (~/Library/Application Support/ABCPlus/memory.json); nothing leaves the Mac.
///
/// Two jobs: stop "correcting" words you meant (solana, gpt5, a colleague's name), and put
/// the words you use most at the front of the choices.
final class UserMemory {
    static let shared = UserMemory()

    private var counts: [String: Int] = [:]       // lowercase word -> times committed
    private var spelling: [String: String] = [:]  // lowercase word -> how you write it
    private var kept: Set<String> = []            // words you kept with Esc: never correct these
    private var pending = 0                       // commits not yet written to disk
    private var writer: DispatchWorkItem?
    private var loaded = false
    private let url: URL

    init(url: URL = Paths.support.appendingPathComponent("memory.json")) { self.url = url }

    /// Words the English dictionary rejects but whose "correction" would be wrong, usually
    /// destructively so: gpt->got, btc->btw, eth->4th, nft->not, defi->defy, hodl->hold.
    /// Tech, crypto and AI names people type every day.
    static let builtin: Set<String> = [
        // crypto
        "btc", "eth", "sol", "bnb", "usdt", "usdc", "dai", "wbtc", "steth", "erc", "bep", "trc",
        "defi", "dex", "cex", "dao", "nft", "tvl", "apy", "apr", "pnl", "ath", "atl", "otc", "kyc",
        "tge", "ido", "ico", "lp", "amm", "mev", "zk", "evm", "svm", "l1", "l2", "rwa", "perp",
        "onchain", "offchain", "memecoin", "shitcoin", "altcoin", "stablecoin", "airdrop", "degen",
        "hodl", "rekt", "wagmi", "ngmi", "gmi", "lfg", "dyor", "fud", "fomo", "ponzi", "rugpull",
        "solana", "ethereum", "binance", "coinbase", "uniswap", "pancakeswap", "hyperliquid",
        "pumpfun", "metamask", "phantom", "ledger", "arbitrum", "optimism", "polygon", "avalanche",
        "aptos", "sui", "ton", "tron", "monad", "berachain", "blast", "linea", "scroll", "starknet",
        "jupiter", "raydium", "jito", "lido", "aave", "curve", "maker", "compound", "pendle", "ena",
        // AI and dev
        "gpt", "llm", "llms", "agi", "asi", "rag", "mcp", "sdk", "api", "cli", "ide", "ui", "ux",
        "chatgpt", "openai", "anthropic", "claude", "gemini", "grok", "deepseek", "qwen", "kimi",
        "mistral", "ollama", "huggingface", "midjourney", "runway", "veo", "sora", "comfyui",
        "cursor", "copilot", "codex", "kiro", "vscode", "neovim", "tmux", "zsh", "homebrew",
        "nextjs", "nodejs", "vite", "vercel", "supabase", "firebase", "postgres", "redis", "sqlite",
        "docker", "kubernetes", "k8s", "nginx", "oauth", "jwt", "webhook", "websocket", "graphql",
        "swiftui", "uikit", "appkit", "xcode", "testflight", "cocoapods", "pnpm", "eslint",
        // products and places people type
        "figma", "notion", "linear", "slack", "lark", "feishu", "tiktok", "xiaohongshu", "douyin",
        "weibo", "bilibili", "zhihu", "taobao", "alipay", "didi", "meituan",
        "substack", "patreon", "twitch", "discord", "telegram", "whatsapp", "zoom",
        "elon", "altman", "satoshi", "vitalik", "trump", "nvidia", "amd", "tsmc", "spacex",
        // chat shorthand (abt -> alt, rn, ngl ...)
        "abt", "rn", "ngl", "lmk", "hmu", "wyd", "omw", "nvm", "ppl", "bc", "msg", "asap", "fyi",
        "irl", "smh", "dm", "dms", "gn", "gg", "wen", "ser", "fren", "anon", "tmrw", "tmr", "pov",
        "afaik", "iirc", "ofc", "probs", "tho", "thru", "ty", "np", "jk", "wtf", "lmao", "rofl",
    ]

    // MARK: disk

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Older versions also saved punctuation picked up from a suggestion ("here,", "man,how").
        // Keep only the word itself, merging duplicates, so those never come back as choices.
        let rawSpelling = obj["spelling"] as? [String: String] ?? [:]
        for (k, n) in obj["counts"] as? [String: Int] ?? [:] {
            let w = Self.wordPart(rawSpelling[k] ?? k)
            guard Self.worthKeeping(w) else { continue }
            counts[key(w), default: 0] += n
            spelling[key(w)] = w
        }
        kept = Set((obj["kept"] as? [String] ?? []).map { key(Self.wordPart($0)) }.filter { !$0.isEmpty })
    }

    /// "here," -> "here", "man,how" -> "man", "hello." -> "hello": only the word is remembered.
    /// Joiners inside it stay, so "don’t", "well-known" and "github.com" are kept whole.
    static func wordPart(_ s: String) -> String {
        var w = String(s.prefix { $0.isLetter || $0.isNumber || "'\u{2019}.-_".contains($0) })
        while let last = w.last, ".-_'\u{2019}".contains(last) { w.removeLast() }
        return w
    }

    private static func worthKeeping(_ w: String) -> Bool {
        w.count > 1 && w.contains(where: { $0.isLetter })
    }

    /// Written a moment after the last commit, and again when the process goes away: an input
    /// method can be killed at any time, so a debounce on its own would lose words.
    private func scheduleWrite() {
        pending += 1
        writer?.cancel()
        if pending >= 20 { flush(); return }
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        writer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    func flush() {
        writer?.cancel()
        writer = nil
        // Never write before the file was read: that would replace your words with nothing.
        guard loaded, pending > 0 else { return }
        pending = 0
        let obj: [String: Any] = ["counts": counts, "spelling": spelling, "kept": Array(kept)]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: use

    /// True if we should leave this word alone: built in, kept with Esc, or typed enough times.
    func isKnown(_ word: String, learnAfter: Int) -> Bool {
        load()
        let w = key(word)
        return Self.builtin.contains(w) || kept.contains(w) || (counts[w] ?? 0) >= max(1, learnAfter)
    }

    /// Records a committed word. `kept` means you pressed Esc to keep your own spelling.
    func note(_ word: String, kept keptNow: Bool) {
        load()
        let clean = Self.wordPart(word)
        guard Self.worthKeeping(clean) else { return }
        let w = key(clean)
        counts[w, default: 0] += 1
        spelling[w] = clean
        if keptNow { kept.insert(w) }
        scheduleWrite()
    }

    /// Your words that start with `prefix`, most used first.
    func matches(prefix: String, limit: Int) -> [String] {
        load()
        guard prefix.count >= 1 else { return [] }
        let p = key(prefix)
        return counts.filter { $0.key.hasPrefix(p) && $0.key != p }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { spelling[$0.key] ?? $0.key }
    }

    func forget() {
        load()
        counts = [:]
        spelling = [:]
        kept = []
        pending = 1
        flush()
    }

    var wordCount: Int { load(); return counts.count }

    private func key(_ w: String) -> String {
        w.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }
}
