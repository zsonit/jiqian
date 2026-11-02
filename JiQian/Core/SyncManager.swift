import Foundation
import SwiftData
import UIKit

// MARK: - 配对同步引擎
//
// 两台手机各自生成/输入同一个 6 位配对码，数据快照存放在云端一张按码索引的表里；
// 本地有改动 → 防抖 1.2 秒后「拉取 → 记录级合并 → 推送」，启动和手动同步走同一条链路。
// 前台每 6 秒轻量轮询 rev 版本号（只查一列），发现对方有新数据才真正同步。
//
// 合并规则见 SyncSnapshot.swift，与安卓 SyncManager.kt 逐条一致。

struct SyncOutcome {
    var ok: Bool
    var message: String
}

final class SyncManager: ObservableObject {

    static let shared = SyncManager()

    private static let rest = CloudCfg.endpoint + "/.cloud/database/rest/v1/" + CloudCfg.table
    private static let publishableKey = CloudCfg.publishableKey
    /// fetchRemote 的解密失败标记
    private static let undecryptable = "undecryptable"
    /// 云端还没有这一行的标记
    private static let empty = "empty"
    private static let defaults = UserDefaults.standard
    private static let keyCode = "jq_sync_code"
    private static let keyDevice = "jq_sync_device_id"
    private static let keyLastSync = "jq_sync_last_at"
    private static let keySalt = "jq_sync_salt"
    private static let keyRev = "jq_sync_rev"
    private static let keyClearedAt = "jq_sync_cl"
    private static let keyTombstones = "jq_sync_del"
    /// 前台自动检查间隔：对端改完后最多这么久就能看到
    private static let pollInterval: TimeInterval = 6
    /// 本机改动后的防抖：够快、又能合并连续输入
    private static let debounce: TimeInterval = 1.2

    @Published var busy = false
    @Published var lastMessage: String?
    @Published var lastSyncAt: TimeInterval

    private var deviceId: String
    private var workItem: DispatchWorkItem?
    private var pollTimer: DispatchSourceTimer?

    /// 本机有未推送的修改；没有就不推，避免两端互推蹭出无限循环
    private var localDirty = false
    /// 同步进行中又来了新改动：等这一轮结束后必须补跑一次，否则这次改动会被丢掉
    private var retryPending = false
    private let syncLock = NSLock()
    private var isSyncing = false
    private var lastRev: Int64 = 0

