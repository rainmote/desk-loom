// Compile with DesktopServices.swift. No application windows or settings open.
import AppKit

@MainActor
final class AppModel {
    var accessibilityGranted = false
    var screenRecordingGranted = false
    var permissionSettingsMessage: String?
    let accessibilityPermissionName = "Accessibility"
    let screenRecordingPermissionName = "Screen Recording"
}

@MainActor
final class InterfaceController {
    var calls: [String] = []
    func showPermissionGuide(permission: String, title: String, sourceFrameInScreen: CGRect?) { calls.append("permission") }
    func diagnostics() -> [String: Any] { ["diagnostics": true] }
    func dismissPermissionGuide() { calls.append("close_permission_guide") }
    func showPopover() { calls.append("show_menu") }
    func showSettings() { calls.append("show_settings") }
    func toggleSettings() { calls.append("toggle_settings") }
    func closeSettings() { calls.append("close_settings") }
    func toggleStatusPopover() { calls.append("toggle_popover") }
    func performMenuAction(_ action: String) -> Bool { calls.append(action); return true }
    func renderEvidence(to directory: URL) throws -> [String: Any] { calls.append("render_ui"); return ["rendered": true] }
}

@main
struct NativeServicesUnitTests {
    @MainActor
    static func main() async throws {
        let interface = InterfaceController()
        let services = DesktopServices(model: AppModel(), interface: interface,
            dataDirectory: URL(fileURLWithPath: "/tmp/deskloom-native-services-test-unused"))
        let removed = ["start", "observe", "set_value", "move_window", "verify", "report_verification_error", "preview"]
        for method in removed {
            do {
                _ = try await services.handle(method: method, params: ["value": "NEVER DISPATCHED", "request_id": "forged"])
                preconditionFailure("Removed method accepted: \(method)")
            } catch let error as DesktopFailure { precondition(error.code == "unknown-method") }
        }
        precondition(interface.calls.isEmpty)
        do {
            _ = try await services.handle(method: "permission_settings", params: ["permission": "invalid"])
            preconditionFailure("Unsupported permission accepted")
        } catch let error as DesktopFailure { precondition(error.code == "invalid-permission") }
        do {
            _ = try await services.handle(method: "menu_action", params: ["action": "start"])
            preconditionFailure("Removed menu action accepted")
        } catch let error as DesktopFailure { precondition(error.code == "invalid-menu-action") }
        precondition(interface.calls.isEmpty)
        let diagnostics = try await services.handle(method: "ui_state", params: [:])
        precondition(diagnostics["diagnostics"] as? Bool == true)
        for method in ["close_permission_guide", "show_menu", "show_settings", "toggle_settings", "close_settings", "toggle_popover"] {
            _ = try await services.handle(method: method, params: [:])
            precondition(interface.calls.last == method)
        }
        let menu = try await services.handle(method: "menu_action", params: ["action": "show_window"])
        precondition(menu["accepted"] as? Bool == true && interface.calls.last == "show_window")
        print("NativeServicesUnitTests: passed; 7 removed RPC methods rejected; no desktop UI opened")
    }
}
