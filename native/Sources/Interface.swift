import AppKit
import Combine
import SwiftUI

struct LLMWindow: Identifiable, Hashable {
    let id: String
    let pid: Int
    let title: String
    let appName: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var appName: String = "未选择应用"
    @Published var windowTitle: String = ""
    @Published var phase: String = "待连接"
    @Published var detail: String = "选择应用窗口后，可让 LLM 操作或通过 MCP 控制。"
    @Published var isActive: Bool = false
    @Published var activeWindowCount: Int = 0
    @Published var accessibilityGranted: Bool = false
    @Published var screenRecordingGranted: Bool = false
    @Published var permissionSettingsMessage: String? = nil
    @Published var previewImage: NSImage? = nil
    @Published var previewError: String? = nil
    @Published var previewWindowAvailable: Bool = false
    @Published var lastCapture: Date? = nil
    @Published var nodeCount: Int = 0
    @Published var selectedIcon: String = "C"
    @Published var isUpdating: Bool = false
    @Published var updateMessage: String? = nil
    @Published var inspectorShowingSettings: Bool = false
    @Published var popoverShowingSettings: Bool = false
    @Published var llmAvailable: Bool = false
    @Published var llmAuthenticated: Bool = false
    @Published var llmStatus: String = "正在检查本地 ChatGPT 登录状态…"
    @Published var llmRunning: Bool = false
    @Published var llmPrompt: String = ""
    @Published var llmModel: String = ""
    @Published var llmWindows: [LLMWindow] = []
    @Published var llmSelectedWindowIDs: Set<String> = []
    @Published var llmOutput: String = ""
    var showingSettings: Bool { inspectorShowingSettings || popoverShowingSettings }
    var controlledWindowCount: Int { max(0, activeWindowCount) }

    var onStop: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onRequestScreenRecording: (() -> Void)?
    var onRevealApplication: (() -> Void)?
    var onRecheckPermissions: (() -> Void)?
    var onSelectIcon: ((String) -> Void)?
    var onUpdate: (() -> Void)?
    var onLLMRefresh: (() -> Void)?
    var onLLMLogin: (() -> Void)?
    var onLLMRun: (() -> Void)?
    var onLLMStop: (() -> Void)?
    var onLLMRefreshWindows: (() -> Void)?

    var accessibilityPermissionName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? "设备控制和数据访问" : "辅助功能（无障碍）"
    }

    var screenRecordingPermissionName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? "录屏与系统录音" : "屏幕与系统音频录制"
    }

    func previewIsLive(at date: Date = Date()) -> Bool {
        isActive && previewWindowAvailable && screenRecordingGranted && previewError == nil &&
        previewImage != nil && lastCapture.map { date.timeIntervalSince($0) <= 3 } == true
    }

    func previewStatus(at date: Date = Date()) -> String {
        if !screenRecordingGranted { return "未授权" }
        if !isActive { return "已暂停" }
        if !previewWindowAvailable || previewError != nil { return "窗口不可用" }
        if previewImage == nil { return "等待画面" }
        if lastCapture == nil { return "时间未知" }
        return previewIsLive(at: date) ? "实时" : "画面过期"
    }
}

private enum InterfaceStyle {
    static let purple = Color(red: 0.55, green: 0.32, blue: 0.94)
    static let nativePurple = NSColor(calibratedRed: 0.55, green: 0.32, blue: 0.94, alpha: 1)
}

func applicationIcon(_ variant: String) -> NSImage? {
    let name = variant == "D" ? "IconD" : "IconC"
    guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
        return NSImage(systemSymbolName: "cursorarrow.motionlines.click", accessibilityDescription: "DeskLoom")
    }
    return NSImage(contentsOf: url)
}

