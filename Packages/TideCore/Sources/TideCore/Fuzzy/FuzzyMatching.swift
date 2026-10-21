import Foundation

// Quick Open and Command Palette matching, ported from Visual Studio Code's
// `src/vs/base/common/fuzzyScorer.ts` and `filters.ts`
// (Copyright (c) Microsoft Corporation, MIT License).

/// A scored match: higher is better. `positions` are `Character` offsets into
/// the target, for highlighting.
public struct FuzzyMatch: Equatable, Sendable {
    public var score: Int
    public var positions: [Int]
}

public enum FuzzyScorer {
    /// Scores `target` against `query` with VS Code's Quick Open scorer.
    /// Returns nil when the query characters do not all occur in order.
    public static func score(_ target: String, query: String, allowNonContiguousMatches: Bool = true) -> FuzzyMatch? {
        let targetChars = Array(target)
        let queryChars = Array(query)
        return score(targetChars, lowered(targetChars), queryChars, lowered(queryChars), allowNonContiguousMatches: allowNonContiguousMatches)
    }

    static func score(_ target: [Character], _ targetLower: [Character], _ query: [Character], _ queryLower: [Character], allowNonContiguousMatches: Bool) -> FuzzyMatch? {
        let targetLength = target.count
        let queryLength = query.count
        guard queryLength > 0, targetLength >= queryLength else { return nil }
        guard isSubsequence(queryLower, of: targetLower) else { return nil }

        // Scorer matrix: rows are query characters, columns target characters.
        var scores = [Int](repeating: 0, count: queryLength * targetLength)
        var matches = [Int](repeating: 0, count: queryLength * targetLength)
        for queryIndex in 0..<queryLength {
            let rowOffset = queryIndex * targetLength
            let previousRowOffset = rowOffset - targetLength
            for targetIndex in 0..<targetLength {
                let current = rowOffset + targetIndex
                let left = current - 1
                let diagonal = previousRowOffset + targetIndex - 1
                let leftScore = targetIndex > 0 ? scores[left] : 0
                let diagonalScore = queryIndex > 0 && targetIndex > 0 ? scores[diagonal] : 0
                let sequenceLength = queryIndex > 0 && targetIndex > 0 ? matches[diagonal] : 0

                // After the first query character, only score when the previous
                // query character matched (keeps matches in order).
                let charScore: Int
                if diagonalScore == 0, queryIndex > 0 {
                    charScore = 0
                } else {
                    charScore = characterScore(query[queryIndex], queryLower[queryIndex], target, targetLower, targetIndex, sequenceLength)
                }

                let isValid = charScore > 0 && diagonalScore + charScore >= leftScore
                if isValid, allowNonContiguousMatches || queryIndex > 0 || hasPrefix(targetLower, queryLower, at: targetIndex) {
                    matches[current] = sequenceLength + 1
                    scores[current] = diagonalScore + charScore
                } else {
                    matches[current] = 0
                    scores[current] = leftScore
                }
            }
        }

        // Walk back from the bottom-right corner to recover match positions.
        var positions: [Int] = []
        var queryIndex = queryLength - 1
        var targetIndex = targetLength - 1
        while queryIndex >= 0, targetIndex >= 0 {
            if matches[queryIndex * targetLength + targetIndex] == 0 {
                targetIndex -= 1
            } else {
                positions.append(targetIndex)
                queryIndex -= 1
                targetIndex -= 1
            }
        }
        let total = scores[queryLength * targetLength - 1]
        guard total > 0, positions.count == queryLength else { return nil }
        return FuzzyMatch(score: total, positions: positions.reversed())
    }

    private static func characterScore(_ queryChar: Character, _ queryLowerChar: Character, _ target: [Character], _ targetLower: [Character], _ index: Int, _ sequenceLength: Int) -> Int {
        guard queryLowerChar == targetLower[index] || (isPathSeparator(queryLowerChar) && isPathSeparator(targetLower[index])) else { return 0 }
        var score = 1
        // Consecutive-run bonus as of VS Code 1.142 (it was `n * 5` before).
        if sequenceLength > 0 {
            score += min(sequenceLength, 3) * 6 + max(0, sequenceLength - 3) * 3
        }
        if queryChar == target[index] {
            score += 1
        }
        if index == 0 {
            score += 8
        } else {
            let separatorBonus = separatorScore(target[index - 1])
            if separatorBonus > 0 {
                score += separatorBonus
            } else if target[index].isUppercase, sequenceLength == 0 {
                // camelCase hump, only outside a contiguous run: NPE matches NullPointerException.
                score += 2
            }
        }
        return score
    }

    private static func separatorScore(_ character: Character) -> Int {
        switch character {
        case "/", "\\": 5
        case "_", "-", ".", " ", "'", "\"", ":": 4
        default: 0
        }
    }

    private static func isPathSeparator(_ character: Character) -> Bool {
        character == "/" || character == "\\"
    }

    static func lowered(_ characters: [Character]) -> [Character] {
        characters.map { character in
            character.isUppercase ? (character.lowercased().first ?? character) : character
        }
    }

    static func isSubsequence(_ query: [Character], of target: [Character]) -> Bool {
        var queryIndex = 0
        for character in target where queryIndex < query.count && character == query[queryIndex] {
            queryIndex += 1
        }
        return queryIndex == query.count
    }

    private static func hasPrefix(_ target: [Character], _ prefix: [Character], at index: Int) -> Bool {
        guard index + prefix.count <= target.count else { return false }
        for offset in 0..<prefix.count where target[index + offset] != prefix[offset] {
            return false
        }
        return true
    }

    // MARK: - Items (file name + folder)

    static let pathIdentityScore = 1 << 18
    static let labelPrefixScoreThreshold = 1 << 17
    static let labelScoreThreshold = 1 << 16

