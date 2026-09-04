import Foundation

/// A tiny, line-oriented reader/splicer for Valve's VDF (KeyValues) text
/// format, scoped to exactly what Bifrost needs: locate a nested `{ ... }`
/// block by a path of keys (tolerating case differences — Steam sometimes
/// lowercases intermediate keys like "software"/"valve"), then read or
/// splice a single leaf key inside that block.
///
/// This deliberately does not build a full parse tree. `localconfig.vdf`
/// can be tens of thousands of lines covering data Bifrost has no business
/// touching, so every line outside the one being changed is preserved
/// byte-for-byte: splicing works by mutating a single element of a
/// line array and rejoining with "\n", never touching the rest.
enum VDF {
    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    /// The result of `settingKey`: the full (possibly unchanged) document
    /// text, plus what — if anything — changed.
    struct SpliceResult: Sendable, Equatable {
        let text: String
        let changed: Bool
        /// Zero-based line index that was replaced or inserted. `nil` when
        /// nothing changed.
        let lineIndex: Int?
        let wasInsert: Bool
    }

    /// The `{ ... }` block located for one segment of a key path.
    private struct BlockRange {
        let keyLine: Int
        let openLine: Int
        let closeLine: Int
    }

    // MARK: - Reading

    /// Reads the value of `key` inside the block found by walking `path`
    /// from the document root. Returns `nil` if the block or the key
    /// doesn't exist.
    static func value(forKey key: String, atPath path: [String], in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let block = locate(path: path, in: lines) else { return nil }
        guard let line = findKeyValueLine(key: key, in: lines, range: (block.openLine + 1)..<block.closeLine) else {
            return nil
        }
        return parseKeyValueLine(lines[line])?.value
    }

    // MARK: - Writing

    /// Ensures `key` equals `value` inside the block found by walking
    /// `path`. If the key already holds exactly that value, the returned
    /// text is byte-identical to `text` (`changed == false`). If the key
    /// exists with a different value, only that one line is rewritten. If
    /// the key doesn't exist, a new line is inserted immediately after the
    /// block's opening `{`, indented one tab deeper than it. Every other
    /// line is left untouched.
    ///
    /// - Throws: `ParseError` if the block named by `path` can't be found.
    static func settingKey(_ key: String, to value: String, atPath path: [String], in text: String) throws -> SpliceResult {
        var lines = text.components(separatedBy: "\n")
        guard let block = locate(path: path, in: lines) else {
            throw ParseError(description: "Could not find block for path \(path.joined(separator: "/"))")
        }

        let bodyRange = (block.openLine + 1)..<block.closeLine
        if let existingLine = findKeyValueLine(key: key, in: lines, range: bodyRange) {
            if let parsed = parseKeyValueLine(lines[existingLine]), parsed.value == value {
                return SpliceResult(text: text, changed: false, lineIndex: existingLine, wasInsert: false)
            }
            let indent = leadingWhitespace(of: lines[existingLine])
            lines[existingLine] = "\(indent)\"\(key)\"\t\t\"\(escape(value))\""
            return SpliceResult(text: lines.joined(separator: "\n"), changed: true, lineIndex: existingLine, wasInsert: false)
        }

        let indent = leadingWhitespace(of: lines[block.openLine]) + "\t"
        let newLine = "\(indent)\"\(key)\"\t\t\"\(escape(value))\""
        lines.insert(newLine, at: block.openLine + 1)
        return SpliceResult(text: lines.joined(separator: "\n"), changed: true, lineIndex: block.openLine + 1, wasInsert: true)
    }

    /// Removes `key`'s line from inside the block found by walking `path`,
    /// if present; a no-op (returns `text` unchanged) if it isn't. Used to
    /// build a "key absent" fixture out of a real file for testing, without
    /// risking touching any line outside the target block.
    static func removingKey(_ key: String, atPath path: [String], in text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard let block = locate(path: path, in: lines) else {
            throw ParseError(description: "Could not find block for path \(path.joined(separator: "/"))")
        }
        let bodyRange = (block.openLine + 1)..<block.closeLine
        guard let existingLine = findKeyValueLine(key: key, in: lines, range: bodyRange) else {
            return text
        }
        lines.remove(at: existingLine)
        return lines.joined(separator: "\n")
    }

