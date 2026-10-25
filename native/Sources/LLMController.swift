import AppKit

/// Codex owns authentication; DeskLoom never reads or stores subscription tokens.
/// The Python worker serializes the model/tool loop off the main thread.
@MainActor
final class LLMController {
    private struct BuildConfiguration: Decodable {
        let pythonExecutable: String
    }
    private let model: AppModel
    private let computer: ComputerCoordinator
    private let dataDirectory: URL
    private var statusProcess: Process?
    private var loginProcess: Process?
    private var taskProcess: Process?
    private var taskID: UUID?
    private var ownedSessionIDs: Set<String> = []
    private var cancelled = false
    private var receivedTerminalEvent = false

    init(model: AppModel, computer: ComputerCoordinator, dataDirectory: URL) {
        self.model = model
        self.computer = computer
        self.dataDirectory = dataDirectory
        model.llmModel = UserDefaults.standard.string(forKey: "llmModel") ?? ""
        model.onLLMRefresh = { [weak self] in self?.refreshStatus() }
        model.onLLMLogin = { [weak self] in self?.login() }
        model.onLLMRefreshWindows = { [weak self] in self?.refreshWindows() }
        model.onLLMRun = { [weak self] in self?.start() }
        model.onLLMStop = { [weak self] in self?.stop() }
    }

    func refreshStatus() {
        guard statusProcess == nil, loginProcess == nil else { return }
        model.llmStatus = "正在检查本地 ChatGPT 登录状态…"
        do {
            statusProcess = try launch(["status"], timeout: 20, onJSON: { [weak self] value in
                guard let self else { return }
                self.model.llmAvailable = value["available"] as? Bool ?? false
                self.model.llmAuthenticated = value["authenticated"] as? Bool ?? false
                self.model.llmStatus = value["message"] as? String ?? "无法读取登录状态"
            }, onExit: { [weak self] code in
                guard let self else { return }
                self.statusProcess = nil
                if code != 0 {
                    self.model.llmAuthenticated = false
                    self.model.llmStatus = "登录状态检查失败，请重新检查或在终端运行 dlm llm status。"
                }
            })
        } catch {
            model.llmAvailable = false
            model.llmAuthenticated = false
            model.llmStatus = error.localizedDescription
        }
    }

    func refreshWindows() {
        guard !model.llmRunning else { return }
        do {
            let result = try computer.windows([:])
            model.llmWindows = (result["windows"] as? [[String: Any]] ?? []).compactMap { value in
                guard let id = value["window_id"] as? String, let pid = value["pid"] as? Int,
                      pid != Int(ProcessInfo.processInfo.processIdentifier),
                      value["minimized"] as? Bool != true else { return nil }
                return LLMWindow(id: id, pid: pid, title: value["title"] as? String ?? "",
                                 appName: value["app_name"] as? String ?? "应用")
            }
            // Only remove vanished windows; refreshing never grants a new target.
            model.llmSelectedWindowIDs.formIntersection(Set(model.llmWindows.map(\.id)))
            if result["complete"] as? Bool != true {
                model.llmOutput = "部分应用未响应，列表可能不完整；可以重新刷新窗口。"
            } else if model.llmWindows.isEmpty {
                model.llmOutput = "没有可控制的窗口，请先打开目标应用。"
            }
        } catch let error as DesktopFailure { model.llmOutput = error.message }
        catch { model.llmOutput = error.localizedDescription }
    }

    func login() {
        guard loginProcess == nil, statusProcess == nil, !model.llmRunning else { return }
        model.llmStatus = "请在浏览器中完成 ChatGPT 登录…"
        do {
            loginProcess = try launch(["login"], timeout: 300, onJSON: { _ in }, onExit: { [weak self] code in
                guard let self else { return }
                self.loginProcess = nil
                if code == 0 { self.refreshStatus() }
                else { self.model.llmStatus = "登录未完成。可重新登录，或在终端运行 dlm llm login。" }
            })
        } catch { model.llmStatus = error.localizedDescription }
    }

