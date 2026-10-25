import AppKit

/// Keeps window capabilities isolated while publishing one application status.
/// Switching the displayed target does not grant focus or reuse another window's
/// node/snapshot handles. All input still passes the owning engine's checks.
@MainActor
final class ComputerCoordinator {
    static let maximumSessions = 8

    private struct Session {
        let engine: any ComputerSessionEngine
        let model: AppModel
    }

    private let model: AppModel
    private let interface: InterfaceController
    private let discovery: any ComputerSessionEngine
    private var sessions: [String: Session] = [:]
    private var sessionOrder: [String] = []
    private var publishing = false
    private var hasPresentedSession = false
    private(set) var currentSessionID: String?
    var isActive: Bool { sessions.values.contains { $0.engine.isActive } }

    init(model: AppModel, interface: InterfaceController,
         discovery: (any ComputerSessionEngine)? = nil) {
        self.model = model
        self.interface = interface
        self.discovery = discovery ?? ComputerEngine(model: AppModel(), interface: interface)
        self.discovery.presentsTarget = false
        self.discovery.updateInProgress = { [weak model] in model?.isUpdating == true }
    }

    private func failure(_ code: String, _ message: String) -> DesktopFailure {
        DesktopFailure(code: code, message: message)
    }

    private func requireAvailable() throws {
        guard !model.isUpdating else { throw failure("update-in-progress", "更新期间不能控制电脑。") }
    }

    /// Preserve discovery IDs even when a query filters out another session's app.
    private func rememberSessionWindows() {
        for session in sessions.values { discovery.rememberWindows(from: session.engine) }
    }

    private func publishState() {
        guard !publishing else { return }
        publishing = true
        defer { publishing = false }
        for id in sessionOrder where sessions[id]?.engine.isActive != true {
            sessions[id]?.engine.onStateChange = nil
            sessions[id]?.engine.presentsTarget = false
            sessions.removeValue(forKey: id)
        }
        sessionOrder.removeAll { sessions[$0] == nil }
        if currentSessionID.flatMap({ sessions[$0] }) == nil { currentSessionID = sessionOrder.first }

        model.activeWindowCount = sessions.count
        model.isActive = !sessions.isEmpty
        // Keep the initial instructions until the first session, and avoid
        // resetting an already idle preview on every status request.
        guard !sessions.isEmpty || hasPresentedSession else { return }
        for (id, session) in sessions { session.engine.presentsTarget = id == currentSessionID }
        if let id = currentSessionID, let selected = sessions[id] {
            hasPresentedSession = true
            model.appName = selected.model.appName
            model.windowTitle = selected.model.windowTitle
            model.phase = selected.model.phase
            model.detail = selected.model.detail
            model.nodeCount = selected.model.nodeCount
            model.previewImage = selected.model.previewImage
            model.previewError = selected.model.previewError
            model.lastCapture = selected.model.lastCapture
        } else {
            hasPresentedSession = false
            model.phase = "已停止"
            model.detail = "所有窗口控制会话已断开"
            model.nodeCount = 0
            model.previewImage = nil
            model.previewError = nil
            model.lastCapture = nil
            interface.updateTargetFrame(nil)
        }
    }

    func capabilities() -> [String: Any] {
        publishState()
        var result = currentSessionID.flatMap { sessions[$0]?.engine.capabilities() } ?? discovery.capabilities()
        result["active"] = isActive
        result["controlled_window_count"] = sessions.count
        result["max_sessions"] = Self.maximumSessions
        result["supports_multiple_windows"] = true
        result["session_id_required_with_multiple_windows"] = true
        result["current_session_id"] = currentSessionID as Any? ?? NSNull()
        result["sessions"] = sessionOrder.compactMap { id -> [String: Any]? in
            guard let session = sessions[id] else { return nil }
            let status = session.engine.capabilities()
            return ["session_id": id, "window_id": session.engine.selectedWindowIdentifier as Any? ?? NSNull(),
                    "pid": status["pid"] ?? NSNull(), "bundle_id": status["bundle_id"] ?? "",
                    "app_name": status["app_name"] ?? "", "window_title": status["window_title"] ?? "",
                    "node_count": status["node_count"] ?? 0, "phase": status["phase"] ?? "",
                    "snapshot_id": status["snapshot_id"] ?? "", "active": session.engine.isActive,
                    "current": id == currentSessionID]
        }
        return result
    }

