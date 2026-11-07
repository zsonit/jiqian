package com.jiqian.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jiqian.app.AppLog
import com.jiqian.app.Bg
import com.jiqian.app.Brand
import com.jiqian.app.CardBg
import com.jiqian.app.Danger
import com.jiqian.app.Ink
import com.jiqian.app.Ink2
import com.jiqian.app.Line
import com.jiqian.app.Teal

/**
 * 运行日志页（排查用）：展示内存环形缓冲里最近的日志，可复制全部、清空。
 * 只读本机内存，不落盘、不同步、不上传。
 */
@Composable
fun LogScreen(onClose: () -> Unit) {
    // version 自增触发整页刷新；页面停着也每 2 秒看一眼有没有新日志
    var version by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            kotlinx.coroutines.delay(2000)
            version++
        }
    }
    val lines = remember(version) { AppLog.snapshot() }
    val clipboard = LocalClipboardManager.current
    var toast by remember { mutableStateOf<String?>(null) }
    val listState = rememberLazyListState()

    fun showToast(msg: String) {
        toast = msg
        Thread {
            Thread.sleep(2200)
            toast = null
            version++
        }.start()
    }

    val platformCtx = androidx.compose.ui.platform.LocalContext.current

    /** 导出为 .txt 文件：写进 cacheDir/log-export/，经 FileProvider 调系统分享（微信 / 邮件 / 保存到文件等） */
    fun exportLog() {
        val ctx = platformCtx
        Thread {
            val lines = AppLog.snapshot()
            if (lines.isEmpty()) return@Thread
            try {
                val dir = java.io.File(ctx.cacheDir, "log-export").apply { mkdirs() }
                val name = "jiqian-log-%s.txt".format(
                    java.text.SimpleDateFormat("yyyyMMdd-HHmmss", java.util.Locale.US).format(java.util.Date())
                )
                val file = java.io.File(dir, name)
                file.writeText(lines.joinToString("\n") + "\n")
                val uri = androidx.core.content.FileProvider.getUriForFile(
                    ctx, ctx.packageName + ".fileprovider", file
                )
                val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(android.content.Intent.EXTRA_STREAM, uri)
                    putExtra(android.content.Intent.EXTRA_SUBJECT, name)
                    addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                ctx.startActivity(android.content.Intent.createChooser(intent, "导出运行日志"))
            } catch (e: Exception) {
                AppLog.w("导出日志失败：${e.message}")
                showToast("导出失败：${e.message ?: "未知错误"}")
            }
        }.start()
    }

    LaunchedEffect(lines.size) {
        if (lines.isNotEmpty()) listState.animateScrollToItem(lines.size - 1)
    }

    Box(Modifier.fillMaxSize().background(Bg)) {
        Column(Modifier.fillMaxSize().padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("‹ 返回", fontSize = 15.sp, color = Brand, modifier = Modifier.clickable { onClose() })
                Text(
                    "🧾 运行日志",
                    fontSize = 20.sp, fontWeight = FontWeight.Bold, color = Ink,
                    modifier = Modifier.weight(1f),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                )
                Spacer(Modifier.width(40.dp))
            }
            Text(
                "最近 ${lines.size} 条 · 只存在本机内存里，不同步不上传；可复制或导出为 txt 文件，关闭开关即清空",
                fontSize = 11.sp, color = Ink2, lineHeight = 15.sp,
                modifier = Modifier.padding(top = 6.dp)
            )

            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(
                    Modifier
                        .background(Brand.copy(alpha = 0.1f), RoundedCornerShape(50))
                        .clickable(enabled = lines.isNotEmpty()) {
                            clipboard.setText(AnnotatedString(lines.joinToString("\n")))
                            showToast("已复制 ${lines.size} 条日志")
                        }
                        .padding(horizontal = 14.dp, vertical = 8.dp)
                ) {
                    Text("复制全部", fontSize = 13.sp, fontWeight = FontWeight.Bold,
                        color = if (lines.isEmpty()) Ink2 else Brand)
                }
                Box(
                    Modifier
                        .background(Teal.copy(alpha = 0.1f), RoundedCornerShape(50))
                        .clickable(enabled = lines.isNotEmpty()) { exportLog() }
                        .padding(horizontal = 14.dp, vertical = 8.dp)
                ) {
                    Text("导出文件", fontSize = 13.sp, fontWeight = FontWeight.Bold,
                        color = if (lines.isEmpty()) Ink2 else Teal)
                }
                Box(
                    Modifier
                        .background(Danger.copy(alpha = 0.1f), RoundedCornerShape(50))
                        .clickable(enabled = lines.isNotEmpty()) {
                            AppLog.clear()
                            version++
                            showToast("日志已清空")
                        }
                        .padding(horizontal = 14.dp, vertical = 8.dp)
                ) {
                    Text("清空", fontSize = 13.sp, fontWeight = FontWeight.Bold,
                        color = if (lines.isEmpty()) Ink2 else Danger)
                }
            }

            Spacer(Modifier.height(10.dp))

            if (lines.isEmpty()) {
                Column(
                    Modifier.fillMaxWidth().padding(top = 80.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text("🕊️", fontSize = 34.sp)
                    Spacer(Modifier.height(8.dp))
                    Text("还没有日志", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Ink2)
                    Text(
                        "打开开关后，同步、配对等关键动作会记到这里。",
                        fontSize = 12.sp, color = Ink2, modifier = Modifier.padding(top = 4.dp)
                    )
                }
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxWidth().weight(1f),
                    verticalArrangement = Arrangement.spacedBy(0.dp)
                ) {
                    items(lines.size) { index ->
                        val line = lines[index]
                        Column(Modifier.fillMaxWidth().padding(vertical = 5.dp)) {
                            Text(
                                line,
                                fontSize = 11.sp,
                                lineHeight = 15.sp,
                                color = when {
                                    "[e]" in line -> Danger
                                    "[w]" in line -> Teal
                                    else -> Ink
                                }
                            )
                            Box(
                                Modifier
                                    .fillMaxWidth()
                                    .padding(top = 5.dp)
                                    .height(1.dp)
                                    .background(Line.copy(alpha = 0.6f))
                            )
                        }
                    }
                }
            }
        }

        if (toast != null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
                Text(
                    toast ?: "",
                    fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Color.White,
                    modifier = Modifier
                        .background(Teal.copy(alpha = 0.96f), RoundedCornerShape(50))
                        .padding(horizontal = 18.dp, vertical = 10.dp)
                        .padding(bottom = 26.dp)
                )
            }
        }
    }
}
