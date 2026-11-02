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
    /** iOS 会话原始数组 {"ks":[...],"cs":[...]}：安卓不解析，透传保存让 iOS 端合并 */
    private const val KEY_EXTRA = "extra"
    /// 前台自动检查间隔：对端改完后最多这么久就能看到
    private const val POLL_MS = 6_000L
    /// 本机改动后的防抖：够快、又能合并连续输入
    private const val DEBOUNCE_MS = 1_200L
    /// 墓碑过期时间：180 天，防止无限增长
    private const val TOMBSTONE_TTL = 180L * 86_400_000L
    private const val TOMBSTONE_CAP = 2000
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

    val pairedCode: String?
        get() = prefs()?.getString(KEY_CODE, null)

    fun bootstrap(context: Context) {
        if (appContext != null) return
        appContext = context.applicationContext
        lastSyncAt = prefs()?.getLong(KEY_LAST_SYNC, 0L) ?: 0L
        lastRev = prefs()?.getLong(KEY_REV, 0L) ?: 0L
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

    private fun deviceId(): String {
        val p = prefs() ?: return "unknown"
        var id = p.getString(KEY_DEVICE, null)
        if (id == null) {
            id = UUID.randomUUID().toString().substring(0, 8).uppercase()
            p.edit().putString(KEY_DEVICE, id).apply()
        }
        return id
    }

    // MARK: 本机标记（清空时间戳 / 删除墓碑）

    private fun cl(): Long = prefs()?.getLong(KEY_CL, 0L) ?: 0L

    private fun markCleared() {
        prefs()?.edit()?.putLong(KEY_CL, System.currentTimeMillis())?.apply()
    }

    /** 撤销等单条删除：写墓碑，让对端也删掉同一条（id 约定见 SyncTombstone 注释）。供 Store 调用 */
    fun addTombstone(id: String) {
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
                val r = syncNow(manual = true)
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
            ?.apply()
        lastSyncAt = 0
        lastMessage = null
        localDirty = false
        lastRev = 0L
        pollHandler.removeCallbacks(pollRunnable)
        return SyncResult(true, "已解除配对：本机与云端的记录都保留，只是不再同步")
    }

    // MARK: 触发（Store 每次落库后调用）

    fun onDataChanged() {
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
    }

    // MARK: 同步主链路

    fun syncNow(manual: Boolean): SyncResult = synchronized(syncLock) {
        val context = appContext
        val code = pairedCode
        if (context == null || code == null) return SyncResult(false, "尚未配对")
        val local = localSnapshot()
        if (snapshotEmpty(local)) {
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
            var merged = local
            // 云端还没有这一行（刚创建配对码）时必须推一次，否则对方永远拉不到数据
            var mustPush = localDirty || lastRev == 0L || remote?.updatedBy == EMPTY
            if (remote != null) {
                merged = mergeSnapshots(local, remote.state)
                if (merged.toString() != local.toString()) {
                    applySnapshot(merged)
                    mustPush = true
                }
            }
            if (!mustPush) {
                // 本机没改、云端也没新东西：什么都不推，避免两端互相蹭出无限推送
                lastMessage = "已是最新"
                return SyncResult(true, "已是最新")
            }
            val resp = upsert(code, merged)
            if (!resp.ok) {
                lastMessage = if (manual) "推送失败：${resp.message}" else null
                AppLog.w("推送失败：${resp.message}")
                return SyncResult(false, "推送失败：${resp.message}")
            }
            localDirty = false
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
