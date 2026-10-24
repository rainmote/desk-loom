import AppKit
import ApplicationServices
import ScreenCaptureKit
import CryptoKit

struct DesktopFailure: Error {
    let code: String
    let message: String
}

@MainActor
final class DesktopEngine {
    let model: AppModel
    let interface: InterfaceController
    let dataDirectory: URL
    private(set) var fixture: URL?
    private var sessionID = ""
    private var application: NSRunningApplication?
    private var processLaunch: Date?
    private var window: AXUIElement?
    private var snapshotID = ""
    private var snapshotAt = Date.distantPast
    private var observedBounds: CGRect?
    private var handles: [String: AXUIElement] = [:]
    private var observedValues: [String: String] = [:]
    private var requests: [String: [String: Any]] = [:]
    private var requestPayloads: [String: String] = [:]
    private var requestValues: [String: String] = [:]
    private var starting = false
    private var controlEpoch = 0
    private var timer: Timer?
    private var captureBusy = false
    private var previewSequence = 0
    private var previewPath: String?
    private var previewHash: String?
    private var lastBounds: CGRect?
    private var windowID: CGWindowID?
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
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
            ? "两项权限已就绪，可以连接 TextEdit。"
            : "已重新检查。若系统开关已开但仍未生效，请从权限列表移除旧条目，再用 Finder 中这份应用重新添加并开启；重新编译的旧临时签名可能留下失效条目。"
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    private func string(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private func boundsData(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func status() -> [String: Any] {
        permissions()
        var result: [String: Any] = [
            "protocol_version": 1, "app_name": "TextEdit", "bundle_id": "com.apple.TextEdit",
            "accessibility": model.accessibilityGranted, "screen_recording": model.screenRecordingGranted,
            "accessibility_permission_name": model.accessibilityPermissionName,
            "controller_application_path": Bundle.main.bundleURL.path,
            "active": model.isActive, "phase": model.phase, "session_id": sessionID,
            "window_title": model.windowTitle, "preview_sequence": previewSequence,
            "node_count": model.nodeCount, "snapshot_id": snapshotID
        ]
        if let fixture { result["fixture_path"] = fixture.path }
        if let previewPath { result["preview_path"] = previewPath }
        if let previewHash { result["preview_sha256"] = previewHash }
        if let lastBounds { result["window_bounds"] = boundsData(lastBounds) }
        if let windowID { result["window_id"] = windowID }
        if let date = model.lastCapture { result["preview_captured_at"] = timestamp(date) }
        return result
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

    func start() async throws -> [String: Any] {
        guard !model.isUpdating else {
            throw DesktopFailure(code: "update-in-progress", message: "应用正在更新，请完成后再连接 TextEdit。")
        }
        permissions()
        guard model.accessibilityGranted else {
            throw DesktopFailure(code: "accessibility-required", message: "请在「\(model.accessibilityPermissionName)」中为 DeskLoom 开启权限。")
        }
        if model.isActive { return status() }
        // Opening a new document in an already-active TextEdit can change its
        // key window even with activates=false. Leave the user's document alone.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.TextEdit" else {
            throw DesktopFailure(code: "target-in-use", message: "你正在使用 TextEdit。请先切换到其他应用，再后台连接，避免切走当前文档。")
        }
        guard !starting else { throw DesktopFailure(code: "busy", message: "会话正在启动。") }
        starting = true
        defer { starting = false }
        controlEpoch += 1
        let startEpoch = controlEpoch
        sessionID = UUID().uuidString
        model.previewImage = nil
        model.lastCapture = nil
        model.previewError = nil
        previewPath = nil
        previewHash = nil
        windowID = nil
        lastBounds = nil
        window = nil
        interface.updateTargetFrame(nil)
        let folder = dataDirectory.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("DeskLoom \(sessionID.prefix(8)).txt")
        try "DeskLoom TextEdit fixture.\nOnly this document is controlled.\n".write(to: file, atomically: true, encoding: .utf8)
        fixture = file
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            throw DesktopFailure(code: "app-missing", message: "找不到 TextEdit。")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Opening a fixture must leave the user's current application in control.
        // Do not restore/activate an earlier app afterwards: the user may have
        // deliberately switched apps while this asynchronous open was pending.
        configuration.activates = false
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: configuration) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if let app { continuation.resume(returning: app) }
                else { continuation.resume(throwing: DesktopFailure(code: "launch-failed", message: "TextEdit 启动失败。")) }
            }
        }
        guard startEpoch == controlEpoch else { throw DesktopFailure(code: "cancelled", message: "启动已被停止。") }
        application = app
        processLaunch = app.launchDate
        model.isActive = true
        model.phase = "连接 TextEdit"
        model.detail = "等待测试文档窗口"
        requests.removeAll()
        requestPayloads.removeAll()
        requestValues.removeAll()
        handles.removeAll()
        observedValues.removeAll()
        snapshotID = ""
        for _ in 0..<30 {
            guard startEpoch == controlEpoch else { throw DesktopFailure(code: "cancelled", message: "启动已被停止。") }
            if let target = try? resolveWindow() {
                window = target
                updateTarget(target)
                model.phase = "正在操作"
                model.detail = "仅限本次创建的测试文档 · 等待 REPL 指令"
                await capturePreview()
                return status()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        model.phase = "等待窗口"
        model.detail = "TextEdit 已启动，等待测试窗口，REPL 可继续轮询 observe。"
        return status()
    }

    private func resolveWindow() throws -> AXUIElement {
        guard model.isActive, let app = application, !app.isTerminated,
              app.bundleIdentifier == "com.apple.TextEdit", app.launchDate == processLaunch,
              let fixture else { throw DesktopFailure(code: "session-inactive", message: "会话未启动或目标应用已重启。") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.4)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let filename = fixture.lastPathComponent
        let stem = fixture.deletingPathExtension().lastPathComponent
        let matches = windows.filter { item in
            let title = string(item, kAXTitleAttribute)
            let document = string(item, kAXDocumentAttribute)
            if !document.isEmpty, let url = URL(string: document) {
                return url.standardizedFileURL == fixture.standardizedFileURL
            }
            return title == filename || title == stem || title.hasPrefix(filename + " —") || title.hasPrefix(stem + " —")
        }
        guard matches.count == 1 else {
            throw DesktopFailure(code: matches.isEmpty ? "window-not-ready" : "ambiguous-window", message: "无法唯一确认本次测试文档窗口，拒绝操作其他文档。")
        }
        return matches[0]
    }

    private func updateTarget(_ target: AXUIElement) {
        window = target
        model.windowTitle = string(target, kAXTitleAttribute)
        if let bounds = frame(target) {
            lastBounds = bounds
            interface.updateTargetFrame(bounds, windowID: windowID,
                                        processID: application?.processIdentifier)
        }
    }

    func observe() throws -> [String: Any] {
        permissions()
        guard model.accessibilityGranted else { throw DesktopFailure(code: "accessibility-required", message: "\(model.accessibilityPermissionName)权限尚未生效。") }
        let target = try resolveWindow()
        updateTarget(target)
        snapshotID = UUID().uuidString
        snapshotAt = Date()
        observedBounds = frame(target)
        handles.removeAll()
        observedValues.removeAll()
        var nodes: [[String: Any]] = []
        var complete = true
        let deadline = Date().addingTimeInterval(2)
        var visited: [AXUIElement] = []
        func walk(_ element: AXUIElement, parent: String?, depth: Int) {
            if nodes.count >= 400 || depth > 24 || Date() > deadline { complete = false; return }
            if visited.contains(where: { CFEqual($0, element) }) { return }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, 0.2)
            let id = "n\(nodes.count)"
            handles[id] = element
            let role = string(element, kAXRoleAttribute)
            var settable = DarwinBoolean(false)
            _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            var actions: CFArray?
            _ = AXUIElementCopyActionNames(element, &actions)
            var node: [String: Any] = [
                "id": id, "role": role, "title": string(element, kAXTitleAttribute),
                "description": string(element, kAXDescriptionAttribute),
                "enabled": (attribute(element, kAXEnabledAttribute) as? Bool) ?? true,
                "settable": settable.boolValue, "actions": (actions as? [String]) ?? [], "depth": depth
            ]
            if let value = attribute(element, kAXValueAttribute) as? String {
                node["value"] = String(value.prefix(100_000))
                observedValues[id] = value
                if value.count > 100_000 { complete = false; node["value_truncated"] = true }
            }
            if let parent { node["parent_id"] = parent }
            if let bounds = frame(element) { node["bounds"] = boundsData(bounds) }
            nodes.append(node)
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for child in children { walk(child, parent: id, depth: depth + 1) }
        }
        walk(target, parent: nil, depth: 0)
        model.nodeCount = nodes.count
        return ["snapshot_id": snapshotID, "session_id": sessionID,
                "pid": Int(application?.processIdentifier ?? 0), "window_title": model.windowTitle,
                "fixture_path": fixture?.path ?? "", "nodes": nodes, "complete": complete,
                "window_bounds": observedBounds.map(boundsData) as Any? ?? NSNull(),
                "captured_at": timestamp(snapshotAt),
                "capture_finished_at": timestamp(Date()), "source": "macos-ax"]
    }

