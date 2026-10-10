import AppKit
import Carbon
import InputMethodKit

let bundleID = Bundle.main.bundleIdentifier ?? "io.github.lyx-27.inputmethod.ABCPlus"

func ourSources() -> [TISInputSource] {
    let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
    return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
}

func boolProp(_ s: TISInputSource, _ key: CFString) -> Bool {
    guard let p = TISGetInputSourceProperty(s, key) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
}

// Command-line helpers used by the install scripts.
let args = CommandLine.arguments
if args.contains("--register") {
    print("register:", TISRegisterInputSource(Bundle.main.bundleURL as CFURL))
    for s in ourSources() { print("enable:", TISEnableInputSource(s)) }
    exit(0)
}
if args.contains("--select") { for s in ourSources() { print("select:", TISSelectInputSource(s)) }; exit(0) }
if args.contains("--disable") { for s in ourSources() { print("disable:", TISDisableInputSource(s)) }; exit(0) }
if args.contains("--status") {
    let list = ourSources()
    if list.isEmpty { print("not registered") }
    for s in list {
        print("enabled:", boolProp(s, kTISPropertyInputSourceIsEnabled),
              "selected:", boolProp(s, kTISPropertyInputSourceIsSelected))
    }
    exit(0)
}

let connection = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String ?? bundleID + "_Connection"
let server = IMKServer(name: connection, bundleIdentifier: bundleID)
withExtendedLifetime(server) {
    NSApplication.shared.run()
}
