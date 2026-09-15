import Foundation

/// One line in a kid's Morning Mode panel, after the two stores behind it have
/// been merged.
struct MorningItem: Equatable, Identifiable, Sendable {
    /// What the line reads as.
    var text: String
    /// Quieter context under it — the reasons behind a collapsed closure.
    var detail: String?
    var isNotable: Bool

    /// What closure detection looks at, which is not always what's displayed:
    /// a timed event displays as "3:30 PM · Cross Country Meet" but should be
    /// matched on its title alone.
    var matchText: String

    var id: String { "\(text)|\(detail ?? "")" }

    init(text: String, detail: String? = nil, isNotable: Bool, matchText: String? = nil) {
        self.text = text
        self.detail = detail
        self.isNotable = isNotable
        self.matchText = matchText ?? text
    }
}

/// Says "no school" once.
///
/// A closure arrives from every source that knows about it — the district PDF,
/// the school's own newsletter, the lunch calendar — each in its own words.
/// "No School - System Wide PD" and "No School - Professional Development" are
/// one fact written twice, and no string-similarity rule will ever link them:
/// they share almost no words. Matching on the closure phrase itself is the
/// only thing that can.
///
/// This matters more than tidiness. The whole screen is built on one rule —
/// weight means something is different today — and saying the single most
/// consequential thing three times spends that signal on repetition.
///
/// Display only. Nothing is deleted, nothing is merged in the store, and every
/// reason survives as a subdued line. If the detection is ever wrong the worst
/// case is two reasons sitting under one heading that is still true.
enum ClosureCollapse {
    /// Phrases that assert school is out. Deliberately short: these are matched
    /// as substrings, so a longer phrase would only fail to match the shorter
    /// wordings that actually appear.
    private static let closurePhrases = [
        "no school",
        "school closed",
        "no classes",
        "schools closed",
    ]

    /// Words that turn "no school —" into something else entirely.
    ///
    /// "Half day — no school buses" contains the phrase and is emphatically not
    /// a closure. Collapsing it would put a half day under a heading reading
    /// "No school", which is the single worst thing this screen can get wrong:
    /// a parent reads it at 7am and keeps a child home from a school that is
    /// open.
    ///
    /// Matched on the word directly after the phrase. A false negative here
    /// costs nothing — the day simply isn't collapsed, which is exactly how the
    /// app behaved before — so this list errs long rather than short.
    private static let disqualifyingFollowers: Set<String> = [
        "bus", "buses", "board", "lunch", "lunches", "breakfast", "supplies",
        "supply", "uniform", "uniforms", "nurse", "photo", "photos", "picture",
        "pictures", "store", "spirit", "fee", "fees", "pickup", "dropoff",
    ]

    static func isClosure(_ text: String) -> Bool {
        matchedPhrase(in: text) != nil
    }

    private static func matchedPhrase(in text: String) -> String? {
        let normalized = normalize(text)

        // Longest first, so "schools closed" isn't reported as "school closed"
        // and leave a stray "s" behind when the reason is extracted.
        for phrase in closurePhrases.sorted(by: { $0.count > $1.count }) {
            guard let range = normalized.range(of: phrase) else { continue }

            let following = normalized[range.upperBound...]
                .split(separator: " ")
                .first
                .map(String.init)

            if let following, disqualifyingFollowers.contains(following) { continue }
            return phrase
        }
        return nil
    }

    /// Lowercased, with dashes and punctuation flattened to spaces so
    /// "No-School", "No School" and "no school:" all read the same.
    private static func normalize(_ text: String) -> String {
        let flattened = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(flattened).split(separator: " ").joined(separator: " ")
    }

    /// What's left of a closure line once the closure phrase is taken out.
    ///
    /// "No School - System Wide PD" → "System Wide PD"
    /// "School Improvement Day — No School" → "School Improvement Day"
    /// "No school" → nil
    ///
    /// Works on the original text rather than the normalized one, so the reason
    /// keeps its capitalisation — it's shown to a person, not compared.
    static func reason(in text: String) -> String? {
        guard let phrase = matchedPhrase(in: text) else { return nil }

        // Located by walking the original, because normalizing changed the
        // indices and a range from one string can't be applied to the other.
        guard let range = rangeOfPhrase(phrase, in: text) else { return nil }

        var remainder = text
        remainder.removeSubrange(range)

        let separators = CharacterSet(charactersIn: " -–—:·,;()[]/\t\n")
        // Collapsed as well as trimmed: cutting the phrase out of the middle of
        // a sentence leaves a double space where it used to be.
        let trimmed = remainder
            .trimmingCharacters(in: separators)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: separators)

        return trimmed.isEmpty ? nil : trimmed
    }

    /// Finds the phrase in the original text, tolerating the punctuation and
    /// spacing differences that `normalize` flattens away.
    private static func rangeOfPhrase(_ phrase: String, in text: String) -> Range<String.Index>? {
        let words = phrase.split(separator: " ").map(String.init)
        guard let first = words.first, let last = words.last else { return nil }

        guard let start = text.range(of: first, options: [.caseInsensitive]) else { return nil }
        guard let end = text.range(of: last, options: [.caseInsensitive], range: start.lowerBound..<text.endIndex)
        else { return nil }

        return start.lowerBound..<end.upperBound
    }

    /// Collapses every closure in one kid's day into a single line.
    ///
    /// Left alone when there is only one. A lone "No School - Professional
    /// Development" is already correct and already reads once; rewriting it
    /// into a heading plus a sub-line would be churn, and churn in the one
    /// place this app is trusted is not free.
    static func collapse(_ items: [MorningItem]) -> [MorningItem] {
        let closureIndices = items.indices.filter { isClosure(items[$0].matchText) }
        guard closureIndices.count > 1 else { return items }

        var reasons: [String] = []
        var seen = Set<String>()
        for index in closureIndices {
            guard let reason = reason(in: items[index].matchText) else { continue }
            let key = normalize(reason)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            reasons.append(reason)
        }

        let merged = MorningItem(
            text: "No school",
            detail: reasons.isEmpty ? nil : reasons.joined(separator: " · "),
            isNotable: true,
            matchText: "No school"
        )

        // Rebuilt in place rather than appended, so the closure keeps the
        // position it had. A day off belongs where it was, which is above the
        // afternoon's events.
        var result: [MorningItem] = []
        var inserted = false
        for (index, item) in items.enumerated() {
            if closureIndices.contains(index) {
                if !inserted {
                    result.append(merged)
                    inserted = true
                }
                continue
            }
            result.append(item)
        }
        return result
    }
}
