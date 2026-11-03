package com.jiqian.app.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import com.jiqian.app.MainActivity
import com.jiqian.app.R
import com.jiqian.app.Store
import com.jiqian.app.SyncManager
import com.jiqian.app.dayStart
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 三个桌面组件的公共渲染逻辑。
 *
 * 和 iOS 不同，安卓组件与 App 在同一进程、同一份 SharedPreferences，
 * 所以这里能直接读出今天的次数、上次记录时间、宫缩是否正在计时，
 * 组件上的数字是真实的，点完立刻就地刷新，不需要打开 App。
 */
object Widgets {

    const val ACTION_KICK = "com.jiqian.app.widget.ACTION_KICK"
    const val ACTION_CONTRACTION = "com.jiqian.app.widget.ACTION_CONTRACTION"

    private const val REQ_KICK = 1001
    private const val REQ_CTN = 1002
    private const val REQ_OPEN = 1003

    data class Info(
        val todayCount: Int,
        val roundCount: Int,
        val lastKick: Long,
        val runningStart: Long,
        val lastDuration: Long,
        val canEdit: Boolean
    )

    private fun hhmm(t: Long): String = SimpleDateFormat("HH:mm", Locale.CHINA).format(Date(t))

    private fun mmss(seconds: Long): String = "%02d:%02d".format(seconds / 60, seconds % 60)

    fun readInfo(context: Context): Info {
        // 组件点击发生在 App 之外，先把同步引擎里的权限状态装起来（幂等）
        SyncManager.bootstrap(context)
        val now = System.currentTimeMillis()
        val day0 = dayStart(now)
        val kicks = Store.kicks(context)
        val today = kicks.filter { dayStart(it) == day0 }
        val roundMs = Store.roundMin(context) * 60_000L
        val roundStart = day0 + ((now - day0) / roundMs) * roundMs
        val ctns = Store.contractions(context)
        val lastCtn = ctns.maxByOrNull { it.first }
        return Info(
            todayCount = today.size,
            roundCount = today.count { it >= roundStart },
            lastKick = kicks.maxOrNull() ?: 0L,
            runningStart = Store.runningContractionStart(context),
            lastDuration = lastCtn?.let { (s, e) -> e - s } ?: 0L,
            canEdit = SyncManager.canEdit
        )
    }

    /** 三个组件一起刷新：App 内落库后、组件被点后、系统更新时都走这里 */
    fun refresh(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val info = readInfo(context)

        val kickIds = manager.getAppWidgetIds(ComponentName(context, KickWidgetProvider::class.java))
        if (kickIds.isNotEmpty()) {
            val views = kickViews(context, info)
            kickIds.forEach { manager.updateAppWidget(it, views) }
        }

        val ctnIds = manager.getAppWidgetIds(ComponentName(context, ContractionWidgetProvider::class.java))
        if (ctnIds.isNotEmpty()) {
            val views = contractionViews(context, info)
            ctnIds.forEach { manager.updateAppWidget(it, views) }
        }

        val bothIds = manager.getAppWidgetIds(ComponentName(context, QuickWidgetProvider::class.java))
        if (bothIds.isNotEmpty()) {
            val views = combinedViews(context, info)
            bothIds.forEach { manager.updateAppWidget(it, views) }
        }
    }

    // ---------- 胎动组件 ----------

