// PermissionFlow-inspired panel layout and launch animation, adapted for DeskLoom.
// Upstream: https://github.com/jaywcjlove/PermissionFlow
// Copyright (c) 2026 小弟调调 — MIT License.
// The upstream notice and full license are retained in references/permissionflow/LICENSE
// and distributed with the application in its third-party notices.
import AppKit
import ApplicationServices
import QuartzCore
import SwiftUI

/// Follows System Settings using window-server metadata. The guide itself never
/// needs the Accessibility or Screen Recording grant that it is explaining.
@MainActor
final class PermissionGuideController: NSObject {
    private let model: AppModel
    private let presentation = PermissionGuidePresentation()
    private let panel = PermissionGuidePanel(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 64),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    private var host: NSHostingController<PermissionGuideView>?
    private var trackingTimer: Timer?
    private var permissionTimer: Timer?
    private var animationTimer: Timer?
    private let trackingInterval = 1.0 / 30.0
    private let permissionProbeInterval = 1.0
    private let animationDuration = 0.60
    private var permission = ""
    private var permissionTitle = ""
    private var startedAt = Date.distantPast
    private var sawSettingsApplication = false
    private var sawSettingsWindow = false
    private var missingWindowSince: Date?
    private var trackingPaused = false
    private var pendingDismissReason: String?
    private var pendingShow: (permission: String, title: String, source: CGRect?)?
    private var dragSessionCount = 0
    private var lastDragCompleted = false
    private var settingsPID: pid_t?
    private var settingsWindowID: CGWindowID?
    private var settingsFrame: NSRect?
    private var attachment = "inactive"
    private var placement = "inactive"
    private var fallbackReason: String?
    private var dismissReason: String?
    private var sourceFrame: CGRect?
    private var launchAnimationPlayed = false
    private var launchAnimating = false
    private var launchStartTime: CFTimeInterval = 0
    private var launchFromFrame = CGRect.zero
    private var launchToFrame = CGRect.zero
    private var launchAnimationFrames = 0
    private var measuredWidth: CGFloat = 0
    private var measuredHeight: CGFloat = 0
    private var measuredLoading = false

