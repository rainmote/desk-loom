// Build with ComputerEngine.swift + ComputerCoordinator.swift, not the app entrypoint.
// These tests never attach, focus, capture, or post any desktop input.
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

@MainActor
final class AppModel {
    var isActive = false
    var activeWindowCount = 0
    var isUpdating = false
    var appName = "未选择窗口"
    var phase = "idle"
    var detail = ""
    var windowTitle = ""
    var nodeCount = 0
    var previewImage: NSImage?
    var previewError: String?
    var lastCapture: Date?
}

@MainActor
final class InterfaceController {
    var clearCount = 0
    func updateTargetFrame(_ rect: CGRect?, windowID: CGWindowID? = nil, processID: pid_t? = nil,
                           sessionID: String? = nil) {
        if rect == nil { clearCount += 1 }
    }
    func updateControlledTarget(sessionID: String, frame: CGRect?, windowID: CGWindowID?, processID: pid_t) {}
    func removeControlledTarget(sessionID: String) {}
    func needsControlledTargetIdentity(sessionID: String) -> Bool { true }
}

/// A deterministic window backend exercises coordinator ownership/routing without
/// requesting desktop permissions or dispatching AX/CG events.
@MainActor
final class FakeComputerSessionEngine: ComputerSessionEngine {
    let model: AppModel
    var isActive = false
    var sessionIdentifier = ""
    var selectedWindowIdentifier: String?
    var presentsTarget = false
    var tracksTarget = false
    var onStateChange: (() -> Void)?
    var updateInProgress: (() -> Bool)?
    var children: [FakeComputerSessionEngine] = []
    var observed = 0
    var actions = 0
    var detached = 0
    var snapshot = ""
    var captureStarted: (() -> Void)?
    var captureContinuation: CheckedContinuation<Void, Never>?

    init(model: AppModel) { self.model = model }
    func capabilities() -> [String: Any] {
        ["active": isActive, "session_id": sessionIdentifier, "pid": 42,
         "app_name": model.appName, "window_title": model.windowTitle, "snapshot_id": snapshot]
    }
    func windows(_ params: [String: Any]) throws -> [String: Any] { ["windows": [], "complete": true] }
    func attach(_ params: [String: Any]) throws -> [String: Any] {
        let window = params["window_id"] as? String ?? "app-window"
        selectedWindowIdentifier = window
        sessionIdentifier = UUID().uuidString
        isActive = true
        model.isActive = true
        model.appName = "Fake app"
        model.windowTitle = window
        model.phase = "attached"
        return ["session_id": sessionIdentifier, "window_id": window, "active": true]
    }
    func observe(_ params: [String: Any]) throws -> [String: Any] {
        observed += 1
        snapshot = UUID().uuidString
        model.nodeCount = observed
        onStateChange?()
        return ["session_id": sessionIdentifier, "snapshot_id": snapshot]
    }
    func act(_ params: [String: Any]) throws -> [String: Any] {
        guard params["snapshot_id"] as? String == snapshot, !snapshot.isEmpty else {
            throw DesktopFailure(code: "stale-target", message: "Wrong snapshot")
        }
        actions += 1
        snapshot = ""
        return ["session_id": sessionIdentifier]
    }
    func screenshot(_ params: [String: Any]) async throws -> [String: Any] {
        let id = sessionIdentifier
        if captureStarted != nil {
            await withCheckedContinuation { continuation in
                captureContinuation = continuation
                captureStarted?()
            }
        }
        guard isActive, id == sessionIdentifier else { throw DesktopFailure(code: "cancelled", message: "Detached") }
        model.previewImage = NSImage(size: NSSize(width: 1, height: 1))
        model.lastCapture = Date()
        onStateChange?()
        return ["session_id": id]
    }
    func detach() -> [String: Any] {
        let id = sessionIdentifier
        detached += 1
        isActive = false
        model.isActive = false
        sessionIdentifier = ""
        onStateChange?()
        return ["session_id": id, "active": false, "detached": true]
    }
    func makeSessionEngine(model: AppModel) -> any ComputerSessionEngine {
        let child = FakeComputerSessionEngine(model: model)
        children.append(child)
        return child
    }
    func rememberWindows(from engine: any ComputerSessionEngine) {}
}

