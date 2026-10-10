// Checks the pure typing logic without a GUI: word choices, autocorrect, memory, chunking.
// Run: scripts/logic_test.sh   (compiles this file together with the sources it needs)
import AppKit

var pass = 0, fail = 0
func check(_ ok: Bool, _ what: String, _ got: String = "") {
    if ok { pass += 1 } else { fail += 1; print("FAIL  \(what)  got: \(got)") }
}

// A memory that never touches the real file.
let mem = UserMemory(url: URL(fileURLWithPath: "/tmp/st_test_memory.json"))
try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/tmp/st_test_memory.json"))

func list(_ w: String, curly: Bool = false, fixI: Bool = true, correct: Bool = true) -> Candidates.Choices {
    Candidates.list(for: w, max: 5, curly: curly, fixI: fixI, correct: correct, learnAfter: 2, memory: mem)
}

print("== autocorrect: the typed word is replaced, your spelling stays at 2 ==")
for (typed, want) in [("recieve", "receive"), ("teh", "the"), ("adn", "and"), ("dont", "don't"),
                      ("becuase", "because"), ("definately", "definitely"), ("seperate", "separate"),
                      ("tommorow", "tomorrow"), ("wierd", "weird"), ("untill", "until"),
                      ("im", "I'm"), ("ive", "I've"), ("youre", "you're"), ("doesnt", "doesn't"),
                      ("github", "GitHub"), ("wechat", "WeChat"), ("iphone", "iPhone"), ("macos", "macOS"),
                      ("experiement", "experiment")] {
    let r = list(typed)
    check(r.items.first == want, "\(typed) -> \(want)", r.items.joined(separator: " "))
    check(r.items.count > 1 && r.items[1] == typed, "\(typed) stays reachable", r.items.joined(separator: " "))
}

print("== words we must not touch ==")
for w in ["gpt", "btc", "eth", "nft", "dao", "dex", "defi", "tvl", "apy", "kol", "lfg", "mcp", "agi",
          "solana", "onchain", "memecoin", "chatgpt", "openai", "claude", "qwen", "figma", "vercel",
          "kiro", "hodl", "wagmi", "degen", "zk", "evm", "erc", "usdc", "tiktok", "weibo"] {
    let r = list(w)
    check(r.items.first == w, "\(w) kept", r.items.joined(separator: " "))
    check(!r.corrected, "\(w) not flagged as corrected")
}

print("== a word that can still grow is never replaced by an unrelated one ==")
// "que"/"ques" begin "question": Space must commit what you typed, not "sue" or "questions".
for typed in ["que", "ques", "tomor", "questi", "rec", "hel", "wor"] {
    let r = list(typed)
    check(r.items.first == typed, "\(typed) kept as the first choice", r.items.joined(separator: " | "))
    check(!r.corrected, "\(typed) not reported as corrected")
}
// but the dictionary's idea is still reachable
check(list("ques").items.contains("questions"), "ques still offers questions",
      list("ques").items.joined(separator: " | "))
check(list("tomor").items.contains("tomorrow"), "tomor still offers tomorrow",
      list("tomor").items.joined(separator: " | "))
// same letters, different punctuation or case: always applied
for (typed, want) in [("im", "I'm"), ("dont", "don't"), ("youre", "you're"), ("github", "GitHub"),
                      ("iphone", "iPhone"), ("macos", "macOS"), ("ive", "I've")] {
    check(list(typed).items.first == want, "\(typed) -> \(want) even though it can grow",
          list(typed).items.joined(separator: " | "))
}

print("== ordinary words just get completions ==")
let web = list("web")
check(web.items.first == "web", "web kept", web.items.joined(separator: " "))
check(web.items.count > 1, "web has choices", web.items.joined(separator: " "))
let ques = list("ques")
check(ques.items.contains("questions") && ques.items.contains("question"), "ques completions",
      ques.items.joined(separator: " "))
let the = list("the")
check(the.items.first == "the", "the kept", the.items.joined(separator: " "))
check(the.items.count > 1, "the still offers choices", the.items.joined(separator: " "))

print("== i, case and curly quotes ==")
check(list("i").items.first == "I", "i -> I", list("i").items.joined(separator: " "))
check(list("i", fixI: false).items.first == "i", "i kept when capitalization is off")
check(list("Recieve").items.first == "Receive", "Recieve -> Receive", list("Recieve").items.joined(separator: " "))
check(list("RECIEVE").items.first == "RECEIVE", "RECIEVE -> RECEIVE", list("RECIEVE").items.joined(separator: " "))
check(list("dont", curly: true).items.first == "don\u{2019}t", "curly apostrophe",
      list("dont", curly: true).items.joined(separator: " "))
check(list("recieve", correct: false).items.first == "recieve", "autocorrect off leaves it alone")

print("== words with digits are never typos ==")
for w in ["web3", "gpt5", "l2", "erc20", "x402"] {
    check(list(w).items.first == w, "\(w) kept", list(w).items.joined(separator: " "))
}

print("== memory: typed twice, then left alone and offered ==")
check(!mem.isKnown("zkhyper", learnAfter: 2), "unknown word starts unknown")
mem.note("zkhyper", kept: false)
check(!mem.isKnown("zkhyper", learnAfter: 2), "once is not enough")
mem.note("zkhyper", kept: false)
check(mem.isKnown("zkhyper", learnAfter: 2), "twice is enough")
check(mem.matches(prefix: "zkh", limit: 3) == ["zkhyper"], "offered by prefix",
      mem.matches(prefix: "zkh", limit: 3).joined(separator: " "))
