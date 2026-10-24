import Foundation

enum AppStorage {
    /// Move the directory, preserving existing data/inodes, and retain a legacy
    /// link so older clients and an in-progress update worker still reach it.
    static func prepare(supportDirectory: URL? = nil) throws -> URL {
        let files = FileManager.default
        let support = supportDirectory ?? files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = support.appendingPathComponent("DeskLoom", isDirectory: true)
        let legacy = support.appendingPathComponent("ComputerUsePrototype", isDirectory: true)
        let currentExists = files.fileExists(atPath: current.path)
        let legacyExists = files.fileExists(atPath: legacy.path)
        let legacyLink = try? files.destinationOfSymbolicLink(atPath: legacy.path)
        if let legacyLink {
            let destination = URL(fileURLWithPath: legacyLink, relativeTo: support).standardizedFileURL
            guard destination.path == current.standardizedFileURL.path else {
                throw storageError("旧数据目录指向其他位置，无法自动迁移：\(legacy.path)")
            }
        } else if legacyExists {
            guard !currentExists else {
                throw storageError("DeskLoom 与旧版数据目录同时存在；已保留两份数据，请先确认迁移来源。")
            }
            try files.moveItem(at: legacy, to: current)
            do {
                try files.createSymbolicLink(atPath: legacy.path, withDestinationPath: current.path)
            } catch {
                // If link creation fails, leave the old application able to run.
                try files.moveItem(at: current, to: legacy)
                throw error
            }
        }
        try files.createDirectory(at: current, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        return current
    }

    private static func storageError(_ message: String) -> NSError {
        NSError(domain: "DeskLoom.Storage", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
