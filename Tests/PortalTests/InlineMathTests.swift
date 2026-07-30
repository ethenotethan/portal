import Foundation
import Testing
@testable import Portal

@Suite("Inline math conversion")
internal struct InlineMathConversionTests {

    // MARK: - render: span detection & passthrough

    @Test("Text with no dollar sign is returned untouched")
    internal func noDollarUntouched() {
        #expect(InlineMath.render("plain prose, no math here") == "plain prose, no math here")
    }

    @Test("A single convertible span is rewritten in place")
    internal func singleSpanRewritten() {
        // $x$ → italic x, surrounding prose preserved verbatim.
        #expect(InlineMath.render("Take half of $x$ now") == "Take half of 𝑥 now")
    }

    @Test("Display math $$…$$ passes through untouched")
    internal func displayMathUntouched() {
        // The opening $$ is emitted literally and scanning resumes after it,
        // so the inner content is never treated as an inline span.
        let out = InlineMath.render("before $$x^2$$ after")
        #expect(out.contains("$$"))
        #expect(!out.contains("𝑥"))
    }

    @Test("A currency-looking span with boundary whitespace never matches")
    internal func currencyNotMatched() {
        // "$5 and $10": the span "5 and " ends in whitespace → rejected,
        // and prices survive verbatim.
        #expect(InlineMath.render("$5 and $10") == "$5 and $10")
    }

    @Test("An unterminated dollar emits the remainder verbatim")
    internal func unterminatedSpan() {
        #expect(InlineMath.render("cost is $x plus tax") == "cost is $x plus tax")
    }

    @Test("A span beyond character-level conversion is left as raw TeX")
    internal func structuralTeXLeftRaw() {
        // \frac has no single-glyph mapping → whole span restored with $…$.
        #expect(InlineMath.render("the ratio $\\frac{1}{2}$ holds") == "the ratio $\\frac{1}{2}$ holds")
    }

    @Test("Multiple spans in one string each convert independently")
    internal func multipleSpans() {
        #expect(InlineMath.render("$a$ and $b$") == "𝑎 and 𝑏")
    }

    // MARK: - convert: rejection rules

    @Test("Empty or whitespace-edged spans are rejected")
    internal func convertRejectsWhitespaceEdges() {
        #expect(InlineMath.convert("") == nil)
        #expect(InlineMath.convert(" x") == nil)
        #expect(InlineMath.convert("x ") == nil)
    }

    @Test("A span containing a newline is rejected")
    internal func convertRejectsNewline() {
        #expect(InlineMath.convert("a\nb") == nil)
    }

    @Test("An unknown backslash command aborts the whole span")
    internal func convertRejectsUnknownCommand() {
        #expect(InlineMath.convert("\\notacommand") == nil)
    }

    @Test("A default-branch character (e.g. #) aborts conversion")
    internal func convertRejectsStrayCharacter() {
        #expect(InlineMath.convert("a#b") == nil)
    }

    // MARK: - convert: letters, operators, digits

    @Test("Latin letters map to mathematical-italic forms")
    internal func convertItalicLetters() {
        #expect(InlineMath.convert("x") == "𝑥")
        #expect(InlineMath.convert("A") == "𝐴")
    }

    @Test("h is special-cased to Planck's h, not the unassigned italic slot")
    internal func convertPlanckH() {
        #expect(InlineMath.convert("h") == "ℎ")
    }

    @Test("Asterisk becomes × and hyphen becomes the true minus sign")
    internal func convertOperators() {
        #expect(InlineMath.convert("a*b") == "𝑎×𝑏")
        #expect(InlineMath.convert("a-b") == "𝑎−𝑏")
    }

    @Test("Digits and allowed punctuation pass through literally")
    internal func convertDigitsAndPunctuation() {
        #expect(InlineMath.convert("2+2=4") == "2+2=4")
    }

    // MARK: - convert: sub/superscripts

    @Test("A caret group maps digits to superscripts")
    internal func convertSuperscript() {
        // b^2 → 𝑏²
        #expect(InlineMath.convert("b^2") == "𝑏²")
    }

    @Test("An underscore group maps digits to subscripts")
    internal func convertSubscript() {
        // x_1 → 𝑥₁
        #expect(InlineMath.convert("x_1") == "𝑥₁")
    }

    @Test("A braced multi-character script converts each member")
    internal func convertBracedScript() {
        // x^{23} → 𝑥²³
        #expect(InlineMath.convert("x^{23}") == "𝑥²³")
    }

    @Test("A script character with no sub/superscript form aborts the span")
    internal func convertScriptUnmappable() {
        // 'z' has no superscript glyph in the table → nil.
        #expect(InlineMath.convert("x^z") == nil)
    }

    // MARK: - convert: named commands & braces

    @Test("Greek and operator commands map to their glyphs")
    internal func convertNamedCommands() {
        #expect(InlineMath.convert("\\alpha") == "α")
        #expect(InlineMath.convert("\\Omega") == "Ω")
        #expect(InlineMath.convert("\\leq") == "≤")
        #expect(InlineMath.convert("\\infty") == "∞")
    }

    @Test("Bare grouping braces vanish in the flat conversion")
    internal func convertBracesVanish() {
        // {ab} → 𝑎𝑏, braces dropped.
        #expect(InlineMath.convert("{ab}") == "𝑎𝑏")
    }

    @Test("A full quadratic-formula fragment converts end to end")
    internal func convertCompoundExpression() {
        // b^2 - 4ac → 𝑏² − 4𝑎𝑐 (superscript, spaces, true minus, italics).
        #expect(InlineMath.convert("b^2 - 4ac") == "𝑏² − 4𝑎𝑐")
    }
}
