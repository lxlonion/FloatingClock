import AppKit

guard !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) else {
    fputs("FloatingClock received an unsupported option. Run scripts/dev.sh for development commands.\n", stderr)
    exit(EX_USAGE)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
