import AppKit
import ApplicationServices
import ScreenCaptureKit
import CryptoKit

/// Each attached window owns its own observation and action capabilities.
@MainActor
protocol ComputerSessionEngine: AnyObject {
    var isActive: Bool { get }
    var sessionIdentifier: String { get }
    var selectedWindowIdentifier: String? { get }
    var presentsTarget: Bool { get set }
    var onStateChange: (() -> Void)? { get set }
    var updateInProgress: (() -> Bool)? { get set }
    func capabilities() -> [String: Any]
    func windows(_ params: [String: Any]) throws -> [String: Any]
    func attach(_ params: [String: Any]) throws -> [String: Any]
    func observe(_ params: [String: Any]) throws -> [String: Any]
    func act(_ params: [String: Any]) throws -> [String: Any]
    func screenshot(_ params: [String: Any]) async throws -> [String: Any]
    func detach() -> [String: Any]
    func makeSessionEngine(model: AppModel) -> any ComputerSessionEngine
    func rememberWindows(from engine: any ComputerSessionEngine)
}

/// AX references are capabilities scoped to one observed window and are
/// discarded after every action. No action is automatically retried.
@MainActor
final class ComputerEngine: ComputerSessionEngine {
    private struct WindowRecord {
        let id: String
        let application: NSRunningApplication
        let launchDate: Date?
        let element: AXUIElement
    }
    private struct NodeRecord {
        let element: AXUIElement
        let role: String
        let titleFingerprint: String?
        let valueFingerprint: String?
        let bounds: CGRect?
        let secure: Bool
    }
    private let model: AppModel
    private let interface: InterfaceController
    private var knownWindows: [WindowRecord] = []
    private var selected: WindowRecord?
    private var lastBundleID = ""
    private var lastAppName = ""
    private var lastWindowTitle = ""
    private var lastNodeCount = 0
    private var lastPhase = "待连接"
    private var sessionID = ""
    private var epoch = 0
    private var snapshotID = ""
    private var snapshotAt = Date.distantPast
    private var snapshotBounds: CGRect?
    private var snapshotTitle = ""
    private var nodes: [String: NodeRecord] = [:]
    private var receipts: [String: [String: Any]] = [:]
    private var payloads: [String: Data] = [:]
    private var payloadBytes = 0
    private var capturedWindowID: CGWindowID?
    private var activationSequence = 0
    private var snapshotActivationSequence = 0
    private var activationObserver: NSObjectProtocol?
    private var timer: Timer?
    private var captureBusy = false
    var isActive: Bool { selected != nil }
    var sessionIdentifier: String { sessionID }
    var selectedWindowIdentifier: String? { selected?.id }
    var onStateChange: (() -> Void)?
    var updateInProgress: (() -> Bool)?
    var presentsTarget = true {
        didSet {
            if presentsTarget && !oldValue, let selected { updateTarget(selected) }
        }
    }

    static let maximumSemanticTextBytes = 1_048_576

    /// AX strings are Unicode: a character-count limit does not bound bytes.
    /// Inspect only a bounded UTF-8 prefix and never emit a partial scalar.
    static func boundedUTF8(_ text: String, maximumBytes: Int) -> (text: String, truncated: Bool) {
        let limit = max(0, maximumBytes)
        let prefix = Array(text.utf8.prefix(limit + 1))
        if prefix.count <= limit { return (text, false) }
        var bytes = Array(prefix.prefix(limit))
        while !bytes.isEmpty {
            if let result = String(bytes: bytes, encoding: .utf8) { return (result, true) }
            bytes.removeLast()
        }
        return ("", true)
    }

    @MainActor
    struct SemanticTextBudget {
        private(set) var remaining: Int
        private(set) var truncated = false
        init(maximumBytes: Int = 1_048_576) { remaining = max(0, maximumBytes) }
        mutating func take(_ text: String, maximumBytes: Int = 8192) -> (text: String, truncated: Bool) {
            let result = ComputerEngine.boundedUTF8(text, maximumBytes: min(remaining, maximumBytes))
            remaining -= result.text.utf8.count
            truncated = truncated || result.truncated
            return result
        }
    }

