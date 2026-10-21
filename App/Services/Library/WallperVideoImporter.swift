import Foundation

/// Imports video wallpapers from the Wallper app's library at
/// `~/Library/Application Support/Wallper/Videos` into WallpaperMachine.
///
/// Wallper stores bare video files (no project folders) in that directory.
/// Each video is wrapped in a `project.json` manifest by `WallpaperImportService`
/// the same way a standalone video chosen through the import picker is.
enum WallperVideoImporter {
    /// The default path where Wallper keeps its downloaded videos.
    static var defaultSourceURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wallper/Videos", isDirectory: true)
    }

    /// Discovers every video file in `source` whose extension the import service
    /// recognises. Returns an empty array when the directory does not exist or
    /// holds no videos.
    static func discoverVideos(in source: URL = defaultSourceURL) -> [URL] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let children = try? fm.contentsOfDirectory(
            at: source, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        return children.filter { url in
            guard (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else {
                return false
            }
            return WallpaperImportService.videoExtensions.contains(url.pathExtension.lowercased())
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Imports every Wallper video found in `source` into `library`, using the
    /// given duplicate policy. Videos the library already holds are handled by
    /// the policy; the originals are never moved or modified.
    static func importAll(
        from source: URL = defaultSourceURL,
        into library: URL = ClientPaths.libraryURL,
        duplicates: WallpaperImportService.DuplicatePolicy = .skip,
        importer: WallpaperImportService = WallpaperImportService(),
        progress: @Sendable (String) async -> Void = { _ in }
    ) async throws -> WallpaperImportService.Report {
        let videos = discoverVideos(in: source)
        guard !videos.isEmpty else { return WallpaperImportService.Report() }
        return try await importer.importItems(videos, into: library, duplicates: duplicates, progress: progress)
    }
}
