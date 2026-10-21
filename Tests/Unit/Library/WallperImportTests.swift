import Darwin
import XCTest

@testable import WallpaperMachine

final class WallperImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Wallper-import-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func wallperFolder(in root: URL) -> URL {
        root.appendingPathComponent("Library/Application Support/Wallper/Videos", isDirectory: true)
    }

    private func video(_ name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("content of \(name)".utf8).write(to: folder.appendingPathComponent(name))
    }

    // MARK: Discovery

    func testNoDiscoveryWhenTheFolderIsMissing() throws {
        let folder = wallperFolder(in: root)
        XCTAssertEqual(WallperVideoImporter.discoverVideos(in: folder), [])
    }

    func testNoDiscoveryWhenTheFolderIsAFile() throws {
        let folder = wallperFolder(in: root)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: folder)
        XCTAssertEqual(WallperVideoImporter.discoverVideos(in: folder), [])
    }

    func testDiscoversEveryRecognisedVideoExtension() throws {
        let folder = wallperFolder(in: root)
        for ext in WallpaperImportService.videoExtensions {
            try video("clip.\(ext)", in: folder)
        }
        // Non-video files beside them are ignored.
        try Data("not a video".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try Data("not a video".utf8).write(to: folder.appendingPathComponent("cover.jpg"))
        let found = try WallperVideoImporter.discoverVideos(in: folder)
        XCTAssertEqual(found.count, WallpaperImportService.videoExtensions.count)
        for url in found {
            XCTAssertTrue(WallpaperImportService.videoExtensions.contains(url.pathExtension.lowercased()), url.path)
        }
    }

    func testIgnoresHiddenFiles() throws {
        let folder = wallperFolder(in: root)
        try video("visible.mp4", in: folder)
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".hidden.mp4"))
        XCTAssertEqual(WallperVideoImporter.discoverVideos(in: folder).map(\.lastPathComponent), ["visible.mp4"])
    }

    func testSortedByLocalizedStandardName() throws {
        let folder = wallperFolder(in: root)
        try video("zebra.mp4", in: folder)
        try video("apple.mp4", in: folder)
        try video("Mango MOV", in: folder)
        let names = WallperVideoImporter.discoverVideos(in: folder).map(\.lastPathComponent)
        XCTAssertEqual(names, ["apple.mp4", "Mango MOV", "zebra.mp4"])
    }

    // MARK: Import

    func testImportWrapsEachVideoInAProjectManifest() async throws {
        let folder = wallperFolder(in: root)
        try video("clip.mp4", in: folder)
        let library = root.appendingPathComponent("Library")
        let report = try await WallperVideoImporter.importAll(
            from: folder, into: library, duplicates: .skip, progress: { _ in })
        XCTAssertEqual(report.importedIDs, ["clip.mp4"])
        XCTAssertEqual(report.failures, [])
        let installed = library.appendingPathComponent("clip.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("project.json").path))
        // The manifest names the video as the wallpaper's file, the same way a standalone
        // video chosen through the import picker is wrapped.
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: installed.appendingPathComponent("project.json"))) as? [String: Any])
        XCTAssertEqual(manifest["type"] as? String, "video")
        XCTAssertEqual(manifest["file"] as? String, "clip.mp4")
        XCTAssertEqual(manifest["title"] as? String, "clip")
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("clip.mp4")),
                       try Data(contentsOf: folder.appendingPathComponent("clip.mp4")))
    }

    func testImportLeavesOriginalsUntouched() async throws {
        let folder = wallperFolder(in: root)
        try video("clip.mp4", in: folder)
        let original = try Data(contentsOf: folder.appendingPathComponent("clip.mp4"))
        let library = root.appendingPathComponent("Library")
        _ = try await WallperVideoImporter.importAll(
            from: folder, into: library, duplicates: .skip, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("clip.mp4")), original)
    }

    func testEmptyFolderProducesNoReportedImports() async throws {
        let folder = wallperFolder(in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("Library")
        let report = try await WallperVideoImporter.importAll(
            from: folder, into: library, duplicates: .skip, progress: { _ in })
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testDuplicatePolicyAppliesToWallperVideos() async throws {
        let folder = wallperFolder(in: root)
        try video("clip.mp4", in: folder)
        let library = root.appendingPathComponent("Library")
        _ = try await WallperVideoImporter.importAll(
            from: folder, into: library, duplicates: .skip, progress: { _ in })
        // Skip: the second import does nothing.
        let skipped = try await WallperVideoImporter.importAll(
            from: folder, into: library, duplicates: .skip, progress: { _ in })
        XCTAssertEqual(skipped.skipped, ["clip.mp4"])
        // Keep both: a second copy is filed under a new id.
        let kept = try await WallperVideoImporter.importAll(
            from: folder, into: library, duplicates: .keepBoth, progress: { _ in })
        XCTAssertEqual(kept.importedIDs.count, 1)
        XCTAssertNotEqual(kept.importedIDs.first, "clip.mp4")
    }

    func testNonVideoFilesAreNotImported() async throws {
        let folder = wallperFolder(in: root)
        try Data("not a video".utf8).write(to: folder.appendingPathComponent("cover.jpg"))
        let library = root.appendingPathComponent("Library")
        let report = try await WallperVideoImporter.importAll(
            from: folder, into: library, duplicates: .skip, progress: { _ in })
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
    }
}