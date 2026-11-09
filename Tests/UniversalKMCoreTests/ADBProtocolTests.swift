import Foundation
import Testing
@testable import UniversalKMCore

/// Raw replies recorded from real phones by scripts/adb-capture.py (task 1.5).
private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/adb/\(name)")
    return try Data(contentsOf: url)
}

private let devices = ["s10e", "x115"]

private func parse(_ data: Data, _ reply: ADBSync.Reply, chunk: Int = .max) throws -> [ADBSync.Message] {
    var parser = ADBSync.Parser(reply)
    var messages: [ADBSync.Message] = []
    var offset = 0
    while offset < data.count {
        let end = min(data.count, offset + chunk)
        messages += try parser.append(data.subdata(in: offset ..< end))
        offset = end
    }
    #expect(parser.isFinished)
    return messages
}

private func entries(_ messages: [ADBSync.Message]) -> [ADBSync.Entry] {
    messages.compactMap { if case .entry(let entry) = $0 { entry } else { nil } }
}

// MARK: Host protocol

@Test func hostRequestHasHexLength() {
    #expect(ADBProtocol.request("host:version") == Data("000chost:version".utf8))
    #expect(ADBProtocol.request("host:transport:192.168.1.7:5555").prefix(4) == Data("001f".utf8))
    // Length is in bytes, not characters.
    #expect(ADBProtocol.request("я").prefix(4) == Data("0002".utf8))
}

@Test func hostStatusAndLength() {
    #expect(ADBProtocol.status(Data("OKAY".utf8)) == .okay)
    #expect(ADBProtocol.status(Data("FAIL".utf8)) == .fail)
    #expect(ADBProtocol.status(Data("DENT".utf8)) == nil)
    #expect(ADBProtocol.hexLength(Data("001a".utf8)) == 26)
    #expect(ADBProtocol.hexLength(Data("zzzz".utf8)) == nil)
}

@Test func featuresFromRealPhones() throws {
    for device in devices {
        let text = String(decoding: try fixture("\(device)-features.txt"), as: UTF8.self)
        let features = ADBProtocol.features(text)
        #expect(features.contains("ls_v2"))
        #expect(features.contains("shell_v2"))
    }
}

// MARK: Sync requests

@Test func syncRequestsAreLittleEndian() {
    #expect(ADBSync.list("/sdcard/", v2: false) == Data("LIST".utf8) + Data([8, 0, 0, 0]) + Data("/sdcard/".utf8))
    #expect(ADBSync.list("/a", v2: true).prefix(4) == Data("LIS2".utf8))
    #expect(ADBSync.send("/sdcard/a.txt") == Data("SEND".utf8) + Data([19, 0, 0, 0]) + Data("/sdcard/a.txt,33188".utf8))
    #expect(ADBSync.done(modified: Date(timeIntervalSince1970: 0x01020304)) == Data("DONE".utf8) + Data([4, 3, 2, 1]))
    #expect(ADBSync.quit == Data("QUIT".utf8) + Data([0, 0, 0, 0]))
    let chunk = Data(repeating: 7, count: 300)
    #expect(ADBSync.data(chunk) == Data("DATA".utf8) + Data([0x2C, 1, 0, 0]) + chunk)
}

// MARK: Sync replies from real phones

@Test(arguments: devices) func listFromRealPhone(device: String) throws {
    for (file, reply) in [("list.bin", ADBSync.Reply.list), ("lis2.bin", .list2)] {
        let data = try fixture("\(device)-\(file)")
        let found = entries(try parse(data, reply))
        #expect(Set(found.map(\.name)) == ["Sub folder", "it's.txt", ".hidden", "Привет мир.txt"])
        let folder = try #require(found.first { $0.name == "Sub folder" })
        #expect(folder.isDirectory)
        let text = try #require(found.first { $0.name == "Привет мир.txt" })
        #expect(!text.isDirectory)
        #expect(text.size == UInt64(try fixture("\(device)-recv.txt").count))
        #expect(found.first { $0.name == "it's.txt" }?.size == 1)
        // Made by the capture script in 2026.
        #expect(text.modified > Date(timeIntervalSince1970: 1_767_225_600 - 86_400 * 365))
        // Byte by byte gives the same.
        #expect(entries(try parse(data, reply, chunk: 1)) == found)
    }
}