    // MARK: - Block location

    /// Walks `path` one key at a time, narrowing the search range to each
    /// matched block's body before looking for the next segment.
    private static func locate(path: [String], in lines: [String]) -> BlockRange? {
        guard !path.isEmpty else { return nil }
        var range = 0..<lines.count
        var result: BlockRange?
        for key in path {
            guard let found = findChildBlock(key: key, in: lines, range: range) else { return nil }
            result = found
            range = (found.openLine + 1)..<found.closeLine
        }
        return result
    }

    /// Finds a `"key"` line immediately (ignoring blank lines) followed by
    /// `{`, at the top level of `range` (not inside some other nested
    /// block), and returns the span from that key line to the matching
    /// closing brace. Key matching is case-insensitive.
    private static func findChildBlock(key: String, in lines: [String], range: Range<Int>) -> BlockRange? {
        var i = range.lowerBound
        var depth = 0
        while i < range.upperBound {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            if depth == 0, let lineKey = soleQuotedKey(trimmed), lineKey.caseInsensitiveCompare(key) == .orderedSame {
                var j = i + 1
                while j < range.upperBound, lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    j += 1
                }
                if j < range.upperBound, lines[j].trimmingCharacters(in: .whitespaces) == "{" {
                    var innerDepth = 1
                    var k = j + 1
                    while k < range.upperBound {
                        let t = lines[k].trimmingCharacters(in: .whitespaces)
                        if t == "{" {
                            innerDepth += 1
                        } else if t == "}" {
                            innerDepth -= 1
                            if innerDepth == 0 {
                                return BlockRange(keyLine: i, openLine: j, closeLine: k)
                            }
                        }
                        k += 1
                    }
                    return nil // unbalanced braces
                }
            }

            if trimmed == "{" {
                depth += 1
            } else if trimmed == "}" {
                depth -= 1
            }
            i += 1
        }
        return nil
    }

    /// Finds a `"key" "value"` line at the top level of `range`
    /// (case-insensitive key match), skipping over any nested blocks.
    private static func findKeyValueLine(key: String, in lines: [String], range: Range<Int>) -> Int? {
        var depth = 0
        var i = range.lowerBound
        while i < range.upperBound {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "{" {
                depth += 1
            } else if trimmed == "}" {
                depth -= 1
            } else if depth == 0, let parsed = parseKeyValueLine(lines[i]), parsed.key.caseInsensitiveCompare(key) == .orderedSame {
                return i
            }
            i += 1
        }
        return nil
    }

    // MARK: - Line tokenizing

    /// A line that is *only* a single quoted token (a block-opening key
    /// line), or `nil` otherwise.
    private static func soleQuotedKey(_ trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("\""), trimmedLine.hasSuffix("\""), trimmedLine.count >= 2 else { return nil }
        let tokens = quotedTokens(in: trimmedLine)
        guard tokens.count == 1 else { return nil }
        return tokens[0]
    }

    /// A `"key" "value"` line's key and (unescaped) value, or `nil` if the
    /// line isn't a simple two-token key/value pair.
    private static func parseKeyValueLine(_ line: String) -> (key: String, value: String)? {
        let tokens = quotedTokens(in: line)
        guard tokens.count >= 2 else { return nil }
        return (tokens[0], tokens[1])
    }

    /// Extracts every quoted, backslash-escape-aware token from a line.
    private static func quotedTokens(in line: String) -> [String] {
        var tokens: [String] = []
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\"" else {
                i += 1
                continue
            }
            i += 1
            var content = ""
            while i < chars.count {
                if chars[i] == "\\", i + 1 < chars.count {
                    content.append(chars[i + 1])
                    i += 2
                    continue
                }
                if chars[i] == "\"" {
                    i += 1
                    break
                }
                content.append(chars[i])
                i += 1
            }
            tokens.append(content)
        }
        return tokens
    }

    private static func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == "\t" || $0 == " " })
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            if character == "\\" || character == "\"" {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }
}
