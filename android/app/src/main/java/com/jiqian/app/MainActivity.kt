package com.jiqian.app

import android.app.DatePickerDialog
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
import com.jiqian.app.ui.LogScreen
import com.jiqian.app.ui.WeightScreen
import com.jiqian.app.widget.Widgets
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
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
// 体重页专用：低饱和青绿，与粉色主色区分
val Teal = Color(0xFF3F8A83)
val TealSoft = Color(0xFFEAF5F3)

/** 一条体重记录（只存时间 + 公斤，不做任何判断） */
data class WeightItem(val id: String, val at: Long, val kg: Double)

// ---------- 数据存储（SharedPreferences + JSON，本地优先不外传） ----------
object Store {
    private const val KEY_KICKS = "kicks"
    private const val KEY_CONTRACTIONS = "contractions"
    private const val KEY_WEIGHTS = "weights"
    private const val KEY_PREFS = "prefs"
    private const val KEY_CTN_RUNNING = "ctn_running"

    private fun sp(ctx: Context) = ctx.getSharedPreferences("store", Context.MODE_PRIVATE)

    /** 宫缩是否在计时：存本次开始时间（0 = 没在计时）。App 与桌面组件共用这份状态 */
    fun runningContractionStart(ctx: Context) = sp(ctx).getLong(KEY_CTN_RUNNING, 0L)
    fun setRunningContractionStart(ctx: Context, v: Long) = sp(ctx).edit().putLong(KEY_CTN_RUNNING, v).apply()

    fun kicks(ctx: Context): MutableList<Long> {
        val a = JSONArray(sp(ctx).getString(KEY_KICKS, "[]"))
        val l = mutableListOf<Long>()
        for (i in 0 until a.length()) l.add(a.getLong(i))
        return l
    }

    fun addKick(ctx: Context) {
        // 查看模式：不能记录（数据由写端同步过来）
        if (!SyncManager.canEdit) return
        val l = kicks(ctx); l.add(System.currentTimeMillis())
        val a = JSONArray(); l.forEach { a.put(it) }
        sp(ctx).edit().putString(KEY_KICKS, a.toString()).apply()
        SyncManager.onDataChanged()
        Widgets.refresh(ctx)
    }

    fun removeLastKick(ctx: Context) {
        if (!SyncManager.canEdit) return
        val l = kicks(ctx); if (l.isNotEmpty()) {
            val removed = l.removeAt(l.size - 1)
            // 撤销也要跨端生效：写墓碑（以发生时间毫秒为锚点），对端会删掉同一条
            SyncManager.addTombstone("ke@$removed")
        }
        val a = JSONArray(); l.forEach { a.put(it) }
        sp(ctx).edit().putString(KEY_KICKS, a.toString()).apply()
        SyncManager.onDataChanged()
        Widgets.refresh(ctx)
    }

    fun clearKicks(ctx: Context) {
        if (!SyncManager.canEdit) return
        // 部分清空：逐条写墓碑，让对端也删掉这些胎动
        kicks(ctx).forEach { SyncManager.addTombstone("ke@$it") }
        sp(ctx).edit().putString(KEY_KICKS, "[]").apply()
        SyncManager.onDataChanged()
        Widgets.refresh(ctx)
    }

    /** 同步引擎专用：整体替换本机数据（不触发 onDataChanged，避免同步循环） */
    fun replaceAll(ctx: Context, newKicks: List<Long>, newCtns: List<Pair<Long, Long>>) {
        val ka = JSONArray(); newKicks.forEach { ka.put(it) }
        val ca = JSONArray(); newCtns.forEach { ca.put(JSONObject().put("s", it.first).put("e", it.second)) }
        sp(ctx).edit().putString(KEY_KICKS, ka.toString()).putString(KEY_CONTRACTIONS, ca.toString()).apply()
        Widgets.refresh(ctx)
    }

    fun contractions(ctx: Context): MutableList<Pair<Long, Long>> {
        val a = JSONArray(sp(ctx).getString(KEY_CONTRACTIONS, "[]"))
        val l = mutableListOf<Pair<Long, Long>>()
        for (i in 0 until a.length()) l.add(Pair(a.getJSONObject(i).getLong("s"), a.getJSONObject(i).getLong("e")))
        return l
    }

    fun addContraction(ctx: Context, start: Long, end: Long) {
        if (!SyncManager.canEdit) return
        val l = contractions(ctx); l.add(Pair(start, end))
        val a = JSONArray(); l.forEach { a.put(JSONObject().put("s", it.first).put("e", it.second)) }
        sp(ctx).edit().putString(KEY_CONTRACTIONS, a.toString()).apply()
        SyncManager.onDataChanged()
        Widgets.refresh(ctx)
    }