@Test(arguments: devices) func deniedListIsEmpty(device: String) throws {
    let messages = try parse(try fixture("\(device)-list-denied.bin"), .list)
    #expect(messages == [.done])
}

@Test(arguments: devices) func receiveFromRealPhone(device: String) throws {
    let data = try fixture("\(device)-recv.bin")
    for chunk in [Int.max, 1, 7] {
        let messages = try parse(data, .receive, chunk: chunk)
        let content = messages.reduce(into: Data()) { if case .data(let d) = $1 { $0.append(d) } }
        #expect(content == (try fixture("\(device)-recv.txt")))
        #expect(messages.last == .done)
    }
}

// MARK: Sync replies, made up

@Test func dnt2WithSizeOver4GB() throws {
    var packet = Data("DNT2".utf8)
    packet.append(Data(count: 20))                                  // error, dev, ino
    packet.appendLE(0o100644)                                       // mode
    packet.append(Data(count: 12))                                  // nlink, uid, gid
    packet.appendLE(0x2345_6789); packet.appendLE(0x1)             // size = 0x1_2345_6789
    packet.append(Data(count: 8))                                   // atime
    packet.appendLE(1_700_000_000); packet.appendLE(0)             // mtime
    packet.append(Data(count: 8))                                   // ctime
    packet.appendLE(5)
    packet.append(Data("v.mp4".utf8))
    packet.append(Data("DONE".utf8) + Data(count: 72))
    let found = entries(try parse(packet, .list2))
    #expect(found == [ADBSync.Entry(name: "v.mp4", mode: 0o100644, size: 0x1_2345_6789, modified: Date(timeIntervalSince1970: 1_700_000_000))])
}

@Test func failCarriesMessage() throws {
    let text = "remote couldn't create file: Permission denied"
    let packet = Data("FAIL".utf8) + Data([UInt8(text.utf8.count), 0, 0, 0]) + Data(text.utf8)
    #expect(try parse(packet, .send, chunk: 3) == [.fail(text)])
    #expect(try parse(Data("OKAY".utf8) + Data(count: 4), .send) == [.okay])
}

@Test func unexpectedPacketThrows() {
    var parser = ADBSync.Parser(.receive)
    #expect(throws: ADBFileError.self) { try parser.append(Data("DENT".utf8) + Data(count: 16)) }
}

@Test func tooLargeDataThrows() {
    var parser = ADBSync.Parser(.receive)
    #expect(throws: ADBFileError.self) { try parser.append(Data("DATA".utf8) + Data([0, 0, 2, 0])) }
}

// MARK: Shell

@Test func shellQuoting() {
    #expect(ADBShell.quote("plain") == "'plain'")
    #expect(ADBShell.quote("it's") == #"'it'\''s'"#)
    #expect(ADBShell.quote("a b $HOME `x` \"q\" a:b Привет") == "'a b $HOME `x` \"q\" a:b Привет'")
    #expect(ADBShell.move("/sdcard/.a.ukm-part", "/sdcard/a") == "shell:'mv' '-f' '/sdcard/.a.ukm-part' '/sdcard/a'; echo; echo UKM_RC=$?")
    #expect(ADBShell.makeDirectory("/sdcard/Docs").hasPrefix("shell:'mkdir' '-p' '/sdcard/Docs';"))
    #expect(ADBShell.remove("/sdcard/x").hasPrefix("shell:'rm' '-rf' '/sdcard/x';"))
}

