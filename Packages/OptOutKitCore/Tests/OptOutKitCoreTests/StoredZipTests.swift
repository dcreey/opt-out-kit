import XCTest
@testable import OptOutKitCore

/// The run export's archive (`StoredZip`): a real zip tool reads it, every file comes back byte for byte, and names stay safe.
final class StoredZipTests: XCTestCase {
    func testTheChecksumIsTheStandardOne() {
        XCTAssertEqual(StoredZip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(StoredZip.crc32(Data()), 0)
    }

    func testNamesKeepOnlySafeCharacters() {
        XCTAssertEqual(StoredZip.safeName("001-courtrecords.us.jpg"), "001-courtrecords.us.jpg")
        XCTAssertEqual(StoredZip.safeName("../a b/é.jpg"), "..-a-b--.jpg")
    }

    /// `unzip` tests the archive and gives back each file exactly as it went in, in order.
    func testUnzipReadsEveryFileBackExactly() throws {
        let picture = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let files: [(name: String, data: Data)] = [("run.json", Data("{\"sites\":[]}".utf8)), ("001-example.com.jpg", picture), ("README.txt", Data())]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = folder.appendingPathComponent("run.zip")
        try StoredZip.make(files).write(to: zip)

        let (status, listing) = try unzip(["-t", zip.path])
        XCTAssertEqual(status, 0, listing)
        XCTAssertTrue(listing.contains("No errors detected"), listing)
        let (_, names) = try unzip(["-Z1", zip.path])
        XCTAssertEqual(names.split(separator: "\n").map(String.init), files.map(\.name))
        for file in files {
            let out = folder.appendingPathComponent("out-" + file.name)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-p", zip.path, file.name]
            FileManager.default.createFile(atPath: out.path, contents: nil)
            p.standardOutput = try FileHandle(forWritingTo: out)
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(try Data(contentsOf: out), file.data, file.name)
        }
    }

    private func unzip(_ args: [String]) throws -> (Int32, String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = args
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
