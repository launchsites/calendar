import Foundation

public struct EntryContext: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var locale: Locale
    public var mode: EntryMode
    public var defaultDuration: Int
    public var selectedSlot: Date?
    public var ignoredTokens: Set<String>
    public var beforeActivity: ActivityBufferDefaults
    public var afterActivity: ActivityBufferDefaults

    public init(now: Date, calendar: Calendar, locale: Locale, mode: EntryMode,
                defaultDuration: Int = 60, selectedSlot: Date? = nil, ignoredTokens: Set<String> = [],
                beforeActivity: ActivityBufferDefaults = .init(), afterActivity: ActivityBufferDefaults = .init()) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.mode = mode
        self.defaultDuration = defaultDuration
        self.selectedSlot = selectedSlot
        self.ignoredTokens = ignoredTokens
        self.beforeActivity = beforeActivity
        self.afterActivity = afterActivity
    }
}

public struct EntryToken: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let source: String
    public init(id: String, label: String, source: String) {
        self.id = id
        self.label = label
        self.source = source
    }
}

public struct ParsedEntry: Equatable, Sendable {
    public var draft: EventDraft
    public var requestedCalendar: String?
    public var notice: String?
    public var tokens: [EntryToken] = []
    public var fields: Set<EntryField> = []
}

public enum EntryField: Hashable, Sendable {
    case date, start, end, duration, allDay, zone, repetition, before, after
}

public enum EntryError: LocalizedError, Equatable, Sendable {
    case missingTitle, invalidDate, invalidTime, invalidDuration, invalidZone, invalidCalendar
    case invalidRange, tooManyTimes, ambiguousTime, unsupportedRecurrence, allDayConflict, recurrenceEdit

    public var errorDescription: String? {
        switch self {
        case .missingTitle: "Enter a title for this event."
        case .invalidDate: "Enter one valid date, such as today or 2026-11-09."
        case .invalidTime: "Enter a time such as 18:30 or 6:30pm."
        case .invalidDuration: "Enter a duration from 1 minute to 24 hours, such as for 45m."
        case .invalidZone: "Enter a time zone such as @Europe/Lisbon."
        case .invalidCalendar: "Enter a calendar name after /, or remove the slash."
        case .invalidRange: "The start and end must be different. Enter a later end or a duration."
        case .tooManyTimes: "Enter up to two times for the start and end."
        case .ambiguousTime: "This time is skipped or repeated when clocks change. Choose a different time or specify a fixed-offset zone."
        case .unsupportedRecurrence: "Use every followed by one weekday, such as every Tuesday, or set Repeat in the form."
        case .allDayConflict: "An all-day event takes a date, without a time, duration or time zone."
        case .recurrenceEdit: "Repeating rules cannot be changed from an existing event’s title."
        }
    }
}

public struct QuickEntryParser: Sendable {
    private struct Clock {
        let hour: Int
        let minute: Int
    }

