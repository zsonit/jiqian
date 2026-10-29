import Foundation

struct Gestation: Sendable {
    let totalDays: Int
    var weeks: Int { totalDays / 7 }
    var days: Int { totalDays % 7 }
    var isPreterm: Bool { totalDays < 259 }
    var label: String { "\(weeks) 周 \(days) 天" }
}

enum PregnancyClock {
    /// 以预产期为基准推算孕周。建档机构给的孕周优先，这里只做展示辅助。
    static func gestation(for edd: Date?, now: Date = Date()) -> Gestation? {
        guard let edd else { return nil }
        let cal = Calendar.current
        let from = cal.startOfDay(for: now)
        let to = cal.startOfDay(for: edd)
        guard let daysToEdd = cal.dateComponents([.day], from: from, to: to).day else { return nil }
        let ga = 280 - daysToEdd
        guard ga >= 0, ga <= 320 else { return nil }
        return Gestation(totalDays: ga)
    }
}

enum Fmt {
    static func hhmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func hhmmss(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    static func md(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }

    /// 00:35 / 12:04
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// 1 分 08 秒
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        if m > 0 { return "\(m) 分 \(String(format: "%02d", s)) 秒" }
        return "\(s) 秒"
    }

    static func isSameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }
}
