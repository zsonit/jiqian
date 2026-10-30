package com.jiqian.app

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// ---------- 配色（与 iOS 版一致） ----------
val Brand = Color(0xFFD9548C)
val BrandSoft = Color(0xFFFBECF2)
val Bg = Color(0xFFFDF3F7)
val CardBg = Color(0xFFFFFFFF)
val Ink = Color(0xFF3A2530)
val Ink2 = Color(0xFF9A7E8A)
val Line = Color(0xFFF2DCE6)
val Danger = Color(0xFFB2362D)

// ---------- 数据存储（SharedPreferences + JSON，本地优先不外传） ----------
object Store {
    private const val KEY_KICKS = "kicks"
    private const val KEY_CONTRACTIONS = "contractions"
    private const val KEY_PREFS = "prefs"

    private fun sp(ctx: Context) = ctx.getSharedPreferences("store", Context.MODE_PRIVATE)

    fun kicks(ctx: Context): MutableList<Long> {
        val a = JSONArray(sp(ctx).getString(KEY_KICKS, "[]"))
        val l = mutableListOf<Long>()
        for (i in 0 until a.length()) l.add(a.getLong(i))
        return l
    }

    fun addKick(ctx: Context) {
        val l = kicks(ctx); l.add(System.currentTimeMillis())
        val a = JSONArray(); l.forEach { a.put(it) }
        sp(ctx).edit().putString(KEY_KICKS, a.toString()).apply()
    }

    fun removeLastKick(ctx: Context) {
        val l = kicks(ctx); if (l.isNotEmpty()) l.removeAt(l.size - 1)
        val a = JSONArray(); l.forEach { a.put(it) }
        sp(ctx).edit().putString(KEY_KICKS, a.toString()).apply()
    }

    fun clearKicks(ctx: Context) { sp(ctx).edit().putString(KEY_KICKS, "[]").apply() }

    fun contractions(ctx: Context): MutableList<Pair<Long, Long>> {
        val a = JSONArray(sp(ctx).getString(KEY_CONTRACTIONS, "[]"))
        val l = mutableListOf<Pair<Long, Long>>()
        for (i in 0 until a.length()) l.add(Pair(a.getJSONObject(i).getLong("s"), a.getJSONObject(i).getLong("e")))
        return l
    }

    fun addContraction(ctx: Context, start: Long, end: Long) {
        val l = contractions(ctx); l.add(Pair(start, end))
        val a = JSONArray(); l.forEach { a.put(JSONObject().put("s", it.first).put("e", it.second)) }
        sp(ctx).edit().putString(KEY_CONTRACTIONS, a.toString()).apply()
    }

    fun clearContractions(ctx: Context) { sp(ctx).edit().putString(KEY_CONTRACTIONS, "[]").apply() }

    fun roundMin(ctx: Context) = sp(ctx).getInt(KEY_PREFS + "roundMin", 60)
    fun setRoundMin(ctx: Context, v: Int) = sp(ctx).edit().putInt(KEY_PREFS + "roundMin", v).apply()
    fun soundOn(ctx: Context) = sp(ctx).getBoolean(KEY_PREFS + "sound", true)
    fun setSoundOn(ctx: Context, v: Boolean) = sp(ctx).edit().putBoolean(KEY_PREFS + "sound", v).apply()
    fun volume(ctx: Context) = sp(ctx).getInt(KEY_PREFS + "vol", 80)
    fun setVolume(ctx: Context, v: Int) = sp(ctx).edit().putInt(KEY_PREFS + "vol", v).apply()
    fun hapticOn(ctx: Context) = sp(ctx).getBoolean(KEY_PREFS + "haptic", true)
    fun setHapticOn(ctx: Context, v: Boolean) = sp(ctx).edit().putBoolean(KEY_PREFS + "haptic", v).apply()
}

// ---------- 反馈：声音 + 震动 ----------
object Feedback {
    fun buzz(ctx: Context) {
        if (!Store.hapticOn(ctx)) return
        val v: Vibrator = if (Build.VERSION.SDK_INT >= 31) {
            val vm = ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            vm.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        v.vibrate(VibrationEffect.createOneShot(40, VibrationEffect.DEFAULT_AMPLITUDE))
    }

    fun click(ctx: Context) {
        if (Store.soundOn(ctx)) {
            try {
                val tg = ToneGenerator(AudioManager.STREAM_MUSIC, Store.volume(ctx))
                tg.startTone(ToneGenerator.TONE_PROP_BEEP, 80)
                Thread { Thread.sleep(200); tg.release() }.start()
            } catch (_: Exception) {}
        }
        buzz(ctx)
    }
}

fun fmtFull(t: Long): String =
    SimpleDateFormat("yyyy年M月d日 HH:mm:ss", Locale.CHINA).format(Date(t))

fun fmtDay(t: Long): String =
    SimpleDateFormat("yyyy年M月d日", Locale.CHINA).format(Date(t))

fun dayStart(t: Long): Long {
    val c = java.util.Calendar.getInstance()
    c.timeInMillis = t
    c.set(java.util.Calendar.HOUR_OF_DAY, 0); c.set(java.util.Calendar.MINUTE, 0)
    c.set(java.util.Calendar.SECOND, 0); c.set(java.util.Calendar.MILLISECOND, 0)
    return c.timeInMillis
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { App() }
    }
}