    init(model: AppModel, interface: InterfaceController) {
        self.model = model
        self.interface = interface
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activationSequence += 1 }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTarget() }
        }
    }

    deinit {
        timer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func makeSessionEngine(model: AppModel) -> any ComputerSessionEngine {
        let engine = ComputerEngine(model: model, interface: interface)
        engine.presentsTarget = false
        engine.knownWindows = knownWindows
        return engine
    }

    func rememberWindows(from engine: any ComputerSessionEngine) {
        guard let engine = engine as? ComputerEngine else { return }
        for record in engine.knownWindows + (engine.selected.map { [$0] } ?? []) {
            if !knownWindows.contains(where: { $0.id == record.id }) { knownWindows.append(record) }
        }
        knownWindows = Array(knownWindows.filter { !$0.application.isTerminated }.suffix(500))
    }

    private func failure(_ code: String, _ message: String) -> DesktopFailure {
        DesktopFailure(code: code, message: message)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    private func string(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }

    private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private func boundsData(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }

    private func timestamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func requireAccessibility() throws {
        guard AXIsProcessTrusted() else { throw failure("accessibility-required", "请先为 DeskLoom 开启无障碍权限。") }
        guard !model.isUpdating, updateInProgress?() != true else {
            throw failure("update-in-progress", "更新期间不能控制电脑。")
        }
    }

    func capabilities() -> [String: Any] {
        ["protocol_version": 1, "backend": "macos-ax", "platform": "macos",
         "controller_application_path": Bundle.main.bundleURL.path,
         "supported_platforms": ["macos"], "active": isActive,
         "session_id": sessionID, "window_id": selected?.id as Any? ?? NSNull(),
         "pid": selected.map { Int($0.application.processIdentifier) } as Any? ?? NSNull(),
         "accessibility": AXIsProcessTrusted(),
         "bundle_id": lastBundleID,
         "app_name": isActive ? model.appName : lastAppName,
         "window_title": isActive ? model.windowTitle : lastWindowTitle,
         "node_count": isActive ? model.nodeCount : lastNodeCount,
         "phase": isActive ? model.phase : lastPhase, "snapshot_id": snapshotID,
         "screen_recording": CGPreflightScreenCaptureAccess(),
         "actions": ["focus", "click", "set_value", "type_text", "key", "scroll", "drag"],
         "coordinate_space": "desktop_points", "coordinate_origin": "main_display_top_left",
         "coordinate_y_direction": "down", "screenshot_scope": "attached_window",
         "snapshot_ttl_ms": 15_000, "default_max_nodes": 300, "max_nodes": 1000,
         "max_requests_per_session": 10_000, "semantic_actions_preferred": true,
         "max_request_history_bytes": 16_777_216,
         "max_observation_text_bytes": Self.maximumSemanticTextBytes,
         "synthetic_input_requires_focus": true, "automatic_action_retries": false,
         "supports_background_ax_actions": true,
         "key_names": Array(Self.keyCodes.keys).sorted(),
         "modifiers": ["command", "shift", "option", "control"],
         "text_input_max_utf16_units": 4096]
    }

    private func windowData(_ record: WindowRecord) -> [String: Any] {
        let title = Self.boundedUTF8(string(record.element, kAXTitleAttribute), maximumBytes: 8192)
        var result: [String: Any] = [
            "window_id": record.id, "id": record.id,
            "pid": Int(record.application.processIdentifier),
            "bundle_id": Self.boundedUTF8(record.application.bundleIdentifier ?? "", maximumBytes: 512).text,
            "app_name": Self.boundedUTF8(record.application.localizedName ?? "", maximumBytes: 1024).text,
            "title": title.text, "title_truncated": title.truncated,
            "minimized": attribute(record.element, kAXMinimizedAttribute) as? Bool ?? false
        ]
        if let bounds = frame(record.element) { result["bounds"] = boundsData(bounds) }
        return result
    }

    func windows(_ params: [String: Any]) throws -> [String: Any] {
        try requireAccessibility()
        let applications = NSWorkspace.shared.runningApplications.filter { app in
            !app.isTerminated && app.activationPolicy == .regular &&
                (params["bundle_id"] == nil || params["bundle_id"] as? String == app.bundleIdentifier) &&
                (params["pid"] == nil || params["pid"] as? Int == Int(app.processIdentifier))
        }
        var records: [WindowRecord] = []
        var output: [[String: Any]] = []
        var complete = true
        let deadline = Date().addingTimeInterval(3)
        for app in applications {
            if Date() > deadline || records.count >= 200 { complete = false; break }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.1)
            var raw: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &raw)
            if result != .success && result != .noValue && result != .attributeUnsupported { complete = false }
            for element in raw as? [AXUIElement] ?? [] {
                if Date() > deadline || records.count >= 200 { complete = false; break }
                AXUIElementSetMessagingTimeout(element, 0.1)
                let existing = (knownWindows + (selected.map { [$0] } ?? [])).first {
                    $0.application.processIdentifier == app.processIdentifier &&
                        $0.launchDate == app.launchDate && CFEqual($0.element, element)
                }
                let record = WindowRecord(id: existing?.id ?? UUID().uuidString,
                                          application: app, launchDate: app.launchDate, element: element)
                records.append(record)
                output.append(windowData(record))
            }
        }
        // Preserve IDs for windows outside a filtered query, but bound registry growth.
        let enumerated = Set(applications.map { $0.processIdentifier })
        knownWindows = Array((knownWindows.filter { !enumerated.contains($0.application.processIdentifier) && !$0.application.isTerminated } + records).suffix(500))
        return ["windows": output, "complete": complete, "source": "macos-ax"]
    }

    func attach(_ params: [String: Any]) throws -> [String: Any] {
        try requireAccessibility()
        guard !model.isActive, selected == nil else {
            throw failure("session-active", "已有控制会话。请先停止或 detach，再选择其他窗口。")
        }
        guard params["bundle_id"] is String || params["pid"] is Int || params["window_id"] is String else {
            throw failure("target-required", "请用 bundle_id、pid 或 computer_windows 返回的 window_id 指定目标。")
        }
        let result = try windows(params)
        let visibleIDs = Set((result["windows"] as? [[String: Any]] ?? []).compactMap { $0["window_id"] as? String })
        let matches = knownWindows.filter {
            visibleIDs.contains($0.id) && (params["window_id"] == nil || params["window_id"] as? String == $0.id)
        }
        // A truncated enumeration is not evidence that an app has a single window.
        guard params["window_id"] != nil || result["complete"] as? Bool == true else {
            throw failure("incomplete-window-list", "窗口枚举不完整，请重试枚举并指定 window_id。")
        }
        guard matches.count == 1, let target = matches.first else {
            throw failure(matches.isEmpty ? "window-not-found" : "ambiguous-window", "请从 computer_windows 选择唯一窗口并传入 window_id。")
        }
        selected = target
        lastBundleID = target.application.bundleIdentifier ?? ""
        sessionID = UUID().uuidString
        epoch += 1
        invalidateSnapshot()
        receipts.removeAll()
        payloads.removeAll()
        payloadBytes = 0
        capturedWindowID = nil
        model.isActive = true
        model.appName = Self.boundedUTF8(target.application.localizedName ?? target.application.bundleIdentifier ?? "应用",
                                       maximumBytes: 1024).text
        model.phase = "已连接"
        model.detail = "通用电脑控制 · 窗口独立会话 · 可随时停止"
        model.nodeCount = 0
        model.previewImage = nil
        model.previewError = nil
        model.lastCapture = nil
        updateTarget(target)
        var response = windowData(target)
        response["session_id"] = sessionID
        response["active"] = true
        response["focused"] = isFocused(target)
        return response
    }

    private func resolveTarget() throws -> WindowRecord {
        try requireAccessibility()
        guard model.isActive, let target = selected, !target.application.isTerminated,
              target.application.launchDate == target.launchDate else {
            throw failure("session-inactive", "会话已停止或目标应用已退出。")
        }
        let root = AXUIElementCreateApplication(target.application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard windows.contains(where: { CFEqual($0, target.element) }) else {
            throw failure("stale-window", "目标窗口已关闭或发生变化，请重新连接。")
        }
        return target
    }

    private func updateTarget(_ target: WindowRecord, windowID: CGWindowID? = nil) {
        if let windowID { capturedWindowID = windowID }
        model.windowTitle = Self.boundedUTF8(string(target.element, kAXTitleAttribute), maximumBytes: 8192).text
        lastAppName = model.appName
        lastWindowTitle = model.windowTitle
        if presentsTarget {
            interface.updateTargetFrame(frame(target.element), windowID: capturedWindowID,
                                        processID: target.application.processIdentifier)
        }
        onStateChange?()
    }

    private func refreshTarget() {
        guard isActive else { return }
        if let target = try? resolveTarget() { updateTarget(target) }
        else {
            _ = detach()
            model.phase = "目标已断开"
            lastPhase = model.phase
            model.detail = "窗口关闭、应用退出、权限变化或更新已使控制会话失效。"
            onStateChange?()
        }
    }

    private func invalidateSnapshot() {
        snapshotID = ""
        snapshotBounds = nil
        nodes.removeAll()
    }

    private func secure(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    private func valueFingerprint(_ value: CFTypeRef?) -> String? {
        if let text = value as? String {
            return "text:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        if let number = value as? NSNumber { return "number:" + number.stringValue }
        return nil
    }

    func observe(_ params: [String: Any]) throws -> [String: Any] {
        let target = try resolveTarget()
        let maxNodes = min(1000, max(1, params["max_nodes"] as? Int ?? 300))
        let maxDepth = min(40, max(1, params["max_depth"] as? Int ?? 24))
        invalidateSnapshot()
        let started = Date()
        let deadline = started.addingTimeInterval(1.5)
        let observedFrame = frame(target.element)
        let observedTitle = string(target.element, kAXTitleAttribute)
        var textBudget = SemanticTextBudget()
        let boundedWindowTitle = textBudget.take(observedTitle)
        let appBundle = textBudget.take(target.application.bundleIdentifier ?? "", maximumBytes: 512).text
        let appName = textBudget.take(target.application.localizedName ?? "", maximumBytes: 1024).text
        var output: [[String: Any]] = []
        var complete = observedFrame != nil
        var textLimitReached = false
        var visited: [AXUIElement] = []
        var queue: [(AXUIElement, String?, Int)] = [(target.element, nil, 0)]
        var cursor = 0
        while cursor < queue.count {
            if output.count >= maxNodes || Date() > deadline { complete = false; break }
            if textBudget.remaining < 256 { complete = false; textLimitReached = true; break }
            let (element, parent, depth) = queue[cursor]
            cursor += 1
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, 0.05)
            let id = "n\(output.count)"
            let rawRole = string(element, kAXRoleAttribute)
            if rawRole.isEmpty { complete = false }
            let title = string(element, kAXTitleAttribute)
            let description = string(element, kAXDescriptionAttribute)
            let isSecure = secure(element)
            let rawValue = isSecure ? nil : attribute(element, kAXValueAttribute)
            let value = rawValue as? String
            let bounds = frame(element)
            var settable = DarwinBoolean(false)
            _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            var actions: CFArray?
            _ = AXUIElementCopyActionNames(element, &actions)
            var truncatedFields: [String] = []
            func bounded(_ text: String, field: String, maximumBytes: Int = 8192) -> String {
                let limited = textBudget.take(text, maximumBytes: maximumBytes)
                if limited.truncated { truncatedFields.append(field) }
                return limited.text
            }
            let role = bounded(rawRole.isEmpty ? "AXUnknown" : rawRole, field: "role", maximumBytes: 256)
            var node: [String: Any] = ["id": id, "role": role,
                                     "subrole": bounded(string(element, kAXSubroleAttribute), field: "subrole", maximumBytes: 256),
                                     "title": bounded(title, field: "title"),
                                     "description": bounded(description, field: "description"),
                                     "label": bounded(title.isEmpty ? description : title, field: "label"),
                                     "enabled": attribute(element, kAXEnabledAttribute) as? Bool ?? true,
                                     "settable": settable.boolValue,
                                     "depth": depth, "secure": isSecure]
            if rawRole.isEmpty { node["role_unavailable"] = true }
            let rawActions = actions as? [String] ?? []
            if rawActions.count > 128 { truncatedFields.append("actions"); complete = false }
            node["actions"] = rawActions.prefix(128).map { bounded($0, field: "actions", maximumBytes: 256) }
            if let value {
                node["value"] = bounded(value, field: "value", maximumBytes: 16_384)
                if truncatedFields.contains("value") { node["value_truncated"] = true }
            } else if let number = rawValue as? NSNumber { node["value"] = number }
            if isSecure { node["value_redacted"] = true }
            if let parent { node["parent_id"] = parent }
            if let bounds { node["bounds"] = boundsData(bounds) }
            let identifier = string(element, "AXIdentifier")
            if !identifier.isEmpty { node["identifier"] = bounded(identifier, field: "identifier") }
            let url = attribute(element, kAXURLAttribute)
            if let url = url as? URL {
                let limited = textBudget.take(url.absoluteString)
                if limited.truncated {
                    // A partial URL must not become a durable page identity.
                    truncatedFields.append("url")
                    node["url_truncated"] = true
                } else { node["url"] = limited.text }
            }
            if !truncatedFields.isEmpty {
                node["truncated_fields"] = Array(Set(truncatedFields)).sorted()
                complete = false
            }
            nodes[id] = NodeRecord(element: element, role: rawRole, titleFingerprint: valueFingerprint(title as CFString),
                                   valueFingerprint: valueFingerprint(rawValue),
                                   bounds: bounds, secure: isSecure)
            output.append(node)
            var rawChildren: CFTypeRef?
            let childResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren)
            if childResult != .success && childResult != .noValue && childResult != .attributeUnsupported { complete = false }
            let children = rawChildren as? [AXUIElement] ?? []
            if depth >= maxDepth {
                if !children.isEmpty { complete = false }
            } else {
                // Bound both the result and pending traversal memory.
                let available = max(0, maxNodes * 2 - queue.count)
                if children.count > available { complete = false }
                queue.append(contentsOf: children.prefix(available).map { ($0, id, depth + 1) })
            }
        }
        snapshotID = UUID().uuidString
        snapshotAt = started
        snapshotBounds = observedFrame
        snapshotTitle = observedTitle
        snapshotActivationSequence = activationSequence
        updateTarget(target)
        model.nodeCount = output.count
        onStateChange?()
        let currentFrame = frame(target.element)
        let stable = currentFrame == observedFrame && string(target.element, kAXTitleAttribute) == observedTitle
        if !stable { complete = false; invalidateSnapshot() }
        if textBudget.truncated { complete = false }
        var window = windowData(target)
        window["title"] = boundedWindowTitle.text
        window["title_truncated"] = boundedWindowTitle.truncated
        window["bundle_id"] = appBundle
        window["app_name"] = appName
        return ["session_id": sessionID, "snapshot_id": snapshotID, "complete": complete,
                "nodes": output, "app": ["bundle_id": appBundle,
                                          "pid": Int(target.application.processIdentifier), "name": appName],
                "window": window, "window_title": boundedWindowTitle.text,
                "text_bytes": Self.maximumSemanticTextBytes - textBudget.remaining,
                "text_budget_bytes": Self.maximumSemanticTextBytes,
                "text_truncated": textBudget.truncated || textLimitReached,
                "window_bounds": observedFrame.map(boundsData) as Any? ?? NSNull(),
                "focused": isFocused(target), "coordinate_space": "desktop_points",
                "captured_at": timestamp(started), "capture_finished_at": timestamp(),
                "elapsed_ms": Int(Date().timeIntervalSince(started) * 1000), "source": "macos-ax"]
    }

    private func belongs(_ element: AXUIElement, to target: WindowRecord) -> Bool {
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == target.application.processIdentifier else { return false }
        var current: AXUIElement? = element
        for _ in 0..<50 {
            guard let item = current else { return false }
            if CFEqual(item, target.element) { return true }
            current = axElement(attribute(item, kAXParentAttribute))
        }
        return false
    }

    private func isFocused(_ target: WindowRecord) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.application.processIdentifier else { return false }
        let root = AXUIElementCreateApplication(target.application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        guard let focusedWindow = axElement(attribute(root, kAXFocusedWindowAttribute)) else { return false }
        return CFEqual(focusedWindow, target.element) && attribute(target.element, kAXMinimizedAttribute) as? Bool != true
    }

    private func requireFocus(_ target: WindowRecord) throws {
        guard activationSequence == snapshotActivationSequence, isFocused(target) else {
            throw failure("focus-required", "请先执行 focus 并重新 observe；合成输入要求目标窗口保持在前台。")
        }
    }

    private func validatedNode(_ id: String, target: WindowRecord) throws -> NodeRecord {
        guard let record = nodes[id], !record.role.isEmpty, belongs(record.element, to: target),
              string(record.element, kAXRoleAttribute) == record.role,
              valueFingerprint(string(record.element, kAXTitleAttribute) as CFString) == record.titleFingerprint,
              secure(record.element) == record.secure,
              frame(record.element) == record.bounds,
              attribute(record.element, kAXEnabledAttribute) as? Bool != false else {
            throw failure("stale-target", "元素已改变、不可用或不属于当前窗口，请重新 observe。")
        }
        if !record.secure, valueFingerprint(attribute(record.element, kAXValueAttribute)) != record.valueFingerprint {
            throw failure("stale-target", "元素内容已改变，请重新 observe。")
        }
        return record
    }

    private func point(_ params: [String: Any], x: String = "x", y: String = "y", bounds: CGRect) throws -> CGPoint {
        guard let px = params[x] as? Double, let py = params[y] as? Double,
              px.isFinite, py.isFinite, bounds.contains(CGPoint(x: px, y: py)) else {
            throw failure("invalid-coordinate", "坐标必须是目标窗口范围内的全局桌面点（左上原点）。")
        }
        return CGPoint(x: px, y: py)
    }

    private func requireHit(_ point: CGPoint, target: WindowRecord, expected: AXUIElement? = nil) throws {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit, belongs(hit, to: target) else {
            throw failure("target-obscured", "坐标命中的控件不属于当前窗口，请重新 observe 或调整窗口。")
        }
        if let expected {
            var current: AXUIElement? = hit
            for _ in 0..<50 {
                guard let element = current else { break }
                if CFEqual(element, expected) { return }
                if CFEqual(element, target.element) { break }
                current = axElement(attribute(element, kAXParentAttribute))
            }
            throw failure("target-obscured", "目标元素中心被其他控件覆盖，请重新 observe。")
        }
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39,
        "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "backspace": 51, "escape": 53,
        "home": 115, "page_up": 116, "delete": 117, "end": 119, "page_down": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    private func flags(_ params: [String: Any]) throws -> CGEventFlags {
        guard params["modifiers"] == nil || params["modifiers"] is [String] else {
            throw failure("invalid-modifier", "modifiers 必须是字符串数组。")
        }
        let available: [String: CGEventFlags] = ["command": .maskCommand, "cmd": .maskCommand,
                                               "shift": .maskShift, "option": .maskAlternate,
                                               "alt": .maskAlternate, "control": .maskControl, "ctrl": .maskControl]
        var result: CGEventFlags = []
        for name in params["modifiers"] as? [String] ?? [] {
            guard let flag = available[name.lowercased()] else { throw failure("invalid-modifier", "未知修饰键：\(name)") }
            result.insert(flag)
        }
        return result
    }

    private func keyboardFocus(_ target: WindowRecord, node: NodeRecord?) throws {
        try requireFocus(target)
        let root = AXUIElementCreateApplication(target.application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        guard let focused = axElement(attribute(root, kAXFocusedUIElementAttribute)), belongs(focused, to: target),
              node == nil || CFEqual(focused, node!.element) else {
            throw failure("focus-required", "键盘焦点必须属于目标窗口；指定 node_id 时该元素必须已获得输入焦点。")
        }
    }

    /// Keep Unicode event payloads small for application-framework compatibility,
    /// without ever splitting a UTF-16 surrogate pair between keyboard events.
    static func unicodeEventChunks(_ text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if current.count + units.count > 20 { chunks.append(current); current = [] }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    func act(_ params: [String: Any]) throws -> [String: Any] {
        guard let requestID = params["request_id"] as? String, !requestID.isEmpty, requestID.count <= 200,
              let action = params["action"] as? String else {
            throw failure("invalid-request", "操作需要 request_id 和 action。")
        }
        let payload = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        if let receipt = receipts[requestID] {
            guard payloads[requestID] == payload else { throw failure("request-id-conflict", "request_id 已用于不同请求。") }
            return receipt
        }
        guard receipts.count < 10_000, payloadBytes + payload.count <= 16_777_216 else {
            throw failure("session-limit", "会话操作记录达到上限，请重新连接。")
        }
        guard let suppliedSnapshot = params["snapshot_id"] as? String,
              !snapshotID.isEmpty, suppliedSnapshot == snapshotID,
              Date().timeIntervalSince(snapshotAt) < 15 else {
            throw failure("stale-target", "操作必须引用 15 秒内的当前快照，请重新 observe。")
        }
        guard params["node_id"] == nil || params["node_id"] is String else {
            throw failure("invalid-request", "node_id 必须是当前快照中的字符串标识。")
        }
        let target = try resolveTarget()
        guard frame(target.element) == snapshotBounds, string(target.element, kAXTitleAttribute) == snapshotTitle,
              let bounds = snapshotBounds else { throw failure("stale-target", "窗口在观测后已变化，请重新 observe。") }
        let node = try (params["node_id"] as? String).map { try validatedNode($0, target: target) }
        let eventFlags = try flags(params)
        var method = "ax"
        var outcome = "dispatched"
        var axError: AXError?
        var events: [CGEvent] = []
        let source = CGEventSource(stateID: .privateState)
        switch action {
        case "focus":
            guard attribute(target.element, kAXMinimizedAttribute) as? Bool != true else {
                throw failure("window-minimized", "请先恢复目标窗口，再执行 focus。")
            }
            let activated = target.application.activate(options: [])
            let result = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
            axError = result
            if !activated || result != .success { outcome = "unknown" }
        case "set_value":
            guard let node, let value = params["value"] as? String, value.utf8.count <= 100_000 else {
                throw failure("invalid-request", "set_value 需要 node_id 和最多 100000 字节的 value 字符串。")
            }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(node.element, kAXValueAttribute as CFString, &settable) == .success,
                  settable.boolValue else { throw failure("not-settable", "元素不支持直接写入 AXValue。") }
            let result = AXUIElementSetAttributeValue(node.element, kAXValueAttribute as CFString, value as CFString)
            axError = result
            if result != .success { outcome = "unknown" }
            else if !node.secure, attribute(node.element, kAXValueAttribute) as? String == value { outcome = "verified" }
        case "click":
            var actions: CFArray?
            if let node { _ = AXUIElementCopyActionNames(node.element, &actions) }
            if let node, (actions as? [String] ?? []).contains(kAXPressAction) {
                let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
                axError = result
                if result != .success { outcome = "unknown" }
            } else {
                try requireFocus(target)
                let location: CGPoint
                if let node, let rect = node.bounds, bounds.contains(CGPoint(x: rect.midX, y: rect.midY)) {
                    location = CGPoint(x: rect.midX, y: rect.midY)
                } else { location = try point(params, bounds: bounds) }
                try requireHit(location, target: target, expected: node?.element)
                guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
                      let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left) else {
                    throw failure("event-unavailable", "无法创建鼠标事件。")
                }
                events = [down, up]
            }
        case "type_text":
            guard let text = params["text"] as? String, !text.isEmpty, text.utf16.count <= 4096 else {
                throw failure("invalid-request", "type_text 需要 1–4096 UTF-16 单元的 text；大段内容请使用 set_value。")
            }
            try keyboardFocus(target, node: node)
            for chunk in Self.unicodeEventChunks(text) {
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    throw failure("event-unavailable", "无法创建键盘事件。")
                }
                chunk.withUnsafeBufferPointer { buffer in
                    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                events.append(contentsOf: [down, up])
            }
        case "key":
            guard let key = params["key"] as? String, let code = Self.keyCodes[key.lowercased()] else {
                throw failure("invalid-key", "不支持该按键；可通过 computer_capabilities 查询 key_names。")
            }
            try keyboardFocus(target, node: node)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
                throw failure("event-unavailable", "无法创建键盘事件。")
            }
            events = [down, up]
        case "scroll":
            try requireFocus(target)
            let location = try point(params, bounds: bounds)
            try requireHit(location, target: target)
            let dx = params["delta_x"] as? Double ?? 0
            let dy = params["delta_y"] as? Double ?? 0
            guard dx.isFinite, dy.isFinite, abs(dx) <= 10_000, abs(dy) <= 10_000,
                  abs(dx) >= 1 || abs(dy) >= 1 else {
                throw failure("invalid-scroll", "滚动距离必须非零且在 -10000 到 10000 之间。")
            }
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
                throw failure("event-unavailable", "无法创建滚动事件。")
            }
            event.location = location
            events = [event]
        case "drag":
            try requireFocus(target)
            let start = try point(params, bounds: bounds)
            let end = try point(params, x: "to_x", y: "to_y", bounds: bounds)
            try requireHit(start, target: target)
            try requireHit(end, target: target)
            guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left),
                  let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: end, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else {
                throw failure("event-unavailable", "无法创建拖动事件。")
            }
            events = [down, drag, up]
        default: throw failure("unsupported-action", "不支持该操作。")
        }
        if !events.isEmpty {
            // Re-check immediately before dispatch. Posting to the known PID
            // prevents a concurrent application switch from redirecting input.
            try requireFocus(target)
            method = "cg_event"
            for event in events { event.flags = eventFlags; event.postToPid(target.application.processIdentifier) }
        }
        var receipt: [String: Any] = ["session_id": sessionID, "request_id": requestID,
                                      "action": action, "outcome": outcome, "method": method,
                                      "based_on": suppliedSnapshot, "dispatched_at": timestamp(),
                                      "requires_observation": true]
        if let axError { receipt["ax_error"] = axError.rawValue }
        if action == "focus" { receipt["focused"] = isFocused(target) }
        receipts[requestID] = receipt
        payloads[requestID] = payload
        payloadBytes += payload.count
        invalidateSnapshot()
        model.phase = outcome == "verified" ? "验证通过" : outcome == "unknown" ? "结果待确认" : "等待结果验证"
        model.detail = "\(model.appName) · \(action) · 请重新 observe 验证结果"
        onStateChange?()
        return receipt
    }

    enum CaptureTitleMode: String {
        case exactTitle = "exact_title"
        case applicationSuffix = "application_suffix"
        case middleEllipsis = "middle_ellipsis"
    }

    /// SC can expose a document title, or its single middle-ellipsis display
    /// representation. This classifies text only; elision requires additional
    /// independent SC and AX window uniqueness checks before capture.
    static func captureTitleMode(_ captureTitle: String?, accessibilityTitle: String,
                                 applicationName: String?) -> CaptureTitleMode? {
        guard let captureTitle else { return nil }
        if captureTitle == accessibilityTitle { return .exactTitle }
        var fullTitle = accessibilityTitle
        if let applicationName, !applicationName.isEmpty {
            let suffix = " - " + applicationName
            if fullTitle.hasSuffix(suffix) {
                fullTitle = String(fullTitle.dropLast(suffix.count))
                if fullTitle == captureTitle { return .applicationSuffix }
            }
        }
        let full = Array(fullTitle.unicodeScalars)
        let displayed = Array(captureTitle.unicodeScalars)
        let ellipsis: Unicode.Scalar = "…"
        let positions = displayed.indices.filter { displayed[$0] == ellipsis }
        guard !full.contains(ellipsis), positions.count == 1, let split = positions.first,
              split > 0, split < displayed.count - 1,
              full.count > displayed.count else { return nil }
        let prefix = displayed[..<split]
        let suffix = displayed[(split + 1)...]
        guard full.starts(with: prefix), full.suffix(suffix.count).elementsEqual(suffix) else { return nil }
        return .middleEllipsis
    }

    static func captureTitleMatches(_ captureTitle: String?, accessibilityTitle: String,
                                    applicationName: String?) -> Bool {
        captureTitleMode(captureTitle, accessibilityTitle: accessibilityTitle, applicationName: applicationName) != nil
    }

    static func captureBoundsMatch(_ captured: CGRect, accessibility: CGRect) -> Bool {
        abs(captured.minX - accessibility.minX) < 2 && abs(captured.minY - accessibility.minY) < 2 &&
            abs(captured.width - accessibility.width) < 2 && abs(captured.height - accessibility.height) < 2
    }

    struct CaptureAXState {
        let title: String?
        let titleError: AXError
        let bounds: CGRect?
        let positionError: AXError
        let sizeError: AXError
        let readAt: TimeInterval
    }

    struct CaptureWindowEvidence {
        let windowID: CGWindowID
        let processID: pid_t
        let title: String?
        let bounds: CGRect
        let layer: Int
        let onScreen: Bool
    }

    struct CaptureAXWindowEvidence {
        let bounds: CGRect?
        let positionError: AXError
        let sizeError: AXError
        let isSelected: Bool
        var geometryReadable: Bool { bounds != nil && positionError == .success && sizeError == .success }
    }

    struct CaptureAXIdentity {
        let enumerationError: AXError
        let enumerationComplete: Bool
        let windows: [CaptureAXWindowEvidence]
    }

    enum CaptureSelection: Equatable {
        case matched(windowID: CGWindowID, mode: CaptureTitleMode, geometryCount: Int)
        case needsAXIdentity
        case rejected(String)
    }

    static func captureAXStatesAgree(_ before: CaptureAXState, _ after: CaptureAXState) -> Bool {
        func readable(_ state: CaptureAXState) -> Bool {
            state.title != nil && state.bounds != nil && state.titleError == .success &&
                state.positionError == .success && state.sizeError == .success
        }
        return readable(before) && readable(after) && before.title == after.title && before.bounds == after.bounds
    }

    /// A pure selection policy makes refusal cases testable without desktop access.
    /// Never narrow geometry uniqueness by title, layer, visibility, or a cached ID.
    static func selectCapture(processID: pid_t, applicationName: String?,
                              before: CaptureAXState, after: CaptureAXState,
                              windows: [CaptureWindowEvidence], boundWindowID: CGWindowID?,
                              axIdentity: CaptureAXIdentity? = nil) -> CaptureSelection {
        guard captureAXStatesAgree(before, after), let title = before.title, let bounds = before.bounds else {
            return .rejected("ax-state-unreadable-or-changed")
        }
        let geometry = windows.filter { $0.processID == processID && captureBoundsMatch($0.bounds, accessibility: bounds) }
        let classified = geometry.compactMap { window -> (CaptureWindowEvidence, CaptureTitleMode)? in
            guard let mode = captureTitleMode(window.title, accessibilityTitle: title, applicationName: applicationName) else { return nil }
            return (window, mode)
        }
        // An exact representation does not disambiguate another matching
        // elided representation at the same geometry: either could be the target.
        guard classified.count == 1, let (chosen, mode) = classified.first else {
            return .rejected("title-geometry-not-unique")
        }
        if let boundWindowID, boundWindowID != chosen.windowID { return .rejected("bound-window-id-changed") }
        if mode == .middleEllipsis {
            guard geometry.count == 1 else { return .rejected("sc-geometry-not-unique") }
            guard let axIdentity else { return .needsAXIdentity }
            guard axIdentity.enumerationError == .success, axIdentity.enumerationComplete,
                  axIdentity.windows.allSatisfy({ $0.geometryReadable }) else {
                return .rejected("ax-window-geometry-incomplete")
            }
            let matching = axIdentity.windows.filter { captureBoundsMatch($0.bounds!, accessibility: bounds) }
            guard matching.count == 1 else { return .rejected("ax-geometry-not-unique") }
            guard matching[0].isSelected else { return .rejected("ax-selected-window-not-confirmed") }
        }
        return .matched(windowID: chosen.windowID, mode: mode, geometryCount: geometry.count)
    }

    private func captureAXIdentity(_ target: WindowRecord) -> CaptureAXIdentity {
        let root = AXUIElementCreateApplication(target.application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &raw)
        guard error == .success, let elements = raw as? [AXUIElement] else {
            return CaptureAXIdentity(enumerationError: error, enumerationComplete: false, windows: [])
        }
        let deadline = Date().addingTimeInterval(0.75)
        var windows: [CaptureAXWindowEvidence] = []
        for element in elements {
            if windows.count >= 200 || Date() > deadline { break }
            AXUIElementSetMessagingTimeout(element, 0.1)
            let state = captureAXState(element)
            windows.append(CaptureAXWindowEvidence(bounds: state.bounds, positionError: state.positionError,
                                                    sizeError: state.sizeError, isSelected: CFEqual(element, target.element)))
        }
        return CaptureAXIdentity(enumerationError: error, enumerationComplete: windows.count == elements.count, windows: windows)
    }

    private func captureAXState(_ element: AXUIElement) -> CaptureAXState {
        var rawTitle: CFTypeRef?
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        let positionError = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPosition)
        let sizeError = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize)
        let titleError = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &rawTitle)
        var bounds: CGRect?
        if positionError == .success, sizeError == .success, let rawPosition, let rawSize,
           CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() {
            var origin = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin),
               AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
               origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
               size.width > 0, size.height > 0 {
                bounds = CGRect(origin: origin, size: size)
            }
        }
        return CaptureAXState(title: titleError == .success ? rawTitle as? String : nil, titleError: titleError, bounds: bounds,
                              positionError: positionError, sizeError: sizeError,
                              readAt: Date().timeIntervalSince1970)
    }

    /// Failure evidence is limited to the attached PID. Keep the actual CGFloat
    /// precision and AX errors so a missing value is distinguishable from empty text.
    static func captureMatchDiagnostics(processID: pid_t, applicationName: String?,
                                        before: CaptureAXState, after: CaptureAXState,
                                        windows: [CaptureWindowEvidence], queryMilliseconds: Double) -> [String: Any] {
        func rect(_ bounds: CGRect?) -> Any {
            guard let bounds else { return NSNull() }
            return ["x": Double(bounds.minX), "y": Double(bounds.minY),
                    "width": Double(bounds.width), "height": Double(bounds.height)]
        }
        func titleData(_ title: String?) -> [String: Any] {
            guard let title else { return ["title": NSNull(), "title_truncated": false] }
            let limited = boundedUTF8(title, maximumBytes: 512)
            return ["title": limited.text, "title_truncated": limited.truncated]
        }
        func axData(_ state: CaptureAXState) -> [String: Any] {
            var data = titleData(state.title)
            data["title_error"] = state.titleError.rawValue
            data["position_error"] = state.positionError.rawValue
            data["size_error"] = state.sizeError.rawValue
            data["bounds"] = rect(state.bounds)
            data["read_at_unix_seconds"] = state.readAt
            return data
        }
        let owned = windows.filter { $0.processID == processID }
        func titleMode(_ window: CaptureWindowEvidence) -> CaptureTitleMode? {
            guard before.titleError == .success, let title = before.title else { return nil }
            return captureTitleMode(window.title, accessibilityTitle: title, applicationName: applicationName)
        }
        func titleMatch(_ window: CaptureWindowEvidence) -> Bool {
            titleMode(window) != nil
        }
        func geometryMatch(_ window: CaptureWindowEvidence) -> Bool {
            before.bounds.map { captureBoundsMatch(window.bounds, accessibility: $0) } ?? false
        }
        // If an app exposes many auxiliary windows, retain the candidates most
        // relevant to this failure before applying the diagnostic output bound.
        let ordered = owned.sorted { left, right in
            let leftScore = (titleMatch(left) ? 1 : 0) + (geometryMatch(left) ? 2 : 0)
            let rightScore = (titleMatch(right) ? 1 : 0) + (geometryMatch(right) ? 2 : 0)
            return leftScore == rightScore ? left.windowID < right.windowID : leftScore > rightScore
        }
        let candidates: [[String: Any]] = ordered.prefix(32).map { window in
            var data = titleData(window.title)
            data["window_id"] = Int(window.windowID)
            data["pid"] = Int(window.processID)
            data["bounds"] = rect(window.bounds)
            data["layer"] = window.layer
            data["on_screen"] = window.onScreen
            data["exact_title_match"] = titleMode(window) == .exactTitle
            data["title_match"] = titleMatch(window)
            data["title_match_mode"] = titleMode(window)?.rawValue as Any? ?? NSNull()
            data["geometry_match"] = geometryMatch(window)
            if let reference = before.bounds {
                data["geometry_delta"] = ["x": Double(window.bounds.minX - reference.minX),
                                          "y": Double(window.bounds.minY - reference.minY),
                                          "width": Double(window.bounds.width - reference.width),
                                          "height": Double(window.bounds.height - reference.height)]
            }
            return data
        }
        return ["kind": "capture-match", "target_pid": Int(processID),
                "application_name": applicationName.map { boundedUTF8($0, maximumBytes: 512).text } as Any? ?? NSNull(),
                "ax_before": axData(before), "ax_after": axData(after),
                "query": ["exclude_desktop_windows": true, "on_screen_windows_only": false,
                          "duration_ms": queryMilliseconds],
                "counts": ["same_pid": owned.count,
                           "title_matches": owned.filter(titleMatch).count,
                           "geometry_matches": owned.filter(geometryMatch).count,
                           "matches": owned.filter { titleMatch($0) && geometryMatch($0) }.count,
                           "reported": candidates.count],
                "candidates_truncated": owned.count > candidates.count,
                "sc_candidates": candidates]
    }

    func screenshot(_ params: [String: Any]) async throws -> [String: Any] {
        let target = try resolveTarget()
        guard CGPreflightScreenCaptureAccess() else { throw failure("screen-recording-required", "请先开启屏幕录制权限。") }
        guard !captureBusy else { throw failure("capture-busy", "已有窗口截图正在执行。") }
        let initialAX = captureAXState(target.element)
        guard let initialBounds = initialAX.bounds else { throw failure("window-unavailable", "窗口没有有效的坐标。") }
        captureBusy = true
        defer { captureBusy = false }
        let capturedSession = sessionID
        let capturedEpoch = epoch
        let applicationName = target.application.localizedName
        let queryStarted = Date()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let queryMilliseconds = Date().timeIntervalSince(queryStarted) * 1000
        guard isActive, sessionID == capturedSession, epoch == capturedEpoch else { throw failure("cancelled", "截图期间会话已停止。") }
        let sameProcess = content.windows.filter { $0.owningApplication?.processID == target.application.processIdentifier }
        let evidence = sameProcess.map {
            CaptureWindowEvidence(windowID: $0.windowID, processID: target.application.processIdentifier,
                                  title: $0.title, bounds: $0.frame, layer: $0.windowLayer, onScreen: $0.isOnScreen)
        }
        var afterAX = captureAXState(target.element)
        var identity: CaptureAXIdentity?
        var selection = Self.selectCapture(processID: target.application.processIdentifier, applicationName: applicationName,
                                           before: initialAX, after: afterAX, windows: evidence, boundWindowID: capturedWindowID)
        if selection == .needsAXIdentity {
            identity = captureAXIdentity(target)
            afterAX = captureAXState(target.element)
            selection = Self.selectCapture(processID: target.application.processIdentifier, applicationName: applicationName,
                                           before: initialAX, after: afterAX, windows: evidence,
                                           boundWindowID: capturedWindowID, axIdentity: identity)
        }
        guard case let .matched(chosenID, matchMode, geometryCount) = selection,
              let chosen = sameProcess.first(where: { $0.windowID == chosenID }) else {
            var details = Self.captureMatchDiagnostics(processID: target.application.processIdentifier,
                                                       applicationName: applicationName,
                                                       before: initialAX, after: afterAX,
                                                       windows: evidence, queryMilliseconds: queryMilliseconds)
            if case let .rejected(reason) = selection { details["rejection_reason"] = reason }
            details["bound_cg_window_id"] = capturedWindowID.map { Int($0) } as Any? ?? NSNull()
            if let identity {
                let matches = identity.windows.filter {
                    $0.geometryReadable && Self.captureBoundsMatch($0.bounds!, accessibility: initialBounds)
                }
                details["ax_window_identity"] = ["enumeration_error": identity.enumerationError.rawValue,
                                                  "complete": identity.enumerationComplete,
                                                  "inspected": identity.windows.count,
                                                  "unreadable_geometry": identity.windows.filter { !$0.geometryReadable }.count,
                                                  "geometry_matches": matches.count,
                                                  "selected_matches": matches.filter { $0.isSelected }.count]
            }
            details["session_id"] = capturedSession
            details["snapshot_id"] = snapshotID
            details["window_id"] = target.id
            let message = selection == .rejected("bound-window-id-changed")
                ? "目标截图窗口标识已变化，请重新 attach。" : "无法唯一匹配目标窗口，拒绝截图。"
            throw DesktopFailure(code: "ambiguous-capture", message: message, details: details)
        }
        let maxWidth = min(2048, max(320, params["max_width"] as? Int ?? 1280))
        let scale = min(1, min(Double(maxWidth) / initialBounds.width, 2048 / initialBounds.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(initialBounds.width * scale))
        configuration.height = max(1, Int(initialBounds.height * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: chosen),
                                                              configuration: configuration)
        let confirmed = try resolveTarget()
        guard sessionID == capturedSession, epoch == capturedEpoch, CFEqual(confirmed.element, target.element),
              Self.captureAXStatesAgree(initialAX, captureAXState(confirmed.element)) else {
            throw failure("stale-capture", "截图期间窗口已变化，请重新截图。")
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw failure("capture-failed", "无法编码窗口截图。")
        }
        model.previewImage = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        model.previewError = nil
        model.lastCapture = Date()
        updateTarget(target, windowID: chosen.windowID)
        var match: [String: Any] = ["mode": matchMode.rawValue, "cg_window_id": Int(chosen.windowID),
                                    "sc_geometry_candidates": geometryCount, "ax_state_stable": true]
        if matchMode == .middleEllipsis {
            match["ax_geometry_candidates"] = 1
            match["ax_selected_window_confirmed"] = true
        }
        return ["session_id": capturedSession, "window_id": target.id,
                "capture_match": match,
                "mime_type": "image/png", "data": png.base64EncodedString(),
                "width": image.width, "height": image.height, "captured_at": timestamp(),
                "window_bounds": boundsData(initialBounds), "coordinate_space": "desktop_points",
                "scale_x": Double(image.width) / initialBounds.width,
                "scale_y": Double(image.height) / initialBounds.height,
                "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()]
    }

    @discardableResult
    func detach() -> [String: Any] {
        let previousSession = sessionID
        guard isActive else { return ["session_id": previousSession, "active": false, "detached": true] }
        lastAppName = model.appName
        lastWindowTitle = model.windowTitle
        lastNodeCount = model.nodeCount
        epoch += 1
        selected = nil
        sessionID = ""
        invalidateSnapshot()
        receipts.removeAll()
        payloads.removeAll()
        payloadBytes = 0
        capturedWindowID = nil
        model.isActive = false
        model.phase = "已停止"
        lastPhase = model.phase
        model.detail = "通用电脑控制会话已断开"
        if presentsTarget { interface.updateTargetFrame(nil) }
        onStateChange?()
        return ["session_id": previousSession, "active": false, "detached": true]
    }

    func handle(method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "computer_capabilities": return capabilities()
        case "computer_windows": return try windows(params)
        case "computer_attach": return try attach(params)
        case "computer_observe": return try observe(params)
        case "computer_act": return try act(params)
        case "computer_screenshot": return try await screenshot(params)
        case "computer_detach":
            // Check and release in one MainActor turn. A client cleaning up an
            // old session must never detach a newer client's selected window.
            if let expected = params["session_id"] {
                guard let expected = expected as? String, !expected.isEmpty else {
                    throw failure("invalid-request", "session_id 必须是非空字符串。")
                }
                guard isActive, expected == sessionID else {
                    throw failure("session-changed", "控制会话已变化，未停止其他会话。")
                }
            }
            return detach()
        default: throw failure("unknown-method", "未知通用电脑控制方法：\(method)")
        }
    }
}
