package com.jiqian.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import com.jiqian.app.widget.Widgets

/**
 * 配对同步引擎（与 iOS SyncManager.swift 逐条一致）。
 *
 * 两台手机各自生成/输入同一个 6 位配对码，数据快照存放在云端一张按码索引的表里；
 * 本地有改动 → 防抖 1.2 秒后「拉取 → 记录级合并 → 推送」，App 启动和手动同步同一条链路。
 * 前台每 6 秒轻量轮询 rev 版本号（只查一列），发现对方有新数据才真正同步。
 *
 * 快照格式（与 iOS SyncSnapshot.swift 一致，时间一律 epoch 毫秒）：
 *  ks 胎动轮次 / ke 胎动事件 / cs 宫缩周期 / ce 宫缩事件
 *  cl 清空时间戳 / del 单条删除墓碑 [{"id":"ke@ms"|"ce@ms","t":删除时间}]
 *  st 共享设置：{edd 预产期毫秒, rm 每轮时长, win 计数窗口, risks 高风险因素,
 *     prov 机构名称, phone 联系电话, t 最后修改毫秒}；安卓不展示的也原样透传
 * 安卓没有会话概念：胎动以时间戳为锚点（id=k<ms>），宫缩以开始时间为锚点（id=c<s>）；
 * iOS 的轮次（ks/cs）原样透传保存，由 iOS 端负责字段级合并。
 */
object SyncManager {

    private const val REST = CloudCfg.DB_REST
    private const val PREFS = "jiqian_sync"
    private const val KEY_CODE = "code"
    private const val KEY_DEVICE = "device_id"
    private const val KEY_LAST_SYNC = "last_sync_at"
    private const val KEY_SALT = "salt"
    private const val KEY_REV = "last_rev"
    private const val KEY_CL = "cl"
    private const val KEY_DEL = "del"
    private const val KEY_ACL = "acl"
    /** 只读端「申请/撤销申请」、写端「同意/忽略」后的待推送标记 */
    private const val KEY_ACL_DIRTY = "acl_dirty"
    /** 已经提醒过的申请设备（同一台设备只提醒一次，重复申请才再提醒） */
    private const val KEY_ACL_NOTIFIED = "acl_notified"
    /** iOS 会话原始数组 {"ks":[...],"cs":[...]}：安卓不解析，透传保存让 iOS 端合并 */
    private const val KEY_EXTRA = "extra"
    /** 共享设置（st）：预产期 / 每轮时长 / 计数窗口 / 高风险因素 / 产科联系方式，原样透传 */
    private const val KEY_ST = "st"
    /// 前台自动检查间隔：对端改完后最多这么久就能看到
    private const val POLL_MS = 6_000L
    /// 本机改动后的防抖：够快、又能合并连续输入
    private const val DEBOUNCE_MS = 1_200L
    /// 墓碑过期时间：180 天，防止无限增长
    private const val TOMBSTONE_TTL = 180L * 86_400_000L
    private const val TOMBSTONE_CAP = 2000
    /// 撤销申请记录上限（与 iOS 一致）
    private const val RV_CAP = 200
    /// fetchRemote 的解密失败标记
    private const val UNDECRYPTABLE = "undecryptable"
    /// 云端还没有这一行的标记
    private const val EMPTY = "empty"
    /** 前台自动完整同步的兜底间隔：rev 判定万一失灵，最多这么久也必拉一次 */
    private const val FORCE_SYNC_INTERVAL = 60_000L

    private var appContext: Context? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pollHandler = Handler(Looper.getMainLooper())
    private val syncLock = Any()

    /** 本机有未推送的修改；没有就不推，避免两端互推蹭出无限循环 */
    @Volatile private var localDirty = false
    /** 同步进行中又来了新改动：等这一轮结束后必须补跑一次，否则这次改动会被丢掉 */
    @Volatile private var retryPending = false
    private var lastRev: Long = 0L
    /** 上次记「失败类」日志的时刻（节流：同类错误最多每分钟一条） */
    private var lastFailLogAt = 0L
    /** 上次前台强制完整同步的时刻：即使 rev 判定失灵也保证数据最终到位 */
    @Volatile private var lastAutoFullSyncAt = 0L

    private val pollRunnable = object : Runnable {
        override fun run() {
            Thread { pollOnce() }.start()
            pollHandler.postDelayed(this, POLL_MS)
        }
    }

    // UI 可观察状态
    var busy by mutableStateOf(false)
        private set
    var lastMessage by mutableStateOf<String?>(null)
        private set
    var lastSyncAt by mutableStateOf(0L)
        private set
    /** 本机是否可修改数据（未配对=可写；配对后在 writers 里=可写，否则只读） */
    var canEdit by mutableStateOf(true)
        private set
    /** 待我审批的编辑权限申请（设备号 + 申请时间）；本机只读时为空 */
    var pendingReqs by mutableStateOf<List<Pair<String, Long>>>(emptyList())
        private set
    /** 点通知要求打开「配对同步」页：每次自增，UI 监听变化即可 */
    var openSyncTick by mutableStateOf(0)
        private set
    /** 权限表版本号：每次落盘自增，界面据此刷新申请列表 */
    var aclVersion by mutableStateOf(0)
        private set
    /** 共享设置（预产期）版本号：同步落地后自增，设置页据此刷新 */
    var eddVersion by mutableStateOf(0)
        private set

    /** 「创建配对码」待登记：首次同步时把本机登记为 owner（可写） */
    @Volatile private var pendingOwnerAcl = false

    // MARK: 共享设置（st）
    //
    // 快照里的 st 段：{edd 预产期毫秒, rm 每轮时长, win 计数窗口,
    // risks 高风险因素(逗号分隔), prov 机构名称, phone 联系电话, t 最后修改毫秒}。
    // win/risks/prov/phone 是 iOS 的设置，安卓不展示但必须原样透传——
    // 少了这一步，安卓一推送就把这些设置抹掉了。
    // 合并取 t 大的一条；t 相同按 stKey 字典序决胜（与 iOS tieBreakKey 逐字一致）。

    /** 本机共享设置；v5.1 的旧数据存在 Store（edd/eddT），首次读取时迁移 */
    private fun sharedSt(): JSONObject? {
        prefs()?.getString(KEY_ST, null)?.let { raw ->
            return runCatching { JSONObject(raw) }.getOrNull()
        }
        val ctx = appContext ?: return null
        val edd = Store.edd(ctx)
        val eddT = Store.eddT(ctx)
        if (edd <= 0L && eddT <= 0L) return null
        return JSONObject().put("edd", edd).put("t", eddT).put("rm", Store.roundMin(ctx))
    }

    private fun saveSt(st: JSONObject?) {
        if (st == null) prefs()?.edit()?.remove(KEY_ST)?.apply()
        else prefs()?.edit()?.putString(KEY_ST, st.toString())?.apply()
    }

    /** t 相同时的决胜键（与 iOS ST.tieBreakKey 逐字一致），保证两端收敛 */
    private fun stKey(o: JSONObject): String =
        "${o.optLong("edd", 0L)}|${o.optLong("rm", 0L)}|${o.optLong("win", 0L)}|" +
            "${o.optString("risks")}|${o.optString("prov")}|${o.optString("phone")}"

    /** 预产期（当天 0 点毫秒，0 = 未设置）：设置页与摘要显示用 */
    fun eddMs(): Long = sharedSt()?.optLong("edd", 0L) ?: 0L

    /** 修改共享设置：更新 st、记修改时刻、触发同步；false = 查看模式不能改 */
    fun updateSharedSettings(edit: (JSONObject) -> Unit): Boolean {
        if (!computeCanEdit()) return false
        val st = sharedSt() ?: JSONObject()
        val prevT = st.optLong("t", 0L)
        edit(st)
        st.put("t", maxOf(System.currentTimeMillis(), prevT + 1))
        saveSt(st)
        onDataChanged()
        return true
    }

    /** 改预产期：写 st 并同步；Store 里留一份镜像给旧代码路径 */
    fun setEddShared(ms: Long) {
        if (!updateSharedSettings { it.put("edd", ms) }) return
        appContext?.let { ctx -> Store.applyEdd(ctx, ms, sharedSt()?.optLong("t", 0L) ?: 0L) }
    }

    /** 改每轮时长：写 st 并同步；Store 里留一份镜像（界面与组件读 Store） */
    fun setRoundMinShared(v: Int) {
        if (!updateSharedSettings { it.put("rm", v) }) return
        appContext?.let { Store.setRoundMin(it, v) }
    }

    val pairedCode: String?
        get() = prefs()?.getString(KEY_CODE, null)

    // MARK: 权限（acl）
    //
    // 权限表存在加密快照里随数据同步：owner = 创建配对码的设备；writers = 允许修改；
    // req = 待审批的「申请编辑权限」列表。合并规则与 iOS 一致（owner 以云端为准、
    // writers 并集、req 并集减去已授权），保证各端算出同一结果、不会互推死循环。

    private fun storedAcl(): JSONObject? {
        val s = prefs()?.getString(KEY_ACL, null) ?: return null
        return runCatching { JSONObject(s) }.getOrNull()
    }

    private fun saveAcl(acl: JSONObject?) {
        val p = prefs() ?: return
        if (acl == null) p.edit().remove(KEY_ACL).apply()
        else p.edit().putString(KEY_ACL, acl.toString()).apply()
        // 让界面能订阅到权限表变化（申请列表、可写状态）
        aclVersion += 1
    }

