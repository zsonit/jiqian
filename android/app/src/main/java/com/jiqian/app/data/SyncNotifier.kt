package com.jiqian.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/**
 * 权限申请的本地通知（与 iOS SyncNotifier.swift 对应）。
 *
 * 只读端（B）点了「申请编辑权限」后，写端（A）需要立刻知道：
 * A 的 App 在前台时，6 秒轮询发现新申请即弹通知；切回前台时也会补提醒
 * （App 被系统冻结时无法联网，所以这不是服务器推送）。
 * 点通知直接打开 App 并跳到「配对同步」页审批。
 */
object SyncNotifier {

    private const val CHANNEL = "jiqian_acl"
    private const val NOTIFY_ID = 1001
    const val EXTRA_OPEN_SYNC = "open_sync"

    fun ensureChannel(ctx: Context) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "编辑权限申请", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "家人手机申请修改胎动记录时提醒"
                    enableVibration(true)
                }
            )
        }
    }

    /** 提醒「这些设备在申请编辑权限」；同一台设备只提醒一次（去重在 SyncManager 里做） */
    fun notifyRequests(ctx: Context, ids: List<String>) {
        if (ids.isEmpty()) return
        ensureChannel(ctx)
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val intent = Intent(ctx, MainActivity::class.java).apply {
            putExtra(EXTRA_OPEN_SYNC, true)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val pending = PendingIntent.getActivity(ctx, NOTIFY_ID, intent, flags)
        val text = if (ids.size == 1) {
            "设备 ${ids[0]} 想修改胎动记录，点开审批"
        } else {
            "${ids.joinToString("、")} 想修改胎动记录，点开审批"
        }
        val notification = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("有设备申请编辑权限")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        // 没有通知权限时静默失败即可（App 内还有横幅和角标）
        runCatching { nm.notify(NOTIFY_ID, notification) }
    }
}
