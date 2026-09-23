import AppKit

if CommandLine.arguments.contains("--self-check") {
    print(SelfCheck.run())
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
