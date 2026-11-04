import Testing
import xpndRDP

struct RDPLinkTests {
    @Test func linksFreeRDP() { #expect(XPRDPVersion.freerdpVersion().hasPrefix("3.33.0")) }
}
