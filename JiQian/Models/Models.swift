import Foundation
import SwiftData

/// 记录来源：用于区分应用内、快捷指令、主屏入口、手表
enum RecordSource: String, Codable, Sendable, CaseIterable {
    case app
    case shortcut
    case widget
    case watch

    var label: String {
        switch self {
        case .app: return "应用内"
        case .shortcut: return "快捷指令"
        case .widget: return "主屏入口"
        case .watch: return "手表"
        }
    }
}

/// 一次胎动计数会话
@Model
final class KickSession {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date?
    var targetCount: Int = 10
    var sourceRaw: String = RecordSource.app.rawValue
    var finishedReason: String?
    /// -1 未回答 / 0 和平时差不多 / 1 明显少于平时
    var lessThanUsualRaw: Int = -1
    var celebrated: Bool = false

    init(id: UUID = UUID(),
         startedAt: Date = Date(),
         targetCount: Int = 10,
         source: RecordSource = .app) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = nil
        self.targetCount = targetCount
        self.sourceRaw = source.rawValue
        self.finishedReason = nil
        self.lessThanUsualRaw = -1
        self.celebrated = false
    }

    var source: RecordSource { RecordSource(rawValue: sourceRaw) ?? .app }
    var isActive: Bool { endedAt == nil }
    var lessThanUsual: Bool? {
        if lessThanUsualRaw < 0 { return nil }
        return lessThanUsualRaw == 1
    }
}

/// 单次胎动事件
@Model
final class KickEvent {
    var id: UUID = UUID()
    var sessionID: UUID = UUID()
    var occurredAt: Date = Date()
    var sourceRaw: String = RecordSource.app.rawValue
    var note: String?

    init(id: UUID = UUID(),
         sessionID: UUID,
         occurredAt: Date = Date(),
         source: RecordSource = .app) {
        self.id = id
        self.sessionID = sessionID
        self.occurredAt = occurredAt
        self.sourceRaw = source.rawValue
        self.note = nil
    }

    var source: RecordSource { RecordSource(rawValue: sourceRaw) ?? .app }
}

/// 一次宫缩记录会话（一次就诊周期内的连续计时）
@Model
final class ContractionSession {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date?
    var sourceRaw: String = RecordSource.app.rawValue

    init(id: UUID = UUID(), startedAt: Date = Date(), source: RecordSource = .app) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = nil
        self.sourceRaw = source.rawValue
    }

    var source: RecordSource { RecordSource(rawValue: sourceRaw) ?? .app }
}

/// 单次宫缩的起止
@Model
final class ContractionEvent {
    var id: UUID = UUID()
    var sessionID: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date?
    var sourceRaw: String = RecordSource.app.rawValue
    var interruptedReason: String?
    /// 与上一次收缩结束之间的间隔（秒），结束后写入，便于历史回放
    var gap: TimeInterval = 0
    /// 明显不足 3 秒，可能是误触
    var isSuspect: Bool = false

    init(id: UUID = UUID(),
         sessionID: UUID,
         startedAt: Date = Date(),
         source: RecordSource = .app) {
        self.id = id
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = nil
        self.sourceRaw = source.rawValue
        self.gap = 0
        self.isSuspect = false
    }

    var source: RecordSource { RecordSource(rawValue: sourceRaw) ?? .app }
    var duration: TimeInterval {
        guard let endedAt else { return 0 }
        return endedAt.timeIntervalSince(startedAt)
    }
}
