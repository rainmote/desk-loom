import AppKit

/// One marker per attached session. Preview selection never owns its lifetime.
@MainActor
final class TargetOverlayController {
    @MainActor
    final class Marker {
        let panel = TargetOverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 42),
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        let view = TargetOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 42))
        let processID: pid_t
        var targetFrame: CGRect?
        var windowID: CGWindowID?
        var visibilityReason = "target_unavailable"
        private(set) var visibilityChanges = 0
        private(set) var frameChanges = 0
        private(set) var orderChanges = 0

        init(processID: pid_t) {
            self.processID = processID
            view.setAccessibilityLabel(view.label)
            panel.contentView = view
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isFloatingPanel = false
            panel.level = .normal
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
        }

        func hide(_ reason: String) {
            visibilityReason = reason
            if panel.isVisible {
                panel.orderOut(nil)
                visibilityChanges += 1
            }
        }

        func show(frame: NSRect, above windowID: Int, needsOrdering: Bool) {
            if panel.frame != frame {
                panel.setFrame(frame, display: true, animate: false)
                frameChanges += 1
            }
            if !panel.isVisible || needsOrdering {
                let wasVisible = panel.isVisible
                panel.order(.above, relativeTo: windowID)
                orderChanges += 1
                if !wasVisible { visibilityChanges += 1 }
            }
            visibilityReason = "visible"
        }
    }

    private(set) var markers: [String: Marker] = [:]
    var isEmpty: Bool { markers.isEmpty }

    func update(sessionID: String, frame: CGRect?, windowID: CGWindowID?, processID: pid_t) {
        guard !sessionID.isEmpty else { return }
        if let previous = markers[sessionID], previous.processID != processID {
            remove(sessionID: sessionID)
        }
        let marker = markers[sessionID] ?? Marker(processID: processID)
        markers[sessionID] = marker
        // AX may temporarily omit geometry during an action. Keep the bound CG
        // window and let the next visibility query decide whether it is onscreen.
        marker.targetFrame = frame.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        if let windowID { marker.windowID = windowID }
    }

    func remove(sessionID: String) {
        guard let marker = markers.removeValue(forKey: sessionID) else { return }
        marker.hide("inactive")
        marker.panel.close()
    }

    func refresh() {
        guard !markers.isEmpty else { return }
        guard let screen = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else {
            for marker in markers.values { marker.hide("window_list_unavailable") }
            return
        }
        // A same-sized window in another Space must not be mistaken for this
        // session. Resolve against all windows, then evaluate onscreen visibility.
        let unresolved = markers.values.filter { $0.windowID == nil }
        let allWindows = unresolved.isEmpty ? [] :
            (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        for marker in unresolved {
            guard let target = marker.targetFrame else { continue }
            let candidates = allWindows.filter { window in
                guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == marker.processID,
                      (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let frame = bounds(window) else { return false }
                return abs(frame.minX - target.minX) < 3 && abs(frame.minY - target.minY) < 3 &&
                    abs(frame.width - target.width) < 3 && abs(frame.height - target.height) < 3
            }
            if candidates.count == 1 {
                marker.windowID = (candidates[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value
            }
        }
        let bindingCounts = markers.values.reduce(into: [CGWindowID: Int]()) { counts, marker in
            if let id = marker.windowID { counts[id, default: 0] += 1 }
        }
        for marker in markers.values {
            if let id = marker.windowID, bindingCounts[id, default: 0] > 1 {
                marker.hide("ambiguous_target")
            } else {
                refresh(marker, windows: windows, primaryScreenMaxY: screen.frame.maxY)
            }
        }
    }

    private func bounds(_ window: [String: Any]) -> CGRect? {
        guard let value = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: value as CFDictionary)
    }

    private func refresh(_ marker: Marker, windows: [[String: Any]], primaryScreenMaxY: CGFloat) {
        let candidates = windows.indices.filter { index in
            let window = windows[index]
            guard let number = window[kCGWindowNumber as String] as? NSNumber,
                  (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == marker.processID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return false }
            return number.uint32Value == marker.windowID
        }
        guard candidates.count == 1, let targetIndex = candidates.first,
              let number = windows[targetIndex][kCGWindowNumber as String] as? NSNumber,
              ((windows[targetIndex][kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
              let frame = bounds(windows[targetIndex]), frame.width >= 180, frame.height >= 42 else {
            marker.hide("target_not_visible")
            return
        }
        // Resolve geometry only once, so movement follows the same window even
        // before AX publishes its new frame or the first screenshot is requested.
        marker.windowID = number.uint32Value
        let size = marker.view.intrinsicContentSize
        let overlayFrame = NSRect(x: frame.maxX - size.width + 3,
                                  y: primaryScreenMaxY - frame.minY + 3 - size.height,
                                  width: size.width, height: size.height).integral
        let panelIndex = windows.firstIndex {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == marker.panel.windowNumber
        }
        // Keep the marker immediately above its target and below covering
        // windows. WindowServer handles occlusion without hiding/re-showing it.
        marker.show(frame: overlayFrame, above: number.intValue,
                    needsOrdering: panelIndex != targetIndex - 1)
    }

    func diagnostics() -> [[String: Any]] {
        markers.keys.sorted().compactMap { id in
            guard let marker = markers[id] else { return nil }
            return ["sessionID": id, "targetWindowID": marker.windowID as Any? ?? NSNull(),
                    "targetProcessID": marker.processID, "windowNumber": marker.panel.windowNumber,
                    "visible": marker.panel.isVisible, "visibilityReason": marker.visibilityReason,
                    "label": marker.view.label, "frame": ["x": marker.panel.frame.minX,
                        "y": marker.panel.frame.minY, "width": marker.panel.frame.width,
                        "height": marker.panel.frame.height],
                    "visibilityChanges": marker.visibilityChanges, "frameChanges": marker.frameChanges,
                    "orderChanges": marker.orderChanges]
        }
    }
}

@MainActor
final class TargetOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TargetOverlayView: NSView {
    let label = "控制中"
    override var isOpaque: Bool { false }
    private let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(96, (label as NSString).size(withAttributes: [.font: font]).width + 63), height: 42)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let purple = NSColor(calibratedRed: 0.55, green: 0.32, blue: 0.94, alpha: 1)
        let corner = NSBezierPath()
        corner.move(to: NSPoint(x: bounds.width - 3, y: bounds.height - 30))
        corner.line(to: NSPoint(x: bounds.width - 3, y: bounds.height - 8))
        corner.curve(to: NSPoint(x: bounds.width - 8, y: bounds.height - 3),
                     controlPoint1: NSPoint(x: bounds.width - 3, y: bounds.height - 5),
                     controlPoint2: NSPoint(x: bounds.width - 5, y: bounds.height - 3))
        corner.line(to: NSPoint(x: bounds.width - 33, y: bounds.height - 3))
        corner.lineWidth = 4
        corner.lineCapStyle = .round
        purple.setStroke()
        corner.stroke()

        let pill = NSRect(x: 9, y: 9, width: bounds.width - 24, height: 24)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        purple.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: pill.minX + 11, y: pill.midY - 3, width: 6, height: 6)).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (label as NSString).draw(in: NSRect(x: pill.minX + 24, y: pill.midY - 8,
                                          width: pill.width - 34, height: 18), withAttributes: [
            .font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph
        ])
    }
}
