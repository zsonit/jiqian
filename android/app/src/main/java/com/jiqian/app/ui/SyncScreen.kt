package com.jiqian.app

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import org.json.JSONObject

// ---------- 配对同步 ----------
// 一台手机创建配对码，另一台输入同一个码，之后双方联网就自动双向同步全部记录。

@Composable
fun SyncScreen(onClose: () -> Unit) {
    // SyncManager 的状态是 Compose snapshot state，组合期直接读取即自动订阅刷新
    val busy = SyncManager.busy
    val lastMessage = SyncManager.lastMessage
    val lastSyncAt = SyncManager.lastSyncAt
    var running by remember { mutableStateOf(false) }
    var joinText by remember { mutableStateOf("") }
    var toast by remember { mutableStateOf<String?>(null) }

    fun toast(msg: String) {
        toast = msg
        Thread {
            Thread.sleep(2200)
            toast = null
        }.start()
    }

    fun run(block: () -> SyncResult) {
        running = true
        Thread {
            val r = block()
            running = false
            toast(r.message)
        }.start()
    }

    val code = SyncManager.pairedCode

    Column(
        Modifier
            .fillMaxSize()
            .background(Bg)
            .verticalScroll(rememberScrollState())
            .padding(20.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("‹ 返回", fontSize = 15.sp, color = Brand, modifier = Modifier.clickable { onClose() })
            Text("☁️ 配对同步", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = Ink, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Spacer(Modifier.width(40.dp))
        }

        Spacer(Modifier.height(16.dp))

        if (code == null) {
            Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
                Column(Modifier.padding(16.dp)) {
                    Text("怎么用", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Ink)
                    Text(
                        "① 这台手机点「创建配对码」\n② 家人手机装好胎动后输入同一个码\n③ 之后所有手机联网就自动同步全部记录\n（准爸爸、长辈的手机都可以加，数量不限）",
                        fontSize = 13.sp, color = Ink2, modifier = Modifier.padding(top = 6.dp), lineHeight = 19.sp
                    )
                }
            }

            Spacer(Modifier.height(12.dp))
            Button(
                onClick = { run { SyncManager.createPairing() } },
                enabled = !running,
                modifier = Modifier.fillMaxWidth().height(50.dp),
                shape = RoundedCornerShape(50),
                colors = ButtonDefaults.buttonColors(containerColor = Brand)
            ) { Text(if (running) "正在创建…" else "创建配对码", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Bold) }

            Spacer(Modifier.height(12.dp))
            Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
                Column(Modifier.padding(16.dp)) {
                    Text("已有配对码？", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Ink)
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = joinText,
                        onValueChange = { joinText = it.filter { c -> c.isDigit() }.take(6) },
                        placeholder = { Text("输入对方的 6 位配对码", fontSize = 13.sp) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Spacer(Modifier.height(10.dp))
                    Button(
                        onClick = { run { SyncManager.joinPairing(joinText) } },
                        enabled = !running && joinText.length == 6,
                        modifier = Modifier.fillMaxWidth().height(48.dp),
                        shape = RoundedCornerShape(50),
                        colors = ButtonDefaults.buttonColors(containerColor = Brand)
                    ) { Text(if (running) "正在配对…" else "加入配对", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Bold) }
                }
            }
        } else {
            Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
                Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("配对码", fontSize = 12.sp, color = Ink2)
                    Text(
                        code.chunked(3).joinToString(" "),
                        fontSize = 34.sp, fontWeight = FontWeight.Bold, color = Brand
                    )
                    Text(
                        "把这个码告诉家人，任何一台手机装好胎动后在「设置 → 配对同步」输入即可加入，数量不限",
                        fontSize = 11.5.sp, color = Ink2, textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        lineHeight = 16.sp, modifier = Modifier.padding(top = 6.dp)
                    )
                }
            }

            Spacer(Modifier.height(12.dp))
            // 订阅权限表版本，申请/审批后列表立即刷新
            val aclVersion = SyncManager.aclVersion
            val acl = remember(aclVersion) { SyncManager.storedAclPublic() }
            PermissionCard(
                canEdit = SyncManager.canEdit,
                hasRequested = acl?.optJSONArray("req")
                    ?.let { arr -> (0 until arr.length()).any { arr.optJSONObject(it)?.optString("id") == SyncManager.deviceId() } } ?: false,
                requests = acl?.optJSONArray("req")?.let { arr ->
                    (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
                } ?: emptyList(),
                onRequest = { run { SyncManager.requestEditPermission() } },
                onCancelRequest = { run { SyncManager.cancelEditPermission() } },
                onGrant = { id -> run { SyncManager.grantWriter(id) } },
                onDeny = { id -> run { SyncManager.denyRequest(id) } },
            )

            // v5.3 设备管理：只有创建配对码的手机可见（权限表变化时随 aclVersion 刷新）
            val manageVersion = SyncManager.aclVersion
            val devices = remember(manageVersion) { SyncManager.managedDevices() }
            val masks = remember(manageVersion) {
                devices.associateWith { SyncManager.maskFor(it) }
            }
            if (SyncManager.isOwner() && devices.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                DeviceManageCard(
                    devices = devices,
                    masks = masks,
                    onSetMask = { id, k, c, s, w -> run { SyncManager.setShareMask(id, k, c, s, w) } },
                    onUnbind = { id -> run { SyncManager.forceUnbind(id) } },
                    onWipe = { id -> run { SyncManager.wipeDevice(id) } },
                )
            }

            Spacer(Modifier.height(12.dp))
            Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
                Column(Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("上次同步", fontSize = 13.sp, color = Ink2)
                            Text(lastSyncText(lastSyncAt), fontSize = 12.sp, color = Ink2)
                        }
                        if (busy || running) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Brand)
                    }
                    lastMessage?.let {
                        Text(it, fontSize = 12.sp, color = Ink2, modifier = Modifier.padding(top = 6.dp))
                    }
                    Spacer(Modifier.height(12.dp))
                    Button(
                        onClick = { run { SyncManager.syncNow(manual = true) } },
                        enabled = !busy && !running,
                        modifier = Modifier.fillMaxWidth().height(48.dp),
                        shape = RoundedCornerShape(50),
                        colors = ButtonDefaults.buttonColors(containerColor = Brand)
                    ) { Text(if (busy || running) "同步中…" else "立即同步", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Bold) }

                    TextButton(
                        onClick = { run { SyncManager.unlink() } },
                        modifier = Modifier.align(Alignment.CenterHorizontally)
                    ) { Text("解除配对", fontSize = 13.sp, color = Danger) }
                    Text(
                        "解除后：本机和云端的记录都不会消失，只是不再同步；重新输入配对码可再次加入",
                        fontSize = 10.5.sp, color = Ink2, textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        lineHeight = 14.sp
                    )
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
            Text(
                "* 一个配对码可以加到多部手机，大家看到的是同一份记录\n" +
                    "* 权限：创建配对码的手机可编辑；加入的手机默认只能查看，点「申请编辑权限」并等对方同意后才能记录\n" +
                    "* 对方申请编辑权限时，这台手机会弹通知，页面顶部也会出现「点此审批」横幅\n" +
                    "* 一台手机记了数据：约 2 秒内自动上传；其他手机开着 App 时约 6 秒内自动拉取，切回 App 会立刻同步\n" +
                    "* 同步内容：胎动、宫缩、体重记录（含轮次、间隔、备注）与共享设置\n" +
                    "* 各自新增的记录都会保留；同一处改动，后改的生效\n" +
                    "* 「撤销上一次」「清空记录」也会同步到对端\n" +
                    "* 解除配对只会停止同步：本机与云端的记录都保留\n" +
                    "* 设备管理（创建者专属）：可单独控制同步给某台手机的胎动 / 宫缩 / 设置，也可强制解绑或清空对方的数据；被解绑的设备不能用原码再加入\n" +
                    "* 端到端加密：记录在手机上用配对码加密后才上传，云端只存密文，服务器也读不到内容\n" +
                    "* 配对码就是唯一的钥匙，请只告诉家人",
                fontSize = 11.sp, color = Ink2, lineHeight = 16.sp, modifier = Modifier.padding(16.dp)
            )
        }

        toast?.let {
            Box(Modifier.fillMaxWidth().padding(top = 14.dp), contentAlignment = Alignment.Center) {
                Text(
                    it,
                    fontSize = 12.5.sp, fontWeight = FontWeight.Bold,
                    color = Color.White,
                    modifier = Modifier.background(Color.Black.copy(alpha = 0.72f), RoundedCornerShape(50))
                        .padding(horizontal = 16.dp, vertical = 8.dp)
                )
            }
        }
    }
}