    private static let timeTokens = try! NSRegularExpression(
        pattern: #"(?<![^\s,–—-])(\d{1,2})(?::(\d{2}))?(?:[ \t]*(am|pm|a\.m\.|p\.m\.))?(?=\s|[-–—,]|$)|^\d{1,2}:|(?<![^\s,–—-])\d{1,2}:(?=\d|$)"#,
        options: .caseInsensitive
    )
    private static let dateTokens = try! NSRegularExpression(
        pattern: #"(?<!\S)(today|yesterday|tomorrow|tommorow|tomorow|\d{4}-\d{2}-\d{2}),?(?=\s|$)"#,
        options: .caseInsensitive
    )
    private static let zone = #"(?:^|\s)@([^\s]+)(?=\s|$)"#
    private static let calendarMarkers = try! NSRegularExpression(pattern: #"(?:^|\s)/"#)
    private static let duration = #"\s+for\s+(\d+)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours)\s*$"#
    private static let durationLike = #"\s+for\s+\d+\S*\s*\w*\s*$"#

    public init() {}

    public func parse(_ input: String, context: EntryContext) throws -> ParsedEntry {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var calendar = context.calendar
        var explicitZone: TimeZone?
        if let matched = Self.match(Self.zone, in: text),
           let zoneName = matched.groups.first ?? nil {
            guard let zone = TimeZone(identifier: zoneName) else { throw EntryError.invalidZone }
            explicitZone = zone
            calendar.timeZone = zone
            text.removeSubrange(matched.range)
            text = text.trimmingCharacters(in: .whitespaces)
        }
        var requestedCalendar: String?
        let markers = Self.calendarMarkers.matches(in: text, range: NSRange(text.startIndex..., in: text))
        if let marker = markers.last, let range = Range(marker.range, in: text) {
            let name = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(where: \.isNewline) else { throw EntryError.invalidCalendar }
            requestedCalendar = name
            text.removeSubrange(range.lowerBound...)
        }

        let today = calendar.startOfDay(for: context.now)
        var date: Date?
        var repeatRule = RepeatRule.none
        var repeatedWeekday: Int?
        if Self.consume(#"^every(?:\s+|$)"#, from: &text) {
            guard let weekday = Self.takeWeekday(from: &text, calendar: calendar) else {
                throw EntryError.unsupportedRecurrence
            }
            repeatRule = .weekly
            repeatedWeekday = weekday
            date = Self.weekday(weekday, from: today, calendar: calendar, minimumDays: 0)
        } else if let next = Self.match(#"^next\s+"#, in: text) {
            var remainder = String(text[next.range.upperBound...])
            if let weekday = Self.takeWeekday(from: &remainder, calendar: calendar) {
                date = Self.weekday(weekday, from: today, calendar: calendar, minimumDays: 1)
                text = remainder
            }
        }

        if let explicitDate = try Self.takeDate(from: &text, today: today, calendar: calendar) {
            guard date == nil else { throw EntryError.invalidDate }
            date = explicitDate
        }

        var tokens: [EntryToken] = []
        let buffers = try Self.takeBuffers(from: &text, context: context)
        let details = buffers.details
        tokens += buffers.tokens
        let allDay = Self.consume(#"^all[ -]day(?:\s+|$)"#, from: &text)
        var duration: Int?
        if let matched = Self.match(Self.duration, in: text),
           let valueText = matched.groups[0], let unit = matched.groups[1] {
            let multiplier = unit.lowercased().hasPrefix("h") ? 60 : 1
            guard let value = Int(valueText), (1...(1440 / multiplier)).contains(value) else {
                throw EntryError.invalidDuration
            }
            duration = value * multiplier
            text.removeSubrange(matched.range)
        } else if Self.match(Self.durationLike, in: text) != nil {
            throw EntryError.invalidDuration
        }

        let extracted = try Self.takeClocks(from: &text, ignored: context.ignoredTokens)
        let startClock = extracted.clocks.first
        let endClock = extracted.clocks.dropFirst().first
        tokens = extracted.tokens + tokens
        if endClock != nil && duration != nil { throw EntryError.invalidRange }
        if allDay && (startClock != nil || duration != nil || explicitZone != nil || details.before != nil || details.after != nil) {
            throw EntryError.allDayConflict
        }
        if repeatedWeekday != nil && startClock == nil && !allDay {
            throw EntryError.unsupportedRecurrence
        }

        let rawTitle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { throw EntryError.missingTitle }
        let title = rawTitle.prefix(1).uppercased(with: context.locale) + rawTitle.dropFirst()
        let baseDay = date ?? context.selectedSlot.map { calendar.startOfDay(for: $0) } ?? today
        let minutes = duration ?? min(max(context.defaultDuration, 1), 1440)

        var start: Date
        var end: Date
        var notice: String?
        if allDay {
            start = baseDay
            if repeatedWeekday != nil && start < today {
                start = calendar.date(byAdding: .day, value: 7, to: start) ?? start
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: start) else {
                throw EntryError.invalidDate
            }
            end = next
        } else if let startClock {
            start = try Self.date(at: startClock, on: baseDay, calendar: calendar)
            if start < context.now {
                if repeatedWeekday != nil {
                    guard let day = calendar.date(byAdding: .day, value: 7, to: baseDay) else {
                        throw EntryError.invalidDate
                    }
                    start = try Self.date(at: startClock, on: day, calendar: calendar)
                } else if date == nil && context.selectedSlot == nil && context.mode == .schedule {
                    guard let day = calendar.date(byAdding: .day, value: 1, to: today) else {
                        throw EntryError.invalidDate
                    }
                    start = try Self.date(at: startClock, on: day, calendar: calendar)
                }
            }
            if let endClock {
                let startMinute = startClock.hour * 60 + startClock.minute
                let endMinute = endClock.hour * 60 + endClock.minute
                guard endMinute != startMinute else { throw EntryError.invalidRange }
                var endDay = calendar.startOfDay(for: start)
                if endMinute < startMinute {
                    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: endDay) else {
                        throw EntryError.invalidDate
                    }
                    endDay = tomorrow
                }
                end = try Self.date(at: endClock, on: endDay, calendar: calendar)
            } else {
                end = start.addingTimeInterval(Double(minutes) * 60)
            }
        } else {
            if let slot = context.selectedSlot, date == nil {
                start = slot
                notice = "Using the selected time. You can change it before saving."
            } else if date != nil {
                start = try Self.date(at: Clock(hour: 9, minute: 0), on: baseDay, calendar: calendar)
                notice = "Suggested start: 09:00. You can change it before saving."
            } else {
                start = calendar.dateInterval(of: .minute, for: context.now)?.start ?? context.now
                notice = "Using the current time. You can change it before saving."
            }
            end = start.addingTimeInterval(Double(minutes) * 60)
        }

        var fields: Set<EntryField> = []
        if date != nil { fields.insert(.date) }
        if startClock != nil { fields.insert(.start) }
        if endClock != nil { fields.insert(.end) }
        if duration != nil { fields.insert(.duration) }
        if allDay { fields.insert(.allDay) }
        if explicitZone != nil { fields.insert(.zone) }
        if repeatedWeekday != nil { fields.insert(.repetition) }
        if details.before != nil { fields.insert(.before) }
        if details.after != nil { fields.insert(.after) }
        return ParsedEntry(
            draft: EventDraft(title: title, start: start, end: end, allDay: allDay,
                              timeZoneID: allDay ? nil : (explicitZone ?? calendar.timeZone).identifier,
                              repetition: repeatRule, notes: details.notes(description: nil)),
            requestedCalendar: requestedCalendar, notice: notice, tokens: tokens, fields: fields
        )
    }

    /// Interpret only the fields actually written, keeping the rest of the existing event intact.
    public func parseEdit(_ input: String, original: EventDraft, context: EntryContext) throws -> ParsedEntry {
        var context = context
        context.selectedSlot = original.start
        context.mode = .log
        if let zone = original.timeZoneID.flatMap(TimeZone.init(identifier:)) { context.calendar.timeZone = zone }
        var parsed = try parse(input, context: context)
        let fields = parsed.fields
        guard !fields.contains(.repetition) else { throw EntryError.recurrenceEdit }
        if original.allDay && fields.contains(.duration) && !fields.contains(.start) { throw EntryError.allDayConflict }
        var draft = original
        draft.title = fields.isEmpty && parsed.requestedCalendar == nil
            ? input.trimmingCharacters(in: .whitespacesAndNewlines) : parsed.draft.title
        var calendar = context.calendar
        if fields.contains(.zone), let zone = parsed.draft.timeZoneID.flatMap(TimeZone.init(identifier:)) {
            calendar.timeZone = zone
            draft.timeZoneID = zone.identifier
        }
        if fields.contains(.allDay) {
            draft.start = parsed.draft.start
            draft.end = parsed.draft.end
            draft.allDay = true
            draft.timeZoneID = nil
        } else if fields.contains(.start) || fields.contains(.date) || fields.contains(.duration) {
            if fields.contains(.start) {
                draft.start = parsed.draft.start
                draft.allDay = false
                if original.allDay { draft.timeZoneID = parsed.draft.timeZoneID }
            } else if fields.contains(.date) {
                if original.allDay { draft.start = calendar.startOfDay(for: parsed.draft.start) }
                else {
                    let time = calendar.dateComponents([.hour, .minute], from: original.start)
                    draft.start = try Self.date(at: Clock(hour: time.hour ?? 0, minute: time.minute ?? 0),
                                                on: parsed.draft.start, calendar: calendar)
                }
            }
            if fields.contains(.end) { draft.end = parsed.draft.end }
            else if fields.contains(.duration) { draft.end = draft.start + parsed.draft.end.timeIntervalSince(parsed.draft.start) }
            else if original.allDay && !fields.contains(.start) {
                let days = max(1, calendar.dateComponents([.day], from: original.start, to: original.end).day ?? 1)
                draft.end = calendar.date(byAdding: .day, value: days, to: draft.start) ?? draft.start + 86400
            } else {
                let duration = original.allDay ? Double(context.defaultDuration * 60) : original.end.timeIntervalSince(original.start)
                draft.end = draft.start + duration
            }
        }
        var details = original.activityDetails
        if let before = parsed.draft.activityDetails.before {
            var value = details.before ?? before
            value.minutes = before.minutes
            details.before = value
        }
        if let after = parsed.draft.activityDetails.after {
            var value = details.after ?? after
            value.minutes = after.minutes
            details.after = value
        }
        draft.activityDetails = details
        parsed.draft = draft
        parsed.notice = nil
        return parsed
    }

    private static func takeDate(from text: inout String, today: Date, calendar: Calendar) throws -> Date? {
        let dates = dateTokens.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let token = dates.first else { return nil }
        guard dates.count == 1, let range = Range(token.range, in: text),
              let value = capture(1, of: token, in: text) else { throw EntryError.invalidDate }

        let day: Date?
        switch value.lowercased() {
        case "today":
            day = today
        case "yesterday":
            day = calendar.date(byAdding: .day, value: -1, to: today)
        case "tomorrow", "tommorow", "tomorow":
            day = calendar.date(byAdding: .day, value: 1, to: today)
        default:
            let parts = value.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { throw EntryError.invalidDate }
            // ISO dates are Gregorian even if the device uses a different display calendar.
            var iso = Calendar(identifier: .gregorian)
            iso.timeZone = calendar.timeZone
            let expected = DateComponents(year: parts[0], month: parts[1], day: parts[2])
            guard let date = iso.date(from: expected),
                  iso.dateComponents([.year, .month, .day], from: date) == expected else {
                throw EntryError.invalidDate
            }
            day = date
        }
        guard let day else { throw EntryError.invalidDate }
        let dateRange = includingPrefix("on", before: range, in: text)
        text = titleText(in: text, removing: [dateRange])
        return calendar.startOfDay(for: day)
    }

    private static func takeBuffers(from text: inout String, context: EntryContext)
        throws -> (details: ActivityDetails, tokens: [EntryToken]) {
        // Match complete clauses together, in input order. Parsing "before" separately would
        // incorrectly consume "before 5m" inside "11m before 5m after".
        let pattern = #"(?<!\S)(?:(\d+)\s*(m|min|mins|minutes?|h|hr|hrs|hours?)\s+(before|after)|(before|after)\s+(\d+)\s*(m|min|mins|minutes?|h|hr|hrs|hours?)?)(?=\s|$)"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        var details = ActivityDetails()
        var tokens: [EntryToken] = []
        var removals: [Range<String.Index>] = []
        var seen: Set<String> = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text),
                  let key = (capture(3, of: match, in: text) ?? capture(4, of: match, in: text))?.lowercased(),
                  let amount = (capture(1, of: match, in: text) ?? capture(5, of: match, in: text)).flatMap(Int.init)
            else { continue }
            let raw = String(text[range])
            let id = "buffer:\(key):\(raw.lowercased())"
            guard !context.ignoredTokens.contains(id) else { continue }
            guard seen.insert(key).inserted else { throw EntryError.invalidDuration }
            let unit = capture(2, of: match, in: text) ?? capture(6, of: match, in: text)
            let multiplier = unit?.lowercased().hasPrefix("h") == true ? 60 : 1
            guard (1...(1440 / multiplier)).contains(amount) else { throw EntryError.invalidDuration }
            let defaults = key == "before" ? context.beforeActivity : context.afterActivity
            let value = defaults.buffer(minutes: amount * multiplier)
            if key == "before" { details.before = value } else { details.after = value }
            tokens.append(EntryToken(id: id, label: "\(key.capitalized) \(value.minutes)m", source: raw))
            removals.append(range)
        }
        text = titleText(in: text, removing: removals)
        return (details, tokens)
    }

    private static func takeClocks(from text: inout String, ignored: Set<String>)
        throws -> (clocks: [Clock], tokens: [EntryToken]) {
        let matches = timeTokens.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let explicit = matches.filter {
            capture(2, of: $0, in: text) != nil || capture(3, of: $0, in: text) != nil
        }
        var clocks: [(clock: Clock, range: Range<String.Index>, token: EntryToken)] = []
        var occurrences: [String: Int] = [:]
        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range, in: text),
                  let hourText = capture(1, of: match, in: text), var hour = Int(hourText) else {
                throw EntryError.invalidTime
            }
            let raw = String(text[range])
            let occurrence = occurrences[raw.lowercased(), default: 0]
            occurrences[raw.lowercased()] = occurrence + 1
            let id = "clock:\(raw.lowercased()):\(occurrence)"
            guard !ignored.contains(id) else { continue }
            let minuteText = capture(2, of: match, in: text)
            let meridiem = capture(3, of: match, in: text)?.lowercased()
            if minuteText == nil && meridiem == nil {
                guard explicit.count < 2, (0...23).contains(hour) else { continue }
                let tail = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = text[..<range.lowerBound]
                let hasCue = prefix.range(of: #"(?:^|\s)(?:at|from|between|to|until)\s*$"#,
                                          options: [.regularExpression, .caseInsensitive]) != nil
                if let clock = explicit.first, let explicitRange = Range(clock.range, in: text) {
                    guard explicitRange.upperBound <= range.lowerBound || prefix.trimmingCharacters(in: .whitespaces).isEmpty || hasCue else {
                        continue
                    }
                }
                let isBufferAmount = prefix.range(of: #"(?:^|\s)(?:before|after)\s*$"#,
                                                   options: [.regularExpression, .caseInsensitive]) != nil
                    || tail.range(of: #"^(?:before|after)(?:\s|$)"#,
                                  options: [.regularExpression, .caseInsensitive]) != nil
                let neighborRanges = [index - 1, index + 1].filter { matches.indices.contains($0) }
                    .compactMap { Range(matches[$0].range, in: text) }
                let hasNeighbor = neighborRanges.contains { neighbor in
                    let gap = neighbor.upperBound <= range.lowerBound
                        ? String(text[neighbor.upperBound..<range.lowerBound])
                        : String(text[range.upperBound..<neighbor.lowerBound])
                    return gap.range(of: #"^\s*(?:[-–—,]|to|until|and)?\s*$"#,
                                     options: [.regularExpression, .caseInsensitive]) != nil
                }
                guard !isBufferAmount, tail.isEmpty || hasCue || hasNeighbor else { continue }
            }
            let minute = minuteText.flatMap(Int.init) ?? 0
            if let meridiem {
                guard (1...12).contains(hour) else { throw EntryError.invalidTime }
                hour = hour % 12 + (meridiem.hasPrefix("p") ? 12 : 0)
            }
            guard (0...23).contains(hour), (0...59).contains(minute) else { throw EntryError.invalidTime }
            let clock = Clock(hour: hour, minute: minute)
            let label = String(format: "%@ %02d:%02d", clocks.isEmpty ? "Start" : "End", hour, minute)
            clocks.append((clock, range, EntryToken(id: id, label: label, source: raw)))
            guard clocks.count <= 2 else { throw EntryError.tooManyTimes }
        }

        guard let first = clocks.first else { return ([], []) }
        let firstPrefix = clocks.count == 2 ? "at|from|between" : "at|from"
        let firstRange = includingPrefix(firstPrefix, before: first.range, in: text)
        var removals = [firstRange]
        if let last = clocks.dropFirst().first {
            let between = String(text[first.range.upperBound..<last.range.lowerBound])
            if match(#"^\s*(?:[-–—,]|to|until|and)\s*$"#, in: between) != nil {
                removals = [firstRange.lowerBound..<last.range.upperBound]
            } else {
                removals.append(includingPrefix("at|to|until", before: last.range, in: text))
            }
        } else if firstRange.lowerBound == text.startIndex,
                  match(#"^\s*(?:[-–—]|to\s+|until\s+)"#, in: String(text[first.range.upperBound...])) != nil {
            throw EntryError.invalidTime
        }

        text = titleText(in: text, removing: removals)
        return (clocks.map(\.clock), clocks.map(\.token))
    }

    private static func includingPrefix(_ words: String, before range: Range<String.Index>,
                                        in text: String) -> Range<String.Index> {
        let prefix = text[..<range.lowerBound]
        guard let connector = prefix.range(of: #"(?:^|\s)(?:\#(words))\s+$"#,
                                           options: [.regularExpression, .caseInsensitive]) else { return range }
        return connector.lowerBound..<range.upperBound
    }

    private static func titleText(in text: String, removing ranges: [Range<String.Index>]) -> String {
        var fragments: [String] = []
        var start = text.startIndex
        for range in ranges {
            let fragment = text[start..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !fragment.isEmpty { fragments.append(fragment) }
            start = range.upperBound
        }
        let tail = text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { fragments.append(tail) }
        return fragments.joined(separator: " ")
    }

    private static func capture(_ index: Int, of token: NSTextCheckingResult, in text: String) -> String? {
        Range(token.range(at: index), in: text).map { String(text[$0]) }
    }

    private static func date(at time: Clock, on day: Date, calendar: Calendar) throws -> Date {
        let start = calendar.startOfDay(for: day)
        let reference = start.addingTimeInterval(-1)
        let clock = DateComponents(hour: time.hour, minute: time.minute, second: 0)
        guard let first = calendar.nextDate(after: reference, matching: clock, matchingPolicy: .strict,
                                            repeatedTimePolicy: .first),
              calendar.isDate(first, inSameDayAs: day),
              let last = calendar.nextDate(after: reference, matching: clock, matchingPolicy: .strict,
                                           repeatedTimePolicy: .last),
              first == last else {
            throw EntryError.ambiguousTime
        }
        return first
    }

    private static func weekday(_ target: Int, from date: Date, calendar: Calendar, minimumDays: Int) -> Date? {
        let distance = (target - calendar.component(.weekday, from: date) + 7) % 7
        return calendar.date(byAdding: .day, value: distance < minimumDays ? distance + 7 : distance, to: date)
    }

    private static func takeWeekday(from text: inout String, calendar: Calendar) -> Int? {
        var english = Calendar(identifier: .gregorian)
        english.locale = Locale(identifier: "en_US_POSIX")
        let names = [calendar.weekdaySymbols, calendar.shortWeekdaySymbols,
                     english.weekdaySymbols, english.shortWeekdaySymbols]
        guard let word = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        for group in names {
            if let index = group.firstIndex(where: { $0.caseInsensitiveCompare(String(word)) == .orderedSame }) {
                text = String(text.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
                return index + 1
            }
        }
        return nil
    }

    private static func consume(_ pattern: String, from text: inout String) -> Bool {
        guard let matched = match(pattern, in: text) else { return false }
        text.removeSubrange(matched.range)
        return true
    }

    private static func match(_ pattern: String, in text: String) -> (range: Range<String.Index>, groups: [String?])? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        let groups = (1..<match.numberOfRanges).map { index in
            capture(index, of: match, in: text)
        }
        return (range, groups)
    }
}