@Composable
fun App() {
    var tab by remember { mutableStateOf(0) }
    MaterialTheme(
        colorScheme = lightColorScheme(primary = Brand, background = Bg, surface = Bg)
    ) {
        Surface(Modifier.fillMaxSize(), color = Bg) {
            Column(Modifier.fillMaxSize()) {
                Box(Modifier.weight(1f)) {
                    when (tab) {
                        0 -> KickScreen()
                        1 -> ContractionScreen()
                        2 -> SummaryScreen()
                        else -> SettingsScreen()
                    }
                }
                BottomBar(tab) { tab = it }
            }
        }
    }
}

@Composable
fun BottomBar(sel: Int, onPick: (Int) -> Unit) {
    val items = listOf("胎动", "宫缩", "摘要", "设置")
    Surface(color = CardBg.copy(alpha = 0.9f), shadowElevation = 8.dp) {
        Row(Modifier.fillMaxWidth().navigationBarsPadding().padding(vertical = 6.dp)) {
            items.forEachIndexed { i, name ->
                Box(Modifier.weight(1f).clickable { onPick(i) }.padding(vertical = 6.dp), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            name,
                            fontSize = 13.sp,
                            fontWeight = if (sel == i) FontWeight.Bold else FontWeight.Normal,
                            color = if (sel == i) Brand else Ink2
                        )
                        Box(
                            Modifier.padding(top = 3.dp).size(width = 28.dp, height = 4.dp)
                                .background(if (sel == i) Brand else Color.Transparent, RoundedCornerShape(2.dp))
                        )
                    }
                }
            }
        }
    }
}

// ---------- 胎动 ----------
@Composable
fun KickScreen() {
    val ctx = LocalContext.current
    var tick by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { while (true) { kotlinx.coroutines.delay(1000); tick++ } }

    val roundMin = Store.roundMin(ctx)
    val all = Store.kicks(ctx)
    val today = all.filter { dayStart(it) == dayStart(System.currentTimeMillis()) }
    // 本轮：从最近一次翻轮点算起。简化：以今天的记录按轮长分组，取当前进行中的一轮
    val now = System.currentTimeMillis()
    val day0 = dayStart(now)
    val roundMs = roundMin * 60_000L
    val roundIndex = ((now - day0) / roundMs).toInt()
    val roundStart = day0 + roundIndex * roundMs
    val roundEnd = roundStart + roundMs
    val remain = roundEnd - now
    val thisRound = today.count { it >= roundStart }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp)) {
        Text("胎动记录", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Ink)
        Text("点击大按钮记录每一次胎动", fontSize = 13.sp, color = Ink2, modifier = Modifier.padding(top = 4.dp))

        Spacer(Modifier.height(18.dp))
        Card(shape = RoundedCornerShape(24.dp), colors = CardDefaults.cardColors(containerColor = BrandSoft)) {
            Column(Modifier.fillMaxWidth().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("本轮", fontSize = 13.sp, color = Ink2)
                Text("$thisRound", fontSize = 64.sp, fontWeight = FontWeight.Bold, color = Brand)
                Text("今日合计 ${today.size} 次", fontSize = 14.sp, color = Ink)
                Spacer(Modifier.height(8.dp))
                val m = remain / 60000
                val s = (remain % 60000) / 1000
                Text("本轮剩余 %02d:%02d".format(m, s), fontSize = 15.sp, color = Ink2)
            }
        }

        Spacer(Modifier.height(18.dp))
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Surface(
                modifier = Modifier.size(180.dp).clickable {
                    Store.addKick(ctx)
                    Feedback.click(ctx)
                    tick++
                },
                shape = RoundedCornerShape(50),
                color = Brand,
                shadowElevation = 6.dp
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text("记一下", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                }
            }
        }

        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
            TextButton(onClick = { Store.removeLastKick(ctx); tick++ }) { Text("撤销上一次", color = Ink2) }
        }

        Spacer(Modifier.height(12.dp))
        Text("本轮记录", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Ink)
        val roundKicks = today.filter { it >= roundStart }.sortedDescending()
        roundKicks.take(10).forEach { t ->
            Text(fmtFull(t), fontSize = 12.5.sp, color = Ink2, modifier = Modifier.padding(top = 6.dp))
        }
        if (roundKicks.isEmpty()) Text("本轮还没有记录", fontSize = 12.5.sp, color = Ink2, modifier = Modifier.padding(top = 6.dp))
    }
}