    fun clearContractions(ctx: Context) {
        if (!SyncManager.canEdit) return
        // 部分清空：逐条写墓碑（以开始时间为锚点），让对端也删掉这些宫缩
        contractions(ctx).forEach { SyncManager.addTombstone("ce@${it.first}") }
        sp(ctx).edit().putString(KEY_CONTRACTIONS, "[]").apply()
        SyncManager.onDataChanged()
        Widgets.refresh(ctx)
    }

    // ---------- 体重（v5.4）：只存时间与公斤，随配对同步 ----------

    fun weights(ctx: Context): MutableList<WeightItem> {
        val a = JSONArray(sp(ctx).getString(KEY_WEIGHTS, "[]"))
        val l = mutableListOf<WeightItem>()
        for (i in 0 until a.length()) {
            val o = a.optJSONObject(i) ?: continue
            val at = o.optLong("at", 0L)
            if (at <= 0L) continue
            val id = o.optString("id").ifEmpty { "w$at" }
            l.add(WeightItem(id, at, o.optDouble("kg", 0.0)))
        }
        return l.sortedBy { it.at }.toMutableList()
    }

    private fun saveWeights(ctx: Context, list: List<WeightItem>) {
        val a = JSONArray()
        list.sortedBy { it.at }.forEach { w ->
            a.put(JSONObject().put("id", w.id).put("at", w.at).put("kg", w.kg))
        }
        sp(ctx).edit().putString(KEY_WEIGHTS, a.toString()).apply()
    }

    /** 记一次体重；返回是否成功（查看模式 / 数值不合理时不落库） */
    fun addWeight(ctx: Context, kg: Double, at: Long = System.currentTimeMillis()): Boolean {
        if (!SyncManager.canEdit) return false
        if (kg < 30.0 || kg > 200.0) return false
        val l = weights(ctx)
        // 同一毫秒重复点击：直接覆盖那一条，避免生成两条一模一样
        val rounded = Math.round(kg * 10.0) / 10.0
        l.removeAll { it.at == at }
        l.add(WeightItem("w$at", at, rounded))
        saveWeights(ctx, l)
        SyncManager.onDataChanged()
        return true
    }

    fun deleteWeight(ctx: Context, item: WeightItem) {
        if (!SyncManager.canEdit) return
        val l = weights(ctx)
        l.removeAll { it.id == item.id }
        saveWeights(ctx, l)
        // 以称重时间为锚点写墓碑，对端同一条一并删除
        SyncManager.addTombstone("we@${item.at}")
        SyncManager.onDataChanged()
    }

    fun clearWeights(ctx: Context) {
        if (!SyncManager.canEdit) return
        weights(ctx).forEach { SyncManager.addTombstone("we@${it.at}") }
        saveWeights(ctx, emptyList())
        SyncManager.onDataChanged()
    }

    /** 同步引擎专用：整体替换（不触发 onDataChanged） */
    fun replaceWeights(ctx: Context, list: List<WeightItem>) {
        saveWeights(ctx, list)
    }

    fun roundMin(ctx: Context) = sp(ctx).getInt(KEY_PREFS + "roundMin", 60)    fun setRoundMin(ctx: Context, v: Int) = sp(ctx).edit().putInt(KEY_PREFS + "roundMin", v).apply()

    /** 预产期（当天 0 点毫秒，0 = 未设置）与最后修改时间的镜像；同步数据源在 SyncManager 的 st */
    fun edd(ctx: Context) = sp(ctx).getLong(KEY_PREFS + "edd", 0L)
    fun eddT(ctx: Context) = sp(ctx).getLong(KEY_PREFS + "eddT", 0L)