    /// Score for a Quick Open item with a `label` (file name) and a
    /// `description` (its folder). Label matches outrank path matches, and a
    /// label prefix match outranks everything but an exact path.
    public struct ItemScore: Equatable, Sendable {
        public var score: Int
        public var labelPositions: [Int]
        public var descriptionPositions: [Int]
    }

    public static func scoreItem(label: String, description: String?, query: String) -> ItemScore? {
        let pieces = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return nil }
        if pieces.count == 1 {
            return scoreItemSingle(label: label, description: description, query: pieces[0])
        }
        // Multiple words: every piece must match; scores add up.
        var total = ItemScore(score: 0, labelPositions: [], descriptionPositions: [])
        for piece in pieces {
            guard let score = scoreItemSingle(label: label, description: description, query: piece) else { return nil }
            total.score += score.score
            total.labelPositions += score.labelPositions
            total.descriptionPositions += score.descriptionPositions
        }
        total.labelPositions = Array(Set(total.labelPositions)).sorted()
        total.descriptionPositions = Array(Set(total.descriptionPositions)).sorted()
        return total
    }

    private static func scoreItemSingle(label: String, description: String?, query: String) -> ItemScore? {
        let path = description.map { $0.isEmpty ? label : "\($0)/\(label)" } ?? label
        if query.lowercased() == path.lowercased() {
            return ItemScore(score: pathIdentityScore, labelPositions: Array(0..<label.count), descriptionPositions: [])
        }
        if let labelMatch = score(label, query: query) {
            var base = labelScoreThreshold
            if label.lowercased().hasPrefix(query.lowercased()) {
                base = labelPrefixScoreThreshold + Int((Double(query.count) / Double(max(label.count, 1)) * 100).rounded())
            }
            return ItemScore(score: base + labelMatch.score, labelPositions: labelMatch.positions, descriptionPositions: [])
        }
        guard let description, !description.isEmpty else { return nil }
        let prefix = description + "/"
        guard let pathMatch = score(prefix + label, query: query) else { return nil }
        let split = prefix.count
        return ItemScore(
            score: pathMatch.score,
            labelPositions: pathMatch.positions.filter { $0 >= split }.map { $0 - split },
            descriptionPositions: pathMatch.positions.filter { $0 < split - 1 }
        )
    }
}

// MARK: - Command filtering

/// Command Palette matching: a contiguous substring, or the starts of
/// consecutive words, so "tog min" finds "View: Toggle Minimap" (VS Code's
/// `or(matchesBaseContiguousSubString, matchesWords)`). Matching ignores case
/// and accents. Returns highlight ranges in `Character` offsets.
public enum WordFilter {
    public static func matches(_ query: String, in target: String) -> [Range<Int>]? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let queryChars = normalized(Array(trimmed))
        let targetChars = normalized(Array(target))
        if let substring = matchesSubstring(queryChars, targetChars) { return substring }
        return matchesWords(queryChars, targetChars)
    }

    /// Lowercases and strips accents per character, keeping one output
    /// character per input character so offsets stay valid.
    static func normalized(_ characters: [Character]) -> [Character] {
        characters.map { character in
            let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return folded.count == 1 ? folded.first! : (character.lowercased().first ?? character)
        }
    }

    static func matchesSubstring(_ query: [Character], _ target: [Character]) -> [Range<Int>]? {
        guard query.count <= target.count else { return nil }
        for start in 0...(target.count - query.count) where Array(target[start..<(start + query.count)]) == query {
            return [start..<(start + query.count)]
        }
        return nil
    }

    static func matchesWords(_ query: [Character], _ target: [Character]) -> [Range<Int>]? {
        var start = 0
        while start < target.count {
            if let result = matchWords(query, target, 0, start) {
                return merge(result)
            }
            start = nextWord(target, from: start + 1)
        }
        return nil
    }

    private static func matchWords(_ query: [Character], _ target: [Character], _ queryIndex: Int, _ targetIndex: Int) -> [Int]? {
        if queryIndex == query.count { return [] }
        if targetIndex == target.count { return nil }
        let queryChar = query[queryIndex]
        let targetChar = target[targetIndex]
        guard queryChar == targetChar || (isSeparator(queryChar) && isSeparator(targetChar)) else { return nil }
        var result = matchWords(query, target, queryIndex + 1, targetIndex + 1)
        var next = targetIndex + 1
        while result == nil {
            next = nextWord(target, from: next)
            guard next < target.count else { break }
            result = matchWords(query, target, queryIndex + 1, next)
            next += 1
        }
        guard let rest = result else { return nil }
        // Matched separators are not highlighted.
        return queryChar == targetChar ? [targetIndex] + rest : rest
    }

    private static func nextWord(_ target: [Character], from start: Int) -> Int {
        var index = start
        while index < target.count {
            if isSeparator(target[index]) || (index > 0 && isSeparator(target[index - 1])) { return index }
            index += 1
        }
        return target.count
    }

    private static let separators: Set<Character> = ["(", ")", "[", "]", "{", "}", "<", ">", "`", "'", "\"", "-", "/", ";", ":", ",", ".", "?", "!", " ", "\t", "_"]

    private static func isSeparator(_ character: Character) -> Bool {
        separators.contains(character)
    }

    public static func merge(_ positions: [Int]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for position in positions.sorted() {
            if let last = ranges.last, last.upperBound == position {
                ranges[ranges.count - 1] = last.lowerBound..<(position + 1)
            } else {
                ranges.append(position..<(position + 1))
            }
        }
        return ranges
    }
}

extension FuzzyMatch {
    /// Positions merged into contiguous ranges, for highlighting.
    public var ranges: [Range<Int>] { WordFilter.merge(positions) }
}
