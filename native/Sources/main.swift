import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel!
    var interface: InterfaceController!
    var engine: DesktopEngine!
    var server: RPCServer!
    var endpoint: URL!
    var icons: IconController!
    var updater: UpdateController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let directory = try AppStorage.prepare()
            endpoint = directory.appendingPathComponent("endpoint.json")
            model = AppModel()
            icons = IconController(model: model, dataDirectory: directory)
            interface = InterfaceController(model: model)
            engine = DesktopEngine(model: model, interface: interface, dataDirectory: directory)
            updater = UpdateController(model: model, dataDirectory: directory)
            model.onSelectIcon = { [weak self] name in
                do { _ = try self?.icons.select(name) }
                catch { self?.model.detail = "图标切换失败：\(error.localizedDescription)" }
            }
            model.onUpdate = { [weak self] in self?.updater.start() }
            model.onStart = { [weak self] in Task { @MainActor in
                do { _ = try await self?.engine.start() }
                catch let failure as DesktopFailure { self?.model.detail = failure.message }
                catch { self?.model.detail = error.localizedDescription }
            } }
            model.onStop = { [weak self] in _ = self?.engine.stop() }
            model.onRefresh = { [weak self] in Task { @MainActor in
                do { _ = try self?.engine.observe(); await self?.engine.capturePreview() }
                catch let failure as DesktopFailure { self?.model.detail = failure.message }
                catch { self?.model.detail = error.localizedDescription }
            } }
            model.onRequestAccessibility = { [weak self] in self?.engine.requestAccessibility() }
            model.onRequestScreenRecording = { [weak self] in self?.engine.requestScreenRecording() }
            model.onRevealApplication = { [weak self] in _ = self?.engine.revealApplication() }
            model.onRecheckPermissions = { [weak self] in self?.engine.recheckPermissions() }
            let token = UUID().uuidString + UUID().uuidString
            server = try RPCServer(token: token) { [weak self] method, params in
                guard let self else { throw DesktopFailure(code: "unavailable", message: "App stopped") }
                if method == "icon_settings" {
                    if let name = params["selected_icon"] as? String { return try self.icons.select(name) }
                    return self.icons.diagnostics()
                }
                return try await self.engine.handle(method: method, params: params)
            }
            let endpointURL = endpoint!
            server.start { port in
                let value: [String: Any] = ["port": port, "token": token, "pid": ProcessInfo.processInfo.processIdentifier, "protocol_version": 1]
                do {
                    try JSONSerialization.data(withJSONObject: value).write(to: endpointURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpointURL.path)
                } catch { NSLog("Endpoint creation failed: %@", error.localizedDescription) }
            }
            engine.permissions()
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
        engine?.permissions()
        interface?.showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        engine?.permissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        // A retiring copy must not delete the endpoint written by its replacement.
        if let endpoint,
           let data = try? Data(contentsOf: endpoint),
           let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           info["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) {
            try? FileManager.default.removeItem(at: endpoint)
        }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
