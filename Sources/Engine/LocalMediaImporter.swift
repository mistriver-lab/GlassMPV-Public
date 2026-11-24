import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// 支持 PhotosPicker 流式拷贝本地/相册大视频到沙盒临时区，避免全量载入内存导致 OOM
struct MovieFileTransferable: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let stagedURL = try LocalMediaImporter.stageTransferredFile(from: received.file)
            return MovieFileTransferable(url: stagedURL)
        }

        FileRepresentation(contentType: .video) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let stagedURL = try LocalMediaImporter.stageTransferredFile(from: received.file)
            return MovieFileTransferable(url: stagedURL)
        }
    }
}

/// 本地与 FileProvider 视频异步导入器（不阻塞主线程，兼容中文/空格/`#` 等特殊字符文件名）
enum LocalMediaImporter: Sendable {
    static var importsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GlassMPV_Imports", isDirectory: true)
    }

    static func preparePlayableLocalURL(
        from sourceURL: URL,
        isSecurityScoped: Bool
    ) async throws -> URL {
        guard sourceURL.isFileURL else {
            return sourceURL
        }

        return try await Task.detached(priority: .userInitiated) {
            let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
            let sourcePath = sourceURL.standardizedFileURL.path
            if sourcePath.hasPrefix(tempRoot), FileManager.default.isReadableFile(atPath: sourcePath) {
                return sourceURL
            }

            let didAccess = isSecurityScoped ? sourceURL.startAccessingSecurityScopedResource() : false
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            return try coordinatedCopyToImports(from: sourceURL)
        }.value
    }

    static func stageTransferredFile(from receivedURL: URL) throws -> URL {
        try ensureImportsDirectory()
        pruneOldImports(keepingLatest: 3)

        let destURL = makeUniqueDestinationURL(for: receivedURL)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: receivedURL, to: destURL)
        guard FileManager.default.isReadableFile(atPath: destURL.path) else {
            throw makeAccessError("相册导入副本不可读: \(destURL.lastPathComponent)")
        }
        return destURL
    }

    private static func coordinatedCopyToImports(from sourceURL: URL) throws -> URL {
        try ensureImportsDirectory()
        pruneOldImports(keepingLatest: 3)

        let destURL = makeUniqueDestinationURL(for: sourceURL)
        var coordinatorError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator()

        coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordinatorError) { readableURL in
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: readableURL, to: destURL)
            } catch {
                copyError = error
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        if let copyError {
            throw copyError
        }
        guard FileManager.default.isReadableFile(atPath: destURL.path) else {
            throw makeAccessError("拷贝后的本地文件不可读: \(destURL.lastPathComponent)")
        }
        return destURL
    }

    private static func ensureImportsDirectory() throws {
        try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
    }

    private static func makeUniqueDestinationURL(for sourceURL: URL) -> URL {
        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let rawBase = sourceURL.deletingPathExtension().lastPathComponent
        let sanitizedBase = sanitizeFilenameComponent(rawBase.isEmpty ? "video" : rawBase)
        let prefix = String(UUID().uuidString.prefix(8))
        let filename = "\(prefix)_\(sanitizedBase).\(ext)"
        return importsDirectory.appendingPathComponent(filename)
    }

    static func sanitizeFilenameComponent(_ raw: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:#?%\"<>|*")
        let parts = raw.components(separatedBy: disallowed)
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "_")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "media"
        }
        return String(trimmed.prefix(80))
    }

    private static func pruneOldImports(keepingLatest limit: Int) {
        guard limit >= 0,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: importsDirectory,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ),
              entries.count > limit else {
            return
        }

        let sorted = entries.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate
        }

        for obsolete in sorted.dropFirst(limit) {
            try? FileManager.default.removeItem(at: obsolete)
        }
    }

    private static func makeAccessError(_ message: String) -> NSError {
        NSError(
            domain: "GlassMPV.LocalMediaImporter",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
