import Foundation
import GaeaProtocol
@testable import KokoroPlugin
import Testing

@Suite("The text plan")
struct PlanTests {
    @Test func pausesSplitTheTextAndBracketsStayWords() throws {
        #expect(try plan("Hello there. [pause 1.5s] Second line [pause] end \\[aside] [S1]")
            == [.words("Hello there."), .pause(1.5), .words("Second line"), .pause(0.5), .words("end [aside] [S1]")])
        #expect(try plan("[pause 0s]Hi") == [.words("Hi")])
        #expect(throws: GPPError.self) { try plan("a [pause 11s] b") }
    }

    @Test func longTextIsCutAtSentencesThenCommas() {
        let sentence = String(repeating: "word ", count: 50).trimmingCharacters(in: .whitespaces) + "."
        let pieces = split(sentence + " " + sentence)
        #expect(pieces.count == 2 && pieces.allSatisfy { $0.count <= maxPieceChars })
        #expect(split("Hi. Yes. No.") == ["Hi. Yes. No."])
        let commas = String(repeating: "alpha beta gamma, ", count: 30)
        #expect(split(commas).allSatisfy { $0.count <= maxPieceChars && ($0.hasSuffix(",") || $0 == split(commas).last) })
        #expect(split(String(repeating: "x", count: 700)).map(\.count) == [300, 300, 100])
    }

    @Test func aPlanNeedsWordsAndAKnownVoice() throws {
        #expect(throws: GPPError.self) { try speakPlan(text: "[pause 1s]", voice: nil) }
        #expect(throws: GPPError.self) { try speakPlan(text: "Hi", voice: "ef_dora") }
        #expect(throws: GPPError.self) { try speakPlan(text: String(repeating: "a", count: maxTextChars + 1), voice: nil) }
        #expect(try speakPlan(text: "Hi", voice: nil).voice == "af_heart")
        #expect(kokoroVoices.count == 28 && Set(kokoroVoices.map(\.id)).count == 28)
        #expect(language("bm_lewis") == "en-GB" && language("af_heart") == "en-US")
    }

    @Test func piecesStreamAsTheyAreDrawnAndAddUpToTheWAV() async throws {
        let plan = try speakPlan(text: "One. [pause 0.1s] Two.", voice: nil)
        let fake = { (words: String) -> Data in wav16(Data(repeating: UInt8(words.count), count: 480)) }
        var sent: [(Data, Bool)] = []
        let all = try await speak(plan, seed: 1, draw: fake, emit: { sent.append(($0, $1)) })
        #expect(sent.map(\.1) == [false, false, true])
        #expect(sent.map(\.0.count) == [480, 4800, 480])
        #expect(sent.reduce(Data()) { $0 + $1.0 } == all)
        #expect(try pcm16(wav16(all)) == all)
    }
}
