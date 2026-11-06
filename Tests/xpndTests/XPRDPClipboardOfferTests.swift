import Foundation
import Testing
import xpndRDP

/// A file offer against a stand-in channel: its completion must wait for the server's Format List Response.
@MainActor struct XPRDPClipboardOfferTests {
    private let files = [URL(fileURLWithPath: "/tmp/a.txt")]

    /// Written and read on main only: the completions run there.
    private final class Answers: @unchecked Sendable {
        var all: [Bool] = []
    }

    /// What was queued on the main queue so far has run; completions arrive through it.
    private func settled() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    /// A clipboard in sync with a server that has answered its first list.
    private func inSync(_ body: (XPRDPClipboard) async -> Void) async {
        let c = XPRDPClipboard()
        c.attachTestChannel()
        c.testServerReady()
        c.testServerAnswersFormatList(true)
        await body(c)
        c.detachTestChannel()
    }

    private func offer(_ c: XPRDPClipboard, _ urls: [URL]? = nil) -> Answers {
        let answers = Answers()
        c.offerFileURLs(urls ?? files) { answers.all.append($0) }
        return answers
    }

    @Test func noChannelIsRefusedAtOnce() async {
        let c = XPRDPClipboard()
        let answers = offer(c)
        await settled()
        #expect(answers.all == [false])
        #expect(c.lastAnnouncedFormats.isEmpty)
    }

    @Test func aChannelNotYetInSyncIsRefusedAtOnceAndNothingGoesOut() async {
        let c = XPRDPClipboard()
        c.attachTestChannel()
        let answers = offer(c)
        await settled()
        #expect(answers.all == [false])
        #expect(c.testListsOnWire == 0)
        #expect(c.lastAnnouncedFormats.isEmpty) // nothing left for MonitorReady to announce either
        c.detachTestChannel()
    }

    @Test func syncSwitchedOffIsRefusedAtOnce() async {
        await inSync { c in
            c.enabled = false
            let answers = offer(c)
            await settled()
            #expect(answers.all == [false])
        }
    }

    @Test func noFilesIsRefused() async {
        await inSync { c in
            let answers = offer(c, [URL(string: "https://example.com/x")!])
            await settled()
            #expect(answers.all == [false])
        }
    }

    @Test func acceptanceWaitsForTheServersResponse() async {
        await inSync { c in
            let before = c.testListsOnWire
            let answers = offer(c)
            await settled()
            #expect(answers.all.isEmpty)
            #expect(c.testListsOnWire == before + 1)
            #expect(c.lastAnnouncedFormats == .files)
            c.testServerAnswersFormatList(true)
            await settled()
            #expect(answers.all == [true])
        }
    }

    @Test func aFailureResponseIsARefusal() async {
        await inSync { c in
            let answers = offer(c)
            c.testServerAnswersFormatList(false)
            await settled()
            #expect(answers.all == [false])
        }
    }

    @Test func noResponseTimesOutOnce() async {
        await inSync { c in
            c.offerTimeout = 0.02
            let answers = offer(c)
            await settled()
            #expect(answers.all.isEmpty)
            try? await Task.sleep(for: .milliseconds(100))
            #expect(answers.all == [false])
            c.testServerAnswersFormatList(true) // late
            await settled()
            #expect(answers.all == [false])
        }
    }

    @Test func aTimeoutOfAnOlderOfferLeavesTheNewerOneAlone() async {
        await inSync { c in
            c.offerTimeout = 0.02
            let older = offer(c)
            c.offerTimeout = 10
            let newer = offer(c)
            try? await Task.sleep(for: .milliseconds(100))
            #expect(older.all == [false])
            #expect(newer.all.isEmpty)
            c.testServerAnswersFormatList(true)
            c.testServerAnswersFormatList(true)
            await settled()
            #expect(newer.all == [true])
        }
    }

    @Test func theSessionEndingIsARefusal() async {
        let c = XPRDPClipboard()
        c.attachTestChannel()
        c.testServerReady()
        c.testServerAnswersFormatList(true)
        let answers = offer(c)
        c.detachTestChannel()
        await settled()
        #expect(answers.all == [false])
    }

    @Test func anEarlierListsResponseIsNotTheOffers() async {
        await inSync { c in
            c.offerText("copied just before the drop", fileURIList: nil)
            let answers = offer(c)
            c.testServerAnswersFormatList(true) // the text's
            await settled()
            #expect(answers.all.isEmpty)
            c.testServerAnswersFormatList(true)
            await settled()
            #expect(answers.all == [true])
        }
    }

    @Test func theFirstListStillUnansweredCountsToo() async {
        let c = XPRDPClipboard()
        c.attachTestChannel()
        c.testServerReady() // its empty first list is answered like any other
        let answers = offer(c)
        c.testServerAnswersFormatList(true)
        await settled()
        #expect(answers.all.isEmpty)
        c.testServerAnswersFormatList(true)
        await settled()
        #expect(answers.all == [true])
        c.detachTestChannel()
    }

    @Test func anEmptyListFreeRDPDropsIsNotWaitedFor() async {
        await inSync { c in
            c.offerText(nil, fileURIList: nil) // a concealed copy: an empty list, which never reaches the wire
            let answers = offer(c)
            c.testServerAnswersFormatList(true)
            await settled()
            #expect(answers.all == [true])
        }
    }

    @Test func aNewerOfferSupersedesAndCountsTheOlderListsResponse() async {
        await inSync { c in
            let older = offer(c)
            let newer = offer(c)
            await settled()
            #expect(older.all == [false])
            #expect(newer.all.isEmpty)
            c.testServerAnswersFormatList(true) // the older offer's
            await settled()
            #expect(newer.all.isEmpty)
            c.testServerAnswersFormatList(true)
            await settled()
            #expect(older.all == [false])
            #expect(newer.all == [true])
        }
    }

    @Test func aRefusedNewerOfferStillEndsTheOlderOne() async {
        await inSync { c in
            let older = offer(c)
            let newer = offer(c, [])
            await settled()
            #expect(older.all == [false])
            #expect(newer.all == [false])
        }
    }

    @Test func thePasteboardChangingMeanwhileIsARefusal() async {
        await inSync { c in
            let answers = offer(c)
            c.offerText("newer", fileURIList: nil)
            await settled()
            #expect(answers.all == [false])
        }
    }

    @Test func syncSwitchedOffMeanwhileIsARefusal() async {
        await inSync { c in
            let answers = offer(c)
            c.enabled = false
            await settled()
            #expect(answers.all == [false])
        }
    }

    @Test func theServersClipboardReplacingTheOfferIsARefusal() async {
        await inSync { c in
            let answers = offer(c)
            c.testServerSendsFormatList()
            await settled()
            #expect(answers.all == [false])
        }
    }

    @Test func theCompletionRunsOnTheMainQueue() async {
        await inSync { c in
            let answers = offer(c)
            nonisolated(unsafe) let channel = c
            await withCheckedContinuation { done in
                DispatchQueue.global().async {
                    channel.testServerAnswersFormatList(true) // as the channel's thread does
                    done.resume()
                }
            }
            await settled()
            #expect(answers.all == [true])
        }
    }
}
