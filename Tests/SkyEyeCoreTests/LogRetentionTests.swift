import Darwin
import Foundation
import XCTest
@testable import SkyEyeCore

final class LogRetentionTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("skyeye-logs-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ text: String, to file: URL, age: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
    }

    func testRetentionDefaultsAndRoundTrip() throws {
        let defaults = try JSONCoding.decoder.decode(SkyEyeCore.Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(defaults.logRetentionDays, 7)
        var forever = defaults
        forever.logRetentionDays = 0
        let restored = try JSONCoding.decoder.decode(SkyEyeCore.Settings.self, from: JSONCoding.encoder.encode(forever))
        XCTAssertEqual(restored.logRetentionDays, 0)
    }

    func testCleanupDeletesOldLogsAndKeepsRecentAndProtectedLogs() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.log")
        let recent = directory.appendingPathComponent("recent.log")
        let protected = directory.appendingPathComponent("protected.log")
        let archive = ServiceLogs.archiveDirectory(for: old).appendingPathComponent("old-archive.log")
        let other = directory.appendingPathComponent("notes.txt")
        try write("old", to: old, age: 9 * 86_400)
        try write("archive", to: archive, age: 9 * 86_400)
        try write("recent", to: recent, age: 2 * 86_400)
        try write("active", to: protected, age: 9 * 86_400)
        try write("keep", to: other, age: 9 * 86_400)
        try ServiceLogs.cleanup(in: directory, retentionDays: 7, protectedNames: ["protected"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testKeepForeverDisablesCleanup() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("old.log")
        try write("old", to: file, age: 365 * 86_400)
        try ServiceLogs.cleanup(in: directory, retentionDays: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testDailyRotationPreservesHistoryAndReadingAcrossArchives() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("web.log")
        let now = Date()
        let writer = try RotatingLogWriter(log: log, now: now)
        try writer.append(Data("first\nsecond\n".utf8), now: now)
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: now))
        try writer.append(Data("third\n".utf8), now: tomorrow)
        XCTAssertEqual(try String(contentsOf: log), "third\n")
        XCTAssertEqual(ServiceLogs.archives(for: log).count, 1)
        XCTAssertEqual(ServiceLogs.read(log, lines: 2), "second\nthird")
        XCTAssertEqual(ServiceLogs.read(log, lines: 10), "first\nsecond\nthird")
    }

    func testWriterLockPreservesActiveLogEvenWithOldTimestamp() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("active.log")
        let writer = try RotatingLogWriter(log: log)
        try writer.append(Data("before\n".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: log.path)
        try ServiceLogs.cleanup(in: directory, retentionDays: 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        try writer.append(Data("after\n".utf8))
        XCTAssertEqual(try String(contentsOf: log), "before\nafter\n")
    }

    func testCleanupDoesNotFollowArchiveSymlinks() throws {
        let directory = try directory()
        let outside = try self.directory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let log = outside.appendingPathComponent("keep.log")
        try write("keep", to: log, age: 30 * 86_400)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("archive"), withDestinationURL: outside)
        try ServiceLogs.cleanup(in: directory, retentionDays: 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
    }

    func testManagedProcessRoutesStdoutAndStderrThroughWriter() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appendingPathComponent(".build/debug/skyeye-logwriter")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        let log = directory.appendingPathComponent("process.log")
        let exited = expectation(description: "service exited")
        let process = try ManagedProcess.spawn(executable: "/bin/sh",
            arguments: ["-c", "printf 'stdout\\n'; printf 'stderr\\n' >&2"], directory: nil,
            environment: ["PATH": "/bin:/usr/bin"], logFile: log, logWriter: helper
        ) { _ in exited.fulfill() }
        defer { process.terminate() }
        wait(for: [exited], timeout: 5)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, ServiceLogs.read(log, lines: 10) != "stdout\nstderr" {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(ServiceLogs.read(log, lines: 10), "stdout\nstderr")
    }
}