    private fun kickViews(context: Context, info: Info): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_kick)
        views.setTextViewText(R.id.count, "今日 ${info.todayCount} 次")
        views.setTextViewText(
            R.id.hint,
            when {
                !info.canEdit -> "查看模式：请在 App 内申请编辑权限"
                info.lastKick > 0L -> "上次 ${hhmm(info.lastKick)} · 本轮 ${info.roundCount} 次"
                else -> "点下面的按钮记一次"
            }
        )
        views.setTextViewText(R.id.btnKick, if (info.canEdit) "＋  记一下" else "仅查看")
        views.setOnClickPendingIntent(R.id.btnKick, action(context, ACTION_KICK, REQ_KICK))
        views.setOnClickPendingIntent(R.id.root, openApp(context))
        return views
    }

    // ---------- 宫缩组件 ----------

    private fun contractionViews(context: Context, info: Info): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_contraction)
        if (info.runningStart > 0L) {
            views.setViewVisibility(R.id.chrono, View.VISIBLE)
            views.setViewVisibility(R.id.duration, View.GONE)
            // Chronometer 以 elapsedRealtime 为基准，换算成本次收缩的开始时刻就能自动走秒
            val base = SystemClock.elapsedRealtime() - (System.currentTimeMillis() - info.runningStart)
            views.setChronometer(R.id.chrono, base, null, true)
            views.setTextViewText(R.id.btnCtn, "■  结束并保存")
            views.setTextViewText(R.id.hint, "收缩中…再点一下保存")
        } else {
            views.setViewVisibility(R.id.chrono, View.GONE)
            views.setViewVisibility(R.id.duration, View.VISIBLE)
            views.setTextViewText(
                R.id.duration,
                if (info.lastDuration > 0L) "上次 ${mmss(info.lastDuration / 1000)}" else "就绪"
            )
            views.setTextViewText(R.id.btnCtn, "▶  开始宫缩")
            views.setTextViewText(
                R.id.hint,
                if (info.canEdit) "点一下开始计时，再点结束保存" else "查看模式：请在 App 内申请编辑权限"
            )
        }
        views.setOnClickPendingIntent(R.id.btnCtn, action(context, ACTION_CONTRACTION, REQ_CTN))
        views.setOnClickPendingIntent(R.id.root, openApp(context))
        return views
    }

    // ---------- 组合组件（4x2） ----------

    private fun combinedViews(context: Context, info: Info): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_combined)
        views.setTextViewText(R.id.status, "今日 ${info.todayCount} 次 · 本轮 ${info.roundCount} 次")
        views.setTextViewText(R.id.btnKick, if (info.canEdit) "＋  记胎动" else "仅查看")
        if (info.runningStart > 0L) {
            views.setViewVisibility(R.id.chrono, View.VISIBLE)
            val base = SystemClock.elapsedRealtime() - (System.currentTimeMillis() - info.runningStart)
            views.setChronometer(R.id.chrono, base, null, true)
            views.setTextViewText(R.id.btnCtn, "■  结束宫缩")
            views.setTextViewText(R.id.foot, "收缩中…")
        } else {
            views.setViewVisibility(R.id.chrono, View.GONE)
            views.setTextViewText(R.id.btnCtn, "▶  宫缩")
            views.setTextViewText(
                R.id.foot,
                when {
                    !info.canEdit -> "查看模式：请在 App 内申请编辑权限"
                    info.lastKick > 0L -> "上次胎动 ${hhmm(info.lastKick)}"
                    else -> "点按钮即可记录，不用打开 App"
                }
            )
        }
        views.setOnClickPendingIntent(R.id.btnKick, action(context, ACTION_KICK, REQ_KICK))
        views.setOnClickPendingIntent(R.id.btnCtn, action(context, ACTION_CONTRACTION, REQ_CTN))
        views.setOnClickPendingIntent(R.id.root, openApp(context))
        return views
    }

    // ---------- 点击 ----------

    private fun action(context: Context, action: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, WidgetActionReceiver::class.java).setAction(action)
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun openApp(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context,
            REQ_OPEN,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}

/** 胎动组件 */
class KickWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        Widgets.refresh(context)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle
    ) {
        Widgets.refresh(context)
    }
}

/** 宫缩组件 */
class ContractionWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        Widgets.refresh(context)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle
    ) {
        Widgets.refresh(context)
    }
}

/** 组合组件：两个开关并排 */
class QuickWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        Widgets.refresh(context)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle
    ) {
        Widgets.refresh(context)
    }
}

/** 组件按钮的落地：直接在本进程里落库，然后刷新组件 */
class WidgetActionReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        SyncManager.bootstrap(context)
        if (SyncManager.canEdit) {
            when (intent.action) {
                Widgets.ACTION_KICK -> {
                    Store.addKick(context)
                    com.jiqian.app.Feedback.buzz(context)
                }
                Widgets.ACTION_CONTRACTION -> {
                    val start = Store.runningContractionStart(context)
                    val now = System.currentTimeMillis()
                    if (start > 0L) {
                        // 误触保护：一秒内的两次点击不当成一次完整收缩
                        if (now - start >= 1000L) {
                            Store.addContraction(context, start, now)
                            Store.setRunningContractionStart(context, 0L)
                        }
                    } else {
                        Store.setRunningContractionStart(context, now)
                    }
                    com.jiqian.app.Feedback.buzz(context)
                }
            }
        }
        Widgets.refresh(context)
    }
}
