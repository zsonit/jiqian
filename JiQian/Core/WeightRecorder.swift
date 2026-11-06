import Foundation
import SwiftData

/// 体重概况（只做算术：最近一次、第一次、差值，不给任何建议）
struct WeightStats {
    var first: WeightEntry?
    var latest: WeightEntry?
    var count: Int = 0

    /// 较第一次记录的变化（公斤）。少于两条时为 nil
    var gained: Double? {
        guard let first, let latest, count > 1 else { return nil }
        return latest.kg - first.kg
    }
}

/// 体重记录：新增 / 删除 / 统计收在一处，界面只调用这里。
/// 口径：只存「什么时候称、多少公斤」，不生成任何体重增减评价或健康判断。
@MainActor
enum WeightRecorder {
    /// 录入范围（防止手滑打成 6.2 / 620）
    static let minKg = 30.0
    static let maxKg = 200.0

    static func all(in ctx: ModelContext = JiQianStore.context) -> [WeightEntry] {
        (try? ctx.fetch(FetchDescriptor<WeightEntry>(sortBy: [SortDescriptor(\.at)]))) ?? []
    }

    static func stats(_ entries: [WeightEntry]) -> WeightStats {
        WeightStats(first: entries.first, latest: entries.last, count: entries.count)
    }

    /// 记一次体重。查看模式下不落库（返回 nil），与胎动 / 宫缩一致。
    @discardableResult
    static func record(kg: Double, at date: Date = Date()) throws -> WeightEntry? {
        guard SyncManager.shared.canEdit else { return nil }
        guard kg >= minKg, kg <= maxKg else { return nil }
        let ctx = JiQianStore.context
        let entry = WeightEntry(at: date, kg: (kg * 10).rounded() / 10)
        ctx.insert(entry)
        try ctx.save()
        SyncManager.shared.onDataChanged()
        return entry
    }

    /// 删除一条（写墓碑，配对设备上同一条也会消失）
    @discardableResult
    static func delete(_ entry: WeightEntry) throws -> Bool {
        guard SyncManager.shared.canEdit else { return false }
        let ctx = JiQianStore.context
        let anchor = SnapshotIO.ms(entry.at)
        ctx.delete(entry)
        try ctx.save()
        SyncManager.addTombstone(SyncTombstone.weight(anchor))
        SyncManager.shared.onDataChanged()
        return true
    }

    /// 清空全部体重记录（逐条写墓碑，好让配对设备一起清）
    static func clearAll() throws {
        guard SyncManager.shared.canEdit else { return }
        let ctx = JiQianStore.context
        let list = all(in: ctx)
        guard !list.isEmpty else { return }
        for entry in list {
            SyncManager.addTombstone(SyncTombstone.weight(SnapshotIO.ms(entry.at)))
            ctx.delete(entry)
        }
        try ctx.save()
        SyncManager.shared.onDataChanged()
    }

    /// 展示用：一位小数（62.4）
    static func text(_ kg: Double) -> String {
        String(format: "%.1f", kg)
    }

    /// 差值展示：+6.2 / -0.3 / ±0.0
    static func deltaText(_ delta: Double) -> String {
        if abs(delta) < 0.05 { return "±0.0" }
        return (delta > 0 ? "+" : "-") + String(format: "%.1f", abs(delta))
    }
}
