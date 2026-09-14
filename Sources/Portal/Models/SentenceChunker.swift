import Foundation

/// Accumulates streamed text and hands back whole sentences as they close.
///
/// Speech that waits for the turn to finish arrives ten seconds after the
/// eye has read the answer. Speaking token by token is unintelligible. A
/// sentence is the unit a voice can start on early and still sound like
/// speech, so this is the seam between the delta stream and the synthesizer.
///
/// Fence-aware: text inside a ``` block is never split mid-way — the whole
/// block is released when it closes, so `SpokenText` sees it intact and can
/// replace it as one unit instead of speaking stray lines of code.
///
/// A value type with no dependencies, kept out of `TTSService` so the
/// boundary rules can be pinned by tests without a synthesizer in the room.
internal struct SentenceChunker: Equatable {
    internal private(set) var buffer = ""

    /// Feed a delta; get back every sentence that is now complete, in order.
    internal mutating func push(_ delta: String) -> [String] {
        buffer += delta
        var out: [String] = []
        while let cut = nextBoundary() {
            let sentence = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            if !sentence.isEmpty { out.append(sentence) }
        }
        return out
    }

    /// Release whatever remains (the last sentence of a turn rarely ends in a
    /// terminator the chunker recognises before the stream stops).
    internal mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    internal mutating func reset() {
        buffer = ""
    }

    // MARK: - Boundaries

    /// The index just past the next sentence end, or nil when the buffer holds
    /// no complete sentence yet. A boundary is: a blank line; or `.`, `!`,
    /// `?`, `…` followed by whitespace — but not a `.` between two digits
    /// (3.14), and never inside a code fence.
    ///
    /// Fence state is recomputed from the buffer's start on every scan rather
    /// than carried between calls: the buffer only ever holds the unfinished
    /// remainder, and a state that outlived the scan mistook a reopened
    /// fence's opener for its closer.
    private func nextBoundary() -> String.Index? {
        var index = buffer.startIndex
        var lineStart = true
        var inFence = false
        while index < buffer.endIndex {
            let char = buffer[index]
            if lineStart, buffer[index...].hasPrefix("```") {
                inFence.toggle()
                // A fence closing is itself a boundary so the block is released whole.
                if !inFence, let eol = buffer[index...].firstIndex(of: "\n") {
                    return buffer.index(after: eol)
                }
            }
            lineStart = char == "\n"
            if inFence {
                index = buffer.index(after: index)
                continue
            }
            if char == "\n" {
                let next = buffer.index(after: index)
                if next < buffer.endIndex, buffer[next] == "\n" {
                    return next
                }
            }
            if ".!?…".contains(char) {
                let next = buffer.index(after: index)
                guard next < buffer.endIndex else { break } // may still be mid-sentence ("3." then "14")
                if buffer[next].isWhitespace, !isDecimalPoint(at: index) {
                    return next
                }
            }
            index = buffer.index(after: index)
        }
        return nil
    }

    private func isDecimalPoint(at index: String.Index) -> Bool {
        guard buffer[index] == ".", index > buffer.startIndex else { return false }
        let before = buffer[buffer.index(before: index)]
        let afterIndex = buffer.index(after: index)
        guard afterIndex < buffer.endIndex else { return false }
        return before.isNumber && buffer[afterIndex].isNumber
    }
}