// ---------- 宫缩 ----------
@Composable
fun ContractionScreen() {
    val ctx = LocalContext.current
    var running by remember { mutableStateOf(false) }
    var startAt by remember { mutableStateOf(0L) }
    var tick by remember { mutableStateOf(0) }
    LaunchedEffect(running) { while (running) { kotlinx.coroutines.delay(500); tick++ } }

    val list = Store.contractions(ctx).sortedByDescending { it.first }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp)) {
        Text("宫缩计时", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Ink)

        Spacer(Modifier.height(18.dp))
        Card(shape = RoundedCornerShape(24.dp), colors = CardDefaults.cardColors(containerColor = BrandSoft)) {
            Column(Modifier.fillMaxWidth().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                if (running) {
                    val elapsed = (System.currentTimeMillis() - startAt) / 1000
                    Text("%02d:%02d".format(elapsed / 60, elapsed % 60), fontSize = 52.sp, fontWeight = FontWeight.Bold, color = Brand)
                    Text("收缩中…", fontSize = 13.sp, color = Ink2)
                } else {
                    Text("就绪", fontSize = 34.sp, fontWeight = FontWeight.Bold, color = Ink)
                    Text("感觉宫缩开始时点「开始」", fontSize = 13.sp, color = Ink2)
                }
            }
        }

        Spacer(Modifier.height(16.dp))
        Button(
            onClick = {
                if (!running) {
                    startAt = System.currentTimeMillis()
                    running = true
                    Feedback.click(ctx)
                } else {
                    Store.addContraction(ctx, startAt, System.currentTimeMillis())
                    running = false
                    Feedback.click(ctx)
                }
                tick++
            },
            modifier = Modifier.fillMaxWidth().height(58.dp),
            shape = RoundedCornerShape(50),
            colors = ButtonDefaults.buttonColors(containerColor = if (running) Danger else Brand)
        ) {
            Text(if (running) "结束本次收缩" else "开始宫缩计时", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        }

        Spacer(Modifier.height(16.dp))
        Text("历史（最近 20 条）", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Ink)
        list.take(20).forEachIndexed { idx, (s, e) ->
            val dur = (e - s) / 1000
            // 与 iOS 一致：显示与上一次收缩的间隔
            val gap = if (idx < list.size - 1) (s - list[idx + 1].first) / 1000 else 0L
            Column(Modifier.padding(top = 8.dp)) {
                Text(fmtFull(s), fontSize = 12.5.sp, color = Ink)
                Text(
                    "持续 %02d:%02d".format(dur / 60, dur % 60) +
                        if (gap > 0) " · 间隔 %02d:%02d".format(gap / 60, gap % 60) else "",
                    fontSize = 12.5.sp, color = Ink2
                )
            }
        }
        if (list.isEmpty()) Text("暂无宫缩记录", fontSize = 12.5.sp, color = Ink2, modifier = Modifier.padding(top = 6.dp))
    }
}

