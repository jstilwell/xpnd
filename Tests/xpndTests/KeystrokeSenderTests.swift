import Testing
@testable import xpnd

struct KeystrokeSenderTests {
    @Test func remoteDesktopAppsAreTypedOthersPasted() {
        #expect(CGEventKeystrokeSender.typesKeystrokes(in: "com.apple.ScreenSharing", always: false, remoteDesktopTabFocused: false))
        #expect(CGEventKeystrokeSender.typesKeystrokes(in: "com.microsoft.rdc.macos", always: false, remoteDesktopTabFocused: false))
        #expect(!CGEventKeystrokeSender.typesKeystrokes(in: "com.apple.Terminal", always: false, remoteDesktopTabFocused: false))
        #expect(!CGEventKeystrokeSender.typesKeystrokes(in: nil, always: false, remoteDesktopTabFocused: false))
        #expect(CGEventKeystrokeSender.typesKeystrokes(in: "com.apple.Terminal", always: true, remoteDesktopTabFocused: false))
    }

    @Test func rdpTabTypesKeystrokes() {
        #expect(CGEventKeystrokeSender.typesKeystrokes(in: "com.jessestilwell.xpnd", always: false, remoteDesktopTabFocused: true))
        #expect(!CGEventKeystrokeSender.typesKeystrokes(in: "com.jessestilwell.xpnd", always: false, remoteDesktopTabFocused: false))
    }
}