    func setValue(_ params: [String: Any]) throws -> [String: Any] {
        guard let requestID = params["request_id"] as? String, !requestID.isEmpty else {
            throw DesktopFailure(code: "invalid-request", message: "必须提供 request_id。")
        }
        let payload = "set_value|\(params["snapshot_id"] as? String ?? "")|\(params["node_id"] as? String ?? "")|\(params["value"] as? String ?? "")"
        if let existing = requests[requestID] {
            guard requestPayloads[requestID] == payload else { throw DesktopFailure(code: "request-id-conflict", message: "同一个 request_id 不能用于不同动作。") }
            return existing
        }
        guard params["snapshot_id"] as? String == snapshotID, !snapshotID.isEmpty,
              Date().timeIntervalSince(snapshotAt) < 30 else {
            throw DesktopFailure(code: "stale-target", message: "快照已过期，请重新 observe。")
        }
        let currentWindow = try resolveWindow()
        guard let observedWindow = window, CFEqual(currentWindow, observedWindow),
              let nodeID = params["node_id"] as? String, let element = handles[nodeID],
              let text = params["value"] as? String, text.utf8.count <= 100_000 else {
            throw DesktopFailure(code: "invalid-target", message: "目标窗口或元素不属于当前快照。")
        }
        var owner: pid_t = 0
        AXUIElementGetPid(element, &owner)
        guard owner == application?.processIdentifier,
              string(element, kAXRoleAttribute) == kAXTextAreaRole,
              (attribute(element, kAXEnabledAttribute) as? Bool) != false else {
            throw DesktopFailure(code: "invalid-target", message: "只允许编辑本次测试文档的 AXTextArea。")
        }
        // Revalidate ancestry against the current window, not merely an old handle.
        var parent: AXUIElement? = element
        var belongs = false
        for _ in 0..<30 {
            guard let candidate = parent else { break }
            if CFEqual(candidate, currentWindow) { belongs = true; break }
            parent = attribute(candidate, kAXParentAttribute) as! AXUIElement?
        }
        guard belongs else { throw DesktopFailure(code: "stale-target", message: "元素已脱离目标窗口。") }
        guard let previous = observedValues[nodeID], attribute(element, kAXValueAttribute) as? String == previous else {
            throw DesktopFailure(code: "stale-target", message: "文本已在观测后改变，请重新读取。")
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { throw DesktopFailure(code: "not-settable", message: "该文本区域不支持 AXValue 写入。") }
        model.phase = "正在写入"
        model.detail = "Clojure REPL → TextEdit · \(text.count) 字符"
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        let record: [String: Any] = ["request_id": requestID, "state": result == .success ? "dispatched" : "unknown",
                                     "ax_error": result.rawValue, "session_id": sessionID,
                                     "based_on": snapshotID, "dispatched_at": timestamp(Date())]
        requests[requestID] = record
        requestPayloads[requestID] = payload
        requestValues[requestID] = text
        snapshotID = ""
        handles.removeAll()
        model.phase = result == .success ? "等待结果验证" : "结果待确认"
        return record
    }

    /// Move only the fixture window; used to verify that the purple indicator follows it.
    func moveWindow(_ params: [String: Any]) throws -> [String: Any] {
        guard let requestID = params["request_id"] as? String, !requestID.isEmpty,
              let x = params["x"] as? Double, let y = params["y"] as? Double,
              x.isFinite, y.isFinite else {
            throw DesktopFailure(code: "invalid-request", message: "移动窗口需要 request_id 和有限的 x/y。")
        }
        let payload = "move_window|\(params["snapshot_id"] as? String ?? "")|\(x)|\(y)"
        if let existing = requests[requestID] {
            guard requestPayloads[requestID] == payload else {
                throw DesktopFailure(code: "request-id-conflict", message: "同一个 request_id 不能用于不同动作。")
            }
            return existing
        }
        guard params["snapshot_id"] as? String == snapshotID, !snapshotID.isEmpty,
              Date().timeIntervalSince(snapshotAt) < 30 else {
            throw DesktopFailure(code: "stale-target", message: "移动前需要新鲜的 observe 快照。")
        }
        let target = try resolveWindow()
        guard let previousWindow = window, CFEqual(previousWindow, target),
              let bounds = frame(target), bounds == observedBounds else {
            throw DesktopFailure(code: "stale-target", message: "目标窗口自观测后已改变。")
        }
        let destination = CGRect(x: x, y: y, width: bounds.width, height: bounds.height)
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let staysVisible = NSScreen.screens.contains { screen in
            let visible = screen.visibleFrame
            let axVisible = CGRect(x: visible.minX, y: primaryMaxY - visible.maxY,
                                   width: visible.width, height: visible.height)
            return axVisible.contains(destination)
        }
        guard staysVisible else {
            throw DesktopFailure(code: "invalid-position", message: "测试窗口必须完整保留在可见屏幕范围内。")
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(target, kAXPositionAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            throw DesktopFailure(code: "not-settable", message: "目标窗口不支持 AXPosition 写入。")
        }
        var point = destination.origin
        guard let value = AXValueCreate(.cgPoint, &point) else {
            throw DesktopFailure(code: "invalid-position", message: "无法创建窗口位置值。")
        }
        let result = AXUIElementSetAttributeValue(target, kAXPositionAttribute as CFString, value)
        var record: [String: Any] = ["request_id": requestID, "session_id": sessionID,
                                    "state": result == .success ? "dispatched" : "unknown",
                                    "ax_error": result.rawValue, "based_on": snapshotID,
                                    "dispatched_at": timestamp(Date())]
        if let actual = frame(target) { record["window_bounds"] = boundsData(actual) }
        requests[requestID] = record
        requestPayloads[requestID] = payload
        snapshotID = ""
        handles.removeAll()
        observedValues.removeAll()
        updateTarget(target)
        return record
    }

    func verification(_ params: [String: Any]) throws -> [String: Any] {
        guard let requestID = params["request_id"] as? String, requests[requestID] != nil,
              let expected = requestValues[requestID], params["expected_value"] as? String == expected else {
            throw DesktopFailure(code: "invalid-verification", message: "验证需要已执行的 request_id 和 expected_value。")
        }
        let observation = try observe()
        let editors = (observation["nodes"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == kAXTextAreaRole }
        let verified = observation["complete"] as? Bool == true && params["success"] as? Bool == true && editors.count == 1 && editors.first?["value"] as? String == expected
        model.phase = verified ? "验证通过" : "验证失败"
        model.detail = verified ? "AX 再次读回一致" + (params["persisted"] as? Bool == true ? " · Clojure 已报告 XTDB 持久化" : "") : "请检查 REPL 返回的实际内容"
        var result = status()
        result["verified"] = verified
        result["request_id"] = requestID
        return result
    }

    func reportVerificationError(_ params: [String: Any]) throws -> [String: Any] {
        guard let requestID = params["request_id"] as? String, requestValues[requestID] != nil else {
            throw DesktopFailure(code: "invalid-verification", message: "中断报告必须关联已执行的文本动作。")
        }
        model.phase = "验证中断"
        let stage = String((params["stage"] as? String ?? "verification").prefix(80))
        model.detail = "\(stage)：" + String((params["message"] as? String ?? "结果未知，请检查 REPL 记录").prefix(240))
        var result = status()
        result["request_id"] = requestID
        result["outcome"] = "unknown"
        result["stage"] = stage
        return result
    }

    func stop() -> [String: Any] {
        controlEpoch += 1
        model.isActive = false
        model.phase = "已停止"
        model.detail = "控制权已释放，测试文档保留在 TextEdit"
        snapshotID = ""
        handles.removeAll()
        observedValues.removeAll()
        interface.updateTargetFrame(nil)
        return status()
    }

    private func tick() async {
        permissions()
        guard model.isActive else { return }
        if let target = try? resolveWindow() {
            updateTarget(target)
            await capturePreview()
        } else {
            interface.updateTargetFrame(nil)
            model.phase = "目标不可用"
            model.detail = "测试窗口已关闭或应用已退出，操作将被拒绝"
            model.previewError = "目标窗口不可用，以下为最后一帧"
        }
    }

    func capturePreview() async {
        guard model.isActive, !captureBusy, model.screenRecordingGranted,
              let app = application, let target = try? resolveWindow() else { return }
        captureBusy = true
        defer { captureBusy = false }
        let captureSession = sessionID
        let captureEpoch = controlEpoch
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard model.isActive, controlEpoch == captureEpoch, sessionID == captureSession,
                  let currentTarget = try? resolveWindow(), CFEqual(target, currentTarget),
                  let currentBounds = frame(currentTarget) else { return }
            let title = string(currentTarget, kAXTitleAttribute)
            let candidates = content.windows.filter { item in
                let geometryMatches = abs(item.frame.minX - currentBounds.minX) < 3 && abs(item.frame.minY - currentBounds.minY) < 3 && abs(item.frame.width - currentBounds.width) < 3 && abs(item.frame.height - currentBounds.height) < 3
                return item.owningApplication?.processID == app.processIdentifier && geometryMatches &&
                    item.title == title && (windowID == nil || item.windowID == windowID)
            }
            guard candidates.count == 1, let chosen = candidates.first else {
                model.previewError = "无法唯一确认测试窗口，暂停截图"
                return
            }
            guard model.isActive, controlEpoch == captureEpoch, sessionID == captureSession else { return }
            let filter = SCContentFilter(desktopIndependentWindow: chosen)
            let configuration = SCStreamConfiguration()
            configuration.width = 720
            configuration.height = max(100, Int(720 * chosen.frame.height / max(1, chosen.frame.width)))
            configuration.showsCursor = false
            configuration.captureResolution = .best
            configuration.ignoreShadowsSingleWindow = true
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard model.isActive, sessionID == captureSession, controlEpoch == captureEpoch,
                  let confirmedTarget = try? resolveWindow(), CFEqual(currentTarget, confirmedTarget),
                  frame(confirmedTarget) == currentBounds else { return }
            let image = NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
            let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])!
            let path = dataDirectory.appendingPathComponent("preview.png")
            try png.write(to: path, options: .atomic)
            model.previewImage = image
            model.previewError = nil
            model.lastCapture = Date()
            previewSequence += 1
            previewPath = path.path
            previewHash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            windowID = chosen.windowID
            interface.updateTargetFrame(currentBounds, windowID: chosen.windowID,
                                        processID: app.processIdentifier)
        } catch {
            model.detail = "预览暂不可用：\(error.localizedDescription)"
            model.previewError = "捕获失败，以下为最后一帧"
        }
    }

    func handle(method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "status": return status()
        case "focus_state": return focusState()
        case "permission_settings": return try openPermissionSettings(params["permission"] as? String ?? "")
        case "reveal_application": return revealApplication()
        case "start": return try await start()
        case "observe": return try observe()
        case "set_value": return try setValue(params)
        case "move_window": return try moveWindow(params)
        case "verify": return try verification(params)
        case "report_verification_error": return try reportVerificationError(params)
        case "stop": return stop()
        case "preview": await capturePreview(); return status()
        case "show": interface.showWindow(); return status()
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