@Test func shellResult() {
    #expect(ADBShell.result("\nUKM_RC=0\n")! == (0, ""))
    let failed = ADBShell.result("mv: bad '/x': No such file or directory\n\nUKM_RC=1\n")!
    #expect(failed.code == 1)
    #expect(failed.output == "mv: bad '/x': No such file or directory")
    #expect(ADBShell.result("out\r\n\r\nUKM_RC=2\r\n")! == (2, "out"))
    #expect(ADBShell.result("no marker") == nil)
}

// MARK: Paths and listings

@Test func remotePaths() {
    let camera = RemotePath.root.appending("DCIM").appending("Camera")
    #expect(RemotePath.root.string == "/sdcard/")
    #expect(camera.string == "/sdcard/DCIM/Camera")
    #expect(camera.parent == RemotePath(["DCIM"]))
    #expect(RemotePath.root.parent == nil)
    #expect(camera.display(rootName: "S10e") == "S10e › DCIM › Camera")
    #expect(camera.name == "Camera")
}

@Test func visibleEntriesHideDotFiles() {
    let now = Date()
    let list = [ADBSync.Entry(name: ".", mode: 0o040755, size: 4096, modified: now),
                ADBSync.Entry(name: ".hidden", mode: 0o100644, size: 1, modified: now),
                ADBSync.Entry(name: ".a.jpg.ukm-part", mode: 0o100644, size: 1, modified: now),
                ADBSync.Entry(name: "DCIM", mode: 0o040771, size: 3452, modified: now),
                ADBSync.Entry(name: "a.jpg", mode: 0o100660, size: 10, modified: now)]
    let visible = DeviceFileEntry.visible(list)
    #expect(visible.map(\.name) == ["DCIM", "a.jpg"])
    #expect(visible[0].isDirectory && visible[0].size == 0)
    #expect(DeviceFileEntry.isPartial(".a.jpg.ukm-part"))
    #expect(DeviceFileEntry.partialName(for: "a.jpg") == ".a.jpg.ukm-part")
}

@Test func sortingKeepsFoldersFirst() {
    let old = Date(timeIntervalSince1970: 1), new = Date(timeIntervalSince1970: 2)
    let list = [DeviceFileEntry(name: "img10.jpg", isDirectory: false, size: 5, modified: old),
                DeviceFileEntry(name: "img2.jpg", isDirectory: false, size: 50, modified: new),
                DeviceFileEntry(name: "Zeta", isDirectory: true, size: 0, modified: old),
                DeviceFileEntry(name: "alpha", isDirectory: true, size: 0, modified: new)]
    #expect(DeviceFileEntry.sorted(list, by: .name, ascending: true).map(\.name) == ["alpha", "Zeta", "img2.jpg", "img10.jpg"])
    #expect(DeviceFileEntry.sorted(list, by: .name, ascending: false).map(\.name) == ["Zeta", "alpha", "img10.jpg", "img2.jpg"])
    #expect(DeviceFileEntry.sorted(list, by: .size, ascending: false).map(\.name) == ["alpha", "Zeta", "img2.jpg", "img10.jpg"])
    #expect(DeviceFileEntry.sorted(list, by: .modified, ascending: true).map(\.name) == ["Zeta", "alpha", "img10.jpg", "img2.jpg"])
}

@Test func uniqueNamesAsFinder() {
    let taken: Set = ["photo.jpg", "photo 2.jpg", "Docs", ".nomedia"]
    #expect(FileNames.unique("new.jpg") { taken.contains($0) } == "new.jpg")
    #expect(FileNames.unique("photo.jpg") { taken.contains($0) } == "photo 3.jpg")
    #expect(FileNames.unique("Docs") { taken.contains($0) } == "Docs 2")
    #expect(FileNames.unique(".nomedia") { taken.contains($0) } == ".nomedia 2")
    #expect(FileNames.unique("archive.tar.gz") { $0 == "archive.tar.gz" } == "archive.tar 2.gz")
}
