import Foundation

/// 判断纯文本内容是否可以明确识别为 Markdown，用于决定拖出时生成 `.md` 还是 `.txt`。
enum MarkdownDetector {
    private static let maximumInspectedCharacters = 65_536

    static func isMarkdown(_ rawText: String) -> Bool {
        let sample = String(rawText.prefix(maximumInspectedCharacters))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // JSON、unified diff 等结构化纯文本不误判为 Markdown。
        if isValidJSON(trimmed) { return false }

        let lines = sample.components(separatedBy: "\n")
        if isUnifiedDiff(lines) { return false }

        let hasShebang = lines.first?.hasPrefix("#!") == true

        var inFenceCharacter: Character?
        var inFenceLength = 0
        var pairedFences = 0
        var atxHeadingLevel1Count = 0
        var atxHeadingLevel2PlusCount = 0
        var setextHeadingCount = 0
        var taskListCount = 0
        var listLineCount = 0
        var blockquoteCount = 0
        var referenceLinkCount = 0
        var tableCount = 0
        var horizontalRuleCount = 0

        var previousNonFencedLine: String?
        var previousLineWasPlainProse = false
        var nonFencedLines: [String] = []

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if let fenceChar = inFenceCharacter {
                if isClosingFence(trimmedLine, character: fenceChar, minimumLength: inFenceLength) {
                    inFenceCharacter = nil
                    inFenceLength = 0
                    pairedFences += 1
                }
                previousNonFencedLine = nil
                previousLineWasPlainProse = false
                continue
            }

            if let (char, length) = openingFence(in: line) {
                inFenceCharacter = char
                inFenceLength = length
                previousNonFencedLine = nil
                previousLineWasPlainProse = false
                continue
            }

            nonFencedLines.append(line)

            if let previous = previousNonFencedLine,
               isTableHeader(previous),
               isTableSeparator(trimmedLine) {
                tableCount += 1
                previousNonFencedLine = line
                previousLineWasPlainProse = false
                continue
            }

            if let level = atxHeadingLevel(in: line) {
                if level == 1 {
                    atxHeadingLevel1Count += 1
                } else {
                    atxHeadingLevel2PlusCount += 1
                }
                previousNonFencedLine = line
                previousLineWasPlainProse = false
                continue
            }

            if matches(Self.taskListRegex, in: line) {
                taskListCount += 1
                previousNonFencedLine = line
                previousLineWasPlainProse = false
                continue
            }

            if matches(Self.listItemRegex, in: line) {
                listLineCount += 1
                previousNonFencedLine = line
                previousLineWasPlainProse = false
                continue
            }

            if matches(Self.blockquoteRegex, in: line) {
                blockquoteCount += 1
                previousNonFencedLine = line
                previousLineWasPlainProse = false
                continue
            }

            if matches(Self.referenceLinkRegex, in: line) {
                referenceLinkCount += 1
                previousNonFencedLine = line
                previousLineWasPlainProse = false
                continue
            }

            if previousLineWasPlainProse, matches(Self.setextUnderlineRegex, in: line) {
                setextHeadingCount += 1
                previousNonFencedLine = line
                previousLineWasPlainProse = false
                continue
            }

            if matches(Self.horizontalRuleRegex, in: line) {
                horizontalRuleCount += 1
                previousNonFencedLine = line
                previousLineWasPlainProse = false
                continue
            }

            previousNonFencedLine = line
            previousLineWasPlainProse = !trimmedLine.isEmpty
        }

        if hasShebang && pairedFences == 0 {
            return false
        }

        let nonFencedText = nonFencedLines.joined(separator: "\n")
        let inlineLinkCount = countMatches(Self.inlineImageRegex, in: nonFencedText)
            + countMatches(Self.inlineLinkRegex, in: nonFencedText)
        let boldCount = countMatches(Self.asteriskBoldRegex, in: nonFencedText)
            + countMatches(Self.underscoreBoldRegex, in: nonFencedText)
        let strikethroughCount = countMatches(Self.strikethroughRegex, in: nonFencedText)
        let inlineCodeCount = countMatches(Self.inlineCodeRegex, in: nonFencedText)

        var score = 0
        if pairedFences > 0 { score += 4 }
        if tableCount > 0 { score += 4 }
        if inlineLinkCount > 0 { score += 3 }
        if referenceLinkCount > 0 { score += 3 }
        if taskListCount > 0 { score += 3 }
        if atxHeadingLevel2PlusCount > 0 { score += 3 }
        if atxHeadingLevel1Count > 0 { score += 2 }
        if boldCount >= 2 {
            score += 3
        } else if boldCount == 1 {
            score += 2
        }
        if strikethroughCount > 0 { score += 2 }
        if inlineCodeCount >= 2 {
            score += 2
        } else if inlineCodeCount == 1 {
            score += 1
        }
        if blockquoteCount >= 2 {
            score += 2
        } else if blockquoteCount == 1 {
            score += 1
        }
        if listLineCount > 0 { score += 1 }
        if setextHeadingCount > 0 { score += 1 }
        if horizontalRuleCount > 0 { score += 1 }