@MainActor
final class InterfaceController: NSObject, NSWindowDelegate, NSPopoverDelegate {
    let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let contextMenu = NSMenu()
    private var updateMenuItem: NSMenuItem?
    private var inspector: NSWindow?
    private lazy var permissionGuide = PermissionGuideController(model: model)
    private var popoverEventMonitors: [Any] = []
    private var popoverDismissCount = 0
    private var lastPopoverDismissReason: String?
    private var pendingPopoverDismissReason: String?
    private var popoverClosing = false
    private let overlay: TargetOverlayPanel
    private let overlayView = TargetOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 42))
    private var targetFrame: CGRect?
    private var targetWindowID: CGWindowID?
    private var targetProcessID: pid_t?
    private var overlayVisibilityReason = "inactive"
    private var cancellable: AnyCancellable?
    private var overlayVisibilityCancellable: AnyCancellable?
    private var statusIconVariant: String?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        overlay = TargetOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 42),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        overlay.contentView = overlayView
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.hidesOnDeactivate = false
        overlay.becomesKeyOnlyIfNeeded = true
        overlay.isFloatingPanel = false
        overlay.level = .normal
        overlay.animationBehavior = .none
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        overlay.isReleasedWhenClosed = false

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("DeskLoom 控制窗口")
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleNone
        }
        contextMenu.autoenablesItems = false
        for (title, action) in [("显示窗口", "show_window"), ("更新", "update"), ("退出", "quit")] {
            let item = NSMenuItem(title: title, action: #selector(contextMenuSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            contextMenu.addItem(item)
            if action == "update" { updateMenuItem = item }
        }
        // Own dismissal explicitly: NSPopover.transient may close on a status
        // button's mouse-down, then reopen on its mouse-up toggle.
        popover.behavior = .applicationDefined
        popover.delegate = self
        let popoverHost = NSHostingController(rootView:
            SurfaceView(model: model, compact: true,
                        openWindow: { [weak self] in self?.showWindow() },
                        toggleSettings: { [weak self] in self?.toggleSettings(inPopover: true) })
        )
        // Page navigation changes content, never the anchored window's size.
        popoverHost.sizingOptions = []
        popover.contentViewController = popoverHost
        popover.contentSize = NSSize(width: 384, height: 490)
        cancellable = model.objectWillChange.sink { [weak self] _ in
            // Published sends before its value changes. Update native chrome on the next turn.
            DispatchQueue.main.async { self?.refreshChrome() }
        }
        // Window movement and occlusion can change without another AX action.
        // Follow visible target geometry without activating either application.
        overlayVisibilityCancellable = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.model.isActive else { return }
                self.refreshOverlay()
            }
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(targetVisibilityChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidResignActive(_:)),
                                               name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged(_:)),
                                               name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        refreshChrome()
    }

    func showWindow() {
        dismissPopover(reason: "show_window")
        createInspectorIfNeeded()
        inspector?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showPermissionGuide(permission: String, title: String, sourceFrameInScreen: CGRect? = nil) {
        dismissPopover(reason: "permission_settings")
        permissionGuide.show(permission: permission, title: title, sourceFrameInScreen: sourceFrameInScreen)
    }

    func dismissPermissionGuide() {
        permissionGuide.dismiss()
    }

    private func createInspectorIfNeeded() {
        if inspector == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "DeskLoom · 本地工作台"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 510, height: 710)
            let host = NSHostingController(rootView:
                SurfaceView(model: model, compact: false, openWindow: {},
                            toggleSettings: { [weak self] in self?.toggleSettings(inPopover: false) })
            )
            host.sizingOptions = []
            window.contentViewController = host
            window.setContentSize(NSSize(width: 620, height: 720))
            window.delegate = self
            window.center()
            inspector = window
        }
    }

    func toggleSettings() {
        toggleSettings(inPopover: popover.isShown)
    }

    private func toggleSettings(inPopover: Bool) {
        let showing = inPopover ? model.popoverShowingSettings : model.inspectorShowingSettings
        if showing { closeSettings(inPopover: inPopover) }
        else { showSettings(inPopover: inPopover) }
    }

    func showSettings() {
        showSettings(inPopover: popover.isShown)
    }

    private func showSettings(inPopover: Bool) {
        if inPopover {
            model.popoverShowingSettings = true
        } else {
            // Keep the existing window and its geometry; create it only if this
            // RPC is used before the workbench has ever been opened.
            createInspectorIfNeeded()
            model.inspectorShowingSettings = true
            inspector?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func closeSettings() {
        closeSettings(inPopover: popover.isShown)
    }

    private func closeSettings(inPopover: Bool) {
        if inPopover { model.popoverShowingSettings = false }
        else { model.inspectorShowingSettings = false }
    }

    private var settingsHost: String? {
        if popover.isShown, model.popoverShowingSettings { return "popover" }
        if inspector?.isVisible == true, model.inspectorShowingSettings { return "inspector" }
        return nil
    }

    private var settingsHostView: NSView? {
        switch settingsHost {
        case "popover": return popover.contentViewController?.view
        case "inspector": return inspector?.contentView
        default: return nil
        }
    }

    /// AX rectangles use a top-left global origin. AppKit windows use a bottom-left origin.
    func updateTargetFrame(_ rect: CGRect?, windowID: CGWindowID? = nil, processID: pid_t? = nil) {
        targetFrame = rect
        targetWindowID = rect == nil ? nil : windowID
        targetProcessID = rect == nil ? nil : processID
        let available = rect.map { $0.width > 0 && $0.height > 0 } ?? false
        if model.previewWindowAvailable != available { model.previewWindowAvailable = available }
        refreshOverlay()
    }

    @objc private func targetVisibilityChanged(_ notification: Notification) {
        // Hide immediately while a Space/application transition settles. The
        // next visibility tick only restores a marker over its actual target.
        overlay.orderOut(nil)
        overlayVisibilityReason = "visibility_changed"
        DispatchQueue.main.async { [weak self] in self?.refreshOverlay() }
    }

    func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        pendingPopoverDismissReason = nil
        popoverClosing = false
        // A status-bar app may be inactive when its button is clicked. Make the
        // popover key so switching apps or windows has an explicit focus boundary.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installPopoverEventMonitors()
    }

    func toggleStatusPopover() {
        if popover.isShown { dismissPopover(reason: "status_toggle") }
        else { showPopover() }
    }

    private func dismissPopover(reason: String) {
        guard popover.isShown, !popoverClosing else { return }
        popoverClosing = true
        pendingPopoverDismissReason = reason
        popover.performClose(nil)
    }

    func popoverWillClose(_ notification: Notification) {
        popoverClosing = true
    }

    func popoverDidClose(_ notification: Notification) {
        // A newly opened menu starts at controls; this does not affect the
        // workbench's independent page selection.
        if model.popoverShowingSettings { model.popoverShowingSettings = false }
        popoverDismissCount += 1
        lastPopoverDismissReason = pendingPopoverDismissReason ?? "native_close"
        pendingPopoverDismissReason = nil
        popoverClosing = false
        for monitor in popoverEventMonitors { NSEvent.removeMonitor(monitor) }
        popoverEventMonitors.removeAll()
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        dismissPopover(reason: "application_deactivated")
    }

    @objc private func windowFocusChanged(_ notification: Notification) {
        guard popover.isShown,
              let window = notification.object as? NSWindow,
              let popoverWindow = popover.contentViewController?.view.window else { return }
        if notification.name == NSWindow.didResignKeyNotification, window === popoverWindow {
            dismissPopover(reason: "popover_resigned_key")
        } else if notification.name == NSWindow.didBecomeKeyNotification, window !== popoverWindow {
            dismissPopover(reason: "other_window_became_key")
        }
    }

    private func installPopoverEventMonitors() {
        guard popoverEventMonitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            self?.dismissPopover(reason: "outside_application_click")
        }) { popoverEventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.dismissPopover(reason: "escape")
                    return nil
                }
                return event
            }
            let popoverWindow = self.popover.contentViewController?.view.window
            // Keep the status button's own mouse-up toggle intact. Clicking any
            // other window in this application dismisses the transient surface.
            if event.window !== popoverWindow, event.window !== self.statusItem.button?.window {
                self.dismissPopover(reason: "outside_popover_click")
            }
            return event
        }) { popoverEventMonitors.append(monitor) }
    }

    @discardableResult
    func performMenuAction(_ action: String) -> Bool {
        switch action {
        case "show_window": showWindow()
        case "update":
            guard !model.isUpdating, !model.isActive, !model.llmRunning, let update = model.onUpdate else { return false }
            update()
        case "quit":
            model.onLLMStop?()
            model.onStop?()
            NSApp.terminate(nil)
        default: return false
        }
        return true
    }

    func diagnostics() -> [String: Any] {
        func rectData(_ rect: CGRect) -> [String: Double] {
            ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
        }
        let anchor = statusItem.button.flatMap { button in
            button.window?.convertToScreen(button.convert(button.bounds, to: nil))
        }
        return [
            "permissionGuide": permissionGuide.diagnostics(),
            "overlayVisible": overlay.isVisible,
            "overlayFrame": rectData(overlay.frame),
            "overlayWindowNumber": overlay.windowNumber,
            "overlayCanBecomeKey": overlay.canBecomeKey,
            "overlayCanBecomeMain": overlay.canBecomeMain,
            "overlayIsKeyWindow": overlay.isKeyWindow,
            "overlayIgnoresMouseEvents": overlay.ignoresMouseEvents,
            "overlayLevel": overlay.level.rawValue,
            "overlayLabel": overlayView.label,
            "overlayVisibilityReason": overlayVisibilityReason,
            "targetFrame": targetFrame.map(rectData) as Any? ?? NSNull(),
            "targetWindowID": targetWindowID as Any? ?? NSNull(),
            "targetProcessID": targetProcessID as Any? ?? NSNull(),
            "primaryScreenMaxY": NSScreen.screens.first?.frame.maxY ?? 0,
            "visibleScreenBounds": NSScreen.screens.map { screen in
                let visible = screen.visibleFrame
                return rectData(CGRect(x: visible.minX,
                                       y: (NSScreen.screens.first?.frame.maxY ?? 0) - visible.maxY,
                                       width: visible.width, height: visible.height))
            },
            "statusTitle": statusItem.button?.attributedTitle.string ?? "",
            "statusThumbnailVisible": false,
            "statusIconVisible": statusItem.button?.image != nil,
            "controlledWindowCount": model.controlledWindowCount,
            "llmAvailable": model.llmAvailable,
            "llmAuthenticated": model.llmAuthenticated,
            "llmRunning": model.llmRunning,
            "llmStatus": model.llmStatus,
            "llmWindowCount": model.llmWindows.count,
            "llmSelectedWindowIDs": model.llmSelectedWindowIDs.sorted(),
            "selectedIcon": model.selectedIcon,
            "showingSettings": model.showingSettings,
            "settingsVisible": settingsHost != nil,
            "settingsHost": settingsHost as Any? ?? NSNull(),
            "settingsWindowNumber": settingsHostView?.window?.windowNumber as Any? ?? NSNull(),
            "settingsWindowTitle": settingsHostView?.window?.title as Any? ?? NSNull(),
            "settingsContentFrame": settingsHostView.map { rectData($0.bounds) } as Any? ?? NSNull(),
            "settingsIsSeparateWindow": false,
            "inspectorPage": model.inspectorShowingSettings ? "settings" : "controls",
            "popoverPage": model.popoverShowingSettings ? "settings" : "controls",
            "inspectorSettingsHighlighted": model.inspectorShowingSettings,
            "popoverSettingsHighlighted": model.popoverShowingSettings,
            "applicationActive": NSApp.isActive,
            "popoverIsKeyWindow": popover.contentViewController?.view.window?.isKeyWindow ?? false,
            "popoverDismissCount": popoverDismissCount,
            "popoverDismissalPolicy": "focus_or_outside_click",
            "lastPopoverDismissReason": lastPopoverDismissReason as Any? ?? NSNull(),
            "contextMenuTitles": contextMenu.items.map(\.title),
            "updateMenuEnabled": updateMenuItem?.isEnabled ?? false,
            "isUpdating": model.isUpdating,
            "updateMessage": model.updateMessage as Any? ?? NSNull(),
            "statusWindowNumber": statusItem.button?.window?.windowNumber as Any? ?? NSNull(),
            "inspectorWindowNumber": inspector?.windowNumber as Any? ?? NSNull(),
            "inspectorVisible": inspector?.isVisible ?? false,
            "inspectorFrame": inspector.map { rectData($0.frame) } as Any? ?? NSNull(),
            "popoverShown": popover.isShown,
            "popoverWindowNumber": popover.contentViewController?.view.window?.windowNumber as Any? ?? NSNull(),
            "popoverAnchorFrame": anchor.map(rectData) as Any? ?? NSNull(),
            "popoverFrame": (popover.isShown ? popover.contentViewController?.view.window?.frame : nil).map(rectData) as Any? ?? NSNull(),
            "popoverPreferredEdge": "minY",
            "previewLive": model.previewIsLive(),
            "previewStatus": model.previewStatus(),
            "previewError": model.previewError as Any? ?? NSNull()
        ]
    }

    /// Renders only this process's own views. This never captures another application's window.
    func renderEvidence(to directory: URL) throws -> [String: String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createInspectorIfNeeded()
        var paths: [String: String] = [:]
        func render(_ view: NSView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard view.bounds.width > 0, view.bounds.height > 0,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw NSError(domain: "DeskLoom.Interface", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "无法创建 \(name) 的界面位图"])
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "DeskLoom.Interface", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "无法编码 \(name) 的 PNG"])
            }
            let url = directory.appendingPathComponent("\(name).png")
            try data.write(to: url, options: .atomic)
            paths[name] = url.path
        }
        if let view = inspector?.contentView { try render(view, name: "inspector") }
        if let view = settingsHostView { try render(view, name: "settings") }
        if let view = statusItem.button { try render(view, name: "status-item") }
        if let view = overlay.contentView { try render(view, name: "overlay") }
        if popover.isShown, let view = popover.contentViewController?.view {
            try render(view, name: "popover")
        }
        paths.merge(try permissionGuide.renderEvidence(to: directory)) { _, new in new }
        return paths
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { toggleStatusPopover(); return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            dismissPopover(reason: "context_menu")
            updateMenuItem?.isEnabled = !model.isUpdating && !model.isActive && !model.llmRunning && model.onUpdate != nil
            NSMenu.popUpContextMenu(contextMenu, with: event, for: sender)
        } else {
            toggleStatusPopover()
        }
    }

    @objc private func contextMenuSelected(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        performMenuAction(action)
    }

    private func refreshChrome() {
        let attributed = NSAttributedString(string: "\(model.controlledWindowCount)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ])
        statusItem.button?.attributedTitle = attributed
        statusItem.button?.toolTip = "DeskLoom · 正在控制 \(model.controlledWindowCount) 个窗口\n\(model.appName) · \(model.phase)\n\(model.detail)"
        statusItem.button?.setAccessibilityValue("正在控制 \(model.controlledWindowCount) 个窗口，\(model.appName)，\(model.phase)")
        updateMenuItem?.isEnabled = !model.isUpdating && !model.isActive && !model.llmRunning && model.onUpdate != nil
        refreshStatusIcon()
        refreshOverlay()
    }

    private func refreshStatusIcon() {
        guard statusIconVariant != model.selectedIcon || statusItem.button?.image == nil else { return }
        let icon = applicationIcon(model.selectedIcon)?.copy() as? NSImage
        icon?.size = NSSize(width: 20, height: 20)
        icon?.isTemplate = false
        icon?.accessibilityDescription = "DeskLoom 图标 \(model.selectedIcon)"
        statusItem.button?.image = icon
        statusIconVariant = model.selectedIcon
    }

    private func refreshOverlay() {
        func hide(_ reason: String) {
            overlayVisibilityReason = reason
            overlay.orderOut(nil)
        }
        guard model.isActive else { hide("inactive"); return }
        guard let targetFrame,
              targetFrame.width > 0, targetFrame.height > 0,
              let primaryScreen = NSScreen.screens.first else {
            hide("target_unavailable")
            return
        }
        // CGWindowList is front-to-back and only includes the current Space.
        // Window bounds and owner PID remain available without screen capture.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else {
            hide("window_list_unavailable")
            return
        }
        func bounds(of window: [String: Any]) -> CGRect? {
            guard let value = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(dictionaryRepresentation: value as CFDictionary)
        }
        func matches(_ window: [String: Any]) -> Bool {
            guard let number = window[kCGWindowNumber as String] as? NSNumber,
                  let owner = window[kCGWindowOwnerPID as String] as? NSNumber else { return false }
            if let targetProcessID, owner.int32Value != targetProcessID { return false }
            if let targetWindowID { return number.uint32Value == targetWindowID }
            guard targetProcessID != nil, let frame = bounds(of: window) else { return false }
            return abs(frame.minX - targetFrame.minX) < 3 && abs(frame.minY - targetFrame.minY) < 3 &&
                abs(frame.width - targetFrame.width) < 3 && abs(frame.height - targetFrame.height) < 3
        }
        let candidates = windows.indices.filter { matches(windows[$0]) }
        guard candidates.count == 1, let targetIndex = candidates.first,
              let number = windows[targetIndex][kCGWindowNumber as String] as? NSNumber,
              ((windows[targetIndex][kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
              let visibleFrame = bounds(of: windows[targetIndex]),
              visibleFrame.width >= 180, visibleFrame.height >= 42 else {
            hide("target_not_visible")
            return
        }
        overlayView.label = "控制中"
        let preferredSize = overlayView.intrinsicContentSize
        let size = NSSize(width: min(preferredSize.width, visibleFrame.width), height: preferredSize.height)
        let overlayBounds = CGRect(x: visibleFrame.maxX - size.width + 3, y: visibleFrame.minY - 3,
                                   width: size.width, height: size.height)
        // Check the filled label, not the transparent margin or the outer 3px
        // corner. A top-aligned target's menu bar covers that corner
        // without covering the label. Window ordering clips the corner itself.
        let labelBounds = CGRect(x: overlayBounds.minX + 9, y: visibleFrame.minY + 6,
                                 width: size.width - 24, height: 24)
        let covered = windows[..<targetIndex].contains { window in
            guard let windowNumber = window[kCGWindowNumber as String] as? NSNumber,
                  windowNumber.intValue != overlay.windowNumber,
                  // Higher layers include full-screen transparent system views.
                  // Our normal-level panel stays below their actual pixels.
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let frame = bounds(of: window) else { return false }
            return frame.intersects(labelBounds)
        }
        guard !covered else { hide("target_covered"); return }
        overlay.setFrame(NSRect(x: overlayBounds.minX,
                                y: primaryScreen.frame.maxY - overlayBounds.maxY,
                                width: size.width,
                                height: size.height), display: true)
        overlay.order(.above, relativeTo: number.intValue)
        overlayVisibilityReason = "visible"
    }
}

@MainActor
private final class TargetOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class TargetOverlayView: NSView {
    var label: String = "控制中" {
        didSet {
            guard label != oldValue else { return }
            needsDisplay = true
            invalidateIntrinsicContentSize()
            setAccessibilityLabel(label)
        }
    }
    override var isOpaque: Bool { false }
    private let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(96, (label as NSString).size(withAttributes: [.font: font]).width + 63), height: 42)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let purple = InterfaceStyle.nativePurple
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

        // Attach the label to the upper-right title bar, leaving the window
        // buttons and the document's first line clear.
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
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
    }
}