    init(model: AppModel) {
        self.model = model
        super.init()
        panel.title = "DeskLoom · 权限授权"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// UI callers supply their button's AppKit screen rect; headless/RPC callers
    /// omit it and get immediate placement without inventing a click origin.
    func show(permission: String, title: String, sourceFrameInScreen: CGRect? = nil) {
        guard !trackingPaused else {
            pendingShow = (permission, title, sourceFrameInScreen)
            return
        }
        finish(reason: "replaced")
        self.permission = permission
        permissionTitle = title
        sourceFrame = sourceFrameInScreen.flatMap { validFrame($0) ? $0 : nil }
        startedAt = Date()
        sawSettingsApplication = false
        sawSettingsWindow = false
        missingWindowSince = nil
        settingsPID = nil
        settingsWindowID = nil
        settingsFrame = nil
        fallbackReason = nil
        dismissReason = nil
        attachment = "waiting_for_settings"
        placement = "waiting"
        launchAnimationPlayed = false
        launchAnimationFrames = 0
        dragSessionCount = 0
        lastDragCompleted = false
        pendingDismissReason = nil
        pendingShow = nil
        measuredWidth = 0
        measuredHeight = 0
        presentation.isDragging = false
        presentation.isAwaitingSettingsWindow = true

        let tracking = Timer(timeInterval: trackingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTracking() }
        }
        tracking.tolerance = trackingInterval * 0.2
        trackingTimer = tracking
        RunLoop.main.add(tracking, forMode: .common)
        // Permission checks are intentionally independent of 30 Hz geometry.
        let permissions = Timer(timeInterval: permissionProbeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        permissions.tolerance = 0.1
        permissionTimer = permissions
        RunLoop.main.add(permissions, forMode: .common)
        refreshPermissions()
        guard trackingTimer != nil else { return }
        showWaitingPanel()
        refreshTracking()
    }

    func dismiss() { finish(reason: "user_dismissed") }

    private func finish(reason: String) {
        guard !trackingPaused else {
            pendingDismissReason = reason
            return
        }
        trackingTimer?.invalidate()
        trackingTimer = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        stopLaunchAnimation()
        panel.orderOut(nil)
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        trackingPaused = false
        presentation.isDragging = false
        attachment = "inactive"
        dismissReason = reason
    }

    private var currentPermissionGranted: Bool {
        (permission == "accessibility" && model.accessibilityGranted) ||
            (permission == "screen_recording" && model.screenRecordingGranted)
    }

    private func refreshPermissions() {
        guard trackingTimer != nil else { return }
        let accessibility = AXIsProcessTrusted()
        let screenRecording = CGPreflightScreenCaptureAccess()
        if model.accessibilityGranted != accessibility { model.accessibilityGranted = accessibility }
        if model.screenRecordingGranted != screenRecording { model.screenRecordingGranted = screenRecording }
        // A successful drop is not proof of a grant. Only the system permission
        // API can end the flow, and AppKit must finish an active drag first.
        if currentPermissionGranted && !trackingPaused { finish(reason: "permission_granted") }
    }

    private func refreshTracking() {
        guard trackingTimer != nil, !trackingPaused else { return }
        if currentPermissionGranted { finish(reason: "permission_granted"); return }
        guard let settings = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences"
        ).first(where: { !$0.isTerminated }) else {
            if sawSettingsApplication || Date().timeIntervalSince(startedAt) > 12 {
                finish(reason: "settings_unavailable")
            } else if !mayShowLoadingWhileOpening() {
                hideForBackground()
            }
            return
        }
        sawSettingsApplication = true
        settingsPID = settings.processIdentifier
        let window = visibleSettingsWindow(pid: settings.processIdentifier)
        if window == nil, sawSettingsWindow {
            // Closing Settings often activates another app immediately. Check
            // disappearance before the foreground guard so the flow can finish
            // even though System Settings' process remains alive without a window.
            hidePanel()
            attachment = "waiting_for_settings_window"
            if missingWindowSince == nil { missingWindowSince = Date() }
            if let since = missingWindowSince, Date().timeIntervalSince(since) > 1 {
                finish(reason: "settings_window_closed")
            }
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == settings.processIdentifier else {
            if !mayShowLoadingWhileOpening() { hideForBackground() }
            missingWindowSince = nil
            return
        }

        if let window {
            let firstWindow = !sawSettingsWindow
            sawSettingsWindow = true
            missingWindowSince = nil
            settingsWindowID = window.id
            settingsFrame = window.frame
            fallbackReason = nil
            if presentation.isAwaitingSettingsWindow { presentation.isAwaitingSettingsWindow = false }
            let target = attachedFrame(to: window.frame)
            attachment = target.placement
            placement = target.placement
            if firstWindow, let sourceFrame,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                beginLaunch(from: sourceFrame, to: target.frame)
            } else if launchAnimating {
                // Keep the launch continuous while Settings moves or resizes.
                launchToFrame = target.frame
            } else {
                positionPanel(target.frame)
            }
        } else {
            guard Date().timeIntervalSince(startedAt) > 0.8 else { return }
            // Keep a usable app drag if this OS withholds Settings metadata;
            // do not require AX access merely to present its own grant guide.
            if presentation.isAwaitingSettingsWindow { presentation.isAwaitingSettingsWindow = false }
            settingsWindowID = nil
            settingsFrame = nil
            attachment = "screen_edge_fallback"
            placement = "screen_edge_fallback"
            fallbackReason = "settings_window_bounds_unavailable"
            let screen = sourceFrame.flatMap { screenFor($0) } ?? screenForMouse()
            guard let screen else { return }
            let area = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            let width = min(480, area.width)
            let height = measuredPanelHeight(width: width, loading: false)
            positionPanel(clampedFrame(CGRect(x: area.maxX - width, y: area.minY,
                                               width: width, height: height), in: area))
        }
    }

