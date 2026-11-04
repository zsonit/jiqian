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

    private var appContext: Context? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pollHandler = Handler(Looper.getMainLooper())
    private val syncLock = Any()

    /** 本机有未推送的修改；没有就不推，避免两端互推蹭出无限循环 */
    @Volatile private var localDirty = false
    /** 同步进行中又来了新改动：等这一轮结束后必须补跑一次，否则这次改动会被丢掉 */
    @Volatile private var retryPending = false
    private var lastRev: Long = 0L

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
            "|" + items("req") + "|" + items("rv")
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

    /** 轻量检查：只拉版本号，变了才真同步 */
    private fun pollOnce() {
        if (busy) return
        val code = pairedCode ?: return
        // 本机有改动还没推成功（上一轮撞上忙碌被跳过了）：直接补推，别干等 rev 变化
        if (localDirty) {
            syncNow(manual = false)
            return
        }
        val (body, _) = http("GET", "$REST?code=eq.$code&select=rev,updated_by&limit=1", null)
        if (body == null) return
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
                prefs()?.edit()?.putString(KEY_CODE, code)?.remove(KEY_SALT)?.apply()
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
        prefs()?.edit()?.putString(KEY_CODE, c)?.remove(KEY_SALT)?.apply()
        val r = syncNow(manual = true)
        return if (r.ok) SyncResult(true, "配对成功：$c") else r
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
        val ex = extra()
        snap.put("ks", ex.optJSONArray("ks") ?: JSONArray())
        snap.put("cs", ex.optJSONArray("cs") ?: JSONArray())
        snap.put("cl", cl())
        snap.put("del", tombstones())
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
            out.put("acl", JSONObject()
                .put("owner", owner)
                .put("writers", JSONArray().apply { writers.sorted().forEach { put(it) } })
                .put("req", req)
                .put("rv", rv))
        }
        return out
    }

    /** 把快照写回本机（Store + 标记），由后台同步线程调用；Store 写入不触发 onDataChanged */
    private fun applySnapshot(snap: JSONObject) {
        val ctx = appContext ?: return
        val kicks = mutableListOf<Long>()
        snap.optJSONArray("ke")?.let { arr ->
            for (i in 0 until arr.length()) {
                arr.optJSONObject(i)?.let { kicks.add(it.optLong("at", 0L)) }
            }
        }
        val ctns = mutableListOf<Pair<Long, Long>>()
        snap.optJSONArray("ce")?.let { arr ->
            for (i in 0 until arr.length()) {
                arr.optJSONObject(i)?.let { o ->
                    ctns.add(o.optLong("s", 0L) to o.optLong("e", 0L))
                }
            }
        }
        Store.replaceAll(ctx, kicks.sorted(), ctns.sortedBy { it.first })
        val ex = JSONObject()
        snap.optJSONArray("ks")?.let { if (it.length() > 0) ex.put("ks", it) }
        snap.optJSONArray("cs")?.let { if (it.length() > 0) ex.put("cs", it) }
        saveExtra(ex)
        prefs()?.edit()
            ?.putLong(KEY_CL, snap.optLong("cl", 0L))
            ?.putString(KEY_DEL, pruneTombstones(snap.optJSONArray("del") ?: JSONArray()).toString())
            ?.apply()
        // 权限表随快照落地，并刷新可写状态（被授权/被批准时立即生效）
        snap.optJSONObject("acl")?.let { refreshAccess(it) }
        // 共享设置：整段原样保存（win/risks/prov/phone 安卓不展示也要透传），
        // 已知字段（预产期、每轮时长）落到各自偏好；比本机旧的不覆盖，
        // 避免刚改好又被对方旧值弹回去
        snap.optJSONObject("st")?.let { st ->
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
                    return SyncResult(true, if (manual) "已就绪，等待对方数据" else "已就绪")
                }
                return SyncResult(false, resp.message)
            }
            applySnapshot(remote.state)
            refreshAccess(remote.state.optJSONObject("acl"))
            markSynced()
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
                AppLog.w(msg)
                return SyncResult(false, msg)
            }
            val localCanEdit = computeCanEdit()
            var merged = local
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
                if (merged.toString() != local.toString()) {
                    applySnapshot(merged)
                    mustPush = true
                }
            }
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
                lastMessage = "已是最新"
                return SyncResult(true, "已是最新")
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
            val mergedNew = remote != null && merged.toString() != local.toString()
            lastMessage = if (mergedNew) "已同步（收到对方的新记录）" else "已同步"
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

    private class RemoteSnapshot(val state: JSONObject, val updatedBy: String)

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
        setRev(row.optLong("rev", 0L))
        val payload = row.optJSONObject("payload") ?: return RemoteSnapshot(JSONObject(), EMPTY)

        // 端到端加密信封 —— 先采用云端盐，再用它解
        if (payload.has("ct")) {
            payload.optString("salt").takeIf { it.isNotEmpty() }?.let { adoptSalt(it) }
            val plain = SyncCrypto.decrypt(code, payload)
            if (plain == null) {
                // 解不开：配对码/盐对不上。返回标记让调用方跳过本轮，绝不能用本机数据覆盖云端
                AppLog.w("云端密文无法解密（密钥不一致），本轮跳过，不覆盖云端")
                return RemoteSnapshot(JSONObject(), UNDECRYPTABLE)
            }
            return RemoteSnapshot(JSONObject(plain), row.optString("updated_by"))
        }

        // 旧格式兼容：直接就是明文互通 JSON
        AppLog.i("检测到旧版明文数据，本次同步后自动改成密文")
        return RemoteSnapshot(payload, row.optString("updated_by"))
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
