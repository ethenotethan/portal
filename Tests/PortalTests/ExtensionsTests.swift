import Foundation
import Testing
@testable import Portal

@Suite("AnyCodable accessors")
internal struct AnyCodableAccessorTests {

    // MARK: - Typed accessors return the value only for the matching case

    @Test("Each typed accessor unwraps its own case and nil for others")
    internal func typedAccessorsMatchOwnCase() {
        #expect(AnyCodable.string("hi").stringValue == "hi")
        #expect(AnyCodable.int(7).stringValue == nil)

        #expect(AnyCodable.int(7).intValue == 7)
        #expect(AnyCodable.string("7").intValue == nil)

        #expect(AnyCodable.bool(true).boolValue == true)
        #expect(AnyCodable.int(1).boolValue == nil)

        #expect(AnyCodable.array([.int(1)]).arrayValue?.count == 1)
        #expect(AnyCodable.string("x").arrayValue == nil)

        #expect(AnyCodable.dictionary(["a": .int(1)]).dictionaryValue?["a"] == .int(1))
        #expect(AnyCodable.string("x").dictionaryValue == nil)
    }

    @Test("doubleValue reads a double and coerces an int, but nothing else")
    internal func doubleValueCoercesInt() {
        #expect(AnyCodable.double(1.5).doubleValue == 1.5)
        // The documented Int → Double coercion.
        #expect(AnyCodable.int(3).doubleValue == 3.0)
        #expect(AnyCodable.string("3").doubleValue == nil)
        #expect(AnyCodable.bool(true).doubleValue == nil)
    }

    // MARK: - displayString (best-effort human rendering)

    @Test("Scalars render as their natural string form")
    internal func displayStringScalars() {
        #expect(AnyCodable.string("hello").displayString == "hello")
        #expect(AnyCodable.int(42).displayString == "42")
        #expect(AnyCodable.bool(false).displayString == "false")
        #expect(AnyCodable.null.displayString == "null")
    }

    @Test("Arrays join with commas, elements rendered recursively")
    internal func displayStringArray() {
        let value = AnyCodable.array([.int(1), .string("two"), .bool(true)])
        #expect(value.displayString == "1, two, true")
    }

    @Test("Dictionaries render key: value sorted by key for stable output")
    internal func displayStringDictionarySorted() {
        // Insertion order is deliberately reversed to prove the sort.
        let value = AnyCodable.dictionary(["b": .int(2), "a": .string("x")])
        #expect(value.displayString == "a: x, b: 2")
    }

    @Test("Nested containers render recursively")
    internal func displayStringNested() {
        let value = AnyCodable.dictionary(["items": .array([.int(1), .int(2)])])
        #expect(value.displayString == "items: 1, 2")
    }
}

@Suite("String.truncated")
internal struct StringTruncatedTests {

    @Test("A short string is returned unchanged with no ellipsis")
    internal func shortStringUnchanged() {
        #expect("abc".truncated(to: 5) == "abc")
        // Exactly at the limit is not truncated.
        #expect("abcde".truncated(to: 5) == "abcde")
    }

    @Test("An over-length string is cut to length plus an ellipsis")
    internal func longStringTruncated() {
        #expect("abcdef".truncated(to: 3) == "abc…")
    }

    @Test("Truncating to zero yields just the ellipsis")
    internal func truncateToZero() {
        #expect("abc".truncated(to: 0) == "…")
    }
}
