import Foundation

/// Converts inline `$…$` TeX spans in flowing text to Unicode so simple
/// math renders typeset-ish inside paragraphs ("Take half of the
/// coefficient of $x$" → italic 𝑥; "$b^2 - 4ac$" → 𝑏² − 4𝑎𝑐).
///
/// Deliberately conservative:
/// - Only spans a Unicode conversion fully covers are rewritten; anything
///   with structural TeX (\frac, \sum, \int, alignment, …) is left as-is
///   rather than half-converted.
/// - Currency stays untouched: a span must not begin or end with
///   whitespace ("$5 and $10" never matches).
/// - Display math ($$…$$) is untouched — MathView typesets it properly.
enum InlineMath {

    /// Rewrite every convertible `$…$` span in `text`.
    static func render(_ text: String) -> String {
        guard text.contains("$") else { return text }
        var result = ""
        var rest = Substring(text)

        while let open = rest.firstIndex(of: "$") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            // $$ is display math — pass through untouched.
            if afterOpen < rest.endIndex, rest[afterOpen] == "$" {
                result += "$$"
                rest = rest[rest.index(after: afterOpen)...]
                continue
            }
            guard let close = rest[afterOpen...].firstIndex(of: "$") else {
                result += rest[open...]
                return result
            }
            let span = String(rest[afterOpen..<close])
            if let converted = convert(span) {
                result += converted
            } else {
                result += "$\(span)$"
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    /// Convert one span's TeX to Unicode, or nil if any part is beyond a
    /// faithful character-level conversion.
    static func convert(_ span: String) -> String? {
        guard !span.isEmpty,
              span.first?.isWhitespace == false,
              span.last?.isWhitespace == false,
              !span.contains("\n") else { return nil }

        var output = ""
        var chars = Substring(span)

        while let c = chars.first {
            switch c {
            case "\\":
                chars.removeFirst()
                let name = String(chars.prefix { $0.isLetter })
                chars.removeFirst(name.count)
                guard let symbol = Self.commands[name] else { return nil }
                output += symbol
            case "^", "_":
                chars.removeFirst()
                guard let script = takeGroup(&chars) else { return nil }
                let table = (c == "^") ? Self.superscripts : Self.subscripts
                var converted = ""
                for sc in script {
                    guard let mapped = table[sc] else { return nil }
                    converted.append(mapped)
                }
                output += converted
            case let letter where letter.isLetter:
                chars.removeFirst()
                output.append(mathItalic(letter) ?? letter)
            case "*":
                chars.removeFirst()
                output.append("×")
            case "-":
                chars.removeFirst()
                output.append("−")  // minus sign, not hyphen
            case "{", "}":
                // Bare grouping braces vanish in the flat conversion.
                chars.removeFirst()
            case let other where other.isNumber || " +=/()[],.!|<>'".contains(other):
                chars.removeFirst()
                output.append(other)
            default:
                return nil
            }
        }
        let trimmed = output.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : output
    }

    /// Take the next script group: a `{…}` body or a single character.
    private static func takeGroup(_ chars: inout Substring) -> String? {
        guard let first = chars.first else { return nil }
        if first == "{" {
            chars.removeFirst()
            guard let close = chars.firstIndex(of: "}") else { return nil }
            let body = String(chars[..<close])
            chars = chars[chars.index(after: close)...]
            return body
        }
        chars.removeFirst()
        return String(first)
    }

    /// Map a Latin letter to its Unicode mathematical-italic form.
    /// `h` is special-cased (U+1D455 is unassigned; ℎ is Planck's h).
    private static func mathItalic(_ c: Character) -> Character? {
        guard let ascii = c.asciiValue else { return nil }
        if c == "h" { return "ℎ" }
        let scalar: UInt32?
        switch ascii {
        case 65...90:  scalar = 0x1D434 + UInt32(ascii - 65)   // A–Z
        case 97...122: scalar = 0x1D44E + UInt32(ascii - 97)   // a–z
        default: scalar = nil
        }
        return scalar.flatMap(Unicode.Scalar.init).map(Character.init)
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "n": "ⁿ", "i": "ⁱ", "(": "⁽", ")": "⁾",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "n": "ₙ", "i": "ᵢ", "x": "ₓ",
        "a": "ₐ", "e": "ₑ", "o": "ₒ", "(": "₍", ")": "₎",
    ]

    /// TeX commands with faithful single-glyph Unicode equivalents.
    /// Structural commands (\frac, \sum, \sqrt with arguments, …) are
    /// deliberately absent — those spans stay raw TeX.
    private static let commands: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ",
        "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ",
        "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ",
        "Psi": "Ψ", "Omega": "Ω",
        "times": "×", "cdot": "·", "pm": "±", "mp": "∓",
        "div": "÷", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥",
        "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡",
        "sim": "∼", "propto": "∝", "infty": "∞", "partial": "∂",
        "nabla": "∇", "in": "∈", "notin": "∉", "subset": "⊂",
        "supset": "⊃", "cup": "∪", "cap": "∩", "emptyset": "∅",
        "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧",
        "lor": "∨", "to": "→", "rightarrow": "→", "leftarrow": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "iff": "⇔",
        "Leftrightarrow": "⇔", "mapsto": "↦", "circ": "∘",
        "degree": "°", "prime": "′", "ell": "ℓ", "hbar": "ℏ",
        "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "angle": "∠",
        "perp": "⊥", "parallel": "∥", "therefore": "∴", "because": "∵",
        "ldots": "…", "cdots": "⋯", "dots": "…",
    ]
}