// ---------- 摘要 ----------
@Composable
fun SummaryScreen() {
    val ctx = LocalContext.current
    var dayOffset by remember { mutableStateOf(0) }   // 0=今天，1=昨天…
    var showAll by remember { mutableStateOf(false) }
    var tick by remember { mutableStateOf(0) }

    val kicks = Store.kicks(ctx)
    val ctns = Store.contractions(ctx)
    val targetDay = dayStart(System.currentTimeMillis()) - dayOffset * 86_400_000L
    val dayKicks = if (showAll) kicks else kicks.filter { dayStart(it) == targetDay }
    val dayCtns = if (showAll) ctns else ctns.filter { dayStart(it.first) == targetDay }

    val sb = StringBuilder()
    sb.append("胎动记录 · ")
    sb.append(if (showAll) "全部" else fmtDay(targetDay))
    sb.append("\n\n胎动：共 ${dayKicks.size} 次")
    if (dayKicks.isNotEmpty()) {
        sb.append("\n首次：").append(fmtFull(dayKicks.min()))
        sb.append("\n末次：").append(fmtFull(dayKicks.max()))
    }
    sb.append("\n\n宫缩：共 ${dayCtns.size} 次")
    dayCtns.sortedBy { it.first }.forEach { (s, e) ->
        val dur = (e - s) / 1000
        sb.append("\n").append(fmtFull(s)).append("（%02d分%02d秒）".format(dur / 60, dur % 60))
    }
    val text = sb.toString()

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp)) {
        Text("摘要", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Ink)

        Spacer(Modifier.height(14.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (!showAll) {
                TextButton(onClick = { dayOffset++; tick++ }) { Text("‹ 前一天") }
                Text(if (dayOffset == 0) "今天" else fmtDay(targetDay), fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Ink, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                if (dayOffset > 0) TextButton(onClick = { dayOffset--; tick++ }) { Text("后一天 ›") } else Spacer(Modifier.width(64.dp))
            } else {
                Text("全部记录", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Ink, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }
            Switch(checked = showAll, onCheckedChange = { showAll = it; tick++ })
            Text("全部", fontSize = 12.sp, color = Ink2)
        }

        Spacer(Modifier.height(10.dp))
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
            Text(text, fontSize = 13.5.sp, color = Ink, modifier = Modifier.padding(16.dp))
        }

        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = {
                    val send = Intent(Intent.ACTION_SEND)
                    send.type = "text/plain"
                    send.putExtra(Intent.EXTRA_TEXT, text)
                    ctx.startActivity(Intent.createChooser(send, "分享摘要"))
                },
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(containerColor = Brand),
                shape = RoundedCornerShape(50)
            ) { Text("分享给家人", color = Color.White) }
            OutlinedButton(
                onClick = {
                    val cb = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                    cb.setPrimaryClip(android.content.ClipData.newPlainText("summary", text))
                    Toast.makeText(ctx, "已复制到剪贴板", Toast.LENGTH_SHORT).show()
                },
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(50)
            ) { Text("复制文字", color = Brand) }
        }
        tick.let {} // 保持 tick 引用
    }
}

// ---------- 设置 ----------
@Composable
fun SettingsScreen() {
    val ctx = LocalContext.current
    var roundMin by remember { mutableStateOf(Store.roundMin(ctx)) }
    var sound by remember { mutableStateOf(Store.soundOn(ctx)) }
    var vol by remember { mutableStateOf(Store.volume(ctx)) }
    var haptic by remember { mutableStateOf(Store.hapticOn(ctx)) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp)) {
        Text("设置", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Ink)

        Spacer(Modifier.height(16.dp))
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
            Column(Modifier.padding(16.dp)) {
                Text("每轮时长", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Ink)
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(5, 10, 15, 30, 45, 60, 75).forEach { m ->
                        Box(
                            Modifier
                                .background(if (roundMin == m) Brand else BrandSoft, RoundedCornerShape(50))
                                .clickable { roundMin = m; Store.setRoundMin(ctx, m) }
                                .padding(horizontal = 12.dp, vertical = 8.dp)
                        ) { Text("${m}分", fontSize = 12.5.sp, color = if (roundMin == m) Color.White else Brand) }
                    }
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
            Column(Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("点击提示音", fontSize = 15.sp, color = Ink, modifier = Modifier.weight(1f))
                    Switch(checked = sound, onCheckedChange = { sound = it; Store.setSoundOn(ctx, it) })
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("音量", fontSize = 15.sp, color = Ink, modifier = Modifier.weight(1f))
                    Slider(
                        value = vol / 100f,
                        onValueChange = { vol = (it * 100).toInt(); Store.setVolume(ctx, vol) },
                        modifier = Modifier.width(160.dp),
                        colors = SliderDefaults.colors(thumbColor = Brand, activeTrackColor = Brand)
                    )
                    Text("$vol%", fontSize = 12.sp, color = Ink2, modifier = Modifier.width(42.dp))
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("点击震动", fontSize = 15.sp, color = Ink, modifier = Modifier.weight(1f))
                    Switch(checked = haptic, onCheckedChange = { haptic = it; Store.setHapticOn(ctx, it) })
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
            Column(Modifier.padding(16.dp)) {
                Text("数据", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Ink)
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedButton(
                        onClick = { Store.clearKicks(ctx); Toast.makeText(ctx, "胎动记录已清空", Toast.LENGTH_SHORT).show() },
                        shape = RoundedCornerShape(50)
                    ) { Text("清空胎动", color = Danger) }
                    OutlinedButton(
                        onClick = { Store.clearContractions(ctx); Toast.makeText(ctx, "宫缩记录已清空", Toast.LENGTH_SHORT).show() },
                        shape = RoundedCornerShape(50)
                    ) { Text("清空宫缩", color = Danger) }
                }
            }
        }

        Spacer(Modifier.height(20.dp))
        Text("胎动记录 v4.1 · 本地优先，无账号、无上传、无广告", fontSize = 12.sp, color = Ink2)
    }
}
