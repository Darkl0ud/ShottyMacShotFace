import AppKit

// The app lives in the menu bar (LSUIElement); it gains a Dock icon only while an editor is open.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--selftest") {
        // Renders the editor, overlay and every annotation to PNGs and checks them, for testing
        // without clicking through the UI. Usage: ShottyMacShotFace --selftest <output dir>
        let dir = args.count > i + 1 ? args[i + 1] : NSTemporaryDirectory() + "shotty-selftest"
        let tester = SelfTest(outputDir: URL(fileURLWithPath: dir, isDirectory: true),
                              includeCapture: !args.contains("--no-capture"))
        app.delegate = tester
        app.setActivationPolicy(.accessory)
        app.run()
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