mem.note("Lyx", kept: true)
check(mem.isKnown("lyx", learnAfter: 2), "Esc keeps a word at once")
check(mem.matches(prefix: "ly", limit: 3) == ["Lyx"], "your own capitalization is remembered",
      mem.matches(prefix: "ly", limit: 3).joined(separator: " "))
let withMem = list("zkh")
check(withMem.items.first == "zkh" || withMem.items.contains("zkhyper"), "memory word in the list",
      withMem.items.joined(separator: " "))

print("== memory file is never wiped by a flush before it was read ==")
let keepURL = URL(fileURLWithPath: "/tmp/st_test_memory_keep.json")
try? #"{"counts":{"solana":5},"spelling":{"solana":"solana"},"kept":[]}"#.data(using: .utf8)!.write(to: keepURL)
let fresh = UserMemory(url: keepURL)
fresh.flush()
check((try? String(contentsOf: keepURL, encoding: .utf8))?.contains("solana") == true, "flush before load keeps the file")
fresh.note("kiro", kept: false)
fresh.flush()
let saved = (try? String(contentsOf: keepURL, encoding: .utf8)) ?? ""
check(saved.contains("solana") && saved.contains("kiro"), "new words are added to the old ones", saved)
try? FileManager.default.removeItem(at: keepURL)

print("== memory keeps the word, not the punctuation a suggestion brought along ==")
let punctURL = URL(fileURLWithPath: "/tmp/st_test_memory_punct.json")
try? FileManager.default.removeItem(at: punctURL)
let pm = UserMemory(url: punctURL)
pm.note("hello,", kept: false)
pm.note("hello,", kept: false)
check(pm.isKnown("hello", learnAfter: 2), "hello, counts as hello")
check(pm.matches(prefix: "hel", limit: 3) == ["hello"], "offered without the comma",
      pm.matches(prefix: "hel", limit: 3).joined(separator: " "))
pm.note("don\u{2019}t", kept: false)
check(pm.matches(prefix: "do", limit: 3) == ["don\u{2019}t"], "apostrophes stay part of the word",
      pm.matches(prefix: "do", limit: 3).joined(separator: " "))
for (raw, want) in [("github.com", "github.com"), ("well-known", "well-known"), ("hello.", "hello"),
                    ("dogs'", "dogs"), ("e.g.", "e.g"), ("man,how", "man"), ("ok!", "ok")] {
    check(UserMemory.wordPart(raw) == want, "wordPart \(raw) -> \(want)", UserMemory.wordPart(raw))
}
// a file written by the old version is cleaned up when it is read
try? #"{"counts":{"here,":3,"man,how":1,"here":2,",":4},"spelling":{"here,":"here,","man,how":"man,how","here":"here"},"kept":["man,how"]}"#
    .data(using: .utf8)!.write(to: punctURL)
let old = UserMemory(url: punctURL)
check(old.matches(prefix: "he", limit: 3) == ["here"], "here, merged into here",
      old.matches(prefix: "he", limit: 3).joined(separator: " "))
check(old.matches(prefix: "ma", limit: 3) == ["man"], "man,how becomes man",
      old.matches(prefix: "ma", limit: 3).joined(separator: " "))
check(old.isKnown("here", learnAfter: 5), "counts merged (3 + 2)")
check(old.isKnown("man", learnAfter: 99), "kept entry cleaned too")
check(old.wordCount == 2, "punctuation-only entry dropped", "\(old.wordCount)")
try? FileManager.default.removeItem(at: punctURL)

print("== sentence ends, addresses and glued words ==")
check(TextLogic.sentenceWord("teh.").map { "\($0.core)|\($0.dots)" } == "teh|.", "teh. is a sentence end")
check(TextLogic.sentenceWord("well...").map { "\($0.core)|\($0.dots)" } == "well|...", "ellipsis")
check(TextLogic.sentenceWord("hello").map { "\($0.core)|\($0.dots)" } == "hello|", "plain word")
check(TextLogic.sentenceWord("github.com") == nil, "github.com is an address")
check(TextLogic.sentenceWord("e.g.") == nil, "e.g. is an abbreviation")
check(TextLogic.sentenceWord("v1.2") == nil, "v1.2 is a version")
for c: Character in ["@", "#", "/", "_", "-", ".", "5", "a", "{", "["] { check(TextLogic.gluesToNext(c), "glued after \(c)") }
for c: Character in [" ", "\n", "(", "\u{201C}", ",", "!"] { check(!TextLogic.gluesToNext(c), "free after \(c)") }
let tm = list("tmrw")
check(tm.items.first == "tmrw", "chat shorthand kept", tm.items.joined(separator: " "))
check(list("abt").items.first == "abt", "abt is not alt", list("abt").items.joined(separator: " "))

print("== capitalization decisions ==")
check(Formatting.atSentenceStart("Hello there. "), "after a full stop")
check(!Formatting.atSentenceStart("hello "), "mid sentence")
check(!Formatting.atSentenceStart("e.g. "), "abbreviation")
check(Formatting.atSentenceStart("He said \"Hi.\" "), "after a closing quote")
check(!Formatting.atSentenceStart("well... "), "ellipsis")

print("== suggestion chunking (Tab takes one word) ==")
check(TextLogic.chunks("questions about this") == ["questions", " about", " this"], "chunks",
      TextLogic.chunks("questions about this").joined(separator: "|"))
check(TextLogic.chunks("tion") == ["tion"], "single chunk")

print("\n\(pass) passed, \(fail) failed")
try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/tmp/st_test_memory.json"))
exit(fail == 0 ? 0 : 1)
