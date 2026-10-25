import AppKit
import Combine
import Darwin

/// Runs only the local build recorded by the installed app. The Python worker
/// owns its process session, log, and lock so replacing this app cannot kill it.
@MainActor
final class UpdateController {
    private struct BuildConfiguration: Decodable {
        let sourceDirectory: String
        let pythonExecutable: String
    }

    private struct UpdateReport: Decodable {
        let state: String
        let message: String
    }

    private let model: AppModel
    private let dataDirectory: URL
    private var polling: AnyCancellable?
    private var launcher: Process?
    private var lastReportData: Data?

    init(model: AppModel, dataDirectory: URL) {
        self.model = model
        self.dataDirectory = dataDirectory
        refresh()
        polling = Timer.publish(every: 0.6, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func start() {
        refresh()
        guard !model.isActive, !model.llmRunning else {
            model.updateMessage = "请先停止当前电脑控制会话，再更新应用。"
            return
        }
        guard !model.isUpdating, launcher == nil else {
            model.updateMessage = "更新正在进行中，完成后应用会自动重启。"
            return
        }
        do {
            guard let configurationURL = Bundle.main.url(forResource: "BuildConfiguration", withExtension: "json") else {
                throw failure("缺少本地更新配置，请从项目重新构建安装。")
            }
            let configuration = try JSONDecoder().decode(BuildConfiguration.self,
                                                        from: Data(contentsOf: configurationURL))
            guard configuration.sourceDirectory.hasPrefix("/"),
                  configuration.pythonExecutable.hasPrefix("/") else {
                throw failure("本地更新配置需要完整路径，请从项目重新构建安装。")
            }
            let source = URL(fileURLWithPath: configuration.sourceDirectory, isDirectory: true)
            let script = source.appendingPathComponent("scripts/update-native.py")
            let build = source.appendingPathComponent("scripts/build-native.sh")
            guard FileManager.default.fileExists(atPath: script.path),
                  FileManager.default.fileExists(atPath: build.path) else {
                throw failure("找不到本地源码：\(source.path)。恢复项目目录或重新构建安装后再更新。")
            }
            guard FileManager.default.isExecutableFile(atPath: configuration.pythonExecutable) else {
                throw failure("本地 Python 已不可用，请从项目重新构建安装。")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: configuration.pythonExecutable)
            process.arguments = [script.path, "--launch", "--source", source.path,
                                 "--data-directory", dataDirectory.path]
            process.currentDirectoryURL = source
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.launcher = nil
                    self.refresh()
                    if process.terminationStatus != 0 && !self.workerIsRunning() {
                        self.model.isUpdating = false
                        if self.model.updateMessage == "正在启动本地更新…" {
                            self.model.updateMessage = "无法启动更新，请检查本地源码与更新日志。"
                        }
                    }
                }
            }
            launcher = process
            model.isUpdating = true
            model.updateMessage = "正在启动本地更新…"
            try process.run()
        } catch {
            launcher = nil
            model.isUpdating = false
            model.updateMessage = error.localizedDescription
        }
    }

    private func refresh() {
        let reportURL = dataDirectory.appendingPathComponent("update-state.json")
        guard let data = try? Data(contentsOf: reportURL),
              let report = try? JSONDecoder().decode(UpdateReport.self, from: data) else { return }
        if data == lastReportData {
            if report.state == "running", model.isUpdating, launcher == nil, !workerIsRunning() {
                model.isUpdating = false
                model.updateMessage = "上次更新意外中断，可以重试。日志：\(dataDirectory.appendingPathComponent("update.log").path)"
            }
            return
        }
        lastReportData = data
        if report.state == "running" {
            model.isUpdating = workerIsRunning()
            model.updateMessage = model.isUpdating ? report.message
                : "上次更新意外中断，可以重试。日志：\(dataDirectory.appendingPathComponent("update.log").path)"
        } else {
            model.isUpdating = false
            model.updateMessage = report.message
        }
    }

    private func workerIsRunning() -> Bool {
        let descriptor = open(dataDirectory.appendingPathComponent("update.lock").path, O_RDWR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "DeskLoom.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
