import Testing
@testable import SpektraEngine

@Test func metalDeviceIsAvailable() {
    #expect(SpektraEngine.device != nil)
}
