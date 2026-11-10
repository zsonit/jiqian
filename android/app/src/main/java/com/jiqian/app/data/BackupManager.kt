package com.jiqian.app.data

import android.content.Context
import org.json.JSONObject
import java.io.File

/** v5.13 本地自动备份：每天自动 3 次（8 小时间隔，回前台时触发），只保留最新一份 */
object BackupManager {
    private const val PREFS = "jq_backup"
    private const val LAST = "last_backup_at"
    private const val AUTO_INTERVAL = 8 * 3600 * 1000L

    private fun file(ctx: Context) = File(ctx.filesDir, "jiqian-backup.json")

    fun lastBackupAt(ctx: Context): Long =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(LAST, 0L)

    /** 回到前台时调用：满 8 小时自动备份一次（新备份覆盖旧备份） */
    fun autoIfNeeded(ctx: Context) {
        if (System.currentTimeMillis() - lastBackupAt(ctx) < AUTO_INTERVAL) return
        backupNow(ctx)
    }

    /** 导出当前全部记录为快照 JSON 并写盘（覆盖上一份备份） */
    fun backupNow(ctx: Context): String = try {
        val json = SyncManager.exportSnapshotJSON()
            ?: return "备份失败：应用未就绪"
        file(ctx).writeText(json)
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong(LAST, System.currentTimeMillis()).apply()
        "已备份（胎动 ${JSONObject(json).optJSONArray("ke")?.length() ?: 0} 条）"
    } catch (e: Exception) {
        "备份失败：${e.message}"
    }

    /** 从备份文件恢复本机记录（无视备份里的清空标记/墓碑；可写端会把恢复的数据推回云端） */
    fun restoreFromBackup(ctx: Context): String {
        val f = file(ctx)
        if (!f.exists()) return "还没有备份文件，先点「立即备份」"
        return try {
            SyncManager.restoreRecords(JSONObject(f.readText()))
        } catch (e: Exception) {
            "恢复失败：${e.message}"
        }
    }
}
