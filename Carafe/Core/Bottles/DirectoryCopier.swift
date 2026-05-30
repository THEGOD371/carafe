import Foundation

/// Recursive directory copy that reports byte-level progress.
/// Wine prefixes are multi-GB and dominated by lots of small files,
/// so per-item updates feel responsive while keeping update volume sane.
enum DirectoryCopier {

    struct Progress: Sendable, Equatable {
        let bytesCopied: Int64
        let totalBytes: Int64
        let currentRelativePath: String?
    }

    /// Two-pass copy:
    ///   1. Walk the source tree to collect items + sum file sizes.
    ///   2. Re-walk, creating directories / symlinks / copying files,
    ///      emitting a Progress after every file.
    ///
    /// Runs on a detached priority-userInitiated task so the calling
    /// MainActor isn't blocked by IO. Honours Task cancellation
    /// between items.
    static func copy(
        from source: URL,
        to destination: URL,
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default

            // --- Pass 1: enumerate, sum logical bytes ---
            //
            // .fileSizeKey is the logical size that matches what
            // Finder shows. For sparse files it overstates disk
            // usage; wine prefixes rarely have sparse files so this
            // is a reasonable proxy and avoids the platform-specific
            // .totalFileAllocatedSizeKey weirdness.
            guard let pass1 = fm.enumerator(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: nil
            ) else {
                throw BottleError.copyFailed("Couldn't open \(source.path)")
            }

            // Use nextObject() in a while-let because `for ... in
            // enumerator` is not async-safe under Swift 6 (the
            // enumerator's makeIterator() is main-actor isolated).
            var totalBytes: Int64 = 0
            while let url = pass1.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true { continue }
                if let size = values.fileSize { totalBytes += Int64(size) }
            }

            onProgress(.init(bytesCopied: 0, totalBytes: totalBytes, currentRelativePath: nil))

            // --- Pass 2: create + copy ---

            try fm.createDirectory(at: destination, withIntermediateDirectories: true)

            // FRAGILITY: FileManager.enumerator order is documented as
            // unspecified. In practice it's pre-order DFS on Darwin so
            // parents come before children, but we set
            // `withIntermediateDirectories: true` defensively in case
            // that ever changes.
            guard let pass2 = fm.enumerator(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: nil
            ) else {
                throw BottleError.copyFailed("Couldn't re-open \(source.path) for copy")
            }

            var bytesCopied: Int64 = 0
            let sourceComponents = source.pathComponents

            while let url = pass2.nextObject() as? URL {
                try Task.checkCancellation()

                // Compute path relative to source root.
                let relativeComponents = Array(url.pathComponents.dropFirst(sourceComponents.count))
                let relativePath = relativeComponents.joined(separator: "/")
                let destURL = relativeComponents.reduce(destination) { $0.appendingPathComponent($1) }

                let values = try url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
                )

                do {
                    if values.isSymbolicLink == true {
                        // Preserve the symlink as-is. Wine prefixes
                        // can contain links pointing into the user's
                        // home (e.g., My Documents → ~/Documents).
                        let target = try fm.destinationOfSymbolicLink(atPath: url.path)
                        try? fm.removeItem(at: destURL)
                        try fm.createSymbolicLink(atPath: destURL.path, withDestinationPath: target)
                    } else if values.isDirectory == true {
                        try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                    } else {
                        try fm.createDirectory(
                            at: destURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try fm.copyItem(at: url, to: destURL)
                        if let size = values.fileSize { bytesCopied += Int64(size) }
                        onProgress(.init(
                            bytesCopied: bytesCopied,
                            totalBytes: totalBytes,
                            currentRelativePath: relativePath
                        ))
                    }
                } catch {
                    throw BottleError.copyFailed(
                        "While copying \(relativePath): \(error.localizedDescription)"
                    )
                }
            }

            // Final tick — round to 100% even if size summing was a
            // few KB off (rounding in fileSizeKey).
            onProgress(.init(
                bytesCopied: max(bytesCopied, totalBytes),
                totalBytes: totalBytes,
                currentRelativePath: nil
            ))
        }.value
    }

    /// Compute the total logical size of a directory. Used by
    /// BottleManager to populate the "Size on disk" column without
    /// blocking the main actor.
    static func size(of directory: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let walker = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: nil
            ) else { return Int64(0) }

            var total: Int64 = 0
            while let url = walker.nextObject() as? URL {
                guard let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .isSymbolicLinkKey]
                ) else { continue }
                if values.isSymbolicLink == true { continue }
                if let size = values.fileSize { total += Int64(size) }
            }
            return total
        }.value
    }
}