    private init() {
        let d = Self.defaults.string(forKey: Self.keyDevice) ?? {
            let id = UUID().uuidString.prefix(8).uppercased()
            Self.defaults.set(String(id), forKey: Self.keyDevice)
            return String(id)
        }()
        deviceId = d
        lastSyncAt = Self.defaults.double(forKey: Self.keyLastSync)
        lastRev = Self.defaults.object(forKey: Self.keyRev) as? Int64 ?? 0
        // 启动后拉一次云端（延迟几秒，避开启动高峰）
        if Self.defaults.string(forKey: Self.keyCode) != nil {
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
                _ = self?.syncNow(manual: false)
            }
        }
    }

    // MARK: 墓碑（删除记录的跨端标记）

    /// 撤销等单条删除：写墓碑，让对端也删掉同一条
    static func addTombstone(_ id: String) {
        var list = tombstones()
        guard !list.contains(where: { $0.id == id }) else { return }
        list.append(SyncSnapshot.Del(id: id, t: SnapshotIO.ms(Date())))
        // 上限保护：超出时丢掉最老的
        if list.count > 2000 {
            list.sort { $0.t < $1.t }
            list = Array(list.suffix(2000))
        }
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: keyTombstones)
        }
    }

    /// 「清空全部」：写清空时间戳，所有锚点早于它的记录在对端一并消失
    static func markCleared() {
        defaults.set(SnapshotIO.ms(Date()), forKey: keyClearedAt)
    }

    static func clearedAt() -> Int64 {
        let v = defaults.double(forKey: keyClearedAt)
        return v > 0 ? Int64(v) : 0
    }

    static func tombstones() -> [SyncSnapshot.Del] {
        guard let data = defaults.data(forKey: keyTombstones),
              let list = try? JSONDecoder().decode([SyncSnapshot.Del].self, from: data) else { return [] }
        return list
    }

    private func withLocalMarks(_ snap: inout SyncSnapshot) {
        snap.cl = Self.clearedAt()
        snap.del = Self.tombstones()
    }

    // MARK: 前台自动刷新

    /// App 回到前台：立即同步一次，然后开启自动检查
    func appDidBecomeActive() {
        guard pairedCode != nil else { return }
        startPolling()
        DispatchQueue.global().async { [weak self] in _ = self?.syncNow(manual: false) }
    }

    /// App 退到后台：停止自动检查（不耗电、不耗流量），但把还没推上去的改动抢推一次
    func appDidEnterBackground() {
        stopPolling()
        guard localDirty, pairedCode != nil else { return }
        AppLog.i("Sync", "退到后台，补推未上传的改动")
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "jiqian.sync.flush") {
            if taskId != .invalid { UIApplication.shared.endBackgroundTask(taskId) }
            taskId = .invalid
        }
        DispatchQueue.global().async { [weak self] in
            _ = self?.syncNow(manual: false)
            DispatchQueue.main.async {
                if taskId != .invalid { UIApplication.shared.endBackgroundTask(taskId) }
                taskId = .invalid
            }
        }
    }

    private func startPolling() {
        stopPolling()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.pollOnce() }
        timer.resume()
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// 轻量检查：只拉版本号，变了才真同步
    private func pollOnce() {
        guard let code = pairedCode else { return }
        // 本机有改动还没推成功（上一轮撞上忙碌被跳过了）：直接补推，别干等 rev 变化
        if localDirty {
            _ = syncNow(manual: false)
            return
        }
        let url = "\(Self.rest)?code=eq.\(code)&select=rev,updated_by&limit=1"
        guard let (resp, status) = Self.request(method: "GET", url: url, body: nil), status == 200,
              let data = resp,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let row = arr.first
        else { return }
        let remoteRev = (row["rev"] as? NSNumber)?.int64Value ?? 0
        guard remoteRev != lastRev else { return }
        if (row["updated_by"] as? String) == deviceId {
            setRev(remoteRev)
            return
        }
        AppLog.i("Sync", "检测到对方有新数据（rev=\(remoteRev)），开始自动同步")
        _ = syncNow(manual: false)
    }

    private func setRev(_ rev: Int64) {
        lastRev = rev
        Self.defaults.set(rev, forKey: Self.keyRev)
    }

    var pairedCode: String? { Self.defaults.string(forKey: Self.keyCode) }

    // MARK: 配对

    func createPairing() -> SyncOutcome {
        for _ in 0..<6 {
            let code = String(format: "%06d", Int.random(in: 100000...999999))
            if codeExists(code) == false {
                Self.defaults.set(code, forKey: Self.keyCode)
                Self.defaults.removeObject(forKey: Self.keySalt)
                let r = syncNow(manual: true)
                return r.ok ? SyncOutcome(ok: true, message: "配对码 \(code) 已就绪") : r
            }
        }
        return SyncOutcome(ok: false, message: "配对码生成失败，请检查网络后重试")
    }

    /// 查码是否已被占用；nil = 网络失败
    private func codeExists(_ code: String) -> Bool? {
        guard let (resp, status) = Self.request(
            method: "GET",
            url: "\(Self.rest)?code=eq.\(code)&select=code&limit=1",
            body: nil,
        ), status == 200, let data = resp,
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return !arr.isEmpty
    }

    func joinPairing(_ raw: String) -> SyncOutcome {
        let code = raw.trimmingCharacters(in: .whitespaces)
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            return SyncOutcome(ok: false, message: "配对码是 6 位数字")
        }
        Self.defaults.set(code, forKey: Self.keyCode)
        Self.defaults.removeObject(forKey: Self.keySalt)
        let r = syncNow(manual: true)
        return r.ok ? SyncOutcome(ok: true, message: "配对成功：\(code)") : r
    }

    /// 解除配对：只停止同步。本机记录、云端记录全部保留，只是不再互通。
    /// 多部手机共用一个配对码时（准爸爸、长辈等），任何一台退出都不影响其他人。
    func unlink() -> SyncOutcome {
        clearLocal()
        return SyncOutcome(ok: true, message: "已解除配对：本机与云端的记录都保留，只是不再同步")
    }

    private func clearLocal() {
        Self.defaults.removeObject(forKey: Self.keyCode)
        Self.defaults.removeObject(forKey: Self.keyLastSync)
        Self.defaults.removeObject(forKey: Self.keySalt)
        Self.defaults.removeObject(forKey: Self.keyRev)
        localDirty = false
        lastRev = 0
        stopPolling()
        DispatchQueue.main.async {
            self.lastSyncAt = 0
            self.lastMessage = nil
        }
    }

    // MARK: 触发（记录器在每次落库后调用）

    func onDataChanged() {
        localDirty = true
        // 正在同步：记一笔，等这一轮结束立刻补跑（否则这次改动会被丢掉）
        syncLock.lock()
        let syncing = isSyncing
        if syncing { retryPending = true }
        syncLock.unlock()
        if syncing { return }
        scheduleSync(after: Self.debounce)
    }

    /// 打一次延时的自动同步（连续改动会重置计时，合并成一次推送）
    private func scheduleSync(after seconds: TimeInterval) {
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in _ = self?.syncNow(manual: false) }
        workItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// 页面打开等场景主动拉一次（不阻塞调用线程）
    func requestSync() {
        syncLock.lock()
        if isSyncing {
            retryPending = true
            syncLock.unlock()
            return
        }
        syncLock.unlock()
        DispatchQueue.global().async { [weak self] in _ = self?.syncNow(manual: false) }
    }

    // MARK: 同步主链路

    @discardableResult
    func syncNow(manual: Bool) -> SyncOutcome {
        syncLock.lock()
        if isSyncing {
            retryPending = true
            syncLock.unlock()
            return SyncOutcome(ok: true, message: "同步进行中")
        }
        isSyncing = true
        syncLock.unlock()
        DispatchQueue.main.async { self.busy = true }

        defer {
            syncLock.lock()
            isSyncing = false
            let again = retryPending
            retryPending = false
            syncLock.unlock()
            DispatchQueue.main.async { self.busy = false }
            // 这一轮同步期间又存了新数据：立刻补跑一轮，避免改动丢失
            if again {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    _ = self?.syncNow(manual: false)
                }
            }
        }

        guard let code = pairedCode else { return SyncOutcome(ok: false, message: "尚未配对") }

        // 在后台线程用自己的 ModelContext 读写，不碰主线程上下文
        let ctx = ModelContext(JiQianStore.container)
        ctx.autosaveEnabled = false

        guard var local = try? SnapshotIO.export(from: ctx) else {
            return SyncOutcome(ok: false, message: "本机数据读取失败")
        }
        withLocalMarks(&local)

        // 本机没数据：只拉不推，避免把空数据盖掉对方
        if local.isEmpty {
            guard let snapshot = fetchRemote(code: code) else {
                return SyncOutcome(ok: false, message: manual ? "网络不可用" : "")
            }
            if snapshot.updatedBy == Self.undecryptable {
                let msg = "云端数据无法解密，请重新输入配对码"
                DispatchQueue.main.async { self.lastMessage = msg }
                AppLog.w("Sync", msg)
                return SyncOutcome(ok: false, message: msg)
            }
            if snapshot.updatedBy == Self.empty {
                // 对方也还没推过：推一次本机（空）快照占行，让对端能发现我们
                _ = upsert(code: code, snapshot: local)
                markSynced()
                return SyncOutcome(ok: true, message: manual ? "已就绪，等待对方数据" : "")
            }
            do {
                try SnapshotIO.apply(snapshot.state, to: ctx)
            } catch {
                AppLog.e("Sync", "应用对方数据失败：\(error)")
                return SyncOutcome(ok: false, message: "应用对方数据失败")
            }
            markSynced()
            DispatchQueue.main.async { self.lastMessage = "已拉取对方记录" }
            return SyncOutcome(ok: true, message: "已拉取对方记录")
        }

        let remoteSnapshot = fetchRemote(code: code)
        if let snapshot = remoteSnapshot, snapshot.updatedBy == Self.undecryptable {
            // 解密不了多半是两端密钥/配对码对不上，此时绝不能拿本机数据覆盖云端，否则另一端会被清空
            let msg = "云端数据无法解密，请重新输入配对码"
            DispatchQueue.main.async { self.lastMessage = msg }
            AppLog.w("Sync", msg)
            return SyncOutcome(ok: false, message: msg)
        }
        var merged = local
        // 云端还没有这一行（刚创建配对码）时必须推一次，否则对方永远拉不到数据
        var mustPush = localDirty || lastRev == 0 || remoteSnapshot?.updatedBy == Self.empty
        if let snapshot = remoteSnapshot {
            merged = SnapshotIO.merge(local: local, remote: snapshot.state)
            if merged != local {
                do {
                    try SnapshotIO.apply(merged, to: ctx)
                } catch {
                    AppLog.e("Sync", "应用合并结果失败：\(error)")
                    return SyncOutcome(ok: false, message: "应用合并结果失败")
                }
                mustPush = true
            }
        }

        // 本机没改、云端也没新东西：什么都不推，避免两端互相蹭出无限推送
        if !mustPush {
            DispatchQueue.main.async { self.lastMessage = "已是最新" }
            return SyncOutcome(ok: true, message: "已是最新")
        }

        guard let status = upsert(code: code, snapshot: merged) else {
            DispatchQueue.main.async {
                if manual { self.lastMessage = "推送失败：网络不可用" }
            }
            AppLog.w("Sync", "推送失败：网络不可用")
            return SyncOutcome(ok: false, message: "推送失败：网络不可用")
        }
        guard (200...299).contains(status) else {
            let msg = "推送失败：HTTP \(status)"
            DispatchQueue.main.async { if manual { self.lastMessage = msg } }
            AppLog.w("Sync", msg)
            return SyncOutcome(ok: false, message: msg)
        }
        localDirty = false
        markSynced()
        let msg = (remoteSnapshot != nil && merged != local) ? "已同步（收到对方的新记录）" : "已同步"
        DispatchQueue.main.async { self.lastMessage = msg }
        return SyncOutcome(ok: true, message: msg)
    }

    private func markSynced() {
        let now = Date().timeIntervalSince1970
        Self.defaults.set(now, forKey: Self.keyLastSync)
        DispatchQueue.main.async { self.lastSyncAt = now }
    }

    // MARK: 网络

    /// 本机配对盐；没有则生成并保存
    private func localSalt() -> String {
        if let existing = Self.defaults.string(forKey: Self.keySalt) { return existing }
        let salt = SyncCrypto.newSalt()
        Self.defaults.set(salt, forKey: Self.keySalt)
        return salt
    }

    /// 采用云端的盐（两端必须用同一个盐才能互相解密）
    private func adoptSalt(_ remoteSalt: String) {
        guard !remoteSalt.isEmpty else { return }
        if Self.defaults.string(forKey: Self.keySalt) != remoteSalt {
            Self.defaults.set(remoteSalt, forKey: Self.keySalt)
        }
    }

    private func fetchRemote(code: String) -> (state: SyncSnapshot, updatedBy: String)? {
        let url = "\(Self.rest)?code=eq.\(code)&select=payload,updated_by,rev&limit=1"
        guard let (resp, status) = Self.request(method: "GET", url: url, body: nil), status == 200,
              let data = resp,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        guard let row = arr.first, let payload = row["payload"] as? [String: Any] else {
            return (SyncSnapshot(), Self.empty)
        }
        setRev((row["rev"] as? NSNumber)?.int64Value ?? 0)

        // 端到端加密信封 —— 先采用云端盐，再用它解
        if payload["ct"] is String {
            if let salt = payload["salt"] as? String { adoptSalt(salt) }
            guard let plain = SyncCrypto.decrypt(code: code, envelope: payload),
                  let jsonData = plain.data(using: .utf8),
                  let state = try? JSONDecoder().decode(SyncSnapshot.self, from: jsonData)
            else {
                AppLog.w("Sync", "云端密文无法解密（密钥不一致），本轮跳过，不覆盖云端")
                return (SyncSnapshot(), Self.undecryptable)
            }
            return (state, row["updated_by"] as? String ?? "")
        }

        // 旧格式兼容：直接就是明文互通 JSON
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let state = try? JSONDecoder().decode(SyncSnapshot.self, from: jsonData)
        else {
            AppLog.e("Sync", "云端数据解码失败")
            return nil
        }
        AppLog.i("Sync", "检测到旧版明文数据，本次同步后自动改成密文")
        return (state, row["updated_by"] as? String ?? "")
    }

    /// 推送：payload 列存加密信封，updated_by 记录来源设备；返回 HTTP 状态码（nil=网络失败）
    private func upsert(code: String, snapshot: SyncSnapshot) -> Int? {
        guard let dataJSON = try? JSONEncoder().encode(snapshot),
              let plain = String(data: dataJSON, encoding: .utf8),
              let envelope = SyncCrypto.encrypt(code: code, plain: plain, salt: localSalt())
        else {
            AppLog.e("Sync", "本机加密失败")
            return nil
        }
        let body: [String: Any] = [
            "code": code,
            "payload": envelope,
            "updated_by": deviceId,
            "rev": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        guard let rev = body["rev"] as? Int64,
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        guard let (_, status) = Self.request(
            method: "POST",
            url: "\(Self.rest)?on_conflict=code",
            body: data,
            extraHeaders: ["Prefer": "resolution=merge-duplicates"],
        ) else { return nil }
        if (200...299).contains(status) { setRev(rev) }
        return status
    }

    private static func request(method: String, url: String, body: Data?, extraHeaders: [String: String] = [:]) -> (Data?, Int)? {
        guard let url = URL(string: url) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue(publishableKey, forHTTPHeaderField: "x-wb-webapp-access-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        var result: (Data?, Int)?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            result = (data, status)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if result?.1 == 0 || result?.1 == nil {
            AppLog.w("Sync", "网络请求失败：\(method)")
        }
        return result
    }
}