    private func mayShowLoadingWhileOpening() -> Bool {
        !sawSettingsWindow && presentation.isAwaitingSettingsWindow &&
            Date().timeIntervalSince(startedAt) < 1.5 &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func hideForBackground() {
        hidePanel()
        attachment = "settings_in_background"
    }

    private func hidePanel() {
        stopLaunchAnimation()
        panel.orderOut(nil)
    }

    private func showWaitingPanel() {
        let screen = sourceFrame.flatMap { screenFor($0) } ?? screenForMouse()
        guard let screen else { return }
        let area = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(480, area.width)
        let height = measuredPanelHeight(width: width, loading: true)
        let anchor = sourceFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: area.midX, y: area.midY)
        positionPanel(clampedFrame(CGRect(x: anchor.x - width / 2, y: anchor.y - height / 2,
                                          width: width, height: height), in: area))
    }

    private func setDragging(_ dragging: Bool) {
        trackingPaused = dragging
        presentation.isDragging = dragging
        panel.ignoresMouseEvents = dragging
        panel.alphaValue = dragging ? 0.72 : 1
        if dragging {
            dragSessionCount += 1
            lastDragCompleted = false
            // Do not move or hide the source window until AppKit calls endedAt.
            stopLaunchAnimation()
        } else {
            lastDragCompleted = true
            if let request = pendingShow {
                pendingShow = nil
                show(permission: request.permission, title: request.title, sourceFrameInScreen: request.source)
            } else if let reason = pendingDismissReason {
                pendingDismissReason = nil
                finish(reason: reason)
            } else if trackingTimer != nil {
                refreshTracking()
            }
        }
    }

