import AppKit

/// Runtime appearance lives in user preferences; signed bundle resources remain untouched.
@MainActor
final class IconController {
    private let model: AppModel
    private let preferencesURL: URL
    private(set) var selectedIcon: String = "C"

    init(model: AppModel, dataDirectory: URL) {
        self.model = model
        preferencesURL = dataDirectory.appendingPathComponent("appearance.json")
        if let data = try? Data(contentsOf: preferencesURL),
           let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let value = values["selectedIcon"] as? String, ["C", "D"].contains(value) {
            selectedIcon = value
        }
        apply(selectedIcon)
    }

    @discardableResult
    func select(_ name: String) throws -> [String: Any] {
        guard !model.isUpdating else {
            throw DesktopFailure(code: "update-in-progress", message: "请在更新完成后切换图标。")
        }
        guard ["C", "D"].contains(name) else {
            throw DesktopFailure(code: "invalid-icon", message: "请选择图标 C 或 D。")
        }
        guard Bundle.main.url(forResource: "Icon\(name)", withExtension: "png") != nil else {
            throw DesktopFailure(code: "icon-missing", message: "应用图标资源缺失，请更新应用。")
        }
        let data = try JSONSerialization.data(withJSONObject: ["selectedIcon": name])
        try data.write(to: preferencesURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
        selectedIcon = name
        apply(name)
        return diagnostics()
    }

    private func apply(_ name: String) {
        model.selectedIcon = name
        if let url = Bundle.main.url(forResource: "Icon\(name)", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }

    func diagnostics() -> [String: Any] {
        let installed = (Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "IconC")
            .replacingOccurrences(of: ".icns", with: "")
        return ["selected_icon": selectedIcon, "installed_icon": ["IconD", "DeskLoomIconD"].contains(installed) ? "D" : "C",
                "selection_persisted": FileManager.default.fileExists(atPath: preferencesURL.path),
                "available_icons": ["C", "D"]]
    }
}
