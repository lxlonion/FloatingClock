import AppKit

private enum DevelopmentCommand: String, CaseIterable {
    case smokeTest = "--smoke-test"
    case liveDisplayTest = "--live-display-test"
    case renderPreview = "--render-preview"
    case renderTimerPreviews = "--render-timer-previews"
    case renderDocumentationPreviews = "--render-documentation-previews"
    case renderQuickPreviews = "--render-quick-previews"
    case renderStylePreviews = "--render-style-previews"

    var outputName: String? {
        switch self {
        case .smokeTest: nil
        case .renderPreview: "output-file"
        default: "output-directory"
        }
    }

    var invocation: String {
        outputName.map { "\(rawValue) <\($0)>" } ?? rawValue
    }
}

private func usageError(_ message: String) -> Never {
    fputs("\(message)\nUsage: scripts/dev.sh <command>\n", stderr)
    for command in DevelopmentCommand.allCases {
        fputs("  \(command.invocation)\n", stderr)
    }
    exit(EX_USAGE)
}

private func render(to path: String, description: String, using renderer: (String) throws -> Void) -> Int32 {
    do {
        try renderer(path)
        return 0
    } catch {
        fputs("\(description) failed: \(error)\n", stderr)
        return 1
    }
}

private func run(arguments: [String]) -> Never {
    guard let option = arguments.first else { usageError("A development command is required.") }
    guard let command = DevelopmentCommand(rawValue: option) else { usageError("Unknown development command: \(option)") }
    let output: String
    if let outputName = command.outputName {
        guard arguments.count >= 2, !arguments[1].isEmpty, !arguments[1].hasPrefix("-") else {
            usageError("\(option) requires an <\(outputName)>.")
        }
        guard arguments.count == 2 else { usageError("Unexpected argument after <\(outputName)>: \(arguments[2])") }
        output = arguments[1]
    } else {
        guard arguments.count == 1 else { usageError("Unexpected argument after \(option): \(arguments[1])") }
        output = ""
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    switch command {
    case .smokeTest:
        DispatchQueue.main.async { exit(RuntimeChecks.run()) }
        application.run()
        exit(1)
    case .liveDisplayTest:
        LiveDisplayChecks.run(to: output)
    case .renderPreview:
        exit(render(to: output, description: "Preview", using: RuntimeChecks.renderPreview))
    case .renderTimerPreviews:
        exit(render(to: output, description: "Timer previews", using: RuntimeChecks.renderTimerPreviews))
    case .renderDocumentationPreviews:
        exit(render(to: output, description: "Documentation previews", using: RuntimeChecks.renderDocumentationPreviews))
    case .renderQuickPreviews:
        exit(render(to: output, description: "Quick access previews", using: RuntimeChecks.renderQuickPreviews))
    case .renderStylePreviews:
        exit(render(to: output, description: "Style previews", using: RuntimeChecks.renderStylePreviews))
    }
}

run(arguments: Array(CommandLine.arguments.dropFirst()))