@MainActor
private struct SurfaceView: View {
    @ObservedObject var model: AppModel
    let compact: Bool
    let openWindow: () -> Void
    let toggleSettings: () -> Void

    private var showingSettings: Bool {
        compact ? model.popoverShowingSettings : model.inspectorShowingSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            // The top row is a single persistent view. Only the content below
            // it changes, so the gear remains in exactly the same position.
            header
            if showingSettings {
                SettingsView(model: model, compact: compact)
            } else {
                ControlView(model: model, compact: compact, openWindow: openWindow)
            }
        }
        .padding(compact ? 18 : 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(InterfaceStyle.purple)
    }

    private var header: some View {
        HStack(spacing: 9) {
            if let icon = applicationIcon(model.selectedIcon) {
                Image(nsImage: icon)
                    .resizable().scaledToFit()
                    .frame(width: compact ? 32 : 42, height: compact ? 32 : 42)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("DeskLoom").font(.system(size: compact ? 16 : 21, weight: .semibold))
                if !compact { Text("可编程的本地桌面").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer()
            Button(action: toggleSettings) {
                Image(systemName: showingSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(showingSettings ? InterfaceStyle.purple : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(showingSettings ? InterfaceStyle.purple.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showingSettings ? "关闭设置" : "打开 DeskLoom 设置")
            .accessibilityLabel("设置")
            .accessibilityValue(showingSettings ? "已打开" : "已关闭")
            .keyboardShortcut(",", modifiers: [.command])
        }
        .frame(height: compact ? 32 : 44)
    }

}

@MainActor
private struct ControlView: View {
    @ObservedObject var model: AppModel
    let compact: Bool
    let openWindow: () -> Void

    private var needsPermissions: Bool {
        !model.accessibilityGranted || !model.screenRecordingGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            // Keep controls reachable at the minimum window/popover size;
            // permission instructions and long system messages scroll together.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                    if model.isUpdating || model.updateMessage != nil { updateStatus }
                    LLMTaskView(model: model, compact: compact)
                    if needsPermissions { permissions }
                    target
                    PreviewView(model: model, compact: compact)
                    status
                    if !needsPermissions { permissions }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 2)
                .padding(.bottom, 2)
            }
            controls
            if compact {
                Divider()
                HStack {
                    Button(action: openWindow) {
                        Label("打开工作台", systemImage: "macwindow")
                    }
                    Spacer()
                    quitButton
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                    Text("用自然语言操作选定窗口")
                    Spacer()
                    quitButton
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var quitButton: some View {
        Button { model.onLLMStop?(); model.onStop?(); NSApp.terminate(nil) } label: {
            Label("退出 DeskLoom", systemImage: "power")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .keyboardShortcut("q", modifiers: [.command])
    }

    private var updateStatus: some View {
        HStack(alignment: .top, spacing: 8) {
            if model.isUpdating {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.down.circle").foregroundStyle(InterfaceStyle.purple)
            }
            Text(model.updateMessage ?? "正在更新应用…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(InterfaceStyle.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var target: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 19))
                .foregroundStyle(InterfaceStyle.purple)
                .frame(width: 38, height: 38)
                .background(InterfaceStyle.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(model.appName).font(.system(size: 14, weight: .semibold))
                Text(model.windowTitle.isEmpty ? "尚未选择窗口" : model.windowTitle)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(model.isActive ? InterfaceStyle.purple : Color.secondary.opacity(0.6)).frame(width: 6, height: 6)
                Text(model.isActive ? "\(model.controlledWindowCount) 个窗口" : "空闲")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(model.isActive ? InterfaceStyle.purple : Color.secondary)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(model.phase).font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.nodeCount > 0 {
                    Text("\(model.nodeCount) 个 AX 元素").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Text(model.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 2 : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(model.detail)
        }
        .frame(minHeight: compact ? 43 : 48, alignment: .top)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if model.isActive || model.llmRunning {
                Button { model.onLLMStop?(); model.onStop?() } label: {
                    Label("停止全部操作", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button { model.onLLMRefreshWindows?() } label: {
                    Label("刷新应用窗口", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.llmRunning || model.isUpdating)
            }
            Button { model.onRefresh?() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 23)
            }
            .buttonStyle(.bordered)
            .disabled(model.llmRunning || model.isUpdating)
            .help("刷新无障碍结构和窗口预览")
            .accessibilityLabel("刷新结构和预览")
        }
        .controlSize(.large)
    }

    private var permissions: some View {
        Group {
            if needsPermissions {
                permissionSetup
            } else {
                HStack(spacing: 12) {
                    permission(model.accessibilityPermissionName, granted: model.accessibilityGranted, action: model.onRequestAccessibility)
                    permission("屏幕录制", granted: model.screenRecordingGranted, action: model.onRequestScreenRecording)
                    Spacer(minLength: 0)
                    Button { model.onRecheckPermissions?() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("重新检查系统权限")
                    .accessibilityLabel("重新检查系统权限")
                }
            }
        }
    }

    private var permissionSetup: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 11) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Color.orange)
                Text("需要允许系统权限")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 6)
                Button("重新检查") { model.onRecheckPermissions?() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(InterfaceStyle.purple)
            }
            permissionRow(model.accessibilityPermissionName,
                          purpose: "读取控件并执行操作", granted: model.accessibilityGranted,
                          action: model.onRequestAccessibility)
            permissionRow("屏幕录制", purpose: "显示目标窗口实时小图",
                          granted: model.screenRecordingGranted,
                          action: model.onRequestScreenRecording)
            Divider()
            applicationDragSource
            HStack(alignment: .top, spacing: 8) {
                Button { model.onRevealApplication?() } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
            Text("允许后返回本窗口，会自动检查。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.permissionSettingsMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(compact ? 11 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.2), lineWidth: 1))
    }

    private func permissionRow(_ title: String, purpose: String, granted: Bool,
                               action: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    Text(purpose).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(granted ? "已允许" : "未允许")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(granted ? Color.green : Color.orange)
                .fixedSize()
            Button("打开设置") { action?() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help("打开 macOS 的\(title)权限设置")
                .accessibilityLabel("打开\(title)权限设置")
        }
    }

    private var applicationDragSource: some View {
        let applicationURL = Bundle.main.bundleURL
        return HStack(spacing: 10) {
            Image(nsImage: applicationIcon(model.selectedIcon) ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: compact ? 34 : 42, height: compact ? 34 : 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("列表里没有此应用？")
                    .font(.system(size: 11, weight: .medium))
                Text("拖动此图标到系统设置的权限列表")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .overlay(ApplicationFileDragSource(applicationURL: applicationURL, iconVariant: model.selectedIcon))
        .help(applicationURL.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("拖动 \(applicationURL.lastPathComponent) 到系统权限列表")
        .accessibilityHint("也可以使用下方的在 Finder 中显示按钮找到此应用。")
    }

    private func permission(_ title: String, granted: Bool, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Label(granted ? "\(title)已授权" : "授权\(title)", systemImage: granted ? "checkmark.circle.fill" : "lock.circle")
                .font(.system(size: 10))
                .foregroundStyle(granted ? Color.secondary : InterfaceStyle.purple)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .help(granted ? "打开\(title)设置" : "需要在 macOS 系统设置中允许\(title)")
    }
}

@MainActor
private struct LLMTaskView: View {
    @ObservedObject var model: AppModel
    let compact: Bool

    private var canRun: Bool {
        model.llmAvailable && model.llmAuthenticated && model.accessibilityGranted &&
        !model.isActive && !model.isUpdating && !model.llmPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.llmSelectedWindowIDs.isEmpty && model.llmSelectedWindowIDs.count <= 8 &&
        model.llmSelectedWindowIDs.isSubset(of: Set(model.llmWindows.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").foregroundStyle(InterfaceStyle.purple)
                Text("交给 LLM 操作").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                if model.llmRunning { ProgressView().controlSize(.small) }
            }
            account
            Divider()
            windowPicker
            VStack(alignment: .leading, spacing: 6) {
                Text("操作任务").font(.system(size: 11, weight: .medium))
                ZStack(alignment: .topLeading) {
                    if model.llmPrompt.isEmpty {
                        Text("例如：读取资料窗口，将三条摘要填写到另一个选定窗口")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 6).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $model.llmPrompt)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(3)
                        .accessibilityLabel("LLM 操作任务")
                }
                .frame(height: compact ? 76 : 96)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.2)))
                .disabled(model.llmRunning)
            }
            HStack(spacing: 8) {
                Text("模型").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("留空使用默认模型", text: $model.llmModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .accessibilityLabel("模型，可留空")
                    .disabled(model.llmRunning)
            }
            if model.llmRunning {
                Button { model.onLLMStop?() } label: {
                    Label("停止任务并释放所有窗口", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button { model.onLLMRun?() } label: {
                    Label("执行任务 · \(model.llmSelectedWindowIDs.count) 个窗口", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
            }
            if !model.llmOutput.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.llmRunning ? "执行进度" : "最近结果")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(model.llmOutput)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: compact ? 110 : 180)
                }
                .padding(9)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(compact ? 11 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InterfaceStyle.purple.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(InterfaceStyle.purple.opacity(0.16)))
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: model.llmAuthenticated ? "checkmark.circle.fill" : "person.crop.circle")
                    .foregroundStyle(model.llmAuthenticated ? Color.green : Color.secondary)
                Text(model.llmAuthenticated ? "已连接 ChatGPT 订阅" : "ChatGPT 订阅登录")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 3)
                Button { model.onLLMRefresh?() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(model.llmRunning)
                .help("重新检查本地登录状态")
                .accessibilityLabel("重新检查 ChatGPT 登录状态")
            }
            Text(model.llmStatus)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !model.llmAuthenticated {
                Button("登录 ChatGPT") { model.onLLMLogin?() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.llmAvailable || model.llmRunning)
            }
        }
    }

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("协作窗口").font(.system(size: 11, weight: .medium))
                Text("已选 \(model.llmSelectedWindowIDs.count)/8")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { model.onLLMRefreshWindows?() } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(InterfaceStyle.purple)
                .disabled(model.llmRunning)
                .accessibilityLabel("刷新可操作窗口")
            }
            if model.llmWindows.isEmpty {
                Text("点击刷新，然后勾选允许 LLM 操作的窗口。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(model.llmWindows) { window in
                            Toggle(isOn: Binding(
                                get: { model.llmSelectedWindowIDs.contains(window.id) },
                                set: { selected in
                                    if selected && model.llmSelectedWindowIDs.count < 8 {
                                        model.llmSelectedWindowIDs.insert(window.id)
                                    } else if !selected { model.llmSelectedWindowIDs.remove(window.id) }
                                })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(window.title.isEmpty ? "未命名窗口" : window.title)
                                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        Text(window.appName).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .toggleStyle(.checkbox)
                                .help("\(window.appName) · \(window.title)")
                                .disabled(model.llmRunning || (!model.llmSelectedWindowIDs.contains(window.id) && model.llmSelectedWindowIDs.count >= 8))
                        }
                    }.padding(8)
                }
                .frame(height: min(CGFloat(model.llmWindows.count) * 42 + 9, compact ? 126 : 168))
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            }
            Text(model.llmRunning ? "当前控制 \(model.controlledWindowCount) 个窗口，任务结束后统一释放。"
                                  : "LLM 可在选定窗口之间读取、整理和填写内容。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
private struct SettingsView: View {
    @ObservedObject var model: AppModel
    let compact: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: compact ? 22 : 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("外观").font(.system(size: compact ? 17 : 19, weight: .semibold))
                    Text("选择你的 DeskLoom 图标")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("应用图标").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("自动保存").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: compact ? 10 : 14) {
                        iconOption("C", title: "可编程桌面", detail: "默认图标")
                        iconOption("D", title: "窗口层叠", detail: "多窗口协作")
                    }
                    Text("菜单栏和窗口立即生效。应用程序图标在更新后同步。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 2)
            .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func iconOption(_ variant: String, title: String, detail: String) -> some View {
        let selected = model.selectedIcon == variant
        return Button { model.onSelectIcon?(variant) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if let icon = applicationIcon(variant) {
                        Image(nsImage: icon).resizable().scaledToFit()
                            .frame(width: compact ? 48 : 60, height: compact ? 48 : 60)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(selected ? InterfaceStyle.purple : Color.secondary.opacity(0.4))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(variant) · \(title)").font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(compact ? 12 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? InterfaceStyle.purple.opacity(0.07) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? InterfaceStyle.purple.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("图标 \(variant)，\(title)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .disabled(model.isUpdating)
    }
}

/// AppKit writes the existing bundle URL straight to the dragging pasteboard.
/// SwiftUI's item-provider drag path may stage an .app in its Drag-* cache;
/// this bridge has no item provider, file promise, or bundle-copy operation.
@MainActor
struct ApplicationFileDragSource: NSViewRepresentable {
    let applicationURL: URL
    let iconVariant: String
    var onDragStateChanged: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> ApplicationFileDragView {
        let view = ApplicationFileDragView(frame: .zero)
        view.applicationURL = applicationURL
        view.iconVariant = iconVariant
        view.onDragStateChanged = onDragStateChanged
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ApplicationFileDragView, context: Context) {
        view.applicationURL = applicationURL
        view.iconVariant = iconVariant
        view.onDragStateChanged = onDragStateChanged
    }
}

@MainActor
final class ApplicationFileDragView: NSView, NSDraggingSource {
    var iconVariant = "C"
    var onDragStateChanged: ((Bool) -> Void)?
    var applicationURL: URL = Bundle.main.bundleURL {
        didSet { toolTip = applicationURL.path }
    }
    private var initialMouseLocation: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        initialMouseLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let initial = initialMouseLocation, applicationURL.isFileURL else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - initial.x
        let dy = current.y - initial.y
        guard dx * dx + dy * dy >= 16 else { return }
        initialMouseLocation = nil

        // NSURL is an NSPasteboardWriting file URL (public.file-url), not a
        // promised file. The destination receives the running app's real path.
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        let icon = applicationIcon(iconVariant) ?? NSImage()
        item.setDraggingFrame(NSRect(x: current.x - 24, y: current.y - 24,
                                     width: 48, height: 48), contents: icon)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    override func mouseUp(with event: NSEvent) {
        initialMouseLocation = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragStateChanged?(true)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        onDragStateChanged?(false)
    }
}

@MainActor
private struct PreviewView: View {
    @ObservedObject var model: AppModel
    let compact: Bool

    private var needsPermissions: Bool {
        !model.accessibilityGranted || !model.screenRecordingGranted
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            preview(at: context.date)
        }
    }

    private func preview(at date: Date) -> some View {
        let isLive = model.previewIsLive(at: date)
        let previewStatus = model.previewStatus(at: date)
        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.inset.filled")
                Text("窗口预览")
                Text(previewStatus)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isLive ? InterfaceStyle.purple : Color.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(isLive ? InterfaceStyle.purple.opacity(0.1) : Color.secondary.opacity(0.08), in: Capsule())
                Spacer()
                if let capturedAt = model.lastCapture {
                    Text(capturedAt, style: .time).monospacedDigit()
                } else { Text("等待画面") }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            ZStack {
                Color.black.opacity(0.035)
                if let image = model.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(5)
                        .opacity(isLive ? 1 : 0.65)
                        .accessibilityLabel("\(model.appName)窗口截图，\(previewStatus)")
                    if !isLive {
                        VStack {
                            Spacer()
                            HStack {
                                Image(systemName: "pause.circle.fill")
                                Text(model.previewError ?? "\(previewStatus) · 显示最后一帧")
                                    .lineLimit(2)
                            }
                            .font(.system(size: 10, weight: .medium))
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                            .padding(9)
                        }
                    }
                } else {
                    VStack(spacing: compact && needsPermissions ? 6 : 8) {
                        Image(systemName: model.screenRecordingGranted ? "macwindow" : "rectangle.slash")
                            .font(.system(size: compact && needsPermissions ? 20 : 25, weight: .light))
                        Text(model.previewError ?? (model.screenRecordingGranted ? "连接应用后显示窗口画面" : "允许屏幕录制后显示实时小图"))
                            .font(.system(size: 11))
                        if !compact || !needsPermissions {
                            Text("仅预览当前操作窗口")
                                .font(.system(size: 10)).opacity(0.7)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(compact && needsPermissions ? 10 : 16)
                }
            }
            .frame(height: needsPermissions ? (compact ? 92 : 122) : (compact ? 160 : 248))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
