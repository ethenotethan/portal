import Foundation
import Testing
@testable import Portal

/// The seam between the delta stream and the synthesizer: where a sentence ends.
@Suite("Sentence chunker")
internal struct SentenceChunkerTests {

    @Test("a sentence is released once its terminator is followed by whitespace")
    internal func basicBoundary() {
        var chunker = SentenceChunker()
        #expect(chunker.push("Hello there").isEmpty)
        #expect(chunker.push(". How").isEmpty == false)
    }

    @Test("token-sized deltas assemble into whole sentences in order")
    internal func assemblesFromTokens() {
        var chunker = SentenceChunker()
        var out: [String] = []
        for token in ["The ", "cat", " sat", ". ", "It ", "purred", "! ", "Then", "?"] {
            out += chunker.push(token)
        }
        #expect(out == ["The cat sat.", "It purred!"])
        #expect(chunker.flush() == "Then?")
        #expect(chunker.flush() == nil)
    }

    @Test("a terminator at the very end waits: '3.' may still become '3.14'")
    internal func waitsAtEnd() {
        var chunker = SentenceChunker()
        #expect(chunker.push("Pi is 3.").isEmpty)
        #expect(chunker.push("14 exactly. Next").first == "Pi is 3.14 exactly.")
    }

    @Test("decimals and ellipses don't split sentences")
    internal func decimalsAndEllipsis() {
        var chunker = SentenceChunker()
        #expect(chunker.push("Version 2.5 shipped. ") == ["Version 2.5 shipped."])
        #expect(chunker.push("Well… maybe. ") == ["Well…", "maybe."])
    }

    @Test("a blank line is a boundary even without punctuation")
    internal func paragraphBreak() {
        var chunker = SentenceChunker()
        #expect(chunker.push("A heading\n\nBody text. ") == ["A heading", "Body text."])
    }

    @Test("a code fence is held whole and released when it closes, never split on its periods")
    internal func fences() {
        var chunker = SentenceChunker()
        #expect(chunker.push("Do this:\n\n").first == "Do this:")
        #expect(chunker.push("```py\nx = obj.value. y = 2\n").isEmpty)
        let released = chunker.push("```\nThen run it. ")
        #expect(released == ["```py\nx = obj.value. y = 2\n```", "Then run it."])
    }

    @Test("reset drops a half-collected sentence and any open fence")
    internal func reset() {
        var chunker = SentenceChunker()
        _ = chunker.push("```\nopen fence. never closed")
        chunker.reset()
        #expect(chunker.push("Fresh start. ") == ["Fresh start."])
    }
}
