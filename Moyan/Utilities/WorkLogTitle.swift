import Foundation

/// 工作日志标题解析：单日 `2026-08-04` 或跨日 `2026-08-04～05`。
enum WorkLogTitle {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 从标题解析起止日（按自然日）；无法识别则返回 nil。
    /// - Important: 区间只用 `～` / `~` / 破折号分隔，**不能**用 `-` 拆 `yyyy-MM-dd`，否则会把年份误当成「日」。
    static func dateRange(from title: String) -> (start: Date, end: Date)? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 整段即单日
        if let single = dayFormatter.date(from: trimmed) {
            return (single, single)
        }

        // 仅用波浪/破折号做区间分隔（不含日期里的 `-`）
        let rangeSeparators = CharacterSet(charactersIn: "～~—–")
        let parts = trimmed
            .components(separatedBy: rangeSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard parts.count >= 2,
              let start = parseFlexibleDay(parts[0], relativeTo: nil) else {
            // 再试一次宽松单日（如误写）
            if let start = parseFlexibleDay(trimmed, relativeTo: nil) {
                return (start, start)
            }
            return nil
        }

        let endRaw = parts[1]
        guard let end = parseFlexibleDay(endRaw, relativeTo: start), end >= start else {
            return (start, start)
        }
        return (start, end)
    }

    /// 标题是否覆盖某一自然日（含区间内）。
    static func covers(_ title: String, day: Date, calendar: Calendar = .current) -> Bool {
        guard let range = dateRange(from: title) else { return false }
        let dayStart = calendar.startOfDay(for: day)
        let start = calendar.startOfDay(for: range.start)
        let end = calendar.startOfDay(for: range.end)
        return dayStart >= start && dayStart <= end
    }

    /// 将昨日起止与今日拼成区间标题，如 `2026-08-04～05`。
    static func continuedTitle(previousTitle: String, today: Date = .now, calendar: Calendar = .current) -> String {
        let todayStart = calendar.startOfDay(for: today)
        let start: Date
        if let range = dateRange(from: previousTitle) {
            start = calendar.startOfDay(for: range.start)
        } else if let parsed = dayFormatter.date(from: previousTitle.trimmingCharacters(in: .whitespacesAndNewlines)) {
            start = calendar.startOfDay(for: parsed)
        } else {
            // 无昨日可解析标题时，退回「昨天～今天」
            start = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        }

        if calendar.isDate(start, inSameDayAs: todayStart) {
            return dayFormatter.string(from: todayStart)
        }
        return formatRange(start: start, end: todayStart, calendar: calendar)
    }

    /// 格式化为 `yyyy-MM-dd` 或缩短尾日的区间标题。
    static func formatRange(start: Date, end: Date, calendar: Calendar = .current) -> String {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        let startText = dayFormatter.string(from: startDay)
        if calendar.isDate(startDay, inSameDayAs: endDay) {
            return startText
        }

        let startY = calendar.component(.year, from: startDay)
        let startM = calendar.component(.month, from: startDay)
        let endY = calendar.component(.year, from: endDay)
        let endM = calendar.component(.month, from: endDay)
        let endD = calendar.component(.day, from: endDay)

        if startY == endY, startM == endM {
            return String(format: "%@～%02d", startText, endD)
        }
        if startY == endY {
            return String(format: "%@～%02d-%02d", startText, endM, endD)
        }
        return "\(startText)～\(dayFormatter.string(from: endDay))"
    }

    /// 排序 / 画廊用：取区间结束日（最新一天）。
    static func sortDate(from title: String) -> Date? {
        dateRange(from: title)?.end
    }

    // MARK: - Private

    /// 支持 `yyyy-MM-dd` / `MM-dd` / `dd`，缺省部分相对 `relativeTo` 补齐。
    private static func parseFlexibleDay(_ raw: String, relativeTo base: Date?) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let full = dayFormatter.date(from: trimmed) {
            return full
        }

        let calendar = Calendar(identifier: .gregorian)
        let parts = trimmed.split(separator: "-").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }

        var year = base.map { calendar.component(.year, from: $0) } ?? calendar.component(.year, from: Date())
        var month = base.map { calendar.component(.month, from: $0) } ?? calendar.component(.month, from: Date())
        var day: Int

        switch parts.count {
        case 1:
            day = parts[0]
        case 2:
            month = parts[0]
            day = parts[1]
        case 3:
            year = parts[0]
            month = parts[1]
            day = parts[2]
        default:
            return nil
        }

        // 拒绝明显非法值，避免 day=2026 一类溢出到「2032年2月」
        guard (2000...2100).contains(year),
              (1...12).contains(month),
              (1...31).contains(day) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        // 再校验未被日历进位（如 2 月 31 日）
        guard calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }
}
