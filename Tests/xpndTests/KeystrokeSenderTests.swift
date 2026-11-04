import Testing
@testable import xpnd

struct KeystrokeSenderTests {
    @Test func remoteDesktopAppsAreTypedOthersPasted() {
        #expect(CGEventKeystrokeSender.typesKeystrokes(in: "com.apple.ScreenSharing", always: false))
        #expect(CGEventKeystrokeSender.typesKeystrokes(in: "com.microsoft.rdc.macos", always: false))
        #expect(!CGEventKeystrokeSender.typesKeystrokes(in: "com.apple.Terminal", always: false))
        #expect(!CGEventKeystrokeSender.typesKeystrokes(in: nil, always: false))
        #expect(CGEventKeystrokeSender.typesKeystrokes(in: "com.apple.Terminal", always: true))
    }
}