private fun lastSyncText(at: Long): String {
    if (at <= 0L) return "还没同步过"
    return SimpleDateFormat("MM-dd HH:mm", Locale.CHINA).format(Date(at))
}

// ---------- 权限卡片：创建者可写；加入者默认只读，可申请编辑权限 ----------

@Composable
fun PermissionCard(
    canEdit: Boolean,
    hasRequested: Boolean,
    requests: List<JSONObject>,
    onRequest: () -> Unit,
    onCancelRequest: () -> Unit,
    onGrant: (String) -> Unit,
    onDeny: (String) -> Unit,
) {
    // 撤销申请前先确认：误触一次这台手机就变只读，而且不会有人提醒
    var showCancelConfirm by remember { mutableStateOf(false) }
    // 「忽略」别人申请前也确认：对方会立刻变只读
    var denyTarget by remember { mutableStateOf<String?>(null) }
    Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
        Column(Modifier.padding(16.dp)) {
            if (canEdit) {
                Text("本机权限：可编辑", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Ink)
                Text(
                    "这台手机可以正常记录胎动和宫缩，改动会同步给所有配对的手机",
                    fontSize = 12.sp, color = Ink2, lineHeight = 17.sp, modifier = Modifier.padding(top = 4.dp)
                )
                if (requests.isNotEmpty()) {
                    Spacer(Modifier.height(10.dp))
                    Text("编辑权限申请", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Ink)
                    requests.forEach { req ->
                        val id = req.optString("id")
                        Row(
                            Modifier.fillMaxWidth().padding(top = 8.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text("设备 $id", fontSize = 13.sp, color = Ink)
                                Text(
                                    "申请于 " + SimpleDateFormat("MM-dd HH:mm", Locale.CHINA)
                                        .format(Date(req.optLong("t", 0L))),
                                    fontSize = 11.sp, color = Ink2
                                )
                            }
                            Button(
                                onClick = { onGrant(id) },
                                shape = RoundedCornerShape(50),
                                colors = ButtonDefaults.buttonColors(containerColor = Brand),
                                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 6.dp)
                            ) { Text("同意", fontSize = 12.5.sp, color = Color.White) }
                            TextButton(onClick = { denyTarget = id }) { Text("忽略", fontSize = 12.5.sp, color = Ink2) }
                        }
                    }
                }
            } else {
                Text("查看模式", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Ink)
                Text(
                    "只能查看同步过来的记录，无法修改对方的数据。想修改请申请编辑权限，对方同意后即可记录。",
                    fontSize = 12.sp, color = Ink2, lineHeight = 17.sp, modifier = Modifier.padding(top = 4.dp)
                )
                Spacer(Modifier.height(10.dp))
                if (hasRequested) {
                    TextButton(
                        onClick = { showCancelConfirm = true },
                        modifier = Modifier.fillMaxWidth()
                    ) { Text("已申请，等待对方同意", fontSize = 12.5.sp, color = Brand) }
                    TextButton(
                        onClick = { showCancelConfirm = true },
                        modifier = Modifier.fillMaxWidth()
                    ) { Text("撤销申请", fontSize = 11.5.sp, color = Ink2) }
                } else {
                    Button(
                        onClick = onRequest,
                        modifier = Modifier.fillMaxWidth().height(46.dp),
                        shape = RoundedCornerShape(50),
                        colors = ButtonDefaults.buttonColors(containerColor = Brand)
                    ) { Text("申请编辑权限", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Color.White) }
                }
            }
        }
    }

    if (showCancelConfirm) {
        AlertDialog(
            onDismissRequest = { showCancelConfirm = false },
            title = { Text("撤销编辑权限申请？") },
            text = { Text("撤销后这台手机会变成「查看模式」：不能记录胎动/宫缩/体重，直到你在另一端重新同意。") },
            confirmButton = {
                TextButton(onClick = {
                    showCancelConfirm = false
                    onCancelRequest()
                }) { Text("撤销申请", color = Color(0xFFC0392B)) }
            },
            dismissButton = { TextButton(onClick = { showCancelConfirm = false }) { Text("取消") } }
        )
    }

    denyTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { denyTarget = null },
            title = { Text("忽略设备 $target 的申请？") },
            text = { Text("对方会保持「查看模式」，无法记录胎动；对方之后仍可再次申请。") },
            confirmButton = {
                TextButton(onClick = {
                    denyTarget = null
                    onDeny(target)
                }) { Text("忽略申请", color = Color(0xFFC0392B)) }
            },
            dismissButton = { TextButton(onClick = { denyTarget = null }) { Text("取消") } }
        )
    }
}

