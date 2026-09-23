import AppKit

let arguments = CommandLine.arguments
if arguments.contains("--self-check") {
    print(SelfCheck.run())
    exit(0)
}
#if DEBUG
if let index = arguments.firstIndex(of: "--render-setup"), index + 1 < arguments.count {
    PreviewRenderer.run(outputDirectory: URL(fileURLWithPath: arguments[index + 1]))
    exit(0)
}
#endif

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
