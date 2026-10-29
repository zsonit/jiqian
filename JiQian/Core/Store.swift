import Foundation
import SwiftData

/// 全局唯一的 SwiftData 容器。
/// 应用主体与 App Intents 共用同一个容器，因此 Siri / 快捷指令写入的记录
/// 与界面看到的是同一份数据。
enum JiQianStore {
    static let container: ModelContainer = {
        let schema = Schema([
            KickSession.self,
            KickEvent.self,
            ContractionSession.self,
            ContractionEvent.self
        ])
        let onDisk = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        if let container = try? ModelContainer(for: schema, configurations: [onDisk]) {
            return container
        }
        // 极端情况下（磁盘损坏、迁移失败）退回内存存储，保证应用仍能打开而不是崩溃
        let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [inMemory])
    }()

    @MainActor
    static var context: ModelContext { container.mainContext }
}