    private func positionPanel(_ frame: CGRect) {
        if !NSEqualRects(panel.frame, frame) { panel.setFrame(frame, display: true) }
        panel.contentView?.layoutSubtreeIfNeeded()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func beginLaunch(from source: CGRect, to target: CGRect) {
        stopLaunchAnimation()
        launchAnimationPlayed = true
        launchAnimating = true
        launchToFrame = target
        let screen = screenFor(source) ?? screenFor(target)
        let area = screen?.visibleFrame.insetBy(dx: 8, dy: 8) ?? target
        // The complete card retains its destination size throughout flight.
        launchFromFrame = clampedFrame(CGRect(x: source.midX - target.width / 2,
                                              y: source.midY - target.height / 2,
                                              width: target.width, height: target.height), in: area)
        launchStartTime = CACurrentMediaTime()
        positionPanel(launchFromFrame)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepLaunchAnimation() }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stepLaunchAnimation() {
        guard launchAnimating, !trackingPaused else { return }
        let elapsed = CACurrentMediaTime() - launchStartTime
        if elapsed >= animationDuration || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopLaunchAnimation()
            positionPanel(launchToFrame)
            return
        }
        let t = CGFloat(max(0, elapsed / animationDuration))
        let progress = t * t * (3 - 2 * t)
        let start = CGPoint(x: launchFromFrame.midX, y: launchFromFrame.midY)
        let end = CGPoint(x: launchToFrame.midX, y: launchToFrame.midY)
        let distance = hypot(end.x - start.x, end.y - start.y)
        let control = CGPoint(x: (start.x + end.x) / 2,
                              y: max(start.y, end.y) + min(120, max(32, distance * 0.16)))
        let inverse = 1 - progress
        let center = CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * progress * control.x + progress * progress * end.x,
            y: inverse * inverse * start.y + 2 * inverse * progress * control.y + progress * progress * end.y
        )
        let frame = CGRect(x: center.x - launchToFrame.width / 2, y: center.y - launchToFrame.height / 2,
                           width: launchToFrame.width, height: launchToFrame.height)
        let area = screenFor(frame)?.visibleFrame.insetBy(dx: 8, dy: 8) ?? frame
        positionPanel(clampedFrame(frame, in: area))
        launchAnimationFrames += 1
    }

    private func stopLaunchAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        launchAnimating = false
    }

    private func visibleSettingsWindow(pid: pid_t) -> (id: CGWindowID, frame: CGRect)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        // CG's origin is the main display's upper left. NSScreen.main follows
        // focus, so it cannot be used as the Y-flip reference on multiple screens.
        let primary = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == CGMainDisplayID()
        }) ?? NSScreen.screens.first
        guard let primary else { return nil }
        let candidates: [(id: CGWindowID, frame: CGRect)] = windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let id = window[kCGWindowNumber as String] as? NSNumber,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  validFrame(frame), frame.width >= 300, frame.height >= 200 else { return nil }
            return (id.uint32Value, CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY,
                                          width: frame.width, height: frame.height))
        }
        // Settings can create sheets and secondary windows. Retain the tracked
        // root window; on first discovery select its largest useful layer-0 window.
        if let id = settingsWindowID, let existing = candidates.first(where: { $0.id == id }) {
            return existing
        }
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func attachedFrame(to anchor: CGRect) -> (frame: CGRect, placement: String) {
        let area = (screenFor(anchor)?.visibleFrame ?? anchor).insetBy(dx: 8, dy: 8)
        // This matches Settings' normal 230 pt sidebar. Narrow windows retain a
        // readable card and align its trailing edge with the Settings content.
        let width = min(max(240, anchor.width - 230), area.width)
        let height = min(measuredPanelHeight(width: width, loading: false), area.height)
        let outsideY = anchor.minY - height
        let fitsBelow = outsideY >= area.minY
        let desired = CGRect(x: anchor.maxX - width,
                             y: fitsBelow ? outsideY : anchor.minY,
                             width: width, height: height)
        return (clampedFrame(desired, in: area), fitsBelow ? "bottom_outside" : "bottom_inside")
    }

    private func measuredPanelHeight(width: CGFloat, loading: Bool) -> CGFloat {
        if abs(measuredWidth - width) < 0.5, measuredLoading == loading, measuredHeight > 0 {
            return measuredHeight
        }
        measuredWidth = width
        measuredLoading = loading
        presentation.isAwaitingSettingsWindow = loading
        let view = PermissionGuideView(model: model, presentation: presentation,
                                       permissionTitle: permissionTitle, width: width,
                                       close: { [weak self] in self?.dismiss() },
                                       dragStateChanged: { [weak self] in self?.setDragging($0) })
        // A separate sizing host prevents SwiftUI intrinsic sizing from pushing
        // its measured frame back into the live NSPanel and undoing attachment.
        let sizingView = NSHostingView(rootView: view)
        sizingView.setFrameSize(NSSize(width: width, height: 500))
        sizingView.layoutSubtreeIfNeeded()
        measuredHeight = ceil(max(56, sizingView.fittingSize.height))
        if let host {
            host.rootView = view
        } else {
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = []
            if let hostingView = controller.view as? NSHostingView<PermissionGuideView> {
                hostingView.sizingOptions = []
            }
            host = controller
            panel.contentViewController = controller
        }
        return measuredHeight
    }

    private func validFrame(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite &&
            !frame.isNull && frame.width > 0 && frame.height > 0
    }

    private func screenFor(_ frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { left, right in
            let a = left.frame.intersection(frame), b = right.frame.intersection(frame)
            let aArea = a.isNull ? 0 : a.width * a.height
            let bArea = b.isNull ? 0 : b.width * b.height
            if aArea != bArea { return aArea < bArea }
            let aDistance = hypot(left.frame.midX - frame.midX, left.frame.midY - frame.midY)
            let bDistance = hypot(right.frame.midX - frame.midX, right.frame.midY - frame.midY)
            return aDistance > bDistance
        }
    }

    private func screenForMouse() -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.screens.first
    }

    private func clampedFrame(_ frame: CGRect, in area: CGRect) -> CGRect {
        let width = min(frame.width, area.width), height = min(frame.height, area.height)
        return CGRect(x: min(max(frame.minX, area.minX), max(area.minX, area.maxX - width)),
                      y: min(max(frame.minY, area.minY), max(area.minY, area.maxY - height)),
                      width: width, height: height)
    }

    func diagnostics() -> [String: Any] {
        var result: [String: Any] = [
            "active": trackingTimer != nil, "visible": panel.isVisible,
            "permission": permission, "permission_title": permissionTitle,
            "application_path": Bundle.main.bundleURL.path,
            "icon_variant": model.selectedIcon, "attachment": attachment,
            "tracking_paused_for_drag": trackingPaused,
            "window_number": panel.windowNumber, "panel_frame": rectData(panel.frame),
            "window_metadata_requires_accessibility": false,
            "window_metadata_requires_screen_capture": false,
            "accessibility_granted": model.accessibilityGranted,
            "screen_recording_granted": model.screenRecordingGranted,
            "takes_keyboard_focus": false,
            "placement": placement, "guidanceLayout": "bottom_content_aligned",
            "awaitingSettingsWindow": presentation.isAwaitingSettingsWindow,
            "launchAnimationPlayed": launchAnimationPlayed, "launchAnimating": launchAnimating,
            "launchAnimationFrames": launchAnimationFrames, "launchAnimationDuration": animationDuration,
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "dragPassthrough": panel.ignoresMouseEvents, "panelAlpha": panel.alphaValue,
            "dragSessionCount": dragSessionCount, "lastDragCompleted": lastDragCompleted,
            "trackingInterval": trackingInterval, "permissionProbeInterval": permissionProbeInterval
        ]
        if let sourceFrame { result["sourceFrame"] = rectData(sourceFrame) }
        if let settingsPID { result["settings_pid"] = settingsPID }
        if let settingsWindowID { result["settings_window_id"] = settingsWindowID }
        if let settingsFrame { result["settings_frame"] = rectData(settingsFrame) }
        if let fallbackReason { result["fallback_reason"] = fallbackReason }
        if let dismissReason { result["dismiss_reason"] = dismissReason }
        return result
    }

    func renderEvidence(to directory: URL) throws -> [String: String] {
        guard panel.isVisible, let view = panel.contentView else { return [:] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [:] }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return [:] }
        let output = directory.appendingPathComponent("permission-guide.png")
        try data.write(to: output, options: .atomic)
        return ["permissionGuide": output.path]
    }

    private func rectData(_ rect: CGRect) -> [String: CGFloat] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
}

