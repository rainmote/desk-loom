import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel!
    var interface: InterfaceController!
    var services: DesktopServices!
    var computer: ComputerCoordinator!
    var server: RPCServer!
    var endpoint: URL!
    var icons: IconController!
    var updater: UpdateController!
    var llm: LLMController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let directory = try AppStorage.prepare()
            endpoint = directory.appendingPathComponent("endpoint.json")
            model = AppModel()
            icons = IconController(model: model, dataDirectory: directory)
            interface = InterfaceController(model: model)
            services = DesktopServices(model: model, interface: interface, dataDirectory: directory)
            computer = ComputerCoordinator(model: model, interface: interface)
            updater = UpdateController(model: model, dataDirectory: directory)
            llm = LLMController(model: model, computer: computer, dataDirectory: directory)
            model.onSelectIcon = { [weak self] name in
                do { _ = try self?.icons.select(name) }
                catch { self?.model.detail = "图标切换失败：\(error.localizedDescription)" }
            }
            model.onUpdate = { [weak self] in self?.updater.start() }
            model.onStop = { [weak self] in self?.stopControl() }
            model.onRefresh = { [weak self] in Task { @MainActor in
                do {
                    guard let self else { return }
                    guard let session = self.computer.currentSessionID else { return }
                    _ = try self.computer.observe(["session_id": session])
                    _ = try await self.computer.screenshot(["session_id": session, "max_width": 720])
                }
                catch let failure as DesktopFailure { self?.model.detail = failure.message }
                catch { self?.model.detail = error.localizedDescription }
            } }
            model.onRequestAccessibility = { [weak self] in self?.services.requestAccessibility() }
            model.onRequestScreenRecording = { [weak self] in self?.services.requestScreenRecording() }
            model.onRevealApplication = { [weak self] in _ = self?.services.revealApplication() }
            model.onRecheckPermissions = { [weak self] in self?.services.recheckPermissions() }
            let token = UUID().uuidString + UUID().uuidString
            server = try RPCServer(token: token) { [weak self] method, params in
                guard let self else { throw DesktopFailure(code: "unavailable", message: "App stopped") }
                if method == "status" { self.services.permissions(); return self.computer.capabilities() }
                if method == "stop" { self.llm.stop(); return self.computer.detach() }
                if method == "show" { self.interface.showWindow(); return self.computer.capabilities() }
                if method == "llm_status" {
                    return ["available": self.model.llmAvailable, "authenticated": self.model.llmAuthenticated,
                            "running": self.model.llmRunning, "message": self.model.llmStatus,
                            "output": self.model.llmOutput]
                }
                if method == "icon_settings" {
                    if let name = params["selected_icon"] as? String { return try self.icons.select(name) }
                    return self.icons.diagnostics()
                }
                if method.hasPrefix("computer_") {
                    let result = try await self.computer.handle(method: method, params: params)
                    if method == "computer_detach", params["session_id"] == nil {
                        self.llm.stop()
                    }
                    return result
                }
                return try await self.services.handle(method: method, params: params)
            }
            let endpointURL = endpoint!
            server.start { port in
                let value: [String: Any] = ["port": port, "token": token, "pid": ProcessInfo.processInfo.processIdentifier, "protocol_version": 1]
                do {
                    try JSONSerialization.data(withJSONObject: value).write(to: endpointURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpointURL.path)
                } catch { NSLog("Endpoint creation failed: %@", error.localizedDescription) }
            }
            services.permissions()
            llm.refreshStatus()
            if !ProcessInfo.processInfo.arguments.contains("--background") {
                interface.showWindow()
            }
        } catch {
            if ProcessInfo.processInfo.arguments.contains("--background") {
                NSLog("Background launch failed: %@", error.localizedDescription)
            } else {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        services?.permissions()
        interface?.showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        services?.permissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        llm?.shutdown()
        stopControl()
        server?.stop()
        // A retiring copy must not delete the endpoint written by its replacement.
        if let endpoint,
           let data = try? Data(contentsOf: endpoint),
           let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           info["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) {
            try? FileManager.default.removeItem(at: endpoint)
        }
    }

    private func stopControl() {
        llm?.stop()
        _ = computer?.detach()
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
