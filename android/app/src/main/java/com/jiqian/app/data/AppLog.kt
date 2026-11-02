package com.jiqian.app

import android.util.Log

/** 统一日志出口（与 iOS AppLog 同形） */
object AppLog {
    private const val TAG = "JiQianSync"

    fun i(msg: String) = Log.i(TAG, msg)
    fun w(msg: String) = Log.w(TAG, msg)
    fun e(msg: String) = Log.e(TAG, msg)
}