@main
struct NativeComputerUnitTests {
    @MainActor
    static func main() async throws {
        let model = AppModel()
        let interface = InterfaceController()
        let engine = ComputerEngine(model: model, interface: interface)
        let capabilities = engine.capabilities()
        precondition(capabilities["platform"] as? String == "macos")
        precondition(capabilities["controller_application_path"] as? String == Bundle.main.bundleURL.path)
        precondition(capabilities["coordinate_space"] as? String == "desktop_points")
        precondition(capabilities["snapshot_ttl_ms"] as? Int == 15_000)
        precondition(capabilities["automatic_action_retries"] as? Bool == false)
        precondition(capabilities["synthetic_input_requires_focus"] as? Bool == true)
        let actions = Set(capabilities["actions"] as? [String] ?? [])
        precondition(actions == Set(["focus", "click", "set_value", "type_text", "key", "scroll", "drag"]))
        // Real Chrome probe: AX and SC/CG bounds agree, but AX appends the app
        // name. Do not permit arbitrary suffixes, partial titles, or missing titles.
        let browserTitle = "DeskLoom Browser Lab · screenshot-probe-cdbf12c7"
        precondition(ComputerEngine.captureTitleMatches(browserTitle,
            accessibilityTitle: browserTitle + " - Google Chrome", applicationName: "Google Chrome"))
        precondition(ComputerEngine.captureTitleMatches(browserTitle,
            accessibilityTitle: browserTitle, applicationName: nil))
        precondition(!ComputerEngine.captureTitleMatches(browserTitle,
            accessibilityTitle: browserTitle + " - Other App", applicationName: "Google Chrome"))
        precondition(!ComputerEngine.captureTitleMatches(browserTitle,
            accessibilityTitle: browserTitle + " - Google Chrome", applicationName: nil))
        precondition(!ComputerEngine.captureTitleMatches("DeskLoom Browser Lab",
            accessibilityTitle: browserTitle + " - Google Chrome", applicationName: "Google Chrome"))
        precondition(!ComputerEngine.captureTitleMatches(nil,
            accessibilityTitle: browserTitle + " - Google Chrome", applicationName: "Google Chrome"))
        precondition(!ComputerEngine.captureTitleMatches("",
            accessibilityTitle: browserTitle + " - Google Chrome", applicationName: "Google Chrome"))
        precondition(!ComputerEngine.captureTitleMatches(browserTitle,
            accessibilityTitle: browserTitle + " - Google Chrome - Google Chrome", applicationName: "Google Chrome"))
        let captureBounds = CGRect(x: 1288.125, y: 51.0625, width: 1251.25, height: 1368.5)
        // Production failure: SC middle-elides the token, while AX preserves it.
        let fullBrowserTitle = "DeskLoom Browser Lab · 21cad08262a0410e9a499e3194cd02ae"
        let elidedBrowserTitle = "DeskLoom Browser Lab · 21ca…8262a0410e9a499e3194cd02ae"
        func titleMode(_ shown: String?, _ full: String, app: String? = "Google Chrome") -> ComputerEngine.CaptureTitleMode? {
            ComputerEngine.captureTitleMode(shown, accessibilityTitle: full, applicationName: app)
        }
        precondition(titleMode(fullBrowserTitle, fullBrowserTitle) == .exactTitle)
        precondition(titleMode(fullBrowserTitle, fullBrowserTitle + " - Google Chrome") == .applicationSuffix)
        precondition(titleMode(elidedBrowserTitle, fullBrowserTitle + " - Google Chrome") == .middleEllipsis)
        precondition(titleMode("任务🙂…完成🧪", "任务🙂中间完成🧪 - Google Chrome") == .middleEllipsis)
        precondition(titleMode("a…z", "a🙂🧪z", app: nil) == .middleEllipsis)
        // Literal ellipses remain valid exact text, but are never fuzzy anchors.
        precondition(titleMode("a…z", "a…z", app: nil) == .exactTitle)
        precondition(titleMode("a…z", "a…z - Google Chrome") == .applicationSuffix)
        for (shown, full) in [("a…z", "a…middlez"), ("a…z", "abz"), ("a…z", "a🙂z"),
                              ("…z", "abcz"), ("a…", "abcz"), ("…", "abcz"),
                              ("a…b…z", "a123b456z"), ("a...z", "a123z"),
                              ("a…z", "xa123z"), ("a…z", "a123zx"), ("abc…bcd", "abcd")] {
            precondition(titleMode(shown, full, app: nil) == nil, "Unexpected elision match: \(shown) / \(full)")
        }
        func state(_ title: String? = fullBrowserTitle + " - Google Chrome", titleError: AXError = .success,
                   bounds: CGRect? = captureBounds, positionError: AXError = .success, sizeError: AXError = .success)
            -> ComputerEngine.CaptureAXState {
            ComputerEngine.CaptureAXState(title: title, titleError: titleError, bounds: bounds,
                positionError: positionError, sizeError: sizeError, readAt: 123)
        }
        func window(_ id: CGWindowID = 7, title: String? = elidedBrowserTitle,
                    bounds: CGRect = captureBounds, pid: pid_t = 42, layer: Int = 0, onScreen: Bool = true)
            -> ComputerEngine.CaptureWindowEvidence {
            ComputerEngine.CaptureWindowEvidence(windowID: id, processID: pid, title: title,
                bounds: bounds, layer: layer, onScreen: onScreen)
        }
        func axWindow(bounds: CGRect? = captureBounds, selected: Bool = true,
                      positionError: AXError = .success, sizeError: AXError = .success)
            -> ComputerEngine.CaptureAXWindowEvidence {
            ComputerEngine.CaptureAXWindowEvidence(bounds: bounds, positionError: positionError,
                sizeError: sizeError, isSelected: selected)
        }
        func identity(_ windows: [ComputerEngine.CaptureAXWindowEvidence], complete: Bool = true,
                      error: AXError = .success) -> ComputerEngine.CaptureAXIdentity {
            ComputerEngine.CaptureAXIdentity(enumerationError: error, enumerationComplete: complete, windows: windows)
        }
        let defaultState = state()
        let defaultWindows = [window()]
        func select(_ windows: [ComputerEngine.CaptureWindowEvidence] = defaultWindows,
                    boundID: CGWindowID? = nil, before: ComputerEngine.CaptureAXState = defaultState,
                    after: ComputerEngine.CaptureAXState = defaultState, ax: ComputerEngine.CaptureAXIdentity? = nil)
            -> ComputerEngine.CaptureSelection {
            ComputerEngine.selectCapture(processID: 42, applicationName: "Google Chrome", before: before, after: after,
                windows: windows, boundWindowID: boundID, axIdentity: ax)
        }
        let uniqueAX = identity([axWindow()])
        precondition(select() == .needsAXIdentity)
        precondition(select(ax: uniqueAX) == .matched(windowID: 7, mode: .middleEllipsis, geometryCount: 1))
        precondition(select(boundID: 7, ax: uniqueAX) == .matched(windowID: 7, mode: .middleEllipsis, geometryCount: 1))
        precondition(select([window(title: fullBrowserTitle)]) == .matched(windowID: 7, mode: .applicationSuffix, geometryCount: 1))
        precondition(select([window(title: fullBrowserTitle + " - Google Chrome")]) == .matched(windowID: 7, mode: .exactTitle, geometryCount: 1))
        // Existing CG identity constrains every representation; it cannot switch
        // to another window simply because its title and geometry look plausible.
        for title in [fullBrowserTitle, fullBrowserTitle + " - Google Chrome", elidedBrowserTitle] {
            precondition(select([window(title: title)], boundID: 8, ax: uniqueAX) == .rejected("bound-window-id-changed"))
        }
        precondition(select([window(), window(8, title: "different full title", layer: 99, onScreen: false)], ax: uniqueAX)
            == .rejected("sc-geometry-not-unique"))
        precondition(select([window(), window(8)], ax: uniqueAX) == .rejected("title-geometry-not-unique"))
        precondition(select([window(), window(8, pid: 99)], ax: uniqueAX)
            == .matched(windowID: 7, mode: .middleEllipsis, geometryCount: 1))
        precondition(select([window(), window(8, bounds: captureBounds.offsetBy(dx: 20, dy: 0))], ax: uniqueAX)
            == .matched(windowID: 7, mode: .middleEllipsis, geometryCount: 1))
        precondition(select([window(title: fullBrowserTitle), window(8)], ax: uniqueAX)
            == .rejected("title-geometry-not-unique"))
        precondition(select([window(title: fullBrowserTitle + " - Google Chrome"), window(8)], ax: uniqueAX)
            == .rejected("title-geometry-not-unique"))
        precondition(select(ax: identity([axWindow(), axWindow(selected: false)])) == .rejected("ax-geometry-not-unique"))
        precondition(select(ax: identity([])) == .rejected("ax-geometry-not-unique"))
        precondition(select(ax: identity([axWindow(selected: false)])) == .rejected("ax-selected-window-not-confirmed"))
        for incomplete in [identity([axWindow()], complete: false), identity([axWindow()], error: .cannotComplete),
                           identity([axWindow(), axWindow(bounds: nil, selected: false)]),
                           identity([axWindow(), axWindow(selected: false, positionError: .cannotComplete)]),
                           identity([axWindow(), axWindow(selected: false, sizeError: .cannotComplete)])] {
            precondition(select(ax: incomplete) == .rejected("ax-window-geometry-incomplete"))
        }
        for unreadable in [state(nil), state(titleError: .cannotComplete), state(bounds: nil),
                           state(positionError: .cannotComplete), state(sizeError: .cannotComplete)] {
            precondition(select(before: unreadable, after: unreadable, ax: uniqueAX) == .rejected("ax-state-unreadable-or-changed"))
        }
        precondition(select(after: state("different"), ax: uniqueAX) == .rejected("ax-state-unreadable-or-changed"))
        precondition(select(after: state(bounds: captureBounds.offsetBy(dx: 0.01, dy: 0)), ax: uniqueAX)
            == .rejected("ax-state-unreadable-or-changed"))
        precondition(select([window(title: "")], before: state(nil), after: state(nil))
            == .rejected("ax-state-unreadable-or-changed"))
        let captureBefore = ComputerEngine.CaptureAXState(title: browserTitle + " - Google Chrome", titleError: .success,
            bounds: captureBounds, positionError: .success, sizeError: .success, readAt: 123.25)
        let captureAfter = ComputerEngine.CaptureAXState(title: nil, titleError: .cannotComplete,
            bounds: nil, positionError: .cannotComplete, sizeError: .cannotComplete, readAt: 123.75)
        let ownedEvidence = ComputerEngine.CaptureWindowEvidence(windowID: 7, processID: 42,
            title: browserTitle, bounds: captureBounds, layer: 0, onScreen: true)
        let foreignEvidence = ComputerEngine.CaptureWindowEvidence(windowID: 8, processID: 99,
            title: "DO NOT DISCLOSE OTHER APP", bounds: captureBounds, layer: 0, onScreen: true)
        let diagnostics = ComputerEngine.captureMatchDiagnostics(processID: 42, applicationName: "Google Chrome",
            before: captureBefore, after: captureAfter, windows: [foreignEvidence, ownedEvidence], queryMilliseconds: 0.125)
        let diagnosticData = try JSONSerialization.data(withJSONObject: diagnostics)
        precondition(!String(decoding: diagnosticData, as: UTF8.self).contains("DO NOT DISCLOSE"))
        let counts = diagnostics["counts"] as! [String: Int]
        precondition(counts["same_pid"] == 1 && counts["matches"] == 1 && counts["reported"] == 1)
        let axAfter = diagnostics["ax_after"] as! [String: Any]
        precondition(axAfter["title"] is NSNull && axAfter["title_error"] as? Int32 == AXError.cannotComplete.rawValue)
        let loggedCandidates = diagnostics["sc_candidates"] as! [[String: Any]]
        let loggedBounds = loggedCandidates[0]["bounds"] as! [String: Double]
        precondition(loggedBounds["x"] == 1288.125 && loggedBounds["y"] == 51.0625)
        precondition(loggedCandidates[0]["title_match"] as? Bool == true)
        precondition(loggedCandidates[0]["exact_title_match"] as? Bool == false)
        let manyWindows = (0..<100).map { index in
            ComputerEngine.CaptureWindowEvidence(windowID: CGWindowID(index), processID: 42,
                title: String(repeating: "中", count: 1000), bounds: captureBounds, layer: index, onScreen: false)
        }
        let boundedDiagnostics = ComputerEngine.captureMatchDiagnostics(processID: 42, applicationName: "Google Chrome",
            before: captureBefore, after: captureBefore, windows: manyWindows, queryMilliseconds: 1)
        let boundedCandidates = boundedDiagnostics["sc_candidates"] as! [[String: Any]]
        precondition(boundedCandidates.count == 32 && boundedDiagnostics["candidates_truncated"] as? Bool == true)
        precondition(boundedCandidates.allSatisfy { ($0["title"] as! String).utf8.count <= 512 })
        precondition((boundedDiagnostics["counts"] as! [String: Int])["same_pid"] == 100)
        for text in ["", "中文输入", String(repeating: "a", count: 19) + "🙂end", String(repeating: "👨‍👩‍👧‍👦", count: 30)] {
            let chunks = ComputerEngine.unicodeEventChunks(text)
            precondition(chunks.allSatisfy { !$0.isEmpty && $0.count <= 20 })
            precondition(chunks.flatMap { $0 } == Array(text.utf16))
            precondition(chunks.map { String(decoding: $0, as: UTF16.self) }.joined() == text)
            for byteLimit in 0...25 {
                let clipped = ComputerEngine.boundedUTF8(text, maximumBytes: byteLimit)
                precondition(clipped.text.utf8.count <= byteLimit)
                precondition(text.unicodeScalars.starts(with: clipped.text.unicodeScalars))
                precondition(clipped.truncated == (text.utf8.count > byteLimit))
            }
        }
        // Large pages stay below the memory writer's limit even with UTF-8 and
        // six-byte JSON escapes; no AX or desktop calls are needed for this test.
        var budget = ComputerEngine.SemanticTextBudget()
        let oversized = String(repeating: "中🙂\u{1}", count: 4096)
        var clippedValues: [String] = []
        for _ in 0..<1000 { clippedValues.append(budget.take(oversized, maximumBytes: 16_384).text) }
        precondition(clippedValues.reduce(0) { $0 + $1.utf8.count } <= 1_048_576)
        precondition(budget.truncated && budget.remaining <= 3)
        let encodedValues = try JSONSerialization.data(withJSONObject: clippedValues)
        precondition(encodedValues.count < 8 * 1024 * 1024)
        let escapedWorstCase = String(repeating: "\u{1}", count: 1_048_576)
        let escapedPayload = try JSONSerialization.data(withJSONObject: [escapedWorstCase])
        precondition(escapedPayload.count < 8 * 1024 * 1024)
        let oversizedLabel = ComputerEngine.boundedUTF8(String(repeating: "🙂", count: 9000), maximumBytes: 8192)
        precondition(oversizedLabel.truncated && oversizedLabel.text.utf16.count <= 8192)
        for action in actions {
            expect("invalid-request") { _ = try engine.act(["action": action]) }
            expect("stale-target") {
                _ = try engine.act(["action": action, "request_id": "forged-\(action)",
                                    "snapshot_id": "forged", "node_id": "n0", "value": "NEVER DISPATCHED",
                                    "text": "NEVER DISPATCHED", "x": 1.0, "y": 1.0])
            }
        }
        precondition(!engine.isActive)
        // An unattached engine exposes no target or stale action capabilities.
        let genericStatus = engine.capabilities()
        precondition(genericStatus["active"] as? Bool == false)
        precondition(genericStatus["bundle_id"] as? String == "")
        precondition(genericStatus["app_name"] as? String == "")
        precondition(genericStatus["window_title"] as? String == "")
        precondition(genericStatus["node_count"] as? Int == 0)
        precondition(genericStatus["session_id"] as? String == "")
        precondition(genericStatus["snapshot_id"] as? String == "")
        precondition(genericStatus["phase"] as? String == "待连接")
        let detached = engine.detach()
        precondition(detached["active"] as? Bool == false)
        precondition(!model.isActive)
        precondition(interface.clearCount == 0)
        for invalidSession: Any in ["stale-session", "", 42, NSNull()] {
            do {
                _ = try await engine.handle(method: "computer_detach", params: ["session_id": invalidSession])
                preconditionFailure("Invalid ownership token accepted")
            } catch let error as DesktopFailure {
                precondition(error.code == ((invalidSession as? String) == "stale-session" ? "session-changed" : "invalid-request"))
            }
            precondition(!model.isActive)
            precondition(interface.clearCount == 0)
        }
        let legacyDetach = try await engine.handle(method: "computer_detach", params: [:])
        precondition(legacyDetach["detached"] as? Bool == true)
        precondition(!model.isActive && interface.clearCount == 0)
        do {
            _ = try await engine.handle(method: "computer_eval", params: [:])
            preconditionFailure("Arbitrary native method accepted")
        } catch let error as DesktopFailure { precondition(error.code == "unknown-method") }
        try await coordinatorTests()
        print("NativeComputerUnitTests: passed; no desktop input dispatched")
    }

