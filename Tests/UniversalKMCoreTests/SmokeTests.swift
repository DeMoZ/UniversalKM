import Testing
@testable import UniversalKMCore

@Test func coreVersionIsSet() {
    #expect(!UniversalKMCore.version.isEmpty)
}
