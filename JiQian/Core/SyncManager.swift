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
    private static let keyACL = "jq_sync_acl"
    /// 只读端「申请/撤销申请」、写端「同意/忽略」后的待推送标记
    private static let keyACLDirty = "jq_sync_acl_dirty"
    /// 已经提醒过的申请设备（同一台设备只提醒一次，重复申请才再提醒一次）
    private static let keyNotifiedReqs = "jq_sync_acl_notified"
    /// 前台自动检查间隔：对端改完后最多这么久就能看到
    private static let pollInterval: TimeInterval = 6
    /// 本机改动后的防抖：够快、又能合并连续输入
    private static let debounce: TimeInterval = 1.2

    @Published var busy = false
    @Published var lastMessage: String?
    @Published var lastSyncAt: TimeInterval
    /// 本机是否可修改数据（未配对=可写；配对后在 writers 里=可写，否则只读）
    @Published var canEdit = true
    /// 最新一次同步得到的权限表（SyncView 展示角色与申请列表用）
    @Published var acl: SyncSnapshot.ACL?

    private var deviceId: String
    private var workItem: DispatchWorkItem?
    private var pollTimer: DispatchSourceTimer?
    /// 「创建配对码」待登记：首次同步时把本机登记为 owner（可写）
    private var pendingOwnerAcl = false

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
        // 启动即恢复权限状态（不等首次同步）
        acl = storedACL()
        canEdit = computeCanEdit()
        // 通知代理要在最早的时机装上，否则点通知打不开对应页面
        SyncNotifier.shared.prepare()
        if Self.defaults.string(forKey: Self.keyCode) != nil {
            SyncNotifier.shared.requestAuthorization()
            // 启动后拉一次云端（延迟几秒，避开启动高峰）
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
                _ = self?.syncNow(manual: false)
            }
        }
    }

    // MARK: 墓碑（删除记录的跨端标记）

    /// 撤销等单条删除：写墓碑，让对端也删掉同一条（只读端不允许）
    static func addTombstone(_ id: String) {
        guard shared.computeCanEdit() else { return }
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

    /// 「清空全部」：写清空时间戳，所有锚点早于它的记录在对端一并消失（只读端不允许）
    static func markCleared() {
        guard shared.computeCanEdit() else { return }
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

    /// 本机设备标识（权限列表里展示用）
    var deviceID: String { deviceId }

    // MARK: 权限（acl）

    private func storedACL() -> SyncSnapshot.ACL? {
        guard let data = Self.defaults.data(forKey: Self.keyACL) else { return nil }
        return try? JSONDecoder().decode(SyncSnapshot.ACL.self, from: data)
    }

    private func saveACL(_ acl: SyncSnapshot.ACL?) {
        if let acl, let data = try? JSONEncoder().encode(acl) {
            Self.defaults.set(data, forKey: Self.keyACL)
        } else {
            Self.defaults.removeObject(forKey: Self.keyACL)
        }
    }

    private func isAclDirty() -> Bool { Self.defaults.bool(forKey: Self.keyACLDirty) }

    /// 计算本机可写性（不依赖 UI 线程）：
    /// 未配对 = 可写；配对了但没有 acl = 旧版本配对，全员可写；有 acl 则必须在 writers 里。
    private func computeCanEdit() -> Bool {
        guard pairedCode != nil else { return true }
        guard let acl = storedACL() else { return true }
        return acl.owner == deviceId || acl.writers.contains(deviceId)
    }

    /// 同步后刷新 UI 可观察的权限状态
    private func refreshAccess(_ newACL: SyncSnapshot.ACL?) {
        saveACL(newACL)
        DispatchQueue.main.async {
            self.acl = newACL
            self.canEdit = self.computeCanEdit()
        }
        notifyIfNewRequests(newACL)
    }

    /// 写端（可编辑方）：发现新的编辑权限申请时发一条本地通知。
    /// 同一台设备只提醒一次；申请被处理掉（同意/忽略）后，再次申请会重新提醒。
    private func notifyIfNewRequests(_ newACL: SyncSnapshot.ACL?) {
        guard computeCanEdit() else { return }
        let reqIDs = (newACL?.req ?? []).map(\.id).filter { $0 != deviceId }
        let notified = Set(Self.defaults.stringArray(forKey: Self.keyNotifiedReqs) ?? [])
        let fresh = reqIDs.filter { !notified.contains($0) }
        if !fresh.isEmpty {
            AppLog.i("Notify", "新的编辑权限申请：\(fresh.joined(separator: ","))")
            SyncNotifier.shared.notifyPermissionRequests(fresh)
        }
        // 只保留仍待审批的，之后重新申请还能再提醒
        Self.defaults.set(reqIDs, forKey: Self.keyNotifiedReqs)
    }

    // MARK: 权限申请（只读端发起，写端审批）

    /// 只读端：申请编辑权限（把自己的设备加进待审批列表）
    func requestEditPermission() -> SyncOutcome {
        guard pairedCode != nil else { return SyncOutcome(ok: false, message: "尚未配对") }
        guard !computeCanEdit() else { return SyncOutcome(ok: true, message: "本机已可修改数据") }
        var aclv = storedACL() ?? SyncSnapshot.ACL(owner: "", writers: [], req: [])
        // 之前撤销过也要能重新申请：时间必须比那条撤销记录新
        let t = SyncACLResolver.revokeTime(requester: deviceId, in: aclv)
        aclv.rv.removeAll { $0.id == deviceId }
        aclv.req.removeAll { $0.id == deviceId }
        aclv.req.append(SyncSnapshot.ACL.Req(id: deviceId, t: t))
        aclv.req.sort { $0.t < $1.t }
        saveACL(aclv)
        Self.defaults.set(true, forKey: Self.keyACLDirty)
        let r = syncNow(manual: true)
        return r.ok ? SyncOutcome(ok: true, message: "已发出申请，等对方在「配对同步」里同意") : r
    }

    /// 只读端：撤销申请（写一条撤销记录，否则两端合并会把申请并回来）
    func cancelEditPermission() -> SyncOutcome {
        guard pairedCode != nil else { return SyncOutcome(ok: false, message: "尚未配对") }
        guard var aclv = storedACL() else { return SyncOutcome(ok: true, message: "没有待审批的申请") }
        let had = aclv.req.contains { $0.id == deviceId }
        let t = SyncACLResolver.revokeTime(requester: deviceId, in: aclv)
        aclv.req.removeAll { $0.id == deviceId }
        aclv.rv.removeAll { $0.id == deviceId }
        aclv.rv.append(SyncSnapshot.ACL.Req(id: deviceId, t: t))
        saveACL(aclv)
        Self.defaults.set(true, forKey: Self.keyACLDirty)
        let r = syncNow(manual: true)
        guard r.ok else { return r }
        return SyncOutcome(ok: true, message: had ? "已撤销申请" : "没有待审批的申请")
    }

    /// 写端：同意某台设备的编辑权限申请
    func grantWriter(_ deviceID: String) -> SyncOutcome {
        guard computeCanEdit() else { return SyncOutcome(ok: false, message: "本机没有审批权限") }
        guard var aclv = storedACL() else { return SyncOutcome(ok: false, message: "没有待审批的申请") }
        if !aclv.writers.contains(deviceID) { aclv.writers.append(deviceID) }
        aclv.req.removeAll { $0.id == deviceID }
        saveACL(aclv)
        Self.defaults.set(true, forKey: Self.keyACLDirty)
        let r = syncNow(manual: true)
        return r.ok ? SyncOutcome(ok: true, message: "已同意，对方约 6 秒内获得修改权限") : r
    }

    /// 写端：忽略某台设备的申请（写撤销记录，对方之后仍可再次申请）
    func denyRequest(_ deviceID: String) -> SyncOutcome {
        guard computeCanEdit() else { return SyncOutcome(ok: false, message: "本机没有审批权限") }
        guard var aclv = storedACL() else { return SyncOutcome(ok: false, message: "没有待审批的申请") }
        let t = SyncACLResolver.revokeTime(requester: deviceID, in: aclv)
        aclv.req.removeAll { $0.id == deviceID }
        aclv.rv.removeAll { $0.id == deviceID }
        aclv.rv.append(SyncSnapshot.ACL.Req(id: deviceID, t: t))
        saveACL(aclv)
        Self.defaults.set(true, forKey: Self.keyACLDirty)
        let r = syncNow(manual: true)
        return r.ok ? SyncOutcome(ok: true, message: "已忽略该申请") : r
    }

    // MARK: 设备管理（owner 专属，v5.3）
    //
    // A 端（创建配对码的手机）可以管理每台加入的 B 设备：
    //   * 单独控制同步给它的数据类别（胎动 / 宫缩 / 共享设置）
    //   * 强制解绑：对方自动解除配对（保留其本机数据），且不能用原码再加入
    //   * 清除数据：对方联网后清空本机全部记录并解除配对
    // 全部通过 acl 里的 ub / wp / sm 字段随加密快照同步，双端合并规则一致。

    /// 本机是否为配对码创建者（只有它有管理权）
    var isOwner: Bool {
        guard pairedCode != nil, let acl = storedACL() else { return false }
        return acl.owner == deviceId
    }

    /// 管理卡里要显示的设备（除本机与 owner 外的全部可写设备）
    var managedDevices: [String] {
        guard let acl = storedACL(), acl.owner == deviceId else { return [] }
        return acl.writers.filter { $0 != deviceId && $0 != acl.owner }.sorted()
    }

    /// 某台设备当前的数据同步掩码（没有条目 = 全部同步）
    func maskFor(_ deviceID: String) -> SyncSnapshot.ACL.Mask? {
        storedACL()?.mask(deviceID: deviceID)
    }

    /// 改完 acl 后统一走「落盘 → 标记待推送 → 立即同步」
    private func pushAclChange(message: String) -> SyncOutcome {
        Self.defaults.set(true, forKey: Self.keyACLDirty)
        let r = syncNow(manual: true)
        return r.ok ? SyncOutcome(ok: true, message: message) : r
    }

    /// 强制解绑一台设备：移出 writers、写解绑记录（只增不减）。
    /// 对方约 6 秒内自动解除配对（保留其本机数据），且不能用原码再加入。
    func forceUnbind(_ deviceID: String) -> SyncOutcome {
        guard isOwner else { return SyncOutcome(ok: false, message: "只有创建配对码的手机可以管理设备") }
        guard deviceID != deviceId else { return SyncOutcome(ok: false, message: "不能解绑本机") }
        var aclv = storedACL() ?? SyncSnapshot.ACL(owner: deviceId, writers: [deviceId], req: [])
        let t = max(SnapshotIO.ms(Date()), (aclv.ub.first { $0.id == deviceID }?.t ?? 0) + 1)
        aclv.writers.removeAll { $0 == deviceID }
        aclv.req.removeAll { $0.id == deviceID }
        aclv.ub.removeAll { $0.id == deviceID }
        aclv.ub.append(SyncSnapshot.ACL.Req(id: deviceID, t: t))
        saveACL(aclv)
        return pushAclChange(message: "已强制解绑：对方约 6 秒内停止同步，本机记录保留")
    }

    /// 清除一台设备的数据：移出 writers、写清除命令 + 解绑记录。
    /// 对方联网后清空本机全部记录并自动解除配对；云端与其他设备的记录不受影响。
    func wipeDevice(_ deviceID: String) -> SyncOutcome {
        guard isOwner else { return SyncOutcome(ok: false, message: "只有创建配对码的手机可以管理设备") }
        guard deviceID != deviceId else { return SyncOutcome(ok: false, message: "不能清除本机数据") }
        var aclv = storedACL() ?? SyncSnapshot.ACL(owner: deviceId, writers: [deviceId], req: [])
        let now = SnapshotIO.ms(Date())
        let tUB = max(now, (aclv.ub.first { $0.id == deviceID }?.t ?? 0) + 1)
        let tWP = max(now, (aclv.wp.first { $0.id == deviceID }?.t ?? 0) + 1)
        aclv.writers.removeAll { $0 == deviceID }
        aclv.req.removeAll { $0.id == deviceID }
        aclv.ub.removeAll { $0.id == deviceID }
        aclv.ub.append(SyncSnapshot.ACL.Req(id: deviceID, t: tUB))
        aclv.wp.removeAll { $0.id == deviceID }
        aclv.wp.append(SyncSnapshot.ACL.Req(id: deviceID, t: tWP))
        saveACL(aclv)
        return pushAclChange(message: "已下发清除：对方联网后本机记录将被清空并解除配对")
    }

    /// 更新某台设备的数据同步掩码（胎动 / 宫缩 / 设置 / 体重，LWW 合并）
    func setShareMask(_ deviceID: String, kick: Bool, contraction: Bool,
                      settings: Bool, weight: Bool) -> SyncOutcome {
        guard isOwner else { return SyncOutcome(ok: false, message: "只有创建配对码的手机可以管理设备") }
        guard deviceID != deviceId else { return SyncOutcome(ok: false, message: "本机不受同步范围限制") }
        var aclv = storedACL() ?? SyncSnapshot.ACL(owner: deviceId, writers: [deviceId], req: [])
        let t = max(SnapshotIO.ms(Date()), (aclv.sm.first { $0.id == deviceID }?.t ?? 0) + 1)
        let mask = SyncSnapshot.ACL.Mask(id: deviceID,
                                         k: kick ? 1 : 0,
                                         c: contraction ? 1 : 0,
                                         s: settings ? 1 : 0,
                                         w: weight ? 1 : 0,
                                         t: t)
        aclv.sm.removeAll { $0.id == deviceID }
        aclv.sm.append(mask)
        saveACL(aclv)
        return pushAclChange(message: "已更新同步范围：对方约 6 秒内生效")
    }

    // MARK: B 端：处理 owner 下发的管理动作

    /// 本机被 owner 强制解绑 / 清除数据时的本地通知
    private func notifyAdminAction(title: String, body: String) {
        SyncNotifier.shared.notifyAdminAction(title: title, body: body)
    }

    /// 清空本机全部记录（不写墓碑、不触发上传——马上就要解除配对了，
    /// 云端与其他设备的记录不受影响）
    private func wipeAllLocalData() {
        let ctx = ModelContext(JiQianStore.container)
        ctx.autosaveEnabled = false
        for event in (try? ctx.fetch(FetchDescriptor<KickEvent>())) ?? [] { ctx.delete(event) }
        for event in (try? ctx.fetch(FetchDescriptor<ContractionEvent>())) ?? [] { ctx.delete(event) }
        for session in (try? ctx.fetch(FetchDescriptor<KickSession>())) ?? [] { ctx.delete(session) }
        for session in (try? ctx.fetch(FetchDescriptor<ContractionSession>())) ?? [] { ctx.delete(session) }
        for entry in (try? ctx.fetch(FetchDescriptor<WeightEntry>())) ?? [] { ctx.delete(entry) }
        try? ctx.save()
        // 本机的清空戳 / 墓碑也一并清掉：这台设备从此是干净状态
        Self.defaults.removeObject(forKey: Self.keyClearedAt)
        Self.defaults.removeObject(forKey: Self.keyTombstones)
        AppLog.i("Sync", "管理员清除：本机全部记录已删除")
    }

    /// 检查云端权限表里有没有指向本机的管理动作（清除数据 / 强制解绑）。
    /// 返回 nil = 没有动作，继续正常同步；有动作则已就地处理（清库 / 解绑 + 通知），
    /// 调用方直接返回、绝不推送 —— 防止把本机（可能已清空的）数据盖回云端。
    private func handleAdminCommands(in state: SyncSnapshot) -> SyncOutcome? {
        guard let acl = state.acl else { return nil }
        // 清除数据（隐含解绑）：清空本机记录 + 解除配对
        if acl.wipeCommand(deviceID: deviceId) != nil {
            wipeAllLocalData()
            notifyAdminAction(title: "管理员已清除本机数据",
                              body: "记录已全部清空，配对已解除")
            clearLocal()
            return SyncOutcome(ok: false, message: "管理员已清除本机数据，配对已解除")
        }
        // 强制解绑：保留本机记录，解除配对（被解绑后原配对码也不能再加入）
        if acl.unbound(deviceID: deviceId) {
            notifyAdminAction(title: "已被管理员解绑",
                              body: "同步已停止，本机记录保留；重新配对请联系创建者")
            clearLocal()
            return SyncOutcome(ok: false, message: "已被管理员解绑：同步已停止，本机记录保留")
        }
        return nil
    }

    // MARK: 配对

    func createPairing() -> SyncOutcome {
        for _ in 0..<6 {
            let code = String(format: "%06d", Int.random(in: 100000...999999))
            if codeExists(code) == false {
                Self.defaults.set(code, forKey: Self.keyCode)
                Self.defaults.removeObject(forKey: Self.keySalt)
                // 本机是创建者：立即登记为 owner（可写），加入的设备默认只读。
                // 先落本地再同步，即使首次推送失败，owner 身份也不会丢
                saveACL(SyncSnapshot.ACL(owner: deviceId, writers: [deviceId], req: []))
                pendingOwnerAcl = true
                // 以后有人申请编辑权限要能提醒到这台手机
                SyncNotifier.shared.requestAuthorization()
                let r = syncNow(manual: true)
                pendingOwnerAcl = false
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
        SyncNotifier.shared.requestAuthorization()
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
        Self.defaults.removeObject(forKey: Self.keyACL)
        Self.defaults.removeObject(forKey: Self.keyACLDirty)
        Self.defaults.removeObject(forKey: Self.keyNotifiedReqs)
        pendingOwnerAcl = false
        localDirty = false
        lastRev = 0
        stopPolling()
        DispatchQueue.main.async {
            self.lastSyncAt = 0
            self.lastMessage = nil
            self.acl = nil
            self.canEdit = true
        }
    }

    // MARK: 触发（记录器在每次落库后调用）

    func onDataChanged() {
        // 只读端：本机改动一律不上传（记录入口也已被拦截，这里是兜底）
        guard computeCanEdit() else { return }
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
        // 本机已知的权限表并入快照（创建者首次同步时在这里登记为 owner）
        if local.acl == nil {
            if let saved = storedACL() {
                local.acl = saved
            } else if pendingOwnerAcl {
                local.acl = SyncSnapshot.ACL(owner: deviceId, writers: [deviceId], req: [])
            }
        }

        // 本机没数据、也没有权限表要登记：只拉不推，避免把空数据盖掉对方
        if local.isEmpty && local.acl == nil {
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
            // owner 下发的管理动作（清除 / 解绑）优先于一切数据同步
            if let admin = handleAdminCommands(in: snapshot.state) {
                return admin
            }
            do {
                try SnapshotIO.apply(snapshot.state, to: ctx, maskedFor: deviceId)
            } catch {
                AppLog.e("Sync", "应用对方数据失败：\(error)")
                return SyncOutcome(ok: false, message: "应用对方数据失败")
            }
            refreshAccess(snapshot.state.acl)
            markSynced()
            DispatchQueue.main.async { self.lastMessage = "已拉取对方记录" }
            return SyncOutcome(ok: true, message: "已拉取对方记录")
        }

        // 本次同步开始时的权限表：同步期间用户可能又点了申请/审批，收尾时要保住那次改动
        let aclAtStart = storedACL()
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
            // owner 下发的管理动作（清除 / 解绑）优先于一切数据同步：
            // 命中就就地处理并返回，绝不推送（防止把本机数据盖回云端）
            if let admin = handleAdminCommands(in: snapshot.state) {
                return admin
            }
            merged = SnapshotIO.merge(local: local, remote: snapshot.state)
            // 权限表合并（两端规则一致）：owner 以云端为准、writers 并集、申请并集减去已授权
            merged.acl = SyncACLResolver.merge(local: local.acl,
                                               remote: snapshot.state.acl,
                                               pendingOwner: pendingOwnerAcl ? deviceId : nil)
            // 申请 / 撤销申请 / 审批本身要推一次：只要本机权限表和云端不一致就推。
            // 不能只比较「合并结果 vs 本机旧值」，撤销时合并结果可能正好等于本机旧值，
            // 那样这一轮就不会推送，对方永远看不到撤销
            if isAclDirty() && merged.acl != snapshot.state.acl { mustPush = true }
            if merged != local {
                do {
                    try SnapshotIO.apply(merged, to: ctx, maskedFor: deviceId)
                } catch {
                    AppLog.e("Sync", "应用合并结果失败：\(error)")
                    return SyncOutcome(ok: false, message: "应用合并结果失败")
                }
                mustPush = true
            }
        }

        // 只读端：本机记录改动一律不推；只有「申请/撤销申请」或首次加入占行时才推，
        // 且推送内容里记录部分原样用云端版本（只更新 acl），保证只读端改不了云端数据
        if !computeCanEdit() {
            let aclNeedsPush = isAclDirty() && merged.acl != remoteSnapshot?.state.acl
            mustPush = lastRev == 0 || remoteSnapshot?.updatedBy == Self.empty || aclNeedsPush
        }

        // 本机没改、云端也没新东西：什么都不推，避免两端互相蹭出无限推送
        if !mustPush {
            // 同步途中本机权限表被改过（点了申请/审批）：以本机为准，别被合并结果盖掉
            refreshAccess(storedACL() == aclAtStart ? merged.acl : storedACL())
            DispatchQueue.main.async { self.lastMessage = "已是最新" }
            return SyncOutcome(ok: true, message: "已是最新")
        }

        var pushSnapshot = merged
        if !computeCanEdit(), let r = remoteSnapshot, r.updatedBy != Self.empty {
            pushSnapshot = r.state
            pushSnapshot.acl = merged.acl
        }

        guard let status = upsert(code: code, snapshot: pushSnapshot) else {
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
        if storedACL() == aclAtStart {
            // 本机权限表在同步期间没被动过：用合并结果落地，并清掉待推送标记
            Self.defaults.set(false, forKey: Self.keyACLDirty)
            refreshAccess(merged.acl)
        } else {
            // 同步途中又点了「申请 / 撤销 / 同意」：保留本机这次改动，立刻补推一轮
            Self.defaults.set(true, forKey: Self.keyACLDirty)
            refreshAccess(storedACL())
            retryPending = true
        }
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
