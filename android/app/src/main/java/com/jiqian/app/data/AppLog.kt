package com.jiqian.app

import android.content.Context
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 统一日志出口（与 iOS AppLog 同形）。
 *
 * v5.5 新增「运行日志（排查用）」：设置页独立开关（默认关）。
 * 打开后，除系统日志外，额外把最近 600 条记进内存环形缓冲，
 * 供 设置 → 运行日志 页面查看 / 复制 / 清空。只在本机内存里，不落盘、不同步、不上传。
 */
object AppLog {
    private const val TAG = "JiQianSync"
    private const val KEY_ENABLED = "diagLogEnabled"
    private const val CAP = 600

    @Volatile private var appContext: Context? = null
    private val buffer = ArrayDeque<String>()
    private val lock = Any()
    private val timeFmt = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US)

    /** 在 Application/Activity onCreate 里调用一次，让日志能读到开关状态 */
    fun init(ctx: Context) {
        appContext = ctx.applicationContext
    }

    private fun prefs(ctx: Context) = ctx.getSharedPreferences("diag", Context.MODE_PRIVATE)

    fun enabled(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_ENABLED, false)

    fun setEnabled(ctx: Context, on: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_ENABLED, on).apply()
        if (!on) clear()   // 关掉即清空，不留残留
        else i("运行日志已开启")
    }

    fun i(msg: String) = record("i", msg) { Log.i(TAG, msg) }
    fun w(msg: String) = record("w", msg) { Log.w(TAG, msg) }
    fun e(msg: String) = record("e", msg) { Log.e(TAG, msg) }

    private fun record(level: String, msg: String, write: () -> Unit) {
        write()
        val ctx = appContext ?: return
        if (!enabled(ctx)) return
        val line = "${timeFmt.format(Date())} [$level] $msg"
        synchronized(lock) {
            buffer.addLast(line)
            while (buffer.size > CAP) buffer.removeFirst()
        }
    }

    /** 最近的记录（旧的在前），给日志页展示 / 复制用 */
    fun snapshot(): List<String> = synchronized(lock) { buffer.toList() }

    fun clear() = synchronized(lock) { buffer.clear() }
}