        return score >= 3
    }

    private static func isValidJSON(_ trimmed: String) -> Bool {
        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
        else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
    }

    private static func isUnifiedDiff(_ lines: [String]) -> Bool {
        if lines.contains(where: { $0.hasPrefix("diff --git ") }) {
            return true
        }
        let hasMinus = lines.contains(where: { $0.hasPrefix("--- ") })
        let hasPlus = lines.contains(where: { $0.hasPrefix("+++ ") })
        let hasHunk = lines.contains(where: { $0.hasPrefix("@@ ") })
        return hasMinus && hasPlus && hasHunk
    }

    private static func openingFence(in line: String) -> (Character, Int)? {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = openingFenceRegex.firstMatch(in: line, range: range) else { return nil }
        let fence = nsLine.substring(with: match.range(at: 1))
        let info = nsLine.substring(with: match.range(at: 2))
        guard let char = fence.first else { return nil }
        if char == "`", info.contains("`") {
            return nil
        }
        return (char, fence.count)
    }

    private static func isClosingFence(_ trimmedLine: String, character: Character, minimumLength: Int) -> Bool {
        guard trimmedLine.count >= minimumLength else { return false }
        return trimmedLine.allSatisfy { $0 == character }
    }

    private static func atxHeadingLevel(in line: String) -> Int? {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = atxHeadingRegex.firstMatch(in: line, range: range) else { return nil }
        let hashes = nsLine.substring(with: match.range(at: 1))
        let content = nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty, !content.allSatisfy({ $0 == "#" }) else { return nil }
        return hashes.count
    }

    private static func isTableHeader(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        return line.contains { $0 != "|" && !$0.isWhitespace }
    }

    private static func isTableSeparator(_ trimmedLine: String) -> Bool {
        guard trimmedLine.contains("|") else { return false }
        return matches(tableSeparatorRegex, in: trimmedLine)
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func countMatches(_ regex: NSRegularExpression, in text: String) -> Int {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.numberOfMatches(in: text, range: range)
    }

    private static let openingFenceRegex = try! NSRegularExpression(
        pattern: "^\\s{0,3}(`{3,}|~{3,})(.*)$"
    )
    private static let atxHeadingRegex = try! NSRegularExpression(
        pattern: "^\\s{0,3}(#{1,6})[ \\t]+(.+)$"
    )
    private static let taskListRegex = try! NSRegularExpression(
        pattern: "^\\s{0,3}(?:[-*+]|\\d+\\.)[ \\t]+\\[[ xX]\\][ \\t]+\\S"
    )
    private static let listItemRegex = try! NSRegularExpression(
        pattern: "^\\s{0,3}(?:[-*+]|\\d+\\.)[ \\t]+\\S"
    )
    private static let blockquoteRegex = try! NSRegularExpression(
        pattern: "^\\s{0,3}>[ \\t]+\\S"
    )
    private static let referenceLinkRegex = try! NSRegularExpression(
        pattern: "^\\s{0,3}\\[[^\\]\\n]+\\]:[ \\t]+(?:https?://\\S+|<\\S+>|/\\S+|\\.\\.?/\\S+)"
    )
    private static let tableSeparatorRegex = try! NSRegularExpression(
        pattern: "^\\|?\\s*:?-{3,}:?\\s*(?:\\|\\s*:?-{3,}:?\\s*)*\\|?\\s*$"
    )
    private static let setextUnderlineRegex = try! NSRegularExpression(
        pattern: "^\\s{0,3}(?:={3,}|-{3,})\\s*$"
    )
    private static let horizontalRuleRegex = try! NSRegularExpression(
        pattern: "^\\s{0,3}(?:\\*{3,}|-{3,}|_{3,})\\s*$"
    )
    private static let inlineImageRegex = try! NSRegularExpression(
        pattern: "!\\[[^\\]\\n]*\\]\\((?:https?://|/|#|\\.\\.?/|[^\\s)\\n]*[/.][^\\s)\\n]*)\\)"
    )
    private static let inlineLinkRegex = try! NSRegularExpression(
        pattern: "(?<!!)\\[[^\\]\\n]+\\]\\((?:https?://|mailto:|/|#|\\.\\.?/|[^\\s)\\n]*[/.][^\\s)\\n]*)\\)"
    )
    private static let asteriskBoldRegex = try! NSRegularExpression(
        pattern: "(?<!\\*)\\*\\*(?!\\s|\\*)([^\\n*]+?)(?<!\\s)\\*\\*(?!\\*)"
    )
    private static let underscoreBoldRegex = try! NSRegularExpression(
        pattern: "(?<![\\w_])__(?!\\s|_)(?![A-Za-z0-9]+__)([^\\n_]+?)(?<!\\s)__(?![\\w_])"
    )
    private static let strikethroughRegex = try! NSRegularExpression(
        pattern: "(?<!~)~~(?!\\s|~)([^\\n~]+?)(?<!\\s)~~(?!~)"
    )
    private static let inlineCodeRegex = try! NSRegularExpression(
        pattern: "(?<!`)`(?!\\s|`)([^`\\n]+?)(?<!\\s)`(?!`)"
    )
}
