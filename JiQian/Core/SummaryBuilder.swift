import Foundation
import SwiftData

enum SummaryRange: String, CaseIterable, Identifiable {
    case day
    case threeDays
    case week
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "24 小时"
        case .threeDays: return "3 天"
        case .week: return "7 天"
        case .all: return "全部"
        }
    }

    var hours: Double? {
        switch self {
        case .day: return 24
        case .threeDays: return 72
        case .week: return 168
        case .all: return nil
        }
    }
}

/// 摘要只写事实：时间、次数、时长、间隔。
/// 不含任何判断句，避免医生被 App 的措辞带偏。
@MainActor
enum SummaryBuilder {
    static func build(range: SummaryRange, now: Date = Date()) -> String {
        let context = JiQianStore.context
        let cutoff: Date = {
            guard let hours = range.hours else { return .distantPast }
            return now.addingTimeInterval(-hours * 3600)
        }()

        let sessions = (try? context.fetch(FetchDescriptor<KickSession>(sortBy: [SortDescriptor(\.startedAt)]))) ?? []
        let kicks = (try? context.fetch(FetchDescriptor<KickEvent>(sortBy: [SortDescriptor(\.occurredAt)]))) ?? []
        let contractions = (try? context.fetch(FetchDescriptor<ContractionEvent>(sortBy: [SortDescriptor(\.startedAt)]))) ?? []

        var lines: [String] = []
        lines.append("孕期记录 · \(range == .all ? "全部" : "最近 " + range.label)")
        lines.append("生成时间：\(now.formatted(date: .abbreviated, time: .shortened))")

        if let gestation = PregnancyClock.gestation(for: Prefs.edd, now: now) {
            lines.append("孕周：\(gestation.label)")
        } else {
            lines.append("孕周：未填写预产期")
        }
        if !Prefs.risks.isEmpty {
            lines.append("已标记：\(Prefs.risks.joined(separator: "、"))")
        }
        lines.append("")

        lines.append("【胎动】")
        let rangedSessions = sessions.filter { ($0.endedAt ?? $0.startedAt) >= cutoff }
        var totalKicks = 0
        var wroteAny = false
        for session in rangedSessions {
            let items = kicks.filter { $0.sessionID == session.id && $0.occurredAt >= cutoff }
            guard !items.isEmpty else { continue }
            wroteAny = true
            totalKicks += items.count
            let start = items.first?.occurredAt ?? session.startedAt
            let end = items.last?.occurredAt ?? start
            var line = "- \(Fmt.md(start)) \(Fmt.hhmm(start))：\(items.count) 次，用时 \(Fmt.duration(end.timeIntervalSince(start)))"
            if session.lessThanUsualRaw == 1 {
                line += "（自觉明显少于平时）"
            }
            lines.append(line)
        }
        if !wroteAny {
            lines.append("该时段无记录。")
        } else {
            lines.append("合计 \(totalKicks) 次。")
        }
        lines.append("")

        lines.append("【宫缩】")
        let rangedContractions = contractions.filter { $0.endedAt != nil && $0.startedAt >= cutoff }
        if rangedContractions.isEmpty {
            lines.append("该时段无记录。")
        } else {
            let hourCount = rangedContractions.filter { now.timeIntervalSince($0.endedAt ?? $0.startedAt) <= 3600 }.count
            let durations = rangedContractions.map { $0.duration }.filter { $0 > 0 }
            let gaps = rangedContractions.map { $0.gap }.filter { $0 > 0 }
            let avgDuration = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
            let avgGap = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
            lines.append("- 共 \(rangedContractions.count) 次，近 1 小时 \(hourCount) 次。")
            lines.append("- 平均持续 \(Int(avgDuration.rounded())) 秒，平均间隔 \(avgGap > 0 ? "\(Int((avgGap / 60).rounded())) 分钟" : "—")。")
            let detail = rangedContractions.suffix(8).map { event -> String in
                let dur = Int(event.duration.rounded())
                let gap = event.gap > 0 ? "/\(Int((event.gap / 60).rounded()))′" : ""
                return "\(Fmt.hhmm(event.startedAt))(\(dur)s\(gap))"
            }.joined(separator: "  ")
            lines.append("- 明细：\(detail)")
        }
        lines.append("")
        lines.append("（本记录为患者自述，由「记签」整理，不构成诊断。）")
        return lines.joined(separator: "\n")
    }
}
