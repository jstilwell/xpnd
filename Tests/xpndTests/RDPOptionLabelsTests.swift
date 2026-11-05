import Testing
@testable import xpnd

struct RDPOptionLabelsTests {
    @Test func labels() {
        #expect(RDPOptionLabels.label(for: .fit) == "Resize to fit")
        #expect(RDPOptionLabels.label(for: .fixed(width: 1920, height: 1080)) == "1920 × 1080")
        #expect(RDPOptionLabels.label(for: .fixed(width: 1234, height: 567)) == "Custom 1234 × 567")
        #expect(RDPOptionLabels.label(for: RDPOptions.Audio.local) == "Play here")
        #expect(RDPOptionLabels.label(for: RDPOptions.Audio.remote) == "Leave on remote")
        #expect(RDPOptionLabels.label(for: RDPOptions.Audio.off) == "Off")
        #expect(RDPOptionLabels.label(for: RDPOptions.Performance.auto) == "Automatic")
        #expect(RDPOptionLabels.presets.count == 4)
    }
}