    /** 同步落地：只写不改标记，避免两端互推 */
    fun applyEdd(ctx: Context, ms: Long, t: Long) {
        sp(ctx).edit().putLong(KEY_PREFS + "edd", ms).putLong(KEY_PREFS + "eddT", t).apply()
    }

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

/** 预产期日期选择：没设置过就从今天往后 90 天（与 iOS 一致） */
fun pickEdd(ctx: Context, cur: Long, onPicked: (Long) -> Unit) {
    val cal = Calendar.getInstance()
    if (cur > 0L) cal.timeInMillis = cur else cal.add(Calendar.DAY_OF_YEAR, 90)
    DatePickerDialog(
        ctx,
        { _, y, m, d ->
            val c = Calendar.getInstance()
            c.set(y, m, d, 0, 0, 0)
            c.set(Calendar.MILLISECOND, 0)
            onPicked(c.timeInMillis)
        },
        cal.get(Calendar.YEAR),
        cal.get(Calendar.MONTH),
        cal.get(Calendar.DAY_OF_MONTH)
    ).show()
}

/** 孕周文案：按预产期倒推 40 周（280 天），与 iOS PregnancyClock 同一套算法 */
fun gestationText(eddMs: Long, now: Long = System.currentTimeMillis()): String {
    if (eddMs <= 0L) return "未设定"
    val daysLeft = ((dayStart(eddMs) - dayStart(now)) / 86_400_000L).toInt()
    val passed = 280 - daysLeft
    if (passed < 0 || passed > 320) return "未设定"
    return "${passed / 7} 周 ${passed % 7} 天"
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppLog.init(applicationContext)
        SyncManager.bootstrap(applicationContext)
        SyncNotifier.ensureChannel(applicationContext)
        // 已配对才申请通知权限（有人申请编辑权限时要能提醒到）
        if (SyncManager.pairedCode != null) requestNotifyPermission()
        handleIntent(intent)
        setContent { App() }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    /** 点「有设备申请编辑权限」的通知进来：直接打开配对同步页 */
    private fun handleIntent(intent: Intent?) {
        if (intent?.getBooleanExtra(SyncNotifier.EXTRA_OPEN_SYNC, false) == true) {
            intent.removeExtra(SyncNotifier.EXTRA_OPEN_SYNC)
            SyncManager.requestOpenSync()
        }
    }

    private fun requestNotifyPermission() {
        if (Build.VERSION.SDK_INT < 33) return
        if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) return
        requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1001)
    }

    override fun onResume() {
        super.onResume()
        SyncManager.onForeground()
    }

    override fun onPause() {
        super.onPause()
        SyncManager.onBackground()
    }
}

@Composable
fun App() {
    var tab by remember { mutableStateOf(0) }
    var showSync by remember { mutableStateOf(false) }
    var showLog by remember { mutableStateOf(false) }
    val openSyncTick = SyncManager.openSyncTick
    // 点通知进来：直接打开配对同步页
    LaunchedEffect(openSyncTick) {
        if (openSyncTick > 0) showSync = true
    }
    MaterialTheme(
        colorScheme = lightColorScheme(primary = Brand, background = Bg, surface = Bg)
    ) {
        Surface(Modifier.fillMaxSize(), color = Bg) {
            Column(Modifier.fillMaxSize()) {
                // 查看模式横幅：配对后未获授权的手机只能看，改不了数据
                if (SyncManager.pairedCode != null && !SyncManager.canEdit) {
                    Text(
                        "👁 查看模式 · 修改数据需在「设置 → 配对同步」申请权限",
                        fontSize = 11.sp, color = Ink2,
                        modifier = Modifier.fillMaxWidth().background(BrandSoft).padding(horizontal = 16.dp, vertical = 6.dp)
                    )
                }
                // 有人申请编辑权限：常驻横幅，点一下直接进审批页
                val reqs = SyncManager.pendingReqs
                if (SyncManager.pairedCode != null && SyncManager.canEdit && reqs.isNotEmpty()) {
                    Row(
                        Modifier.fillMaxWidth().background(Brand).clickable { showSync = true }
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("🔔", fontSize = 12.sp)
                        Text(
                            if (reqs.size == 1) "设备 ${reqs[0].first} 申请编辑权限 · 点此审批"
                            else "${reqs.size} 台设备申请编辑权限 · 点此审批",
                            fontSize = 11.sp, color = Color.White, maxLines = 1,
                            modifier = Modifier.weight(1f).padding(start = 6.dp)
                        )
                        Text("›", fontSize = 15.sp, color = Color.White)
                    }
                }
                Box(Modifier.weight(1f)) {
                    when {
                        showSync -> SyncScreen(onClose = { showSync = false })
                        showLog -> LogScreen(onClose = { showLog = false })
                        tab == 0 -> KickScreen()
                        tab == 1 -> ContractionScreen()
                        tab == 2 -> WeightScreen()
                        tab == 3 -> SummaryScreen()
                        else -> SettingsScreen(onOpenSync = { showSync = true }, onOpenLog = { showLog = true })
                    }
                }
                BottomBar(tab) { tab = it }
            }
        }
    }
}