    func start() {
        guard taskProcess == nil, !model.llmRunning, !model.isActive, !model.isUpdating else {
            model.llmOutput = "请先停止当前控制会话或等待更新完成。"
            return
        }
        let windows = model.llmWindows.filter { model.llmSelectedWindowIDs.contains($0.id) }
        guard model.llmAuthenticated, !windows.isEmpty, windows.count <= 8,
              windows.count == model.llmSelectedWindowIDs.count,
              !model.llmPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            model.llmOutput = "请先登录 ChatGPT、选择窗口并填写任务。"
            return
        }
        let prompt = model.llmPrompt
        guard prompt.utf8.count <= 32_768 else {
            model.llmOutput = "任务描述过长，请缩短到 32 KB 以内。"
            return
        }
        var arguments = ["run", "--prompt-stdin", "--json"]
        for window in windows { arguments += ["--window", "\(window.pid):\(window.id)"] }
        let selectedModel = model.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedModel.isEmpty { arguments += ["--model", selectedModel] }
        UserDefaults.standard.set(selectedModel, forKey: "llmModel")
        let id = UUID()
        taskID = id
        ownedSessionIDs.removeAll()
        cancelled = false
        receivedTerminalEvent = false
        model.llmRunning = true
        model.llmOutput = "正在连接所选的 \(windows.count) 个窗口…"
        do {
            taskProcess = try launch(arguments, input: prompt, timeout: 660, onJSON: { [weak self] event in
                guard let self, self.taskID == id else { return }
                if let session = event["session_id"] as? String, !session.isEmpty {
                    self.ownedSessionIDs.insert(session)
                    if self.cancelled { self.releaseOwnedWindows() }
                }
                guard !self.cancelled else { return }
                if let message = event["message"] as? String, !message.isEmpty {
                    self.appendOutput(message)
                }
                if ["completed", "error"].contains(event["type"] as? String ?? "") {
                    self.receivedTerminalEvent = true
                }
            }, onExit: { [weak self] code in
                guard let self, self.taskID == id else { return }
                self.releaseOwnedWindows()
                self.taskProcess = nil
                self.taskID = nil
                self.model.llmRunning = false
                if self.cancelled { self.appendOutput("任务已停止。") }
                else if !self.receivedTerminalEvent {
                    self.appendOutput(code == 0 ? "任务结束，但未收到完成回执，请检查目标窗口。"
                                               : "任务中断，未自动重试。可运行 dlm llm status 检查连接。")
                }
            })
        } catch {
            taskID = nil
            taskProcess = nil
            model.llmRunning = false
            model.llmOutput = error.localizedDescription
        }
    }

    func stop() {
        guard !cancelled, let process = taskProcess, process.isRunning else { return }
        cancelled = true
        releaseOwnedWindows()
        appendOutput("正在停止任务并释放所有协作窗口…")
        process.terminate()
    }

    func shutdown() {
        stop()
        if let process = statusProcess, process.isRunning { process.terminate() }
        if let process = loginProcess, process.isRunning { process.terminate() }
    }

    private func appendOutput(_ message: String) {
        // Keep a bounded, useful run transcript in memory only.
        model.llmOutput = String((model.llmOutput + "\n" + message).suffix(16_000))
    }

    private func releaseOwnedWindows() {
        // Each detach atomically checks the session identity. Newer sessions
        // established for the same windows by another client remain untouched.
        for session in ownedSessionIDs { _ = try? computer.detach(sessionID: session) }
        ownedSessionIDs.removeAll()
    }

    private func launch(_ arguments: [String], input: String? = nil, timeout: TimeInterval,
                        onJSON: @escaping ([String: Any]) -> Void,
                        onExit: @escaping (Int32) -> Void) throws -> Process {
        guard let configURL = Bundle.main.url(forResource: "BuildConfiguration", withExtension: "json"),
              let script = Bundle.main.url(forResource: "dlm", withExtension: nil),
              let config = try? JSONDecoder().decode(BuildConfiguration.self, from: Data(contentsOf: configURL)),
              config.pythonExecutable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: config.pythonExecutable) else {
            throw NSError(domain: "DeskLoom.LLM", code: 1, userInfo:
                [NSLocalizedDescriptionKey: "缺少 LLM 启动配置，请从项目重新构建安装。"])
        }
        let process = Process()
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: config.pythonExecutable)
        process.arguments = [script.path, "llm"] + arguments
        process.currentDirectoryURL = dataDirectory
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        try process.run()
        DispatchQueue.global(qos: .userInitiated).async {
            if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
            try? stdin.fileHandleForWriting.close()
        }
        DispatchQueue.global(qos: .utility).async {
            // Drain stderr without exposing OAuth URLs, credentials or private window text.
            while let chunk = try? errors.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {}
            try? errors.fileHandleForReading.close()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var pending = Data()
            while let chunk = try? output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                pending.append(chunk)
                while let end = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: end)
                    if let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                        DispatchQueue.main.async { onJSON(value) }
                    }
                    pending.removeSubrange(...end)
                }
                if pending.count > 1_048_576 { process.terminate(); break }
            }
            try? output.fileHandleForReading.close()
            process.waitUntilExit()
            let code = process.terminationStatus
            DispatchQueue.main.async { onExit(code) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        return process
    }
}
