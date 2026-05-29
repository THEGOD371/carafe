import Foundation

/// One node in a Valve KeyValues (VDF) tree. Either a leaf string or
/// a nested object. Preserves insertion order so we can iterate
/// numbered keys ("0", "1", ...) without sorting.
///
/// Lookup helpers are case-insensitive: Valve's own tools tolerate
/// `"appstate"` vs `"AppState"` and we should too.
struct SteamVDFNode: Equatable {
    var entries: [(key: String, value: SteamVDFValue)] = []

    static func == (lhs: SteamVDFNode, rhs: SteamVDFNode) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        for (l, r) in zip(lhs.entries, rhs.entries) {
            if l.key != r.key || l.value != r.value { return false }
        }
        return true
    }

    func string(_ key: String) -> String? {
        for entry in entries where entry.key.caseInsensitiveCompare(key) == .orderedSame {
            if case .string(let s) = entry.value { return s }
        }
        return nil
    }

    func integer(_ key: String) -> Int? {
        string(key).flatMap(Int.init)
    }

    func object(_ key: String) -> SteamVDFNode? {
        for entry in entries where entry.key.caseInsensitiveCompare(key) == .orderedSame {
            if case .object(let n) = entry.value { return n }
        }
        return nil
    }

    /// All children with string values, in order.
    var stringEntries: [(key: String, value: String)] {
        entries.compactMap { e in
            if case .string(let s) = e.value { return (e.key, s) }
            return nil
        }
    }

    /// All children with object values, in order.
    var objectEntries: [(key: String, value: SteamVDFNode)] {
        entries.compactMap { e in
            if case .object(let n) = e.value { return (e.key, n) }
            return nil
        }
    }
}

enum SteamVDFValue: Equatable {
    case string(String)
    case object(SteamVDFNode)
}

/// Recursive-descent parser for Valve's KeyValues text format.
///
/// FRAGILITY: VDF has multiple dialects. We target the "vdf_text"
/// flavour written by Steam itself (libraryfolders.vdf,
/// appmanifest_*.acf, config.vdf). The binary KeyValues format used
/// elsewhere is out of scope. If we ever see a file that fails to
/// parse, log it but degrade gracefully — never crash the scanner.
enum SteamVDFParser {

    enum Failure: LocalizedError {
        case unexpectedEnd(String)
        case expected(String, at: Int)

        var errorDescription: String? {
            switch self {
            case .unexpectedEnd(let what):
                return "Unexpected end of VDF input while reading \(what)."
            case .expected(let what, let at):
                return "Expected \(what) at position \(at)."
            }
        }
    }

    static func parse(_ text: String) throws -> SteamVDFNode {
        var parser = Parser(text: text)
        return try parser.parseObjectBody()
    }

    /// Parse a file from disk. nil on read failure or parse error.
    static func parseFile(at url: URL) -> SteamVDFNode? {
        // Steam writes UTF-8. Fall back to a lossy decode if the
        // file has weird non-UTF-8 bytes (rare but happens with
        // games whose names contain Latin-1 in older manifests).
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        return try? parse(text)
    }

    // MARK: - Private parser

    private struct Parser {
        let chars: [Character]
        var index: Int = 0

        init(text: String) {
            // Strip BOM if present — Steam files don't usually have
            // one, but some external tools insert it.
            let stripped = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            self.chars = Array(stripped)
        }

        mutating func parseObjectBody() throws -> SteamVDFNode {
            var node = SteamVDFNode()
            skipWhitespaceAndComments()
            while index < chars.count && chars[index] != "}" {
                let key = try parseString()
                skipWhitespaceAndComments()
                let value = try parseValue()
                node.entries.append((key, value))
                skipWhitespaceAndComments()
            }
            return node
        }

        mutating func parseValue() throws -> SteamVDFValue {
            skipWhitespaceAndComments()
            guard index < chars.count else {
                throw Failure.unexpectedEnd("value")
            }
            if chars[index] == "{" {
                index += 1
                let body = try parseObjectBody()
                guard index < chars.count, chars[index] == "}" else {
                    throw Failure.expected("'}'", at: index)
                }
                index += 1
                return .object(body)
            } else {
                return .string(try parseString())
            }
        }

        mutating func parseString() throws -> String {
            skipWhitespaceAndComments()
            guard index < chars.count else {
                throw Failure.unexpectedEnd("string")
            }
            guard chars[index] == "\"" else {
                throw Failure.expected("'\"'", at: index)
            }
            index += 1
            var out = ""
            while index < chars.count {
                let ch = chars[index]
                if ch == "\\" {
                    // Escape sequence: \" \\ \n \t \r — anything else
                    // we pass through verbatim (Steam treats unknown
                    // escapes leniently).
                    index += 1
                    guard index < chars.count else {
                        throw Failure.unexpectedEnd("escape")
                    }
                    switch chars[index] {
                    case "n":  out.append("\n")
                    case "t":  out.append("\t")
                    case "r":  out.append("\r")
                    case "\\": out.append("\\")
                    case "\"": out.append("\"")
                    default:   out.append(chars[index])
                    }
                    index += 1
                } else if ch == "\"" {
                    index += 1
                    return out
                } else {
                    out.append(ch)
                    index += 1
                }
            }
            throw Failure.unexpectedEnd("unterminated string")
        }

        mutating func skipWhitespaceAndComments() {
            while index < chars.count {
                let ch = chars[index]
                if ch.isWhitespace {
                    index += 1
                } else if ch == "/" && index + 1 < chars.count && chars[index + 1] == "/" {
                    while index < chars.count && chars[index] != "\n" {
                        index += 1
                    }
                } else {
                    break
                }
            }
        }
    }
}
