import Foundation
import SwiftData

/// v5.13 本地自动备份：把全部记录导出成一个 JSON 文件放在 App 文档目录。
/// - 每天自动备份 3 次：回到前台时距上次备份超过 8 小时就自动备一次
/// - 只保留最新一份：新备份直接覆盖旧文件（保存新的就删旧的）
/// - 设置页可手动「立即备份」，以及「从备份恢复 / 从云端恢复」
enum BackupManager {
    /// 自动备份最小间隔（8 小时 ≈ 每天 3 次）
    static let autoInterval: TimeInterval = 8 * 3600
    private static let lastKey = "jq_backup_last"

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jiqian-backup.json")
    }

    static func lastBackupAt() -> Date? {
        let v = UserDefaults.standard.double(forKey: lastKey)
        return v > 0 ? Date(timeIntervalSince1970: v) : nil
    }

    /// 回到前台时调用：满 8 小时就自动备份一次（新备份覆盖旧备份）
    static func autoIfNeeded() {
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard Date().timeIntervalSince1970 - last >= autoInterval else { return }
        let msg = backupNow()
        AppLog.i("Backup", "自动备份：\(msg)")
    }

    /// 导出当前全部记录为快照 JSON 并写盘（覆盖上一份备份）
    @discardableResult
    static func backupNow() -> String {
        do {
            let ctx = ModelContext(JiQianStore.container)
            var snap = try SnapshotIO.export(from: ctx)
            snap.cl = SyncManager.clearedAt()
            snap.del = SyncManager.tombstones()
            let data = try JSONEncoder().encode(snap)
            try data.write(to: fileURL, options: .atomic)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
            return "成功（胎动 \(snap.ke.count) 条）"
        } catch {
            return "失败：\(error.localizedDescription)"
        }
    }

    /// 从备份文件恢复本机记录（无视备份里的清空标记/墓碑；可写端会把恢复的数据推回云端）
    @discardableResult
    static func restoreFromBackup() -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return "还没有备份文件，先点「立即备份」"
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snap = try JSONDecoder().decode(SyncSnapshot.self, from: data)
            return SyncManager.shared.restoreRecords(from: snap)
        } catch {
            return "恢复失败：\(error.localizedDescription)"
        }
    }
}
