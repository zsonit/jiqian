package com.jiqian.app.ui

import android.app.DatePickerDialog
import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jiqian.app.*
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max

// ---------- 体重记录（v5.4）----------
// 只记「什么时候称、多少公斤」，不出现任何增重评价或健康判断。
// 数据随配对同步（acl.sm 的 w 位控制是否同步给某台设备）。

private fun fmtKg(v: Double): String = "%.1f".format(v)

private fun deltaText(d: Double): String =
    if (kotlin.math.abs(d) < 0.05) "±0.0" else (if (d > 0) "+" else "-") + "%.1f".format(kotlin.math.abs(d))

/** 选称重日期：默认今天 */
private fun pickWeightDay(ctx: Context, cur: Long, onPicked: (Long) -> Unit) {
    val cal = Calendar.getInstance()
    if (cur > 0L) cal.timeInMillis = cur
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

/** 把选中的日期与当前钟点拼起来（回填历史日期时保留现在的时间） */
private fun dayWithNowClock(dayMs: Long): Long {
    val day = Calendar.getInstance().apply {
        timeInMillis = dayMs
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }
    val now = Calendar.getInstance()
    day.set(Calendar.HOUR_OF_DAY, now.get(Calendar.HOUR_OF_DAY))
    day.set(Calendar.MINUTE, now.get(Calendar.MINUTE))
    day.set(Calendar.SECOND, now.get(Calendar.SECOND))
    return day.timeInMillis
}

@Composable
fun WeightScreen() {
    val ctx = LocalContext.current
    var version by remember { mutableStateOf(0) }
    // 配对同步是在后台线程落库的，界面靠这个 2 秒心跳把对方同步过来的体重刷出来
    var tick by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { while (true) { kotlinx.coroutines.delay(2000); tick++ } }
    val list = remember(version, tick) { Store.weights(ctx) }
    var input by remember { mutableStateOf("") }
    var dayMs by remember { mutableStateOf(System.currentTimeMillis()) }
    var confirmDelete by remember { mutableStateOf<WeightItem?>(null) }
    var confirmClear by remember { mutableStateOf(false) }
    // 首次进来（或还空着）时用最近一次的体重预填，省得每次都敲
    LaunchedEffect(list.size) {
        if (input.isBlank() && list.isNotEmpty()) input = fmtKg(list.last().kg)
    }

    val canEdit = SyncManager.canEdit
    val first = list.firstOrNull()
    val latest = list.lastOrNull()
    val gained = if (list.size > 1 && first != null && latest != null) latest.kg - first.kg else null

    fun save() {
        val kg = input.replace("，", ".").replace(",", ".").toDoubleOrNull()
        if (kg == null || kg < 30.0 || kg > 200.0) {
            android.widget.Toast.makeText(ctx, "请填 30–200 之间的公斤数", android.widget.Toast.LENGTH_SHORT).show()
            return
        }
        val at = dayWithNowClock(dayMs)
        if (Store.addWeight(ctx, kg, at)) {
            version++
            dayMs = System.currentTimeMillis()
            android.widget.Toast.makeText(ctx, "已记录 ${fmtKg(kg)} kg", android.widget.Toast.LENGTH_SHORT).show()
            Feedback.click(ctx)
        } else {
            android.widget.Toast.makeText(ctx, "查看模式不能记录", android.widget.Toast.LENGTH_SHORT).show()
        }
    }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp)
    ) {
        Text("体重记录", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Ink)
        Text("只记时间和公斤数，不做任何评价", fontSize = 13.sp, color = Ink2, modifier = Modifier.padding(top = 4.dp))

        // 概况
        Spacer(Modifier.height(16.dp))
        Card(shape = RoundedCornerShape(24.dp), colors = CardDefaults.cardColors(containerColor = TealSoft)) {
            Column(Modifier.fillMaxWidth().padding(18.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    Column(Modifier.weight(1f)) {
                        Text("最近一次", fontSize = 11.sp, color = Ink2)
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text(latest?.let { fmtKg(it.kg) } ?: "—", fontSize = 38.sp, fontWeight = FontWeight.Bold, color = Teal)
                            Text("kg", fontSize = 13.sp, color = Ink2, modifier = Modifier.padding(start = 4.dp, bottom = 6.dp))
                        }
                    }
                    Column(horizontalAlignment = Alignment.End) {
                        if (gained != null) {
                            Text("较首次 ${deltaText(gained)} kg", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Teal)
                            Spacer(Modifier.height(4.dp))
                        }
                        Text("共 ${list.size} 次记录", fontSize = 11.sp, color = Ink2)
                    }
                }
                Spacer(Modifier.height(8.dp))
                Text(
                    latest?.let { "最近记录：${fmtDay(it.at)} ${SimpleDateFormat("HH:mm", Locale.CHINA).format(Date(it.at))}" }
                        ?: "还没有记录，把今天称的数字填到下面就行",
                    fontSize = 12.sp, color = Ink2
                )
            }
        }

        // 曲线
        if (list.size >= 2) {
            val points = list.takeLast(30)
            Spacer(Modifier.height(12.dp))
            Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
                Column(Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("体重变化", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Ink, modifier = Modifier.weight(1f))
                        Text("最近 ${points.size} 次", fontSize = 11.sp, color = Ink2)
                    }
                    Spacer(Modifier.height(10.dp))
                    WeightChart(points)
                    Row(Modifier.fillMaxWidth()) {
                        Text("${fmtDay(points.first().at)} · ${fmtKg(points.first().kg)}", fontSize = 10.5.sp, color = Ink2, modifier = Modifier.weight(1f))
                        Text("${fmtDay(points.last().at)} · ${fmtKg(points.last().kg)}", fontSize = 10.5.sp, color = Ink2)
                    }
                }
            }
        }

        // 录入
        Spacer(Modifier.height(12.dp))
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
            Column(Modifier.padding(16.dp)) {
                Text("记一次体重", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Ink)
                Spacer(Modifier.height(10.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = input,
                        onValueChange = { if (it.length <= 6) input = it },
                        placeholder = { Text("例如 62.4", color = Ink2, fontSize = 15.sp) },
                        singleLine = true,
                        enabled = canEdit,
                        textStyle = androidx.compose.ui.text.TextStyle(
                            fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Ink
                        ),
                        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.weight(1f)
                    )
                    Text("kg", fontSize = 14.sp, color = Ink2, modifier = Modifier.padding(start = 8.dp))
                }
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(-0.5, -0.1, 0.1, 0.5).forEach { d ->
                        Box(
                            Modifier
                                .weight(1f)
                                .background(TealSoft, RoundedCornerShape(50))
                                .clickable(enabled = canEdit) {
                                    val base = input.replace("，", ".").replace(",", ".").toDoubleOrNull()
                                        ?: latest?.kg ?: 0.0
                                    if (base > 0) input = fmtKg((base + d).coerceIn(30.0, 200.0))
                                }
                                .padding(vertical = 8.dp),
                            contentAlignment = Alignment.Center
                        ) { Text(if (d > 0) "+%.1f".format(d) else "%.1f".format(d), fontSize = 12.5.sp, color = Teal) }
                    }
                }
                Spacer(Modifier.height(6.dp))
                Row(
                    Modifier.fillMaxWidth().clickable(enabled = canEdit) { pickWeightDay(ctx, dayMs) { dayMs = it } }
                        .padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("称重日期", fontSize = 14.sp, color = Ink)
                    Spacer(Modifier.weight(1f))
                    Text(fmtDay(dayMs), fontSize = 14.sp, color = Teal)
                    Text(" ›", fontSize = 14.sp, color = Ink2)
                }
                Spacer(Modifier.height(4.dp))
                Button(
                    onClick = { save() },
                    enabled = canEdit,
                    modifier = Modifier.fillMaxWidth().height(50.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Teal, disabledContainerColor = Ink2)
                ) { Text(if (canEdit) "记录这次体重" else "查看模式不能记录", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Color.White) }
                if (!canEdit) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "这台手机是查看模式：体重记录由可编辑的手机同步过来。想自己记录请在「设置 → 配对同步」申请编辑权限。",
                        fontSize = 11.sp, color = Ink2, lineHeight = 15.sp
                    )
                }
            }
        }

        // 列表
        Spacer(Modifier.height(12.dp))
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
            Column(Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("全部记录", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Ink, modifier = Modifier.weight(1f))
                    if (list.isNotEmpty() && canEdit) {
                        TextButton(onClick = { confirmClear = true }) { Text("清空", fontSize = 12.sp, color = Danger) }
                    }
                }
                if (list.isEmpty()) {
                    Text("还没有记录", fontSize = 12.5.sp, color = Ink2, modifier = Modifier.padding(top = 6.dp))
                }
                list.asReversed().forEachIndexed { idx, item ->
                    // 与上一条（时间更早的那条）比较
                    val prev = if (idx < list.size - 1) list[list.size - 2 - idx] else null
                    val delta = prev?.let { item.kg - it.kg }
                    Row(Modifier.fillMaxWidth().padding(vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(fmtDay(item.at), fontSize = 13.sp, color = Ink)
                            Text(SimpleDateFormat("HH:mm", Locale.CHINA).format(Date(item.at)), fontSize = 11.sp, color = Ink2)
                        }
                        if (delta != null && kotlin.math.abs(delta) >= 0.05) {
                            Text(deltaText(delta), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = if (delta > 0) Teal else Color(0xFFC08089),
                                modifier = Modifier.background(TealSoft, RoundedCornerShape(50)).padding(horizontal = 7.dp, vertical = 3.dp))
                            Spacer(Modifier.width(6.dp))
                        }
                        Text(fmtKg(item.kg), fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Ink)
                        Text(" kg", fontSize = 10.5.sp, color = Ink2)
                        if (canEdit) {
                            Spacer(Modifier.width(6.dp))
                            Text("✕", fontSize = 13.sp, color = Ink2, modifier = Modifier.clickable { confirmDelete = item }.padding(4.dp))
                        }
                    }
                    Box(Modifier.fillMaxWidth().height(1.dp).background(Line))
                }
            }
        }

        Spacer(Modifier.height(14.dp))
        Text(
            "只记录称重的时间和公斤数，供你和产科沟通时参考。本应用不对体重做任何评价或建议。\n" +
                "孕后期体重变化较大时，以建档机构的随访安排为准。",
            fontSize = 12.sp, color = Ink2, lineHeight = 18.sp
        )
        Spacer(Modifier.height(20.dp))
    }

    confirmDelete?.let { item ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("删除这条记录？", fontSize = 16.sp, fontWeight = FontWeight.Bold) },
            text = { Text("${fmtDay(item.at)} ${fmtKg(item.kg)} kg。配对的手机会同步删掉同一条记录。", fontSize = 13.sp, lineHeight = 19.sp) },
            confirmButton = {
                TextButton(onClick = {
                    Store.deleteWeight(ctx, item)
                    confirmDelete = null
                    version++
                }) { Text("删除", color = Danger, fontWeight = FontWeight.Bold) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("取消", color = Ink2) } }
        )
    }
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("清空全部体重记录？", fontSize = 16.sp, fontWeight = FontWeight.Bold) },
            text = { Text("本机与配对手机上的体重记录都会被删除，无法恢复。胎动、宫缩记录不受影响。", fontSize = 13.sp, lineHeight = 19.sp) },
            confirmButton = {
                TextButton(onClick = {
                    Store.clearWeights(ctx)
                    confirmClear = false
                    version++
                }) { Text("清空", color = Danger, fontWeight = FontWeight.Bold) }
            },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("取消", color = Ink2) } }
        )
    }
}