@Composable
fun BottomBar(sel: Int, onPick: (Int) -> Unit) {
    val items = listOf("胎动", "宫缩", "体重", "摘要", "设置")
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
            TextButton(onClick = {
                // 以前点了没反应（查看模式被拦截时静默返回）：这里明确告诉用户为什么
                if (!SyncManager.canEdit) {
                    Toast.makeText(ctx, "查看模式不能改记录，去「设置 → 配对同步」申请权限", Toast.LENGTH_SHORT).show()
                } else if (Store.kicks(ctx).isEmpty()) {
                    Toast.makeText(ctx, "还没有可以撤销的记录", Toast.LENGTH_SHORT).show()
                } else {
                    Store.removeLastKick(ctx)
                    tick++
                }
            }) { Text("撤销上一次", color = Ink2) }
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
    // 计时状态存进 SharedPreferences：App 被杀掉、或从桌面组件点了开始，都能接上
    var startAt by remember { mutableStateOf(Store.runningContractionStart(ctx)) }
    var running by remember { mutableStateOf(startAt > 0L) }
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
                    Store.setRunningContractionStart(ctx, startAt)
                    running = true
                    Feedback.click(ctx)
                } else {
                    Store.addContraction(ctx, startAt, System.currentTimeMillis())
                    Store.setRunningContractionStart(ctx, 0L)
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
fun TotalBlock(label: String, value: Int, tint: Color) {
    Column(horizontalAlignment = Alignment.End) {
        Text(label, fontSize = 10.sp, color = Ink2)
        Row(verticalAlignment = Alignment.Bottom) {
            Text("$value", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = tint)
            Text("次", fontSize = 10.sp, color = Ink2, modifier = Modifier.padding(start = 2.dp, bottom = 3.dp))
        }
    }
}

@Composable
fun SummaryScreen() {
    val ctx = LocalContext.current
    var dayOffset by remember { mutableStateOf(0) }   // 0=今天，1=昨天…
    var showAll by remember { mutableStateOf(false) }
    var tick by remember { mutableStateOf(0) }

    val kicks = Store.kicks(ctx)
    val ctns = Store.contractions(ctx)
    val weights = Store.weights(ctx)
    val targetDay = dayStart(System.currentTimeMillis()) - dayOffset * 86_400_000L
    val dayKicks = if (showAll) kicks else kicks.filter { dayStart(it) == targetDay }
    val dayCtns = if (showAll) ctns else ctns.filter { dayStart(it.first) == targetDay }
    val dayWeights = if (showAll) weights else weights.filter { dayStart(it.at) == targetDay }

    val sb = StringBuilder()
    sb.append("胎动记录 · ")
    sb.append(if (showAll) "全部" else fmtDay(targetDay))
    // 预产期来自同步设置，孕周按所看那一天算（与 iOS 摘要一致）
    SyncManager.eddMs().takeIf { it > 0L }?.let { sb.append("\n孕周：").append(gestationText(it, targetDay)) }
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
    // 体重：只给最近一次与时段内的前后差，不做任何增重评价
    sb.append("\n\n体重：")
    if (dayWeights.isEmpty()) {
        sb.append("无记录")
    } else {
        val last = dayWeights.last()
        sb.append("最近 ").append(fmtDay(last.at)).append(" ").append("%.1f".format(last.kg)).append(" kg")
        if (dayWeights.size > 1) {
            val delta = last.kg - dayWeights.first().kg
            sb.append("\n共 ${dayWeights.size} 次记录，较第一次 ")
                .append(if (kotlin.math.abs(delta) < 0.05) "±0.0" else (if (delta > 0) "+" else "-") + "%.1f".format(kotlin.math.abs(delta)))
                .append(" kg")
        }
    }
    val text = sb.toString()

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("摘要", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Ink, modifier = Modifier.weight(1f))
            // 右上角合计：胎动 / 宫缩
            TotalBlock("胎动", dayKicks.size, Brand)
            Box(Modifier.padding(horizontal = 10.dp).size(width = 1.dp, height = 30.dp).background(Line))
            TotalBlock("宫缩", dayCtns.size, Color(0xFFC08089))
        }

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
fun SettingsScreen(onOpenSync: () -> Unit, onOpenLog: () -> Unit = {}) {
    val ctx = LocalContext.current
    var roundMin by remember(SyncManager.eddVersion) { mutableStateOf(Store.roundMin(ctx)) }
    var sound by remember { mutableStateOf(Store.soundOn(ctx)) }
    var vol by remember { mutableStateOf(Store.volume(ctx)) }
    var haptic by remember { mutableStateOf(Store.hapticOn(ctx)) }
    // 共享设置（预产期 / 每轮时长）：同步落地后 eddVersion 自增，这里跟着刷新
    var edd by remember(SyncManager.eddVersion) { mutableStateOf(SyncManager.eddMs()) }
    // 清空记录的两道确认：1=第一次提醒，2=最后确认
    var confirmStep by remember { mutableStateOf(0) }
    var wipeKind by remember { mutableStateOf("kicks") }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp)) {
        Text("设置", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Ink)

        Spacer(Modifier.height(16.dp))
        Card(
            shape = RoundedCornerShape(20.dp),
            colors = CardDefaults.cardColors(containerColor = CardBg),
            modifier = Modifier.fillMaxWidth().clickable { onOpenSync() }
        ) {
            Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("☁️", fontSize = 16.sp)
                Text("配对同步", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Ink, modifier = Modifier.padding(start = 8.dp))
                Spacer(Modifier.weight(1f))
                if (SyncManager.canEdit && SyncManager.pendingReqs.isNotEmpty()) {
                    // 有人申请编辑权限：红色角标，一眼能看到
                    Text(
                        "${SyncManager.pendingReqs.size} 待审批",
                        fontSize = 10.5.sp, fontWeight = FontWeight.Bold, color = Color.White,
                        modifier = Modifier
                            .background(Danger, RoundedCornerShape(9.dp))
                            .padding(horizontal = 7.dp, vertical = 2.dp)
                    )
                    Spacer(Modifier.width(6.dp))
                }
                Text(
                    SyncManager.pairedCode?.let {
                        if (SyncManager.canEdit) "已配对 ${it.take(3)}···" else "已配对 ${it.take(3)}···（查看）"
                    } ?: "未配对",
                    fontSize = 12.sp, color = Ink2
                )
            }
        }
        Text(
            "用 6 位配对码把这台手机和家人的手机连起来，记录端到端加密后自动双向同步",
            fontSize = 11.sp, color = Ink2, lineHeight = 15.sp, modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp)
        )

        Spacer(Modifier.height(12.dp))
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
            Column(Modifier.padding(16.dp)) {
                Text("孕周与目标", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Ink)
                Spacer(Modifier.height(4.dp))
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable(enabled = SyncManager.canEdit) {
                            pickEdd(ctx, edd) { v -> edd = v; SyncManager.setEddShared(v) }
                        }
                        .padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("预产期", fontSize = 14.sp, color = Ink)
                    Spacer(Modifier.weight(1f))
                    Text(if (edd > 0L) fmtDay(edd) else "未设置", fontSize = 14.sp, color = Brand)
                    Text(" ›", fontSize = 14.sp, color = Ink2)
                }
                Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("当前孕周", fontSize = 14.sp, color = Ink)
                    Spacer(Modifier.weight(1f))
                    Text(gestationText(edd), fontSize = 14.sp, color = Ink2)
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    if (SyncManager.canEdit)
                        "预产期、每轮时长等设置随配对同步：改完约 6 秒内同步到家人的手机，孕周与摘要按同一套设置算。"
                    else
                        "查看模式下不能改这些设置，会由配对设备同步过来；要修改请先申请编辑权限（设置 → 配对同步）。",
                    fontSize = 11.sp, color = Ink2, lineHeight = 15.sp
                )
            }
        }

        Spacer(Modifier.height(12.dp))
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
            Column(Modifier.padding(16.dp)) {
                Text("桌面组件", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Ink)
                Spacer(Modifier.height(6.dp))
                Text(
                    "长按桌面空白处 → 小组件 → 搜「胎动记录」，可添加：\n" +
                        "· 胎动 · 记一下（2×2，点一下记一次）\n" +
                        "· 宫缩 · 计时开关（2×2，点一下开始，再点结束保存）\n" +
                        "· 胎动 / 宫缩 快捷开关（4×2，两个开关并排）\n" +
                        "组件上的次数与计时是实时读取的，点完就地刷新，不用打开 App。",
                    fontSize = 12.sp, color = Ink2, lineHeight = 18.sp
                )
            }
        }

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
                                .clickable(enabled = SyncManager.canEdit) {
                                    roundMin = m; SyncManager.setRoundMinShared(m)
                                }
                                .padding(horizontal = 12.dp, vertical = 8.dp)
                        ) { Text("${m}分", fontSize = 12.5.sp, color = if (roundMin == m) Color.White else Brand) }
                    }
                }
                if (!SyncManager.canEdit) {
                    Spacer(Modifier.height(6.dp))
                    Text("查看模式下不能改，会由配对设备同步过来", fontSize = 11.sp, color = Ink2)
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
                        onClick = { wipeKind = "kicks"; confirmStep = 1 },
                        enabled = SyncManager.canEdit,
                        shape = RoundedCornerShape(50)
                    ) { Text("清空胎动", color = if (SyncManager.canEdit) Danger else Ink2) }
                    OutlinedButton(
                        onClick = { wipeKind = "ctns"; confirmStep = 1 },
                        enabled = SyncManager.canEdit,
                        shape = RoundedCornerShape(50)
                    ) { Text("清空宫缩", color = if (SyncManager.canEdit) Danger else Ink2) }
                    OutlinedButton(
                        onClick = { wipeKind = "weights"; confirmStep = 1 },
                        enabled = SyncManager.canEdit,
                        shape = RoundedCornerShape(50)
                    ) { Text("清空体重", color = if (SyncManager.canEdit) Danger else Ink2) }
                }
                if (!SyncManager.canEdit) {
                    Spacer(Modifier.height(6.dp))
                    // 查看模式：记录是同步来的，清空入口锁死，防误触把别人的记录清了
                    Text(
                        "查看模式不能清空记录；请在可编辑的那台手机上清空（会同步删掉所有配对设备的记录）",
                        fontSize = 11.sp, color = Ink2, lineHeight = 15.sp
                    )
                }
            }
        }

        Spacer(Modifier.height(20.dp))
        Spacer(Modifier.height(14.dp))
        // 运行日志（排查用）：独立开关，默认关；打开后可进入日志页查看
        var logOn by remember { mutableStateOf(AppLog.enabled(ctx)) }
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
            Column(Modifier.padding(16.dp)) {
                Row(
                    Modifier.fillMaxWidth().clickable(enabled = logOn) { onOpenLog() },
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("🧾 运行日志（排查用）", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Ink)
                        Text(
                            if (logOn) "已开启 · 点这里查看日志" else "开启后记录同步、配对等关键动作，供排查问题",
                            fontSize = 11.sp, color = Ink2, modifier = Modifier.padding(top = 2.dp)
                        )
                    }
                    Switch(checked = logOn, onCheckedChange = { on ->
                        logOn = on
                        AppLog.setEnabled(ctx, on)
                    })
                }
                Text(
                    "日志只存在这台手机的内存里（最近 600 条），不落盘、不同步、不上传；关闭开关即清空。",
                    fontSize = 10.5.sp, color = Ink2, lineHeight = 14.sp, modifier = Modifier.padding(top = 6.dp)
                )
            }
        }

        Spacer(Modifier.height(14.dp))
        Text("胎动记录 v5.6 · 本地优先，无账号、无广告；配对同步采用端到端加密", fontSize = 12.sp, color = Ink2)

        if (confirmStep > 0) {
            val name = when (wipeKind) {
                "kicks" -> "胎动"
                "ctns" -> "宫缩"
                else -> "体重"
            }
            AlertDialog(
                onDismissRequest = { confirmStep = 0 },
                title = { Text(if (confirmStep == 1) "清空${name}记录？" else "最后确认一次") },
                text = {
                    Text(
                        if (confirmStep == 1)
                            "本机的${name}记录将被删除，无法恢复。"
                        else
                            "确定要彻底清空${name}记录吗？删除后无法找回。"
                    )
                },
                confirmButton = {
                    TextButton(onClick = {
                        if (confirmStep == 1) {
                            confirmStep = 2
                        } else {
                            if (wipeKind == "kicks") {
                                Store.clearKicks(ctx)
                                Toast.makeText(ctx, "胎动记录已清空", Toast.LENGTH_SHORT).show()
                            } else if (wipeKind == "ctns") {
                                Store.clearContractions(ctx)
                                Toast.makeText(ctx, "宫缩记录已清空", Toast.LENGTH_SHORT).show()
                            } else {
                                Store.clearWeights(ctx)
                                Toast.makeText(ctx, "体重记录已清空", Toast.LENGTH_SHORT).show()
                            }
                            confirmStep = 0
                        }
                    }) { Text(if (confirmStep == 1) "继续" else "彻底清空", color = Danger) }
                },
                dismissButton = {
                    TextButton(onClick = { confirmStep = 0 }) { Text("取消", color = Ink2) }
                }
            )
        }
    }
}
