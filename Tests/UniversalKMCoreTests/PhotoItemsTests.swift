import Foundation
import Testing
@testable import UniversalKMCore

private func item(_ name: String, _ created: TimeInterval?, sidecars: [String] = []) -> PhotoItem {
    PhotoItem(id: name, name: name, created: created.map(Date.init(timeIntervalSince1970:)), size: 1,
              duration: 0, kind: PhotoItem.kind(ofName: name), sidecars: sidecars)
}

@Suite struct PhotoItemsTests {
    @Test func newestFirstUndatedLast() {
        let sorted = PhotoItem.sorted([item("a.HEIC", 10), item("b.HEIC", nil), item("c.MOV", 30), item("d.JPG", 20)])
        #expect(sorted.map(\.name) == ["c.MOV", "d.JPG", "a.HEIC", "b.HEIC"])
    }

    @Test func sameDateByName() {
        let sorted = PhotoItem.sorted([item("IMG_10.HEIC", 5), item("IMG_9.HEIC", 5)])
        #expect(sorted.map(\.name) == ["IMG_9.HEIC", "IMG_10.HEIC"])
    }

    @Test func kinds() {
        #expect(PhotoItem.kind(ofName: "IMG_1.MOV") == .video)
        #expect(PhotoItem.kind(ofName: "x.mp4") == .video)
        #expect(PhotoItem.kind(ofName: "IMG_1.HEIC") == .photo)
        #expect(PhotoItem.kind(ofName: "IMG_E1.JPG") == .photo)
        #expect(item("IMG_1.HEIC", 1, sidecars: ["IMG_1.MOV"]).isLivePhoto)
        #expect(!item("IMG_1.HEIC", 1).isLivePhoto)
    }

    @Test func durations() {
        #expect(PhotoItem.duration(0) == "0:00")
        #expect(PhotoItem.duration(65.4) == "1:05")
        #expect(PhotoItem.duration(188.5) == "3:09")
        #expect(PhotoItem.duration(3723) == "1:02:03")
    }

    @Test func freeNameAlone() {
        let names = item("IMG_1.HEIC", 1).freeNames { $0 == "IMG_1.HEIC" }
        #expect(names.main == "IMG_1 2.HEIC")
        #expect(names.sidecars.isEmpty)
    }

    @Test func livePhotoKeepsOneBase() {
        let live = item("IMG_1.HEIC", 1, sidecars: ["IMG_1.MOV"])
        #expect(live.freeNames { _ in false } == ("IMG_1.HEIC", ["IMG_1.MOV"]))
        // Only the video name is taken: both move to the next base.
        let taken: Set = ["IMG_1.MOV", "IMG_1 2.HEIC"]
        let names = live.freeNames(isTaken: taken.contains)
        #expect(names.main == "IMG_1 3.HEIC")
        #expect(names.sidecars == ["IMG_1 3.MOV"])
    }
}