    func windows(_ params: [String: Any]) throws -> [String: Any] {
        try requireAvailable()
        rememberSessionWindows()
        return try discovery.windows(params)
    }

    func attach(_ params: [String: Any]) throws -> [String: Any] {
        try requireAvailable()
        publishState()
        if let windowID = params["window_id"] as? String,
           sessions.values.contains(where: { $0.engine.selectedWindowIdentifier == windowID }) {
            throw failure("window-already-attached", "此窗口已有控制会话，请复用现有 session_id。")
        }
        guard sessions.count < Self.maximumSessions else {
            throw failure("session-limit", "最多同时控制 \(Self.maximumSessions) 个窗口，请先断开不需要的窗口。")
        }
        rememberSessionWindows()
        let childModel = AppModel()
        let child = discovery.makeSessionEngine(model: childModel)
        child.presentsTarget = false
        child.updateInProgress = { [weak model] in model?.isUpdating == true }
        let attached = try child.attach(params)
        guard let windowID = child.selectedWindowIdentifier, !child.sessionIdentifier.isEmpty else {
            _ = child.detach()
            throw failure("invalid-session", "窗口连接未返回有效会话。")
        }
        // bundle_id/pid attachment also resolves through the shared registry.
        guard !sessions.values.contains(where: { $0.engine.selectedWindowIdentifier == windowID }) else {
            _ = child.detach()
            throw failure("window-already-attached", "此窗口已有控制会话，请复用现有 session_id。")
        }
        discovery.rememberWindows(from: child)
        let id = child.sessionIdentifier
        sessions[id] = Session(engine: child, model: childModel)
        sessionOrder.append(id)
        currentSessionID = id
        child.onStateChange = { [weak self] in self?.publishState() }
        publishState()
        var result = attached
        result["controlled_window_count"] = sessions.count
        return result
    }

    private func session(_ params: [String: Any], present: Bool = true) throws -> Session {
        publishState()
        let id: String
        if let supplied = params["session_id"] {
            guard let supplied = supplied as? String, !supplied.isEmpty else {
                throw failure("invalid-request", "session_id 必须是非空字符串。")
            }
            guard sessions[supplied]?.engine.isActive == true else {
                throw failure("session-changed", "控制会话已变化，未操作其他窗口。")
            }
            id = supplied
        } else {
            guard sessionOrder.count <= 1 else {
                throw failure("session-required", "同时控制多个窗口时必须提供目标 session_id。")
            }
            guard let single = sessionOrder.first else {
                throw failure("session-inactive", "没有已连接的窗口，请先 attach。")
            }
            id = single
        }
        let selected = sessions[id]!
        if present {
            currentSessionID = id
            publishState()
        }
        return selected
    }

    func observe(_ params: [String: Any]) throws -> [String: Any] {
        try requireAvailable()
        let selected = try session(params)
        defer { publishState() }
        return try selected.engine.observe(params)
    }

    func act(_ params: [String: Any]) throws -> [String: Any] {
        try requireAvailable()
        let selected = try session(params)
        defer { publishState() }
        return try selected.engine.act(params)
    }

    func screenshot(_ params: [String: Any]) async throws -> [String: Any] {
        try requireAvailable()
        let selected = try session(params)
        defer { publishState() }
        // The child verifies its own session and epoch after each await. Another
        // window may become current during capture without stealing its preview.
        return try await selected.engine.screenshot(params)
    }

    @discardableResult
    func detach(sessionID: String) throws -> [String: Any] {
        let selected = try session(["session_id": sessionID], present: false)
        selected.engine.onStateChange = nil
        var result = selected.engine.detach()
        selected.engine.presentsTarget = false
        sessions.removeValue(forKey: sessionID)
        sessionOrder.removeAll { $0 == sessionID }
        publishState()
        result["controlled_window_count"] = sessions.count
        return result
    }

    /// Explicit application Stop releases every window. RPC detach is scoped.
    @discardableResult
    func detach() -> [String: Any] {
        let ids = sessionOrder
        for id in ids { _ = try? detach(sessionID: id) }
        publishState()
        return ["active": false, "detached": true, "session_ids": ids, "controlled_window_count": 0]
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
            if params["session_id"] == nil, !isActive {
                return detach()
            }
            let selected = try session(params, present: false)
            return try detach(sessionID: selected.engine.sessionIdentifier)
        default: throw failure("unknown-method", "未知通用电脑控制方法：\(method)")
        }
    }
}
