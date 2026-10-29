import Foundation
import SwiftData

struct ContractionOutcome: Sendable {
    var started: Bool = false
    var ended: Bool = false
    var alreadyRunning: Bool = false
    var noneRunning: Bool = false
    var duration: TimeInterval = 0
    var gap: TimeInterval = 0
    var isSuspect: Bool = false
}

struct ContractionStats: Sendable {
    var hourCount: Int = 0
    var avgDuration: TimeInterval = 0
    var avgGap: TimeInterval = 0
    var sampleCount: Int = 0
    /// 达到需要联系的参考条件
    var trigger: Bool = false
    /// 存在高风险因素时的提前提示
    var soft: Bool = false
    var highRisk: Bool = false
}

/// 宫缩计时：状态不可静默丢失。
/// 开始与结束都是「立即落库」，App 被杀掉后重新打开仍能恢复。
@MainActor
enum ContractionRecorder {
    static let sessionTTL: TimeInterval = 6 * 3600
    /// 近 1 小时次数阈值
    static let triggerHourCount = 6
    /// 平均持续下限（秒）
    static let triggerDuration: TimeInterval = 45
    /// 平均间隔上限（秒）
    static let triggerGap: TimeInterval = 600

    static func openEvent(in ctx: ModelContext) throws -> ContractionEvent? {
        let all = try ctx.fetch(FetchDescriptor<ContractionEvent>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))
        return all.first(where: { $0.endedAt == nil })
    }

    static func finishedEvents(in ctx: ModelContext) throws -> [ContractionEvent] {
        let all = try ctx.fetch(FetchDescriptor<ContractionEvent>(sortBy: [SortDescriptor(\.startedAt)]))
        return all.filter { $0.endedAt != nil }
    }

    @discardableResult
    static func start(source: RecordSource, at date: Date = Date()) throws -> ContractionOutcome {
        let ctx = JiQianStore.context
        if try openEvent(in: ctx) != nil {
            return ContractionOutcome(started: false, alreadyRunning: true)
        }
        var session = try ctx.fetch(FetchDescriptor<ContractionSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))
            .first(where: { $0.endedAt == nil })
        if let s = session, date.timeIntervalSince(s.startedAt) > sessionTTL {
            s.endedAt = s.startedAt.addingTimeInterval(sessionTTL)
            try ctx.save()
            session = nil
        }
        if session == nil {
            let created = ContractionSession(startedAt: date, source: source)
            ctx.insert(created)
            try ctx.save()
            session = created
        }
        guard let targetSession = session else {
            return ContractionOutcome(started: false)
        }
        let event = ContractionEvent(sessionID: targetSession.id, startedAt: date, source: source)
        ctx.insert(event)
        try ctx.save()
        return ContractionOutcome(started: true)
    }

    @discardableResult
    static func end(at date: Date = Date()) throws -> ContractionOutcome {
        let ctx = JiQianStore.context
        guard let event = try openEvent(in: ctx) else {
            return ContractionOutcome(ended: false, noneRunning: true)
        }
        event.endedAt = date
        let duration = date.timeIntervalSince(event.startedAt)
        event.isSuspect = duration < 3

        let earlier = try finishedEvents(in: ctx)
            .filter { $0.id != event.id && $0.startedAt <= event.startedAt }
        var gap: TimeInterval = 0
        if let previous = earlier.last, let previousEnd = previous.endedAt {
            gap = event.startedAt.timeIntervalSince(previousEnd)
        }
        event.gap = gap
        try ctx.save()
        return ContractionOutcome(ended: true,
                                  duration: duration,
                                  gap: gap,
                                  isSuspect: event.isSuspect)
    }

    static func stats(at date: Date = Date()) throws -> ContractionStats {
        let ctx = JiQianStore.context
        let finished = try finishedEvents(in: ctx)
        var result = ContractionStats()
        result.highRisk = !Prefs.risks.isEmpty

        let lastHour = finished.filter { date.timeIntervalSince($0.endedAt ?? $0.startedAt) <= 3600 }
        let sample = Array(finished.suffix(6))
        let durations = sample.map { $0.duration }.filter { $0 > 0 }
        let gaps = stride(from: 1, to: sample.count, by: 1).compactMap { index -> TimeInterval? in
            guard let previousEnd = sample[index - 1].endedAt else { return nil }
            let gap = sample[index].startedAt.timeIntervalSince(previousEnd)
            return gap > 0 ? gap : nil
        }

        result.hourCount = lastHour.count
        result.sampleCount = sample.count
        result.avgDuration = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
        result.avgGap = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
        result.trigger = lastHour.count >= triggerHourCount
            && result.avgDuration >= triggerDuration
            && result.avgGap > 0
            && result.avgGap <= triggerGap
        result.soft = result.highRisk && lastHour.count >= 4
        return result
    }
}
