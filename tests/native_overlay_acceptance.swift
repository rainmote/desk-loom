// Build with native/Sources/*.swift except main.swift. Uses only test-owned
// in-memory AppKit windows; never requests AX access or sends desktop input.
import AppKit

@main
struct NativeOverlayAcceptance {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel()
        let interface = InterfaceController(model: model)
        let screen = NSScreen.screens.first!
        let visible = screen.visibleFrame
        let windows = (0..<2).map { index -> NSWindow in
            let window = NSWindow(contentRect: NSRect(x: visible.minX + 30 + CGFloat(index) * 370,
                                                       y: visible.midY - 140, width: 340, height: 280),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "DeskLoom overlay regression \(index + 1)"
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.orderFrontRegardless()
            return window
        }
        defer { for window in windows { window.close() } }
        let pid = ProcessInfo.processInfo.processIdentifier
        func axFrame(_ window: NSWindow) -> CGRect {
            CGRect(x: window.frame.minX, y: screen.frame.maxY - window.frame.maxY,
                   width: window.frame.width, height: window.frame.height)
        }
        func settle(_ duration: TimeInterval = 0.25) {
            RunLoop.main.run(until: Date().addingTimeInterval(duration))
        }
        func rows() -> [[String: Any]] {
            interface.diagnostics()["overlays"] as! [[String: Any]]
        }
        func marker(_ id: String) -> [String: Any] {
            rows().first { $0["sessionID"] as? String == id }!
        }
        func select(_ index: Int) {
            interface.updateTargetFrame(axFrame(windows[index]), windowID: CGWindowID(windows[index].windowNumber),
                                        processID: pid, sessionID: String(index))
        }
        func assertPlacement(_ index: Int) {
            let row = marker(String(index))
            let frame = row["frame"] as! [String: CGFloat]
            precondition(abs(frame["x"]! + frame["width"]! - windows[index].frame.maxX - 3) < 1)
            precondition(abs(frame["y"]! + frame["height"]! - windows[index].frame.maxY - 3) < 1)
            precondition(row["label"] as? String == "控制中")
            precondition(row["visible"] as? Bool == true)
        }
        model.isActive = true
        model.activeWindowCount = 2
        for (index, window) in windows.enumerated() {
            interface.updateControlledTarget(sessionID: String(index), frame: axFrame(window),
                                             windowID: CGWindowID(window.windowNumber), processID: pid)
        }
        select(0)
        // Let the window manager finish its initial placement before measuring
        // an idle interval; legitimate target movement must move the marker.
        settle(1.5)
        precondition(rows().count == 2)
        let original = rows()
        for index in 0..<40 {
            select(index % 2)
            // The old activation handler unconditionally ordered the marker out.
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                                                       object: nil)
            precondition(rows().allSatisfy { $0["visible"] as? Bool == true })
            settle(0.015)
        }
        for index in 0..<2 {
            assertPlacement(index)
            let before = original.first { $0["sessionID"] as? String == String(index) }!
            let after = marker(String(index))
            for key in ["windowNumber", "visibilityChanges", "frameChanges", "orderChanges"] {
                if before[key] as? Int != after[key] as? Int {
                    let stack = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                            kCGNullWindowID) as! [[String: Any]]).filter {
                        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                    }
                    let evidence: [String: Any] = ["before": before, "after": after,
                                                   "targetFrame": NSStringFromRect(windows[index].frame), "stack": stack]
                    FileHandle.standardError.write(try! JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted]))
                }
                precondition(before[key] as? Int == after[key] as? Int, "Unexpected \(key) after selection/activation")
            }
        }
        let state = interface.diagnostics()
        precondition(state["statusTitle"] as? String == "2")
        precondition(state["overlayCanBecomeKey"] as? Bool == false)
        precondition(state["overlayCanBecomeMain"] as? Bool == false)
        precondition(state["overlayIsKeyWindow"] as? Bool == false)
        precondition(state["overlayIgnoresMouseEvents"] as? Bool == true)

        // Follow WindowServer geometry even before the AX frame refresh arrives.
        windows[0].setFrameOrigin(NSPoint(x: windows[0].frame.minX + 40, y: windows[0].frame.minY - 50))
        settle()
        assertPlacement(0)
        interface.updateControlledTarget(sessionID: "0", frame: nil, windowID: nil, processID: pid)
        assertPlacement(0)

        // An overlapping window must cover the marker naturally, with no blink.
        let cover = NSWindow(contentRect: windows[0].frame, styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        defer { cover.close() }
        let changes = marker("0")["visibilityChanges"] as! Int
        cover.orderFrontRegardless()
        settle()
        precondition(marker("0")["visibilityChanges"] as? Int == changes)
        let cgWindows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
        let numbers = cgWindows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
        let panelNumber = marker("0")["windowNumber"] as! Int
        precondition(numbers.firstIndex(of: cover.windowNumber)! < numbers.firstIndex(of: panelNumber)!)
        precondition(numbers.firstIndex(of: panelNumber)! < numbers.firstIndex(of: windows[0].windowNumber)!)
        cover.orderOut(nil)

        windows[0].orderOut(nil)
        let hiddenDeadline = Date().addingTimeInterval(2)
        while marker("0")["visible"] as? Bool == true && Date() < hiddenDeadline { settle(0.05) }
        if marker("0")["visible"] as? Bool == true {
            FileHandle.standardError.write(Data("Target visible: \(windows[0].isVisible); marker: \(marker("0"))\n".utf8))
        }
        precondition(marker("0")["visible"] as? Bool == false)
        precondition(marker("1")["visible"] as? Bool == true)
        windows[0].orderFrontRegardless()
        settle()
        assertPlacement(0)
        interface.removeControlledTarget(sessionID: "0")
        model.activeWindowCount = 1
        settle()
        precondition(rows().count == 1 && marker("1")["visible"] as? Bool == true)
        precondition(interface.diagnostics()["statusTitle"] as? String == "1")
        interface.removeControlledTarget(sessionID: "1")
        interface.updateTargetFrame(nil)
        model.activeWindowCount = 0
        model.isActive = false
        settle()
        precondition(rows().isEmpty && interface.diagnostics()["overlayVisible"] as? Bool == false)
        precondition(interface.diagnostics()["statusTitle"] as? String == "0")
        print("NativeOverlayAcceptance: passed; two real windows, 40 selection/activation cycles without hide, redraw or reorder; movement, occlusion, hide/restore and detach verified")
    }
}
