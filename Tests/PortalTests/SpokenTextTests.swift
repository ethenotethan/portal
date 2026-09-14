import Foundation
import Testing
@testable import Portal

/// What a response *sounds* like: markdown in, speakable prose out.
@Suite("Spoken text preparation")
internal struct SpokenTextTests {

    @Test("code fences are replaced by one announcement, whatever their length or language")
    internal func codeFences() {
        let md = "Run this:\n```swift\nlet x = 1\nprint(x)\n```\nThen check the output."
        #expect(SpokenText.prepare(md) == "Run this:\nCode block omitted.\nThen check the output.")
        #expect(SpokenText.prepare(md, options: .skippingCode) == "Run this:\nThen check the output.")
    }

    @Test("an unterminated fence — still streaming — is treated as a block, not read aloud")
    internal func openFence() {
        #expect(SpokenText.prepare("Here:\n```py\nimport os\nos.listdir()") == "Here:\nCode block omitted.")
    }

    @Test("inline code keeps its words, links keep their text, bare URLs become 'link'")
    internal func inlineAndLinks() {
        #expect(SpokenText.prepare("Use `swift build` first.") == "Use swift build first.")
        #expect(SpokenText.prepare("See [the docs](https://example.com/a/b) now.") == "See the docs now.")
        #expect(SpokenText.prepare("Go to https://example.com/x?y=1 please.") == "Go to link please.")
        #expect(SpokenText.prepare("![diagram](https://x/y.png) Caption.") == "Caption.")
    }

    @Test("headings, emphasis, quotes, bullets and rules are stripped to their words")
    internal func markdownSyntax() {
        let md = """
        ## Summary
        > **Bold** point and *italic* one, plus __strong__ and _soft_.
        - first item
        1. numbered item
        ---
        Done.
        """
        #expect(SpokenText.prepare(md) == "Summary\nBold point and italic one, plus strong and soft.\nfirst item\nnumbered item\nDone.")
    }

    @Test("asterisks that aren't emphasis survive (multiplication, footnotes)")
    internal func literalAsterisks() {
        #expect(SpokenText.prepare("2 * 3 = 6") == "2 * 3 = 6")
    }

    @Test("tables read cell by cell, the separator row is dropped")
    internal func tables() {
        let md = "| Name | Size |\n|---|---|\n| a.py | 3 KB |"
        #expect(SpokenText.prepare(md) == "Name, Size.\na.py, 3 KB.")
    }

    @Test("think blocks, media tags, math and html never reach the voice")
    internal func nonProse() {
        #expect(SpokenText.prepare("<think>plan</think>Answer.") == "Answer.")
        #expect(SpokenText.prepare("<think>still thinking").isEmpty)
        #expect(SpokenText.prepare("Energy is $E = mc^2$ and $$\\int x$$ done.") == "Energy is and done.")
        #expect(SpokenText.prepare("Hi <br/> there <span class=\"x\">friend</span>.") == "Hi\nthere friend.")
    }

    @Test("whitespace collapses; an input with nothing to say becomes empty")
    internal func whitespace() {
        #expect(SpokenText.prepare("  a   b \n\n\n c  ") == "a b\nc")
        #expect(SpokenText.prepare("```\nx\n```", options: .skippingCode).isEmpty)
        #expect(SpokenText.prepare("").isEmpty)
    }
}