/** 体重折线：自绘，避免引入图表库 */
@Composable
private fun WeightChart(points: List<WeightItem>) {
    Canvas(Modifier.fillMaxWidth().height(140.dp)) {
        if (points.isEmpty()) return@Canvas
        val values = points.map { it.kg }
        val lo = floor((values.min() - 0.4) * 2) / 2
        val hi = ceil((values.max() + 0.4) * 2) / 2
        val span = max(hi - lo, 0.5)
        val t0 = points.first().at.toDouble()
        val t1 = points.last().at.toDouble()
        val spanT = max(t1 - t0, 1.0)

        for (i in 0..2) {
            val y = size.height * i / 2f
            drawLine(Line, Offset(0f, y), Offset(size.width, y), strokeWidth = 1.5f)
        }
        val pts = points.map { w ->
            Offset(
                x = (size.width * ((w.at - t0) / spanT)).toFloat().coerceIn(4f, max(size.width - 4f, 4f)),
                y = (size.height * (1 - (w.kg - lo) / span)).toFloat().coerceIn(6f, max(size.height - 6f, 6f))
            )
        }
        for (i in 1 until pts.size) {
            drawLine(Teal, pts[i - 1], pts[i], strokeWidth = 6f, cap = StrokeCap.Round)
        }
        pts.forEach { p ->
            drawCircle(Color.White, radius = 6.5f, center = p)
            drawCircle(Teal, radius = 6.5f, center = p, style = Stroke(width = 3f))
        }
    }
}