private final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PermissionGuidePresentation: ObservableObject {
    @Published var isAwaitingSettingsWindow = true
    @Published var isDragging = false
}

@MainActor
private struct PermissionGuideView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: PermissionGuidePresentation
    let permissionTitle: String
    let width: CGFloat
    let close: () -> Void
    let dragStateChanged: (Bool) -> Void
    private let purple = Color(red: 0.55, green: 0.32, blue: 0.94)

    var body: some View {
        Group {
            if presentation.isAwaitingSettingsWindow {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在打开系统设置…").font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    closeButton
                }
                .frame(minHeight: 32)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "arrowshape.up.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(purple)
                            .frame(width: 18, height: 20)
                        Text("将 \(Text("DeskLoom").bold()) 拖到上方列表，允许 \(Text(permissionTitle).bold())")
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        closeButton
                    }
                    HStack(spacing: 10) {
                        Image(nsImage: applicationIcon(model.selectedIcon) ?? NSImage())
                            .resizable().scaledToFit().frame(width: 36, height: 36)
                        Text("DeskLoom").font(.system(size: 15, weight: .medium))
                        Spacer(minLength: 8)
                        VStack(spacing: 2) {
                            Image(systemName: "hand.draw").font(.system(size: 16))
                            Text("拖动").font(.system(size: 9))
                        }
                        .foregroundStyle(presentation.isDragging ? purple : Color.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.65),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .contentShape(Rectangle())
                    .overlay(ApplicationFileDragSource(applicationURL: Bundle.main.bundleURL,
                                                       iconVariant: model.selectedIcon,
                                                       onDragStateChanged: dragStateChanged))
                    .accessibilityLabel("DeskLoom 应用，可拖入系统设置权限列表")
                    HStack(spacing: 8) {
                        Text("添加后开启开关").foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("在 Finder 中显示") { model.onRevealApplication?() }
                            .buttonStyle(.plain).foregroundStyle(purple)
                    }
                    .font(.system(size: 10))
                }
            }
        }
        .padding(12)
        .frame(width: width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.secondary, Color.primary.opacity(0.08))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭权限引导")
    }
}
