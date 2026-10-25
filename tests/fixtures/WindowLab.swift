import AppKit

// A test-owned application with in-memory text only. It never opens or saves
// documents and exposes ordinary AppKit accessibility controls to DeskLoom.
final class WindowLabDelegate: NSObject, NSApplicationDelegate {
    private let token: String
    private let readyURL: URL
    private var windows: [NSWindow] = []

    init(token: String, readyURL: URL) {
        self.token = token
        self.readyURL = readyURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(560, max(320, (visible.width - 72) / 2))
        let height = min(440, max(240, visible.height - 80))
        for (index, role) in ["Source", "Destination"].enumerated() {
            let frame = NSRect(x: visible.minX + 24 + CGFloat(index) * (width + 24),
                               y: visible.maxY - height - 40, width: width, height: height)
            let window = NSWindow(contentRect: frame,
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "DeskLoom WindowLab \(token) · \(role)"
            window.identifier = NSUserInterfaceItemIdentifier("windowlab-\(role.lowercased())")
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            // macOS adds a transient tiling AXGroup under the zoom button at
            // launch, then removes it several seconds later. This text fixture
            // does not exercise resizing or tiling; omit that animated control
            // so planner observations have a stable, ordinary AppKit AX tree.
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.zoomButton)?.isHidden = true

            let scroll = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder

            let text = NSTextView(frame: scroll.contentView.bounds)
            text.isRichText = false
            text.isEditable = true
            text.isSelectable = true
            text.allowsUndo = true
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.isAutomaticTextReplacementEnabled = false
            text.font = .systemFont(ofSize: 16)
            text.textContainerInset = NSSize(width: 18, height: 18)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true
            text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                       height: CGFloat.greatestFiniteMagnitude)
            text.setAccessibilityIdentifier("windowlab-\(role.lowercased())-text")
            text.setAccessibilityLabel("\(role) test text")
            text.string = "WindowLab \(role.lowercased()) test window"
            scroll.documentView = text
            window.contentView = scroll
            window.orderFrontRegardless()
            windows.append(window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            do {
                let ready: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                             "titles": windows.map(\.title),
                                             "bundle_id": Bundle.main.bundleIdentifier ?? ""]
                try JSONSerialization.data(withJSONObject: ready).write(to: readyURL, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("WindowLab readiness failed: \(error)\n".utf8))
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 4, arguments[0] == "--token", arguments[2] == "--ready-file",
      !arguments[1].isEmpty else {
    FileHandle.standardError.write(Data("Usage: WindowLab --token TOKEN --ready-file PATH\n".utf8))
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = WindowLabDelegate(token: arguments[1], readyURL: URL(fileURLWithPath: arguments[3]))
app.delegate = delegate
app.run()