    private fun isAclDirty(): Boolean = prefs()?.getBoolean(KEY_ACL_DIRTY, false) ?: false

    /**
     * 权限表规范化字符串：与键序/数组顺序无关，用来判断「本机权限表和云端是否一致」。
     * JSONObject.toString() 受插入顺序影响，不能直接比较
     */
    private fun aclKey(acl: JSONObject?): String {
        if (acl == null) return ""
        val writers = mutableListOf<String>()
        acl.optJSONArray("writers")?.let { arr ->
            for (i in 0 until arr.length()) writers.add(arr.optString(i))
        }
        fun items(name: String): String {
            val out = mutableListOf<String>()
            acl.optJSONArray(name)?.let { arr ->
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    out.add(o.optString("id") + ":" + o.optLong("t", 0L))
                }
            }
            return out.sorted().joinToString(",")
        }
        return acl.optString("owner") + "|" + writers.sorted().joinToString(",") +
            "|" + items("req") + "|" + items("rv") +
            "|" + items("ub") + "|" + items("wp") + "|" + items("ra") + "|" + masksKey(acl)
    }

    /** sm 掩码的规范化字符串（与顺序无关）：id:k|c|s|t，排序后拼接 */
    private fun masksKey(acl: JSONObject?): String {
        val out = mutableListOf<String>()
        acl?.optJSONArray("sm")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                out.add(o.optString("id") + ":" + o.optInt("k", 1) + "|" + o.optInt("c", 1) +
                    "|" + o.optInt("s", 1) + "|" + o.optLong("t", 0L))
            }
        }
        return out.sorted().joinToString(",")
    }

    private fun setAclDirty(v: Boolean) {
        prefs()?.edit()?.putBoolean(KEY_ACL_DIRTY, v)?.apply()
    }

    /** 计算本机可写性：未配对=可写；没有 acl=旧版配对全员可写；有 acl 必须在 writers 里 */
    private fun computeCanEdit(): Boolean {
        if (pairedCode == null) return true
        val acl = storedAcl() ?: return true
        val me = deviceId()
        return acl.optString("owner") == me || acl.optJSONArray("writers")?.let { arr ->
            (0 until arr.length()).any { arr.optString(it) == me }
        } ?: false
    }

    /** 同步后刷新 UI 可观察的权限状态；写端发现新申请时发本地通知 */
    private fun refreshAccess(acl: JSONObject?) {
        saveAcl(acl)
        canEdit = computeCanEdit()
        val reqs = pendingFrom(acl)
        pendingReqs = reqs
        // 写端：新出现的申请提醒一次（同一台设备不重复提醒）
        val notified = (prefs()?.getString(KEY_ACL_NOTIFIED, "") ?: "")
            .split(",").filter { it.isNotEmpty() }.toSet()
        val fresh = reqs.map { it.first }.filter { it !in notified }
        if (canEdit && fresh.isNotEmpty()) {
            AppLog.i("新的编辑权限申请：${fresh.joinToString(",")}")
            appContext?.let { SyncNotifier.notifyRequests(it, fresh) }
        }
        // 只保留仍待审批的，之后重新申请还能再提醒
        prefs()?.edit()?.putString(KEY_ACL_NOTIFIED, reqs.joinToString(",") { it.first })?.apply()
    }

    /** 权限表里待审批的申请（排除本机自己），按申请时间排序 */
    private fun pendingFrom(acl: JSONObject?): List<Pair<String, Long>> {
        val out = mutableListOf<Pair<String, Long>>()
        acl?.optJSONArray("req")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val id = o.optString("id")
                if (id.isNotEmpty() && id != deviceId()) {
                    out.add(id to o.optLong("t", 0L))
                }
            }
        }
        return out.sortedBy { it.second }
    }

    /** 本机设备标识（权限列表里展示用） */
    fun deviceId(): String {        val p = prefs() ?: return "unknown"
        var id = p.getString(KEY_DEVICE, null)
        if (id == null) {
            id = UUID.randomUUID().toString().substring(0, 8).uppercase()
            p.edit().putString(KEY_DEVICE, id).apply()
        }
        return id
    }

    /** 读取本机权限表（UI 展示用） */
    fun storedAclPublic(): JSONObject? = storedAcl()

    /**
     * 撤销时刻 = 「对应申请时间 + 1ms」，两端时钟有偏差也不会让撤销失效；
     * 重新申请时同样用它保证比撤销记录更新
     */
    private fun revokeTime(acl: JSONObject?, requester: String): Long {
        var base = 0L
        acl?.optJSONArray("req")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (o.optString("id") == requester) base = maxOf(base, o.optLong("t", 0L))
            }
        }
        acl?.optJSONArray("rv")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (o.optString("id") == requester) base = maxOf(base, o.optLong("t", 0L))
            }
        }
        return maxOf(System.currentTimeMillis(), base + 1)
    }

    /** 写一条撤销记录（本机放弃申请 / 写端忽略申请），并移除待审批项 */
    private fun markRevoked(acl: JSONObject, requester: String): JSONObject {
        val t = revokeTime(acl, requester)
        val req = JSONArray()
        acl.optJSONArray("req")?.let { old ->
            for (i in 0 until old.length()) {
                val o = old.optJSONObject(i) ?: continue
                if (o.optString("id") != requester) req.put(o)
            }
        }
        val rv = JSONArray()
        acl.optJSONArray("rv")?.let { old ->
            for (i in 0 until old.length()) {
                val o = old.optJSONObject(i) ?: continue
                if (o.optString("id") != requester) rv.put(o)
            }
        }
        rv.put(JSONObject().put("id", requester).put("t", t))
        acl.put("req", req)
        acl.put("rv", rv)
        return acl
    }

    // MARK: 权限申请（只读端发起，写端审批）

    /** 只读端：申请编辑权限（把自己的设备加进待审批列表） */
    fun requestEditPermission(): SyncResult {
        if (pairedCode == null) return SyncResult(false, "尚未配对")
        if (computeCanEdit()) return SyncResult(true, "本机已可修改数据")
        val acl = storedAcl() ?: JSONObject().put("owner", "").put("writers", JSONArray()).put("req", JSONArray())
        val req = JSONArray()
        var exists = false
        acl.optJSONArray("req")?.let { old ->
            for (i in 0 until old.length()) {
                val o = old.optJSONObject(i) ?: continue
                if (o.optString("id") == deviceId()) { exists = true }
                else req.put(o)
            }
        }
        // 撤销过也要能重新申请：时间必须比那条撤销记录新
        req.put(JSONObject().put("id", deviceId()).put("t", revokeTime(acl, deviceId())))
        acl.put("req", req)
        // 本机这一条撤销记录已经不起作用了，顺手清掉
        val rv = JSONArray()
        acl.optJSONArray("rv")?.let { old ->
            for (i in 0 until old.length()) {
                val o = old.optJSONObject(i) ?: continue
                if (o.optString("id") != deviceId()) rv.put(o)
            }
        }
        acl.put("rv", rv)
        saveAcl(acl)
        setAclDirty(true)
        val r = syncNow(manual = true)
        return if (r.ok) SyncResult(true, if (exists) "已更新申请，等对方在「配对同步」里同意" else "已发出申请，等对方在「配对同步」里同意") else r
    }

    /** 只读端：撤销申请（写撤销记录，否则两端合并会把申请并回来） */
    fun cancelEditPermission(): SyncResult {
        if (pairedCode == null) return SyncResult(false, "尚未配对")
        val acl = storedAcl() ?: return SyncResult(true, "没有待审批的申请")
        var had = false
        acl.optJSONArray("req")?.let { old ->
            for (i in 0 until old.length()) {
                if (old.optJSONObject(i)?.optString("id") == deviceId()) had = true
            }
        }
        markRevoked(acl, deviceId())
        saveAcl(acl)
        setAclDirty(true)
        val r = syncNow(manual = true)
        return if (r.ok) SyncResult(true, if (had) "已撤销申请" else "没有待审批的申请") else r
    }

    /** 写端：同意某台设备的编辑权限申请 */
    fun grantWriter(id: String): SyncResult {
        if (!computeCanEdit()) return SyncResult(false, "本机没有审批权限")
        val acl = storedAcl() ?: return SyncResult(false, "没有待审批的申请")
        val writers = JSONArray()
        acl.optJSONArray("writers")?.let { old ->
            for (i in 0 until old.length()) writers.put(old.optString(i))
        }
        if (!writers.toString().contains("\"$id\"")) writers.put(id)
        acl.put("writers", writers)
        val req = JSONArray()
        acl.optJSONArray("req")?.let { old ->
            for (i in 0 until old.length()) {
                val o = old.optJSONObject(i) ?: continue
                if (o.optString("id") != id) req.put(o)
            }
        }
        acl.put("req", req)
        saveAcl(acl)
        setAclDirty(true)
        val r = syncNow(manual = true)
        return if (r.ok) SyncResult(true, "已同意，对方约 6 秒内获得修改权限") else r
    }

    /** 写端：忽略某台设备的申请（写撤销记录，对方之后仍可再次申请） */
    fun denyRequest(id: String): SyncResult {
        if (!computeCanEdit()) return SyncResult(false, "本机没有审批权限")
        val acl = storedAcl() ?: return SyncResult(false, "没有待审批的申请")
        markRevoked(acl, id)
        saveAcl(acl)
        setAclDirty(true)
        val r = syncNow(manual = true)
        return if (r.ok) SyncResult(true, "已忽略该申请") else r
    }

    fun bootstrap(context: Context) {
        if (appContext != null) return
        appContext = context.applicationContext
        lastSyncAt = prefs()?.getLong(KEY_LAST_SYNC, 0L) ?: 0L
        lastRev = prefs()?.getLong(KEY_REV, 0L) ?: 0L
        // 启动即恢复权限状态（不等首次同步），顺便提醒还没审批的申请
        refreshAccess(storedAcl())
        // 启动后拉一次云端（延迟几秒，避开启动高峰）
        if (pairedCode != null) {
            mainHandler.postDelayed({ Thread { syncNow(manual = false) }.start() }, 4000)
        }
    }

    // MARK: 前台自动刷新

    /** App 回到前台：立即同步一次，然后开启轮询 */
    fun onForeground() {
        if (pairedCode == null) return
        pollHandler.removeCallbacks(pollRunnable)
        pollHandler.postDelayed(pollRunnable, 1200)
        Thread { syncNow(manual = false) }.start()
    }

    /** App 退到后台：停止轮询（不耗电、不耗流量），但把还没推上去的改动抢推一次 */
    fun onBackground() {
        pollHandler.removeCallbacks(pollRunnable)
        if (localDirty && !busy) {
            AppLog.i("退到后台，补推未上传的改动")
            Thread { syncNow(manual = false) }.start()
        }
    }

    /** 轻量检查：只拉版本号，变了才真同步；另有 60 秒兜底强制同步 */
    private fun pollOnce() {
        if (busy) return
        val code = pairedCode ?: return
        // 本机有改动还没推成功（上一轮撞上忙碌被跳过了）：直接补推，别干等 rev 变化
        if (localDirty) {
            syncNow(manual = false)
            return
        }
        // 兜底保险丝：即使 rev 判定失灵（rev 被异常消费、接口返回异常值等），
        // 前台最多 FORCE_SYNC_INTERVAL 也必做一次完整同步，数据最终一定到位。
        // 不单独记日志（syncNow 内部已有「同步完成」行），避免把运行日志刷满
        val now = System.currentTimeMillis()
        if (lastAutoFullSyncAt == 0L || now - lastAutoFullSyncAt >= FORCE_SYNC_INTERVAL) {
            lastAutoFullSyncAt = now
            syncNow(manual = false)
            return
        }
        val pollResp = http("GET", "$REST?code=eq.$code&select=rev,updated_by&limit=1", null)
        val body = pollResp.first
        if (body == null) {
            logThrottled(if (pollResp.second == 0) "轮询失败：网络不可用"
                         else "轮询失败：HTTP ${pollResp.second}")
            return
        }
        val row = runCatching { JSONArray(body).optJSONObject(0) }.getOrNull() ?: return
        val remoteRev = row.optLong("rev", 0L)
        val by = row.optString("updated_by")
        if (remoteRev == lastRev) return
        if (by == deviceId()) {
            // 自己推的那次没记上版本号，补上即可
            setRev(remoteRev)
            return
        }
        AppLog.i("检测到对方有新数据（rev=$remoteRev），开始自动同步")
        syncNow(manual = false)
    }

    private fun setRev(rev: Long) {
        lastRev = rev
        prefs()?.edit()?.putLong(KEY_REV, rev)?.apply()
    }

    /** 失败日志节流：断网等重复错误最多每分钟记一条，避免刷屏 */
    private fun logThrottled(msg: String) {
        val now = System.currentTimeMillis()
        if (now - lastFailLogAt < 60_000L) return
        lastFailLogAt = now
        AppLog.w(msg)
    }

    /** 这轮合并从对方新收到多少条（按类别，用于日志） */
    private fun diffSummary(local: JSONObject, merged: JSONObject): String {
        fun added(o: JSONArray?, n: JSONArray?): Int {
            val old = HashSet<String>()
            for (i in 0 until (o?.length() ?: 0)) old.add(o!!.optJSONObject(i)?.optString("id") ?: "")
            var count = 0
            for (i in 0 until (n?.length() ?: 0)) {
                if ((n!!.optJSONObject(i)?.optString("id") ?: "") !in old) count++
            }
            return count
        }
        val parts = ArrayList<String>()
        val k = added(local.optJSONArray("ke"), merged.optJSONArray("ke")) +
                added(local.optJSONArray("ks"), merged.optJSONArray("ks"))
        if (k > 0) parts.add("胎动${k}条")
        val c = added(local.optJSONArray("ce"), merged.optJSONArray("ce")) +
                added(local.optJSONArray("cs"), merged.optJSONArray("cs"))
        if (c > 0) parts.add("宫缩${c}条")
        val w = added(local.optJSONArray("we"), merged.optJSONArray("we"))
        if (w > 0) parts.add("体重${w}条")
        return if (parts.isEmpty()) "无新记录" else "新收到 " + parts.joinToString("、")
    }

    /**
     * 「有效数据」投影：把快照压缩成本机 Store 能完整表达的字段集合，输出稳定的规范字符串。
     * 用于「合并结果 vs 本机快照」的比较 —— 直接 toString 比较会因字段顺序、
     * iOS 独有字段（ke.note/sid、ce.gap/sus、we.note 等）永远不相等，导致每轮假应用假推送。
     */
    private fun significant(snap: JSONObject): String {
        val out = JSONObject()
        out.put("cl", snap.optLong("cl", 0L))
        fun sorted(name: String, key: (JSONObject) -> Long): List<JSONObject> =
            snap.optJSONArray(name)?.let { a ->
                (0 until a.length()).mapNotNull { a.optJSONObject(it) }.sortedBy(key)
            } ?: emptyList()
        val ke = JSONArray()
        sorted("ke") { it.optLong("at", 0L) }.forEach {
            ke.put(JSONObject().put("at", it.optLong("at", 0L)))
        }
        out.put("ke", ke)
        val ce = JSONArray()
        sorted("ce") { it.optLong("s", 0L) }.forEach {
            ce.put(JSONObject().put("s", it.optLong("s", 0L)).put("e", it.optLong("e", 0L)))
        }
        out.put("ce", ce)
        // 轮次透传（iOS 数据，安卓只转发）：内容原样、顺序稳定即可
        out.put("ks", snap.optJSONArray("ks")?.toString() ?: "[]")
        out.put("cs", snap.optJSONArray("cs")?.toString() ?: "[]")
        val we = JSONArray()
        sorted("we") { it.optLong("at", 0L) }.forEach {
            we.put(JSONObject()
                .put("id", it.optString("id"))
                .put("at", it.optLong("at", 0L))
                .put("kg", it.optDouble("kg", 0.0)))
        }
        out.put("we", we)
        val del = JSONArray()
        sorted("del") { it.optLong("t", 0L) }.forEach {
            del.put(JSONObject().put("id", it.optString("id")).put("t", it.optLong("t", 0L)))
        }
        out.put("del", del)
        out.put("st", snap.optJSONObject("st")?.toString() ?: "")
        out.put("acl", aclKey(snap.optJSONObject("acl")))
        return out.toString()
    }

    private fun prefs() = appContext?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // MARK: 本机标记（清空时间戳 / 删除墓碑）

    private fun cl(): Long = prefs()?.getLong(KEY_CL, 0L) ?: 0L

    private fun markCleared() {
        if (!computeCanEdit()) return
        prefs()?.edit()?.putLong(KEY_CL, System.currentTimeMillis())?.apply()
    }

    /** 撤销等单条删除：写墓碑，让对端也删掉同一条（id 约定见 SyncTombstone 注释）。供 Store 调用。只读端不允许 */
    fun addTombstone(id: String) {
        if (!computeCanEdit()) return
        val p = prefs() ?: return
        val arr = JSONArray(p.getString(KEY_DEL, "[]"))
        for (i in 0 until arr.length()) {
            if (arr.optJSONObject(i)?.optString("id") == id) return
        }
        arr.put(JSONObject().put("id", id).put("t", System.currentTimeMillis()))
        p.edit().putString(KEY_DEL, pruneTombstones(arr).toString()).apply()
    }

    private fun tombstones(): JSONArray = JSONArray(prefs()?.getString(KEY_DEL, "[]") ?: "[]")

    /** 过期修剪 + 数量上限（与 iOS 一致：180 天、2000 条） */
    private fun pruneTombstones(arr: JSONArray): JSONArray {
        val cutoff = System.currentTimeMillis() - TOMBSTONE_TTL
        val kept = mutableListOf<Pair<String, Long>>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val t = o.optLong("t", 0L)
            if (t >= cutoff) kept.add(o.optString("id") to t)
        }
        kept.sortBy { it.second }
        val out = JSONArray()
        kept.takeLast(TOMBSTONE_CAP).forEach { (id, t) ->
            out.put(JSONObject().put("id", id).put("t", t))
        }
        return out
    }

    private fun extra(): JSONObject = JSONObject(prefs()?.getString(KEY_EXTRA, "{}") ?: "{}")

    private fun saveExtra(obj: JSONObject) {
        prefs()?.edit()?.putString(KEY_EXTRA, obj.toString())?.apply()
    }

    // MARK: 配对操作（在调用方线程执行网络；UI 层用 Thread 包裹）

    /** 创建配对码：随机 6 位数字，云端已占用则换号重试；创建后立即推送本机快照 */
    fun createPairing(): SyncResult {
        repeat(6) {
            val code = (100000..999999).random().toString()
            val exists = codeExists(code)
            if (exists == false) {
                // 先清干净上一个配对留下的所有状态（权限表、版本号、脏标记）：
                // 否则旧配对的解绑/撤销记录会被合并进新码的权限表，把对方甚至本机踢成只读
                unlink()
                prefs()?.edit()?.putString(KEY_CODE, code)?.remove(KEY_SALT)?.apply()
                pollHandler.postDelayed(pollRunnable, 1200)
                // 本机是创建者：立即登记为 owner（可写），加入的设备默认只读。
                // 先落本地再同步，即使首次推送失败，owner 身份也不会丢
                saveAcl(JSONObject()
                    .put("owner", deviceId())
                    .put("writers", JSONArray().put(deviceId()))
                    .put("req", JSONArray()))
                pendingOwnerAcl = true
                val r = syncNow(manual = true)
                pendingOwnerAcl = false
                return if (r.ok) SyncResult(true, "配对码 $code 已就绪") else r
            }
        }
        return SyncResult(false, "配对码生成失败，请检查网络后重试")
    }

    /** 加入对方的配对码：存码后立即拉取合并 */
    fun joinPairing(code: String): SyncResult {
        val c = code.trim()
        if (!Regex("\\d{6}").matches(c)) return SyncResult(false, "配对码是 6 位数字")
        // 先清干净上一个配对留下的所有状态：旧码的权限表（含解绑记录）绝不能带进新码，
        // 否则合并规则会把旧解绑记录写进新码，把刚创建配对的那台手机踢成只读
        unlink()
        prefs()?.edit()?.putString(KEY_CODE, c)?.remove(KEY_SALT)?.apply()
        pollHandler.postDelayed(pollRunnable, 1200)
        val r = syncNow(manual = true)
        return if (r.ok) SyncResult(true, "配对成功：$c") else r
    }

    // MARK: 设备管理（owner 专属，v5.3）
    //
    // A 端（创建配对码的手机）可以管理每台加入的 B 设备：
    //   * 单独控制同步给它的数据类别（胎动 / 宫缩 / 共享设置）
    //   * 强制解绑：对方自动解除配对（保留其本机数据），且不能用原码再加入
    //   * 清除数据：对方联网后清空本机全部记录并解除配对
    // 全部通过 acl 里的 ub / wp / sm 字段随加密快照同步，与 iOS 合并规则一致。

    /** 本机是否为配对码创建者（只有它有管理权） */
    fun isOwner(): Boolean {
        if (pairedCode == null) return false
        val acl = storedAcl() ?: return false
        return acl.optString("owner") == deviceId()
    }

    /** 管理卡里要显示的设备（除本机与 owner 外的全部可写设备） */
    fun managedDevices(): List<String> {
        val acl = storedAcl() ?: return emptyList()
        if (acl.optString("owner") != deviceId()) return emptyList()
        val me = deviceId()
        val owner = acl.optString("owner")
        val out = mutableListOf<String>()
        acl.optJSONArray("writers")?.let { arr ->
            for (i in 0 until arr.length()) {
                val id = arr.optString(i)
                if (id.isNotEmpty() && id != me && id != owner) out.add(id)
            }
        }
        return out.sorted()
    }

    /** 被解绑且尚未获准重新加入的设备（owner 端展示「允许重新加入」入口） */
    fun unboundDevices(): List<String> {
        val acl = storedAcl() ?: return emptyList()
        if (acl.optString("owner") != deviceId()) return emptyList()
        val me = deviceId()
        val ids = mutableSetOf<String>()
        acl.optJSONArray("ub")?.let { arr ->
            for (i in 0 until arr.length()) {
                val id = arr.optJSONObject(i)?.optString("id") ?: continue
                if (id.isNotEmpty() && id != me) ids.add(id)
            }
        }
        return ids.filter { isUnbound(acl, it) }.sorted()
    }

    /** 某台设备当前的数据同步掩码（没有条目 = 全部同步） */
    fun maskFor(deviceId: String): JSONObject? = maskIn(storedAcl(), deviceId)

    /** 从权限表里取某台设备的掩码（同设备取 t 更大的一条） */
    private fun maskIn(acl: JSONObject?, id: String): JSONObject? {
        var best: JSONObject? = null
        acl?.optJSONArray("sm")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (o.optString("id") != id) continue
                if (best == null || o.optLong("t", 0L) > best!!.optLong("t", 0L)) best = o
            }
        }
        return best
    }

    /** 改完 acl 后统一走「落盘 → 标记待推送 → 立即同步」 */
    private fun pushAclChange(message: String): SyncResult {
        setAclDirty(true)
        val r = syncNow(manual = true)
        return if (r.ok) SyncResult(true, message) else r
    }

    /** acl 里的 [id,t] 列表是否包含某设备 */
    private fun aclHas(acl: JSONObject?, name: String, id: String): Boolean =
        acl?.optJSONArray(name)?.let { arr ->
            (0 until arr.length()).any { arr.optJSONObject(it)?.optString("id") == id }
        } ?: false

    /** 记录的最新时刻（没有该设备的记录 = 0） */
    private fun aclLatestT(acl: JSONObject?, name: String, id: String): Long =
        acl?.optJSONArray(name)?.let { arr ->
            var t = 0L
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (o.optString("id") == id) t = maxOf(t, o.optLong("t", 0L))
            }
            t
        } ?: 0L

    /** 设备是否处于「已被解绑且未获准重新加入」状态：解绑记录比准入记录晚 = 仍被解绑（v5.11） */
    private fun isUnbound(acl: JSONObject?, id: String): Boolean {
        val ubT = aclLatestT(acl, "ub", id)
        return ubT > 0 && ubT > aclLatestT(acl, "ra", id)
    }

    /** 强制解绑一台设备：移出 writers、写解绑记录（只增不减） */
    fun forceUnbind(id: String): SyncResult {
        if (!isOwner()) return SyncResult(false, "只有创建配对码的手机可以管理设备")
        if (id == deviceId()) return SyncResult(false, "不能解绑本机")
        val acl = storedAcl() ?: JSONObject()
            .put("owner", deviceId()).put("writers", JSONArray().put(deviceId())).put("req", JSONArray())
        val me = deviceId()
        val ub = JSONArray()
        var t = System.currentTimeMillis()
        acl.optJSONArray("ub")?.let { old ->
            for (i in 0 until old.length()) {
                val o = old.optJSONObject(i) ?: continue
                if (o.optString("id") == id) t = maxOf(t, o.optLong("t", 0L) + 1)
                else ub.put(o)
            }
        }
        ub.put(JSONObject().put("id", id).put("t", t))
        acl.put("ub", ub)
        val writers = JSONArray()
        acl.optJSONArray("writers")?.let { old ->
            for (i in 0 until old.length()) if (old.optString(i) != id && old.optString(i) != me) writers.put(old.optString(i))
        }
        if (!writers.toString().contains("\"$me\"")) writers.put(me)
        acl.put("writers", writers)
        val req = JSONArray()
        acl.optJSONArray("req")?.let { old ->
            for (i in 0 until old.length()) {
                val o = old.optJSONObject(i) ?: continue
                if (o.optString("id") != id) req.put(o)
            }
        }
        acl.put("req", req)
        saveAcl(acl)
        return pushAclChange("已强制解绑：对方约 6 秒内停止同步，本机记录保留")
    }

    /** owner 撤销对某设备的解绑：写「重新准入」记录（比解绑记录晚就生效）。
     *  对方重新输入原配对码即可加入（默认仍为只读，需再批一次编辑权限）。 */
    fun allowRejoin(id: String): SyncResult {
        if (!isOwner()) return SyncResult(false, "只有创建配对码的手机可以管理设备")
        if (id == deviceId()) return SyncResult(false, "本机无需重新加入")
        val acl = storedAcl() ?: return SyncResult(false, "尚未配对")
        val t = maxOf(System.currentTimeMillis(),
            aclLatestT(acl, "ra", id) + 1, aclLatestT(acl, "ub", id) + 1)
        val ra = JSONArray()
        acl.optJSONArray("ra")?.let { old ->
            for (i in 0 until old.length()) {
                val o = old.optJSONObject(i) ?: continue
                if (o.optString("id") != id) ra.put(o)
            }
        }
        ra.put(JSONObject().put("id", id).put("t", t))
        acl.put("ra", ra)
        saveAcl(acl)
        return pushAclChange("已允许重新加入：请对方重新输入原配对码")
    }

    /** 清除一台设备的数据：移出 writers、写清除命令 + 解绑记录 */
    fun wipeDevice(id: String): SyncResult {
        if (!isOwner()) return SyncResult(false, "只有创建配对码的手机可以管理设备")
        if (id == deviceId()) return SyncResult(false, "不能清除本机数据")
        val acl = storedAcl() ?: JSONObject()
            .put("owner", deviceId()).put("writers", JSONArray().put(deviceId())).put("req", JSONArray())
        val me = deviceId()
        val now = System.currentTimeMillis()
        val ub = JSONArray()
        var tUB = now
        acl.optJSONArray("ub")?.let { old ->
            for (i in 0 until old.length()) {
                val o = old.optJSONObject(i) ?: continue
                if (o.optString("id") == id) tUB = maxOf(tUB, o.optLong("t", 0L) + 1)
                else ub.put(o)
            }
        }
        ub.put(JSONObject().put("id", id).put("t", tUB))
        acl.put("ub", ub)
        val wp = JSONArray()
        var tWP = now
        acl.optJSONArray("wp")?.let { old ->
            for (i in 0 until old.length()) {
                val o = old.optJSONObject(i) ?: continue
                if (o.optString("id") == id) tWP = maxOf(tWP, o.optLong("t", 0L) + 1)
                else wp.put(o)
            }
        }
        wp.put(JSONObject().put("id", id).put("t", tWP))
        acl.put("wp", wp)
        val writers = JSONArray()
        acl.optJSONArray("writers")?.let { old ->
            for (i in 0 until old.length()) if (old.optString(i) != id && old.optString(i) != me) writers.put(old.optString(i))
        }
        if (!writers.toString().contains("\"$me\"")) writers.put(me)
        acl.put("writers", writers)
        val req = JSONArray()
        acl.optJSONArray("req")?.let { old ->
            for (i in 0 until old.length()) {
                val o = old.optJSONObject(i) ?: continue
                if (o.optString("id") != id) req.put(o)
            }
        }
        acl.put("req", req)
        saveAcl(acl)
        return pushAclChange("已下发清除：对方联网后本机记录将被清空并解除配对")
    }

    /** 更新某台设备的数据同步掩码（胎动 / 宫缩 / 设置 / 体重，LWW 合并） */
    fun setShareMask(id: String, kick: Boolean, contraction: Boolean,
                     settings: Boolean, weight: Boolean): SyncResult {
        if (!isOwner()) return SyncResult(false, "只有创建配对码的手机可以管理设备")
        if (id == deviceId()) return SyncResult(false, "本机不受同步范围限制")
        val acl = storedAcl() ?: JSONObject()
            .put("owner", deviceId()).put("writers", JSONArray().put(deviceId())).put("req", JSONArray())
        val sm = JSONArray()
        var t = System.currentTimeMillis()
        acl.optJSONArray("sm")?.let { old ->
            for (i in 0 until old.length()) {
                val o = old.optJSONObject(i) ?: continue
                if (o.optString("id") == id) t = maxOf(t, o.optLong("t", 0L) + 1)
                else sm.put(o)
            }
        }
        sm.put(JSONObject()
            .put("id", id)
            .put("k", if (kick) 1 else 0)
            .put("c", if (contraction) 1 else 0)
            .put("s", if (settings) 1 else 0)
            .put("w", if (weight) 1 else 0)
            .put("t", t))
        acl.put("sm", sm)
        saveAcl(acl)
        return pushAclChange("已更新同步范围：对方约 6 秒内生效")
    }

    // MARK: B 端：处理 owner 下发的管理动作

    /** 清空本机全部记录（不写墓碑、不触发上传——马上就要解除配对了，
     *  云端与其他设备的记录不受影响） */
    private fun wipeAllLocalData() {
        val ctx = appContext ?: return
        Store.replaceAll(ctx, emptyList(), emptyList())
        Store.setRunningContractionStart(ctx, 0L)
        Store.replaceWeights(ctx, emptyList())
        saveExtra(JSONObject())
        prefs()?.edit()?.putLong(KEY_CL, 0L)?.putString(KEY_DEL, "[]")?.apply()
        // 桌面组件就地刷新，别留着已清空的旧数字
        Widgets.refresh(ctx)
        AppLog.i("管理员清除：本机全部记录已删除")
    }

    /** 检查云端权限表里有没有指向本机的管理动作（清除数据 / 强制解绑）。
     *  返回 null = 没有动作，继续正常同步；有动作则已就地处理（清库 / 解绑 + 通知），
     *  调用方直接返回、绝不推送 —— 防止把本机（可能已清空的）数据盖回云端。 */
    private fun handleAdminAction(state: JSONObject): SyncResult? {
        val acl = state.optJSONObject("acl") ?: return null
        val me = deviceId()
        // 清除数据（隐含解绑）：清空本机记录 + 解除配对
        if (aclHas(acl, "wp", me)) {
            wipeAllLocalData()
            appContext?.let {
                SyncNotifier.notifyAdminAction(it, "管理员已清除本机数据", "记录已全部清空，配对已解除")
            }
            unlink()
            return SyncResult(false, "管理员已清除本机数据，配对已解除")
        }
        // 强制解绑：保留本机记录，解除配对（被解绑后原配对码也不能再加入，
        // 除非创建者在设备管理里点了「允许重新加入」）
        if (isUnbound(acl, me)) {
            appContext?.let {
                SyncNotifier.notifyAdminAction(it, "已被管理员解绑", "同步已停止，本机记录保留；如需重新配对，请创建者在「设备管理」里允许本机重新加入")
            }
            unlink()
            return SyncResult(false, "已被管理员解绑：请创建者在设备管理里允许重新加入后再配对")
        }
        return null
    }

    /**
     * 解除配对：只停止同步。本机记录、云端记录全部保留，只是不再互通。
     * 多部手机共用一个配对码时（准爸爸、长辈等），任何一台退出都不影响其他人。
     * 清空时间戳与删除墓碑保留：重新配对后，本机删过的记录不会被对端推回来。
     */
    fun unlink(): SyncResult {
        prefs()?.edit()
            ?.remove(KEY_CODE)?.remove(KEY_SALT)
            ?.remove(KEY_REV)?.remove(KEY_LAST_SYNC)
            ?.remove(KEY_ACL)?.remove(KEY_ACL_DIRTY)?.remove(KEY_ACL_NOTIFIED)
            ?.apply()
        pendingOwnerAcl = false
        lastSyncAt = 0
        lastMessage = null
        canEdit = true
        pendingReqs = emptyList()
        localDirty = false
        lastRev = 0L
        pollHandler.removeCallbacks(pollRunnable)
        return SyncResult(true, "已解除配对：本机与云端的记录都保留，只是不再同步")
    }

    // MARK: 触发（Store 每次落库后调用）

    fun onDataChanged() {
        // 只读端：本机改动一律不上传（记录入口也已被拦截，这里是兜底）
        if (!computeCanEdit()) return
        localDirty = true
        // 正在同步：记一笔，等这一轮结束立刻补跑（否则这次改动会被丢掉）
        if (busy) {
            retryPending = true
            return
        }
        scheduleSync(DEBOUNCE_MS)
    }

    /** 打一次延时的自动同步（连续改动会重置计时，合并成一次推送） */
    private fun scheduleSync(delayMs: Long) {
        mainHandler.removeCallbacksAndMessages(null)
        mainHandler.postDelayed({ Thread { syncNow(manual = false) }.start() }, delayMs)
    }

    /** 页面打开等场景主动拉一次（不阻塞调用线程） */
    fun requestSync() {
        if (busy) {
            retryPending = true
            return
        }
        Thread { syncNow(manual = false) }.start()
    }

    /** 点了「有设备申请编辑权限」的通知：让界面跳到配对同步页 */
    fun requestOpenSync() {
        openSyncTick += 1
    }

    // MARK: 快照构建（Store ↔ 互通 JSON）

    /** 胎动墓碑 id：以发生时间毫秒为锚点，跨平台互认 */
    private fun tombKick(atMs: Long) = "ke@$atMs"

    /** 宫缩墓碑 id：以开始时间毫秒为锚点 */
    private fun tombCtn(startMs: Long) = "ce@$startMs"

    private fun localSnapshot(): JSONObject {
        val snap = JSONObject()
        val ctx = appContext
        snap.put("v", 1)
        val ke = JSONArray()
        val ce = JSONArray()
        if (ctx != null) {
            Store.kicks(ctx).sorted().forEach { ms ->
                ke.put(JSONObject()
                    .put("id", "k$ms")
                    .put("sid", "")
                    .put("at", ms)
                    .put("src", "app"))
            }
            Store.contractions(ctx).sortedBy { it.first }.forEach { (s, e) ->
                val o = JSONObject()
                    .put("id", "c$s")
                    .put("sid", "")
                    .put("s", s)
                    .put("src", "app")
                if (e > 0) o.put("e", e)
                o.put("gap", 0.0).put("sus", false)
                ce.put(o)
            }
        }
        snap.put("ke", ke)
        snap.put("ce", ce)
        // 体重（v5.4）：id + 称重时间 + 公斤
        val we = JSONArray()
        if (ctx != null) {
            Store.weights(ctx).sortedBy { it.at }.forEach { w ->
                we.put(JSONObject()
                    .put("id", w.id)
                    .put("at", w.at)
                    .put("kg", w.kg)
                    .put("src", "app"))
            }
        }
        snap.put("we", we)
        val ex = extra()
        snap.put("ks", ex.optJSONArray("ks") ?: JSONArray())
        snap.put("cs", ex.optJSONArray("cs") ?: JSONArray())
        snap.put("cl", cl())
        // 墓碑规范化成与 merge() 输出一致的形状（去过期、按时间排序、限量）：
        // 不然「本机快照 vs 合并结果」永远不相等，每轮假应用 + 假推送
        snap.put("del", pruneTombstones(tombstones()))
        // 权限表随快照加密同步（创建者首次同步时由 pendingOwnerAcl 登记）
        storedAcl()?.let { snap.put("acl", it) }
        if (pendingOwnerAcl && storedAcl() == null) {
            snap.put("acl", JSONObject()
                .put("owner", deviceId())
                .put("writers", JSONArray().put(deviceId()))
                .put("req", JSONArray()))
        }
        // 共享设置（预产期 / 每轮时长 / 计数窗口 / 高风险因素 / 产科联系方式）
        sharedSt()?.let { snap.put("st", it) }
        return snap
    }

    /** 全新安装（本机从头到尾没有任何数据）：只拉不推，避免空快照盖掉对方 */
    private fun snapshotEmpty(snap: JSONObject): Boolean =
        (snap.optJSONArray("ke")?.length() ?: 0) == 0 &&
            (snap.optJSONArray("ce")?.length() ?: 0) == 0 &&
            (snap.optJSONArray("ks")?.length() ?: 0) == 0 &&
            (snap.optJSONArray("cs")?.length() ?: 0) == 0 &&
            (snap.optJSONArray("we")?.length() ?: 0) == 0 &&
            snap.optLong("cl", 0L) == 0L &&
            (snap.optJSONArray("del")?.length() ?: 0) == 0

    /**
     * 合并（纯函数，两端算出的结果一致）：
     * * cl 取两端较大值；锚点早于 cl 的记录在所有设备上丢弃；
     * * 墓碑取并集（180 天过期、2000 条上限）；
     * * 胎动按时间锚点并集、宫缩按开始时间并集，双方独有的都保留；
     *   宫缩结束时间取较晚的非空值，iOS 事件备注非空优先；
     * * iOS 轮次（ks/cs）：远端非空则整体采用，否则保留本机透传副本。
     */
    private fun mergeSnapshots(local: JSONObject, remote: JSONObject): JSONObject {
        val out = JSONObject()
        out.put("v", 1)

        val cl = maxOf(local.optLong("cl", 0L), remote.optLong("cl", 0L))
        val delMap = LinkedHashMap<String, Long>()
        local.optJSONArray("del")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                delMap[o.optString("id")] = o.optLong("t", 0L)
            }
        }
        remote.optJSONArray("del")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (!delMap.containsKey(o.optString("id"))) delMap[o.optString("id")] = o.optLong("t", 0L)
            }
        }
        val cutoff = System.currentTimeMillis() - TOMBSTONE_TTL
        val kept = delMap.entries.filter { it.value >= cutoff }.sortedBy { it.value }.takeLast(TOMBSTONE_CAP)
        val delArr = JSONArray()
        kept.forEach { delArr.put(JSONObject().put("id", it.key).put("t", it.value)) }
        out.put("cl", cl)
        out.put("del", delArr)
        val delIds = kept.map { it.key }.toSet()

        // 胎动事件：按锚点（at）并集；iOS 端备注非空优先
        val keMap = sortedMapOf<Long, JSONObject>()
        local.optJSONArray("ke")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                keMap[o.optLong("at", 0L)] = o
            }
        }
        remote.optJSONArray("ke")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val at = o.optLong("at", 0L)
                val ex = keMap[at]
                if (ex == null) keMap[at] = o
                else if (ex.optString("note").isEmpty() && o.optString("note").isNotEmpty()) {
                    ex.put("note", o.optString("note"))
                }
            }
        }
        val keOut = JSONArray()
        keMap.entries.filter { it.key >= cl && tombKick(it.key) !in delIds }.forEach { keOut.put(it.value) }
        out.put("ke", keOut)

        // 宫缩事件：按开始时间并集；结束时间取较晚的非空值
        val ceMap = sortedMapOf<Long, JSONObject>()
        local.optJSONArray("ce")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                ceMap[o.optLong("s", 0L)] = o
            }
        }
        remote.optJSONArray("ce")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val s = o.optLong("s", 0L)
                val ex = ceMap[s]
                if (ex == null) ceMap[s] = o
                else {
                    val le = ex.optLong("e", 0L)
                    val re = o.optLong("e", 0L)
                    if (re > le && re > 0) ex.put("e", re)
                }
            }
        }
        val ceOut = JSONArray()
        ceMap.entries.filter { it.key >= cl && tombCtn(it.key) !in delIds }.forEach { ceOut.put(it.value) }
        out.put("ce", ceOut)

        // iOS 轮次透传：远端非空整体采用
        val rks = remote.optJSONArray("ks")
        out.put("ks", if (rks != null && rks.length() > 0) rks else (local.optJSONArray("ks") ?: JSONArray()))
        val rcs = remote.optJSONArray("cs")
        out.put("cs", if (rcs != null && rcs.length() > 0) rcs else (local.optJSONArray("cs") ?: JSONArray()))

        // 体重（v5.4）：按 id 并集，锚点早于 cl 的丢弃、被墓碑标记的丢弃。
        // 同一条冲突时以 at 较早的整条取胜（记录不可改，只为两端收敛），与 iOS mergeWE 一致。
        // 两端都是旧版（没有 we 字段）时不写这个字段，避免把对方的体重当成「空」。
        if (local.has("we") || remote.has("we")) {
            val weMap = linkedMapOf<String, JSONObject>()
            local.optJSONArray("we")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    weMap[o.optString("id")] = o
                }
            }
            remote.optJSONArray("we")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val id = o.optString("id")
                    val cur = weMap[id]
                    if (cur == null) weMap[id] = o
                    else if (o.optLong("at", 0L) < cur.optLong("at", 0L)) weMap[id] = o
                }
            }
            val weOut = JSONArray()
            weMap.values
                .filter { it.optLong("at", 0L) >= cl && "we@${it.optLong("at", 0L)}" !in delIds }
                .sortedBy { it.optLong("at", 0L) }
                .forEach { weOut.put(it) }
            out.put("we", weOut)
        }

        // 共享设置（预产期）：取最后一次修改（t 大者胜，t 相同比 edd），
        // 规则与 iOS SnapshotIO.mergeST 一致
        val ls = local.optJSONObject("st")
        val rs = remote.optJSONObject("st")
        var st: JSONObject? = ls ?: rs
        if (ls != null && rs != null) {
            val lt = ls.optLong("t", 0L)
            val rt = rs.optLong("t", 0L)
            st = when {
                lt != rt -> if (lt > rt) ls else rs
                else -> if (stKey(ls) >= stKey(rs)) ls else rs
            }
        }
        st?.let { out.put("st", it) }

        // 权限表合并（与 iOS SyncACLResolver 一致）：owner 以云端为准、writers 并集、申请并集减去已授权
        val la = local.optJSONObject("acl")
        val ra = remote.optJSONObject("acl")
        if (la == null && ra == null && !pendingOwnerAcl) {
            // 旧版配对：无权限表，全员可写
        } else {
            val owner = ra?.optString("owner").takeUnless { it.isNullOrEmpty() }
                ?: la?.optString("owner").takeUnless { it.isNullOrEmpty() }
                ?: if (pendingOwnerAcl) deviceId() else ""
            val writers = linkedSetOf<String>()
            la?.optJSONArray("writers")?.let { arr -> for (i in 0 until arr.length()) writers.add(arr.optString(i)) }
            ra?.optJSONArray("writers")?.let { arr -> for (i in 0 until arr.length()) writers.add(arr.optString(i)) }
            if (owner.isNotEmpty()) writers.add(owner)
            val reqMap = linkedMapOf<String, Long>()
            (la?.optJSONArray("req") ?: JSONArray()).let { arr ->
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val id = o.optString("id")
                    reqMap[id] = maxOf(reqMap[id] ?: 0L, o.optLong("t", 0L))
                }
            }
            (ra?.optJSONArray("req") ?: JSONArray()).let { arr ->
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val id = o.optString("id")
                    reqMap[id] = maxOf(reqMap[id] ?: 0L, o.optLong("t", 0L))
                }
            }
            // 撤销并集：撤销（本机放弃 / 被忽略）过就压住更早的申请。
            // 少了这一步，「撤销申请」会被并集原样并回来 —— 点了等于没点
            val rvMap = linkedMapOf<String, Long>()
            (la?.optJSONArray("rv") ?: JSONArray()).let { arr ->
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val id = o.optString("id")
                    rvMap[id] = maxOf(rvMap[id] ?: 0L, o.optLong("t", 0L))
                }
            }
            (ra?.optJSONArray("rv") ?: JSONArray()).let { arr ->
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val id = o.optString("id")
                    rvMap[id] = maxOf(rvMap[id] ?: 0L, o.optLong("t", 0L))
                }
            }
            val rvCutoff = System.currentTimeMillis() - TOMBSTONE_TTL
            val rvKept = rvMap.entries.filter { it.value >= rvCutoff }.sortedBy { it.value }.takeLast(RV_CAP)
            val rv = JSONArray()
            rvKept.forEach { rv.put(JSONObject().put("id", it.key).put("t", it.value)) }
            val req = JSONArray()
            reqMap.entries
                .filter { it.key !in writers && (rvMap[it.key] ?: 0L) < it.value }
                .sortedBy { it.value }
                .forEach { (id, t) -> req.put(JSONObject().put("id", id).put("t", t)) }

            // v5.3 设备管理：ub 强制解绑 / wp 清除命令（[id,t] 并集取最大 t，只增不减，
            // 180 天过期、200 条上限，与撤销记录同规则）；sm 掩码（每台一条，LWW t 大者胜）。
            // 被解绑的设备从 writers 并集里剔除，防止其他端的旧权限表把它并回来。
            fun mergeReqList(name: String): JSONArray {
                val map = linkedMapOf<String, Long>()
                listOf(la, ra).forEach { a ->
                    a?.optJSONArray(name)?.let { arr ->
                        for (i in 0 until arr.length()) {
                            val o = arr.optJSONObject(i) ?: continue
                            val id = o.optString("id")
                            map[id] = maxOf(map[id] ?: 0L, o.optLong("t", 0L))
                        }
                    }
                }
                val cutoff = System.currentTimeMillis() - TOMBSTONE_TTL
                val outArr = JSONArray()
                map.entries.filter { it.value >= cutoff }.sortedBy { it.value }
                    .takeLast(RV_CAP)
                    .forEach { (id, t) -> outArr.put(JSONObject().put("id", id).put("t", t)) }
                return outArr
            }
            val ub = mergeReqList("ub")
            val wp = mergeReqList("wp")
            // v5.11 重新准入：准入记录比解绑记录晚 = 已获准重新加入，不再从 writers 里剔除
            // 注意：形参 ra 是远端 ACL 本体，这里必须用别的名字，否则会遮蔽它
            val raArr = mergeReqList("ra")
            val raMap = linkedMapOf<String, Long>()
            for (i in 0 until raArr.length()) {
                val o = raArr.optJSONObject(i) ?: continue
                raMap[o.optString("id")] = o.optLong("t", 0L)
            }
            val stillUnbound = mutableSetOf<String>()
            for (i in 0 until ub.length()) {
                val o = ub.optJSONObject(i) ?: continue
                val id = o.optString("id")
                if (o.optLong("t", 0L) > (raMap[id] ?: 0L)) stillUnbound.add(id)
            }
            val finalWriters = JSONArray()
            writers.filter { it !in stillUnbound }.sorted().forEach { finalWriters.put(it) }
            val smMap = linkedMapOf<String, JSONObject>()
            listOf(la, ra).forEach { a ->
                a?.optJSONArray("sm")?.let { arr ->
                    for (i in 0 until arr.length()) {
                        val o = arr.optJSONObject(i) ?: continue
                        val id = o.optString("id")
                        val cur = smMap[id]
                        if (cur == null) smMap[id] = o
                        else if (o.optLong("t", 0L) > cur.optLong("t", 0L)) smMap[id] = o
                    }
                }
            }
            val sm = JSONArray()
            smMap.entries.sortedBy { it.key }.forEach { sm.put(it.value) }

            out.put("acl", JSONObject()
                .put("owner", owner)
                .put("writers", finalWriters)
                .put("req", req)
                .put("rv", rv)
                .put("ub", ub)
                .put("wp", wp)
                .put("sm", sm)
                .put("ra", raArr))
        }
        return out
    }

    /** 把快照写回本机（Store + 标记），由后台同步线程调用；Store 写入不触发 onDataChanged。
     *  v5.3：本机不是 owner 且 acl.sm 里有本机掩码时，按掩码过滤要落地的数据类别 ——
     *  owner 关掉「胎动」后，本机胎动不再落地、已有的会被清空。过滤只影响写入本机的
     *  副本，绝不动原快照（推送内容不受影响）。 */
    private fun applySnapshot(snap0: JSONObject) {
        val ctx = appContext ?: return
        var keArr = snap0.optJSONArray("ke")
        var ceArr = snap0.optJSONArray("ce")
        var ksArr = snap0.optJSONArray("ks")
        var csArr = snap0.optJSONArray("cs")
        var weArr = snap0.optJSONArray("we")
        var hasWe = snap0.has("we")
        var stObj = snap0.optJSONObject("st")
        val aclForMask = snap0.optJSONObject("acl")
        if (aclForMask != null && aclForMask.optString("owner") != deviceId()) {
            maskIn(aclForMask, deviceId())?.let { mask ->
                if (mask.optInt("k", 1) == 0) { keArr = JSONArray(); ksArr = JSONArray() }
                if (mask.optInt("c", 1) == 0) { ceArr = JSONArray(); csArr = JSONArray() }
                if (mask.optInt("w", 1) == 0) { weArr = JSONArray(); hasWe = true }
                if (mask.optInt("s", 1) == 0) stObj = null
            }
        }
        val kicks = mutableListOf<Long>()
        keArr?.let { arr ->
            for (i in 0 until arr.length()) {
                arr.optJSONObject(i)?.let { kicks.add(it.optLong("at", 0L)) }
            }
        }
        val ctns = mutableListOf<Pair<Long, Long>>()
        ceArr?.let { arr ->
            for (i in 0 until arr.length()) {
                arr.optJSONObject(i)?.let { o ->
                    ctns.add(o.optLong("s", 0L) to o.optLong("e", 0L))
                }
            }
        }
        Store.replaceAll(ctx, kicks.sorted(), ctns.sortedBy { it.first })
        // 体重：整体替换（id 保留，跨端删除靠墓碑）。
        // 旧版快照里没有 we 字段时跳过，绝不把本机体重清空。
        if (hasWe) {
            val wList = mutableListOf<WeightItem>()
            weArr?.let { arr ->
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val at = o.optLong("at", 0L)
                    if (at <= 0L) continue
                    val id = o.optString("id").ifEmpty { "w$at" }
                    wList.add(WeightItem(id, at, o.optDouble("kg", 0.0)))
                }
            }
            Store.replaceWeights(ctx, wList)
        }
        val ex = JSONObject()
        ksArr?.let { if (it.length() > 0) ex.put("ks", it) }
        csArr?.let { if (it.length() > 0) ex.put("cs", it) }
        saveExtra(ex)
        prefs()?.edit()
            ?.putLong(KEY_CL, snap0.optLong("cl", 0L))
            ?.putString(KEY_DEL, pruneTombstones(snap0.optJSONArray("del") ?: JSONArray()).toString())
            ?.apply()
        // 权限表随快照落地，并刷新可写状态（被授权/被批准时立即生效）
        snap0.optJSONObject("acl")?.let { refreshAccess(it) }
        // 共享设置：整段原样保存（win/risks/prov/phone 安卓不展示也要透传），
        // 已知字段（预产期、每轮时长）落到各自偏好；比本机旧的不覆盖，
        // 避免刚改好又被对方旧值弹回去
        stObj?.let { st ->
            val t = st.optLong("t", 0L)
            val curT = sharedSt()?.optLong("t", 0L) ?: 0L
            if (t >= curT) {
                var changed = false
                if (st.toString() != sharedSt()?.toString()) {
                    saveSt(st)
                    changed = true
                }
                val edd = st.optLong("edd", 0L)
                if (edd != Store.edd(ctx) || t != Store.eddT(ctx)) {
                    Store.applyEdd(ctx, edd, t)
                    changed = true
                }
                st.optLong("rm", 0L).takeIf { it > 0L }?.let { rm ->
                    if (Store.roundMin(ctx) != rm.toInt()) {
                        Store.setRoundMin(ctx, rm.toInt())
                        changed = true
                    }
                }
                if (changed) eddVersion++
            }
        }
    }

    // MARK: 同步主链路

    fun syncNow(manual: Boolean): SyncResult = synchronized(syncLock) {
        val context = appContext
        val code = pairedCode
        if (context == null || code == null) return SyncResult(false, "尚未配对")
        // 本次同步开始时的权限表：同步期间用户可能又点了申请/审批，收尾时要保住那次改动
        val aclAtStart = prefs()?.getString(KEY_ACL, null)
        val local = localSnapshot()
        val hasAclToPush = pendingOwnerAcl || local.optJSONObject("acl") != null
        if (snapshotEmpty(local) && !hasAclToPush) {
            // 本机没数据：只拉不推，避免把空数据盖掉对方
            val remote = fetchRemote(code)
                ?: return if (manual) SyncResult(false, "网络不可用") else SyncResult(false, "")
            if (remote.updatedBy == UNDECRYPTABLE) {
                val msg = "云端数据无法解密，请重新输入配对码"
                lastMessage = msg
                return SyncResult(false, msg)
            }
            if (remote.updatedBy == EMPTY) {
                // 对方也还没推过：推一次本机（空）快照占行，让对端能发现我们
                val resp = upsert(code, local)
                if (resp.ok) {
                    markSynced()
                    AppLog.i("云端还没有数据，已推送本机占位")
                    return SyncResult(true, if (manual) "已就绪，等待对方数据" else "已就绪")
                }
                return SyncResult(false, resp.message)
            }
            // owner 下发的管理动作（清除 / 解绑）优先于一切数据同步
            handleAdminAction(remote.state)?.let { return it }
            applySnapshot(remote.state)
            // 数据真正落地了才记「已看过」这一版（apply 失败会在上面抛异常提前返回，
            // rev 不被消费，下一轮轮询会重拉这版数据）
            setRev(remote.rev)
            refreshAccess(remote.state.optJSONObject("acl"))
            markSynced()
            AppLog.i("已拉取对方数据：${diffSummary(local, remote.state)}")
            lastMessage = "已拉取对方记录"
            return SyncResult(true, "已拉取对方记录")
        }
        busy = true
        try {
            val remote = fetchRemote(code) // null=网络失败；空 payload=对方还没推过
            if (remote != null && remote.updatedBy == UNDECRYPTABLE) {
                // 解密不了多半是两端密钥/配对码对不上，此时绝不能拿本机数据覆盖云端，否则另一端会被清空
                val msg = "云端数据无法解密，请重新输入配对码"
                lastMessage = msg
                logThrottled(msg)
                return SyncResult(false, msg)
            }
            val localCanEdit = computeCanEdit()
            // owner 下发的管理动作（清除 / 解绑）优先于一切数据同步：
            // 命中就就地处理并返回，绝不推送（防止把本机数据盖回云端）
            if (remote != null) handleAdminAction(remote.state)?.let { return it }
            var merged = local
            // 这一轮真的从对方落到新数据了（只读端也能拉到，所以单独立标记）
            var appliedFromRemote = false
            // 云端还没有这一行（刚创建配对码）时必须推一次，否则对方永远拉不到数据
            var mustPush = localDirty || lastRev == 0L || remote?.updatedBy == EMPTY
            if (remote != null) {
                merged = mergeSnapshots(local, remote.state)
                // 申请 / 撤销申请 / 审批本身要推一次：只要本机权限表和云端不一致就推。
                // 不能只比较「合并结果 vs 本机旧值」，撤销时合并结果可能正好等于本机旧值，
                // 那样这一轮就不会推送，对方永远看不到撤销
                if (isAclDirty() &&
                    aclKey(merged.optJSONObject("acl")) != aclKey(remote.state.optJSONObject("acl"))) {
                    mustPush = true
                }
                // 用「有效投影」比较，而不是整对象 toString：
                // iOS 快照里 ke/ce/we 带 note、sid、gap 等安卓 Store 存不下的字段，
                // 本机每次重建快照都会丢掉它们 —— 直接比较会永远不相等，
                // 表现就是每轮假报「已应用对方数据」+ 假推送（rev 被凭空顶高，对端跟着空转）
                if (significant(merged) != significant(local)) {
                    applySnapshot(merged)
                    appliedFromRemote = true
                    AppLog.i("已应用对方数据：${diffSummary(local, merged)}")
                    mustPush = true
                }
            }
            // rev 只在真正拿到数据之后才记「已看过」（v5.7 只防住了「解密失败」这一种，
            // 这里补上「apply 失败」：上面 apply 抛错会进 catch 提前返回，rev 不被消费，
            // 下一轮轮询会重拉这一版，数据不会静默丢失）
            remote?.let { setRev(it.rev) }
            // 只读端：本机记录改动一律不推；只有「申请/撤销申请」或首次加入占行时才推，
            // 且推送内容里记录部分原样用云端版本（只更新 acl），保证只读端改不了云端数据
            if (!localCanEdit) {
                val aclNeedsPush = isAclDirty() &&
                    aclKey(merged.optJSONObject("acl")) != aclKey(remote?.state?.optJSONObject("acl"))
                mustPush = lastRev == 0L || remote?.updatedBy == EMPTY || aclNeedsPush
            }
            if (!mustPush) {
                // 本机没改、云端也没新东西：什么都不推，避免两端互相蹭出无限推送
                // 同步途中若本机权限表被改过（点了申请/审批），以本机为准，别被合并结果盖掉
                refreshAccess(
                    if (prefs()?.getString(KEY_ACL, null) == aclAtStart) merged.optJSONObject("acl")
                    else storedAcl()
                )
                // 拉取成功（哪怕没有新记录）也算同步过一次：只读端从不推送，
                // 不在这里更新「上次同步」的话，页面会永远停在很久以前的旧时间
                markSynced()
                lastMessage = if (appliedFromRemote) "已收到对方新数据" else "已是最新"
                AppLog.i("同步完成：$lastMessage（rev=$lastRev，${if (computeCanEdit()) "可写" else "只读"}）")
                return SyncResult(true, lastMessage!!)
            }
            var pushSnapshot = merged
            if (!localCanEdit && remote != null && remote.updatedBy != EMPTY) {
                pushSnapshot = remote.state
                merged.optJSONObject("acl")?.let { pushSnapshot.put("acl", it) }
            }
            val resp = upsert(code, pushSnapshot)
            if (!resp.ok) {
                lastMessage = if (manual) "推送失败：${resp.message}" else null
                AppLog.w("推送失败：${resp.message}")
                return SyncResult(false, "推送失败：${resp.message}")
            }
            localDirty = false
            if (prefs()?.getString(KEY_ACL, null) == aclAtStart) {
                // 权限表在同步期间没被动过：用合并结果落地，并清掉待推送标记
                setAclDirty(false)
                refreshAccess(merged.optJSONObject("acl"))
            } else {
                // 同步途中又点了「申请 / 撤销 / 同意」：保留本机这次改动，立刻补推一轮
                setAclDirty(true)
                refreshAccess(storedAcl())
                retryPending = true
            }
            markSynced()
            val mergedNew = remote != null && significant(merged) != significant(local)
            lastMessage = if (mergedNew) "已同步（收到对方的新记录）" else "已同步"
            AppLog.i("同步完成：$lastMessage（${diffSummary(local, merged)}，rev=$lastRev）")
            return SyncResult(true, lastMessage ?: "已同步")
        } catch (e: Exception) {
            AppLog.e("同步异常：$e")
            lastMessage = if (manual) "同步失败：${e.message}" else null
            return SyncResult(false, "同步失败：${e.message}")
        } finally {
            busy = false
            // 这一轮同步期间又存了新数据：立刻补跑一轮，避免改动丢失
            if (retryPending) {
                retryPending = false
                scheduleSync(600)
            }
        }
    }

    private fun markSynced() {
        val ts = System.currentTimeMillis()
        lastSyncAt = ts
        prefs()?.edit()?.putLong(KEY_LAST_SYNC, ts)?.apply()
    }

    // MARK: 网络与快照

    private class RemoteSnapshot(val state: JSONObject, val updatedBy: String, val rev: Long = 0L)

    /** 查码是否已被占用；null = 网络失败 */
    private fun codeExists(code: String): Boolean? {
        val (body, status) = http("GET", "$REST?code=eq.$code&select=code&limit=1", null)
        if (status !in 200..299 || body == null) return null
        return JSONArray(body).length() > 0
    }

    /** 本机配对盐；没有则生成并保存 */
    private fun localSalt(): String {
        val p = prefs()
        val existing = p?.getString(KEY_SALT, null)
        if (existing != null) return existing
        val salt = SyncCrypto.newSalt()
        p?.edit()?.putString(KEY_SALT, salt)?.apply()
        return salt
    }

    /** 采用云端的盐（对方先创建配对时，两端必须用同一个盐才能互相解密） */
    private fun adoptSalt(remoteSalt: String) {
        val p = prefs() ?: return
        if (p.getString(KEY_SALT, null) != remoteSalt) {
            p.edit()?.putString(KEY_SALT, remoteSalt)?.apply()
        }
    }

    private fun fetchRemote(code: String): RemoteSnapshot? {
        val (body, _) = http("GET", "$REST?code=eq.$code&select=payload,updated_by,rev&limit=1", null)
        if (body == null) return null
        val arr = JSONArray(body)
        if (arr.length() == 0) return RemoteSnapshot(JSONObject(), EMPTY)
        val row = arr.optJSONObject(0) ?: return null
        // 注意：这里只带回 rev，不记「已看过」。是否消费由调用方决定 ——
        // 数据真正落地（apply 成功）之后才 setRev，apply 失败就留给下一轮重拉
        val remoteRev = row.optLong("rev", 0L)
        val payload = row.optJSONObject("payload")
            ?: return RemoteSnapshot(JSONObject(), EMPTY, remoteRev)

        // 端到端加密信封 —— 先采用云端盐，再用它解
        if (payload.has("ct")) {
            payload.optString("salt").takeIf { it.isNotEmpty() }?.let { adoptSalt(it) }
            val plain = SyncCrypto.decrypt(code, payload)
            if (plain == null) {
                // 解不开：配对码/盐对不上。返回标记让调用方跳过本轮，绝不能用本机数据覆盖云端
                logThrottled("云端密文无法解密（密钥不一致），本轮跳过，不覆盖云端")
                return RemoteSnapshot(JSONObject(), UNDECRYPTABLE)
            }
            return RemoteSnapshot(JSONObject(plain), row.optString("updated_by"), remoteRev)
        }

        // 旧格式兼容：直接就是明文互通 JSON
        AppLog.i("检测到旧版明文数据，本次同步后自动改成密文")
        return RemoteSnapshot(payload, row.optString("updated_by"), remoteRev)
    }

    /** 推送：payload 列存加密信封，updated_by 记录来源设备，rev 供对端轻度轮询发现变化 */
    private fun upsert(code: String, snapshot: JSONObject): SyncResult {
        val envelope = SyncCrypto.encrypt(code, snapshot.toString(), localSalt())
            ?: return SyncResult(false, "本机加密失败")
        val rev = System.currentTimeMillis()
        val body = JSONObject()
            .put("code", code)
            .put("payload", envelope)
            .put("updated_by", deviceId())
            .put("rev", rev)
            .toString()
        val (errBody, status) = http(
            "POST",
            "$REST?on_conflict=code",
            body,
            extraHeaders = mapOf("Prefer" to "resolution=merge-duplicates"),
        ) ?: return SyncResult(false, "网络不可用")
        if (status in 200..299) {
            setRev(rev)
            return SyncResult(true, "OK")
        }
        val detail = errBody?.let {
            runCatching { JSONObject(it).optString("message") }.getOrNull()
        }
        return SyncResult(false, "HTTP $status${detail?.let { "：${it.take(80)}" } ?: ""}")
    }

    /** 返回 (响应体, HTTP 状态码)；网络异常返回 (null, 0) */
    private fun http(
        method: String,
        url: String,
        body: String?,
        extraHeaders: Map<String, String> = emptyMap(),
    ): Pair<String?, Int> {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = 15000
                readTimeout = 20000
                setRequestProperty("x-wb-webapp-access-key", CloudCfg.PUBLISHABLE_KEY)
                setRequestProperty("Content-Type", "application/json")
                extraHeaders.forEach { (k, v) -> setRequestProperty(k, v) }
                if (body != null) doOutput = true
            }
            body?.let { text -> conn.outputStream.use { it.write(text.toByteArray(Charsets.UTF_8)) } }
            val status = conn.responseCode
            val stream = if (status in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) }
            text to status
        } catch (e: Exception) {
            AppLog.w("网络请求失败：$method $e")
            null to 0
        } finally {
            conn?.disconnect()
        }
    }
}

data class SyncResult(val ok: Boolean, val message: String)
