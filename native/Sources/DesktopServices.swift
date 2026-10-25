import AppKit
import ApplicationServices

struct DesktopFailure: Error {
    let code: String
    let message: String
    let details: [String: Any]?

    init(code: String, message: String, details: [String: Any]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

/// Application services contain no target application or window-control policy.
/// Window sessions and all desktop actions belong to ComputerCoordinator.
@MainActor
final class DesktopServices {
    private let model: AppModel
    private let interface: InterfaceController
    private let dataDirectory: URL
    private var permissionTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var activationSequence = 0
    private var lastFocusWindow: AXUIElement?
    private var focusWindowSequence = 0

    init(model: AppModel, interface: InterfaceController, dataDirectory: URL) {
        self.model = model
        self.interface = interface
        self.dataDirectory = dataDirectory
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activationSequence += 1 }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.permissions() }
        }
    }

    deinit {
        permissionTimer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func permissions() {
        let accessibility = AXIsProcessTrusted()
        let screenRecording = CGPreflightScreenCaptureAccess()
        if model.accessibilityGranted != accessibility { model.accessibilityGranted = accessibility }
        if model.screenRecordingGranted != screenRecording { model.screenRecordingGranted = screenRecording }
    }

    func requestAccessibility() {
        _ = try? openPermissionSettings("accessibility", sourceFrameInScreen: permissionClickFrame())
    }

    func requestScreenRecording() {
        _ = try? openPermissionSettings("screen_recording", sourceFrameInScreen: permissionClickFrame())
    }

    private func permissionClickFrame() -> CGRect {
        let point = NSEvent.mouseLocation
        return CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
    }

    @discardableResult
    func revealApplication() -> [String: Any] {
        let applicationURL = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
        return ["application_path": applicationURL.path, "finder_reveal_requested": true]
    }

    /// Opens the user-facing settings only. The user grants access in macOS.
    func openPermissionSettings(_ permission: String, sourceFrameInScreen: CGRect? = nil) throws -> [String: Any] {
        let anchor: String
        let title: String
        switch permission {
        case "accessibility": anchor = "Privacy_Accessibility"; title = model.accessibilityPermissionName
        case "screen_recording": anchor = "Privacy_ScreenCapture"; title = model.screenRecordingPermissionName
        default: throw DesktopFailure(code: "invalid-permission", message: "仅支持无障碍或屏幕录制设置。")
        }
        permissions()
        let destination = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        let candidates = [destination, "x-apple.systempreferences:com.apple.preference.security"]
        for address in candidates {
            if let url = URL(string: address), NSWorkspace.shared.open(url) {
                interface.showPermissionGuide(permission: permission, title: title,
                                              sourceFrameInScreen: sourceFrameInScreen)
                model.permissionSettingsMessage = "将系统设置下方引导卡中的 DeskLoom 拖入「\(title)」列表，再打开开关。已开启但仍未生效时，请先重新检查。"
                return ["permission": permission, "settings_open_requested": true,
                        "settings_url": address, "application_path": Bundle.main.bundleURL.path,
                        "permission_guide_requested": true, "finder_reveal_requested": false]
            }
        }
        model.permissionSettingsMessage = "未能打开系统设置。请进入「系统设置 → 隐私与安全性 → \(title)」，将下方应用图标拖入列表，或点「＋」添加。"
        throw DesktopFailure(code: "settings-open-failed", message: model.permissionSettingsMessage!)
    }

    func recheckPermissions() {
        permissions()
        model.permissionSettingsMessage = model.accessibilityGranted && model.screenRecordingGranted
            ? "两项权限已就绪，可以选择应用窗口。"
            : "已重新检查。若系统开关已开但仍未生效，请从权限列表移除旧条目，再用 Finder 中这份应用重新添加并开启；重新编译的旧临时签名可能留下失效条目。"
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    /// Read-only focus evidence, without exposing another document's title or content.
    func focusState() -> [String: Any] {
        let frontmost = NSWorkspace.shared.frontmostApplication
        var result: [String: Any] = [
            "frontmost_pid": frontmost.map { Int($0.processIdentifier) } as Any? ?? NSNull(),
            "frontmost_bundle_id": frontmost?.bundleIdentifier as Any? ?? NSNull(),
            "activation_sequence": activationSequence,
            "focused_window_known": false
        ]
        if AXIsProcessTrusted(), let frontmost {
            let root = AXUIElementCreateApplication(frontmost.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.2)
            if let value = attribute(root, kAXFocusedWindowAttribute),
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                let focused = value as! AXUIElement
                if lastFocusWindow.map({ !CFEqual($0, focused) }) ?? true {
                    focusWindowSequence += 1
                    lastFocusWindow = focused
                }
                result["focused_window_token"] = focusWindowSequence
                result["focused_window_known"] = true
            }
        }
        return result
    }

    func handle(method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "focus_state": return focusState()
        case "permission_settings": return try openPermissionSettings(params["permission"] as? String ?? "")
        case "reveal_application": return revealApplication()
        case "ui_state": return interface.diagnostics()
        case "close_permission_guide": interface.dismissPermissionGuide(); return interface.diagnostics()
        case "show_menu": interface.showPopover(); return interface.diagnostics()
        case "show_settings": interface.showSettings(); return interface.diagnostics()
        case "toggle_settings": interface.toggleSettings(); return interface.diagnostics()
        case "close_settings": interface.closeSettings(); return interface.diagnostics()
        case "toggle_popover": interface.toggleStatusPopover(); return interface.diagnostics()
        case "menu_action":
            guard let action = params["action"] as? String,
                  ["show_window", "update", "quit"].contains(action) else {
                throw DesktopFailure(code: "invalid-menu-action", message: "不支持此菜单操作。")
            }
            // Give the authenticated caller its response before quit/restart.
            if action == "quit" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    _ = self?.interface.performMenuAction(action)
                }
                return ["quit_requested": true]
            }
            let accepted = interface.performMenuAction(action)
            return ["accepted": accepted, "ui": interface.diagnostics()]
        case "render_ui": return try interface.renderEvidence(to: dataDirectory.appendingPathComponent("ui-evidence"))
        default: throw DesktopFailure(code: "unknown-method", message: "未知方法：\(method)")
        }
    }
}
