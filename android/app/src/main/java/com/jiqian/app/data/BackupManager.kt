package com.jiqian.app

import android.content.Context
import android.content.Intent
import org.json.JSONObject
import java.io.File

/** v5.13 本地自动备份：每天自动 3 次（8 小时间隔，回前台时触发），只保留最新一份 */
object BackupManager {
    private const val PREFS = "jq_backup"
    private const val LAST = "last_backup_at"
    private const val AUTO_INTERVAL = 8 * 3600 * 1000L

    private fun file(ctx: Context): File = File(ctx.filesDir, "jiqian-backup.json")

    fun lastBackupAt(ctx: Context): Long =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(LAST, 0L)

    /** 回到前台时调用：满 8 小时自动备份一次（新备份覆盖旧备份） */
    fun autoIfNeeded(ctx: Context) {
        if (System.currentTimeMillis() - lastBackupAt(ctx) < AUTO_INTERVAL) return
        backupNow(ctx)
    }

    /** 导出当前全部记录为快照 JSON 并写盘（覆盖上一份备份） */
    fun backupNow(ctx: Context): String {
        return try {
            val json = SyncManager.exportSnapshotJSON()
            if (json == null) {
                "备份失败：应用未就绪"
            } else {
                file(ctx).writeText(json)
                ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .putLong(LAST, System.currentTimeMillis()).apply()
                val n = JSONObject(json).optJSONArray("ke")?.length() ?: 0
                "已备份（胎动 $n 条）"
            }
        } catch (e: Exception) {
            "备份失败：${e.message}"
        }
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

    // ---------- v5.14 本地备份通道：导出到手机文件夹 / 分享出去 ----------

    /** 导出时的默认文件名：jiqian-backup-2026-11-11.json */
    fun exportFileName(): String {
        val d = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(java.util.Date())
        return "jiqian-backup-$d.json"
    }

    /** 备份文件大小，设置页展示 */
    fun fileSizeText(ctx: Context): String {
        val f = file(ctx)
        if (!f.exists()) return "无"
        val kb = f.length() / 1024.0
        return if (kb < 1.0) "${f.length()} B" else "%.0f KB".format(kb)
    }

    /**
     * 导出到用户选中的文件夹（系统文件选择器 SAF）：写入最新快照，同时刷新本地备份。
     * 不申请任何存储权限，用户选哪里就存哪里（下载 / 文档 / U 盘都行）。
     */
    fun exportTo(ctx: Context, uri: android.net.Uri): String {
        return try {
            val json = SyncManager.exportSnapshotJSON() ?: return "导出失败：应用未就绪"
            val out = ctx.contentResolver.openOutputStream(uri) ?: return "导出失败：无法写入所选位置"
            out.use { it.write(json.toByteArray()) }
            // 导出成功的同时刷新本地备份，保持一致
            file(ctx).writeText(json)
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putLong(LAST, System.currentTimeMillis()).apply()
            val n = JSONObject(json).optJSONArray("ke")?.length() ?: 0
            "已导出（胎动 $n 条），去文件管理器里就能看到、也能拷到电脑"
        } catch (e: Exception) {
            "导出失败：${e.message}"
        }
    }

    /** 分享备份文件（微信 / 邮件 / 保存到文件等） */
    fun shareBackup(ctx: Context): String {
        val f = file(ctx)
        if (!f.exists()) return "还没有备份文件，先点「立即备份」"
        return try {
            val uri = androidx.core.content.FileProvider.getUriForFile(
                ctx, ctx.packageName + ".fileprovider", f
            )
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "application/json"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "胎动记录备份")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            ctx.startActivity(Intent.createChooser(send, "分享备份文件").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
            "已打开分享"
        } catch (e: Exception) {
            "分享失败：${e.message}"
        }
    }
}