// ---------- 设备管理卡（创建者专属，v5.3）----------
// 对每台加入的手机：单独开关同步给它的胎动 / 宫缩 / 设置；
// 也可以强制解绑（对方保留本机数据、停止同步）或清除数据（对方清空记录并解除配对）。

@Composable
fun DeviceManageCard(
    devices: List<String>,
    masks: Map<String, JSONObject?>,
    onSetMask: (String, Boolean, Boolean, Boolean, Boolean) -> Unit,
    onUnbind: (String) -> Unit,
    onWipe: (String) -> Unit,
) {
    var confirmUnbind by remember { mutableStateOf<String?>(null) }
    var confirmWipe by remember { mutableStateOf<String?>(null) }

    Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = CardBg)) {
        Column(Modifier.padding(16.dp)) {
            Text("设备管理", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Ink)
            Text(
                "单独控制同步给每台手机的内容；也可以强制解绑，或清空对方的数据",
                fontSize = 12.sp, color = Ink2, lineHeight = 17.sp, modifier = Modifier.padding(top = 4.dp)
            )
            devices.forEach { dev ->
                val mask = masks[dev]
                val kickOn = mask?.optInt("k", 1) != 0
                val ctnOn = mask?.optInt("c", 1) != 0
                val setOn = mask?.optInt("s", 1) != 0
                val weightOn = mask?.optInt("w", 1) != 0
                Spacer(Modifier.height(12.dp))
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(1.dp)
                        .background(Ink.copy(alpha = 0.08f))
                )
                Spacer(Modifier.height(10.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("设备 $dev", fontSize = 13.sp, color = Ink, modifier = Modifier.weight(1f))
                    Text(
                        if (mask == null || (kickOn && ctnOn && setOn && weightOn)) "全部同步" else "部分同步",
                        fontSize = 11.sp, color = Ink2
                    )
                }
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    MaskChip("胎动", kickOn) { onSetMask(dev, !kickOn, ctnOn, setOn, weightOn) }
                    MaskChip("宫缩", ctnOn) { onSetMask(dev, kickOn, !ctnOn, setOn, weightOn) }
                    MaskChip("设置", setOn) { onSetMask(dev, kickOn, ctnOn, !setOn, weightOn) }
                    MaskChip("体重", weightOn) { onSetMask(dev, kickOn, ctnOn, setOn, !weightOn) }
                }
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(
                        onClick = { confirmUnbind = dev },
                        enabled = true,
                        shape = RoundedCornerShape(50),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Color.Transparent,
                            contentColor = Danger
                        ),
                        border = BorderStroke(1.dp, Danger.copy(alpha = 0.55f)),
                        modifier = Modifier.weight(1f).height(40.dp)
                    ) { Text("强制解绑", fontSize = 12.5.sp, fontWeight = FontWeight.Bold) }
                    Button(
                        onClick = { confirmWipe = dev },
                        shape = RoundedCornerShape(50),
                        colors = ButtonDefaults.buttonColors(containerColor = Danger),
                        modifier = Modifier.weight(1f).height(40.dp)
                    ) { Text("清除数据", fontSize = 12.5.sp, fontWeight = FontWeight.Bold, color = Color.White) }
                }
            }
        }
    }

    confirmUnbind?.let { dev ->
        AlertDialog(
            onDismissRequest = { confirmUnbind = null },
            title = { Text("强制解绑设备 $dev？", fontSize = 16.sp, fontWeight = FontWeight.Bold) },
            text = {
                Text(
                    "对方将立即停止同步（对方本机已同步的数据保留），且无法再用这个配对码加入。",
                    fontSize = 13.sp, lineHeight = 19.sp
                )
            },
            confirmButton = {
                TextButton(onClick = { onUnbind(dev); confirmUnbind = null }) {
                    Text("强制解绑", color = Danger, fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmUnbind = null }) { Text("取消") }
            },
        )
    }
    confirmWipe?.let { dev ->
        AlertDialog(
            onDismissRequest = { confirmWipe = null },
            title = { Text("清除设备 $dev 的数据？", fontSize = 16.sp, fontWeight = FontWeight.Bold) },
            text = {
                Text(
                    "对方手机联网后会清空全部胎动、宫缩与体重记录并自动解除配对；本机与云端的记录不受影响。",
                    fontSize = 13.sp, lineHeight = 19.sp
                )
            },
            confirmButton = {
                TextButton(onClick = { onWipe(dev); confirmWipe = null }) {
                    Text("清除对方数据", color = Danger, fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmWipe = null }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun MaskChip(label: String, on: Boolean, onClick: () -> Unit) {
    Text(
        if (on) "✓ $label" else "○ $label",
        fontSize = 12.sp,
        color = if (on) Brand else Ink2,
        modifier = Modifier
            .background(if (on) Brand.copy(alpha = 0.12f) else Color.Transparent, RoundedCornerShape(50))
            .border(1.dp, if (on) Color.Transparent else Ink.copy(alpha = 0.15f), RoundedCornerShape(50))
            .clickable { onClick() }
            .padding(horizontal = 14.dp, vertical = 7.dp)
    )
}
