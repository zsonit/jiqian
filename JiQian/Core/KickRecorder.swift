import Foundation
import SwiftData

struct KickOutcome: Sendable {
    var saved: Bool
    var duplicate: Bool
    var count: Int
    var target: Int
    var sessionStart: Date?
}

/// 胎动记录：去重、会话续接、撤销都收在这里，
/// 界面和 App Intents 调同一套方法，避免两条逻辑分叉。
@MainActor
enum KickRecorder {
    static let duplicateWindow: TimeInterval = 1.2

    /// 每轮时长，到点自动收尾并开启下一轮
    static var roundLength: TimeInterval { Double(Prefs.roundMin) * 60 }

    /// 到点自动翻轮：结束超时轮次并立即开启下一轮（持续循环，直到手动结束）。
    @discardableResult
    static func rolloverIfNeeded(at date: Date = Date()) throws -> Bool {
        let ctx = JiQianStore.context
        guard let current = try activeSession(in: ctx) else { return false }
        guard date.timeIntervalSince(current.startedAt) >= roundLength else { return false }
        current.endedAt = current.startedAt.addingTimeInterval(roundLength)
        current.finishedReason = "timeup"
        let next = KickSession(startedAt: current.endedAt ?? date,
                               targetCount: Prefs.target,
                               source: current.source)
        ctx.insert(next)
        try ctx.save()
        return true
    }

    static func activeSession(in ctx: ModelContext) throws -> KickSession? {
        let all = try ctx.fetch(FetchDescriptor<KickSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))
        return all.first(where: { $0.endedAt == nil })
    }

    static func events(of sessionID: UUID, in ctx: ModelContext) throws -> [KickEvent] {
        let all = try ctx.fetch(FetchDescriptor<KickEvent>(sortBy: [SortDescriptor(\.occurredAt)]))
        return all.filter { $0.sessionID == sessionID }
    }

    static func count(of sessionID: UUID, in ctx: ModelContext) -> Int {
        let all = (try? ctx.fetch(FetchDescriptor<KickEvent>())) ?? []
        return all.filter { $0.sessionID == sessionID }.count
    }

    @discardableResult
    static func record(source: RecordSource, at date: Date = Date()) throws -> KickOutcome {
        let ctx = JiQianStore.context
        let all = try ctx.fetch(FetchDescriptor<KickEvent>(sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]))
        if let last = all.first,
           last.sourceRaw == source.rawValue,
           abs(date.timeIntervalSince(last.occurredAt)) < duplicateWindow {
            return KickOutcome(saved: false, duplicate: true, count: 0, target: 0, sessionStart: nil)
        }

        let session = try resolveSession(source: source, at: date, in: ctx)
        let event = KickEvent(sessionID: session.id, occurredAt: date, source: source)
        ctx.insert(event)
        try ctx.save()

        let total = try events(of: session.id, in: ctx).count
        return KickOutcome(saved: true,
                           duplicate: false,
                           count: total,
                           target: session.targetCount,
                           sessionStart: session.startedAt)
    }

    static func resolveSession(source: RecordSource, at date: Date, in ctx: ModelContext) throws -> KickSession {
        if let current = try activeSession(in: ctx) {
            if date.timeIntervalSince(current.startedAt) >= roundLength {
                // 已过本轮时长：上一轮按整点收尾，本次记录落入新一轮
                current.endedAt = current.startedAt.addingTimeInterval(roundLength)
                current.finishedReason = "timeup"
                try ctx.save()
            } else {
                return current
            }
        }
        let session = KickSession(startedAt: date, targetCount: Prefs.target, source: source)
        ctx.insert(session)
        try ctx.save()
        return session
    }

    @discardableResult
    static func startNewSession(source: RecordSource, at date: Date = Date()) throws -> KickSession {
        let ctx = JiQianStore.context
        if let current = try activeSession(in: ctx) {
            current.endedAt = date
            current.finishedReason = "replaced"
            try ctx.save()
        }
        let session = KickSession(startedAt: date, targetCount: Prefs.target, source: source)
        ctx.insert(session)
        try ctx.save()
        return session
    }

    static func endActiveSession(reason: String = "manual") throws {
        let ctx = JiQianStore.context
        guard let current = try activeSession(in: ctx) else { return }
        current.endedAt = Date()
        current.finishedReason = reason
        try ctx.save()
    }

    @discardableResult
    static func undoLast() throws -> Bool {
        let ctx = JiQianStore.context
        guard let current = try activeSession(in: ctx) else { return false }
        let list = try events(of: current.id, in: ctx)
        guard let last = list.last else { return false }
        ctx.delete(last)
        try ctx.save()
        return true
    }

    static func markUsual(_ lessThanUsual: Bool) throws {
        let ctx = JiQianStore.context
        guard let current = try activeSession(in: ctx) else { return }
        current.lessThanUsualRaw = lessThanUsual ? 1 : 0
        try ctx.save()
    }

    /// 超过计数窗口仍未达标时返回提示数据（不构成诊断）
    static func windowHint(at date: Date = Date()) throws -> (count: Int, target: Int, minutes: Int)? {
        let ctx = JiQianStore.context
        guard let current = try activeSession(in: ctx) else { return nil }
        let total = try events(of: current.id, in: ctx).count
        guard total < current.targetCount else { return nil }
        let elapsed = date.timeIntervalSince(current.startedAt)
        guard elapsed >= Double(Prefs.windowMin) * 60 else { return nil }
        return (total, current.targetCount, Int(elapsed / 60))
    }
}