    @MainActor
    static func coordinatorTests() async throws {
        let model = AppModel()
        let interface = InterfaceController()
        let discovery = FakeComputerSessionEngine(model: AppModel())
        let coordinator = ComputerCoordinator(model: model, interface: interface, discovery: discovery)
        let attachedA = try coordinator.attach(["window_id": "A"])
        let idA = attachedA["session_id"] as! String
        precondition(model.activeWindowCount == 1 && model.isActive)
        let observedA = try coordinator.observe([:]) // legacy single-window request
        let snapshotA = observedA["snapshot_id"] as! String
        let attachedB = try coordinator.attach(["window_id": "B"])
        let idB = attachedB["session_id"] as! String
        precondition(idA != idB && model.activeWindowCount == 2)
        precondition(model.windowTitle == "B" && coordinator.currentSessionID == idB)
        precondition(!discovery.children[0].presentsTarget && discovery.children[1].presentsTarget)
        precondition(discovery.children.allSatisfy { $0.tracksTarget })
        expect("window-already-attached") { _ = try coordinator.attach(["window_id": "A"]) }
        precondition(discovery.children.count == 2 && discovery.children[0].snapshot == snapshotA)
        expect("session-required") { _ = try coordinator.observe([:]) }
        expect("session-required") { _ = try coordinator.act(["snapshot_id": snapshotA]) }
        for invalid: Any in ["", 7, NSNull()] {
            expect("invalid-request") { _ = try coordinator.observe(["session_id": invalid]) }
        }
        expect("session-changed") { _ = try coordinator.observe(["session_id": "stale"]) }
        expect("session-changed") { _ = try coordinator.detach(sessionID: "stale") }
        do {
            _ = try await coordinator.handle(method: "computer_detach", params: [:])
            preconditionFailure("Unscoped multi-window detach accepted")
        } catch let error as DesktopFailure { precondition(error.code == "session-required") }
        precondition(discovery.children.allSatisfy { $0.detached == 0 })
        let observedB = try coordinator.observe(["session_id": idB])
        expect("stale-target") { _ = try coordinator.act(["session_id": idB, "snapshot_id": snapshotA]) }
        precondition(discovery.children[1].actions == 0)
        _ = try coordinator.act(["session_id": idA, "snapshot_id": snapshotA])
        precondition(discovery.children[0].actions == 1 && discovery.children[1].actions == 0)
        precondition(discovery.children[1].snapshot == observedB["snapshot_id"] as? String)
        precondition(model.windowTitle == "A" && coordinator.currentSessionID == idA)
        let capabilities = coordinator.capabilities()
        precondition(capabilities["controlled_window_count"] as? Int == 2)
        precondition(capabilities["supports_multiple_windows"] as? Bool == true)
        precondition((capabilities["sessions"] as! [[String: Any]]).map { $0["session_id"] as! String } == [idA, idB])

        // A capture completing after B becomes current must not overwrite B's preview.
        let childA = discovery.children[0]
        let started = Task { @MainActor in
            while childA.captureContinuation == nil { await Task.yield() }
        }
        childA.captureStarted = {}
        let capture = Task { @MainActor in try await coordinator.screenshot(["session_id": idA]) }
        await started.value
        _ = try coordinator.observe(["session_id": idB])
        childA.captureContinuation?.resume()
        _ = try await capture.value
        precondition(coordinator.currentSessionID == idB && model.previewImage == nil)
        precondition(childA.model.previewImage != nil)

        // Closing a background target removes just that session and updates count.
        _ = childA.detach()
        precondition(model.activeWindowCount == 1 && model.isActive)
        precondition(coordinator.currentSessionID == idB && discovery.children[1].isActive)
        expect("session-changed") { _ = try coordinator.detach(sessionID: idA) }
        let singleAfterClosure = try coordinator.observe([:])
        precondition(singleAfterClosure["session_id"] as? String == idB)
        _ = try coordinator.detach(sessionID: idB)
        precondition(model.activeWindowCount == 0 && !model.isActive)

        // Same-app selector duplicates cannot reset the already attached engine.
        let sameApp = try coordinator.attach(["pid": 42])
        let sameAppID = sameApp["session_id"] as! String
        expect("window-already-attached") { _ = try coordinator.attach(["pid": 42]) }
        precondition(discovery.children.last?.tracksTarget == false)
        precondition(model.activeWindowCount == 1 && coordinator.currentSessionID == sameAppID)
        for index in 1..<ComputerCoordinator.maximumSessions { _ = try coordinator.attach(["window_id": "limit-\(index)"]) }
        precondition(model.activeWindowCount == 8)
        expect("session-limit") { _ = try coordinator.attach(["window_id": "overflow"]) }
        model.isUpdating = true
        expect("update-in-progress") { _ = try coordinator.observe(["session_id": sameAppID]) }
        precondition(discovery.children.last?.updateInProgress?() == true)
        _ = coordinator.detach()
        precondition(model.activeWindowCount == 0 && !coordinator.isActive)
        model.isUpdating = false

        // Status/count derive exclusively from attached sessions, even if a
        // stale presentation retained values after asynchronous work ended.
        model.isActive = true
        model.activeWindowCount = 99
        let clearCount = interface.clearCount
        _ = coordinator.detach()
        _ = try await coordinator.handle(method: "computer_detach", params: [:])
        _ = coordinator.capabilities()
        expect("session-changed") { _ = try coordinator.detach(sessionID: sameAppID) }
        precondition(!model.isActive && model.activeWindowCount == 0)
        precondition(interface.clearCount == clearCount)
        _ = try coordinator.attach(["window_id": "next-window"])
        precondition(model.isActive && model.activeWindowCount == 1)
        _ = coordinator.detach()
    }

    @MainActor
    static func expect(_ code: String, _ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected \(code)") }
        catch let error as DesktopFailure { precondition(error.code == code, "Expected \(code), got \(error.code)") }
        catch { preconditionFailure("Unexpected error: \(error)") }
    }
}
