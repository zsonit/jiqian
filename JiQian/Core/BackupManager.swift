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

    /// 备份目录：Documents/备份/ —— 开启文件共享后，在「文件」App 里能直接看到
    static var dirURL: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("备份", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    static var fileURL: URL { dirURL.appendingPathComponent("jiqian-backup.json") }

    /// 老版本把备份放在 Documents 根目录：升级后搬到「备份」文件夹（只搬一次）
    static func migrateLegacyFile() {
        let fm = FileManager.default
        let old = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jiqian-backup.json")
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: fileURL.path) else { return }
        try? fm.moveItem(at: old, to: fileURL)
    }

    /// 备份文件大小，设置页展示
    static func fileSizeText() -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
              let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int else { return "无" }
        return size < 1024 ? "\(size) B" : String(format: "%.0f KB", Double(size) / 1024)
    }

    static var hasBackup: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func lastBackupAt() -> Date? {
        let v = UserDefaults.standard.double(forKey: lastKey)
        return v > 0 ? Date(timeIntervalSince1970: v) : nil
    }

    /// 回到前台时调用：满 8 小时就自动备份一次（新备份覆盖旧备份）
    static func autoIfNeeded() {
        migrateLegacyFile()
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard Date().timeIntervalSince1970 - last >= autoInterval else { return }
        let msg = backupNow()
        AppLog.i("Backup", "自动备份：\(msg)")
    }

    /// 导出当前全部记录为快照 JSON 并写盘（覆盖上一份备份）
    @discardableResult
    static func backupNow() -> String {
        migrateLegacyFile()
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
        migrateLegacyFile()
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
