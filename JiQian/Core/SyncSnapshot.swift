import Foundation
import SwiftData

// MARK: - 互通快照（与安卓端逐字段一致）
//
// 时间统一用 epoch 毫秒（Int64），id 用 UUID 字符串（安卓端没有会话概念，
// 其胎动/宫缩记录的锚点就是时间戳，两端以锚点互认）。
// 字段名刻意用短名，减小密文体积：
//   ks 胎动轮次 / ke 胎动事件 / cs 宫缩周期 / ce 宫缩事件
//   cl 清空时间戳（clear-all 墓碑）/ del 单条删除墓碑 [["ke@ms"|"ce@ms", 删除时间ms]]
//
// 合并规则（与安卓 SyncManager.kt 一致）：
// * cl 取两端较大值；锚点早于 cl 的记录在所有设备上丢弃（「清空全部」可跨端生效）；
// * 墓碑取并集，180 天后过期修剪（防止墓碑无限增长）；
// * 记录按 id 并集，双方独有的都保留；同一 id 冲突时做字段级融合：
//   结束时间取较晚的非空值、备注取非空值、可疑标记取或，保证两端算出同一结果。

struct SyncSnapshot: Codable, Equatable {
    struct KS: Codable, Equatable {
        var id: String
        var s: Int64          // startedAt
        var e: Int64?         // endedAt
        var t: Int            // targetCount
        var src: String
        var fr: String?       // finishedReason
        var ltu: Int          // lessThanUsualRaw
        var cel: Bool         // celebrated
    }
    struct KE: Codable, Equatable {
        var id: String
        var sid: String       // sessionID
        var at: Int64         // occurredAt
        var src: String
        var note: String?
    }
    struct CS: Codable, Equatable {
        var id: String
        var s: Int64
        var e: Int64?
        var src: String
    }
    struct CE: Codable, Equatable {
        var id: String
        var sid: String
        var s: Int64
        var e: Int64?
        var src: String
        var ir: String?       // interruptedReason
        var gap: Double
        var sus: Bool         // isSuspect
    }
    struct Del: Codable, Equatable {
        var id: String        // "ke@<ms>" / "ce@<startMs>"
        var t: Int64          // 删除发生时间（毫秒），用于过期修剪
    }

    /// 共享设置。预产期决定孕周与摘要里的提示；每轮时长 / 计数窗口 / 高风险因素 /
    /// 产科联系方式也是两台手机要一致的设置（圈出来的那几项）。
    /// edd = 预产期当天 0 点（本地时区）的 epoch 毫秒，0 = 未设置；
    /// rm = 每轮时长（分钟）；win = 计数窗口（分钟）；
    /// risks = 高风险因素（逗号分隔原文）；prov/phone = 产科联系方式。
    /// t = 最后修改时间（毫秒）。合并取 t 较大的一条（LWW），t 相同按字段字典序
    /// 决出胜者，保证两端算出同一结果、不会互推。
    struct ST: Codable, Equatable {
        var edd: Int64 = 0
        var t: Int64 = 0
        var rm: Int?        // 每轮时长（分钟）
        var win: Int?       // 计数窗口（分钟）
        var risks: String?  // 高风险因素，逗号分隔
        var prov: String?   // 机构名称
        var phone: String?  // 联系电话

        init(edd: Int64 = 0, t: Int64 = 0,
             rm: Int? = nil, win: Int? = nil,
             risks: String? = nil, prov: String? = nil, phone: String? = nil) {
            self.edd = edd
            self.t = t
            self.rm = rm
            self.win = win
            self.risks = risks
            self.prov = prov
            self.phone = phone
        }

        enum CodingKeys: String, CodingKey { case edd, t, rm, win, risks, prov, phone }

        /// 手写解码：字段缺失时用默认值，避免旧/半截数据把整份快照解崩
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            edd = try c.decodeIfPresent(Int64.self, forKey: .edd) ?? 0
            t = try c.decodeIfPresent(Int64.self, forKey: .t) ?? 0
            rm = try c.decodeIfPresent(Int.self, forKey: .rm)
            win = try c.decodeIfPresent(Int.self, forKey: .win)
            risks = try c.decodeIfPresent(String.self, forKey: .risks)
            prov = try c.decodeIfPresent(String.self, forKey: .prov)
            phone = try c.decodeIfPresent(String.self, forKey: .phone)
        }

        /// 决胜键（与安卓 stKey 逐字一致）：t 相同时按它比大小，两端必收敛
        var tieBreakKey: String {
            "\(edd)|\(rm ?? 0)|\(win ?? 0)|\(risks ?? "")|\(prov ?? "")|\(phone ?? "")"
        }
    }

    /// 配对权限（端到端加密，随快照同步）：
    /// owner = 创建配对码的设备；writers = 允许修改数据的设备；
    /// req = 「申请编辑权限」的待审批列表。不在 writers 里 = 只读（查看模式）。
    /// 两端对 acl 的合并规则一致（owner 以云端为准、writers 并集、req 并集减去已授权），
    /// 保证各端算出同一结果，不会互推死循环。
    ///
    /// v5.3 设备管理（只有 owner 能写这三个字段，其他端只读应用）：
    /// ub = 强制解绑记录 [设备id + 时刻]。被解绑的设备同步时发现自己在这里，
    ///      就自动解除配对（保留本机数据），且无法再用同一个配对码加入。
    /// wp = 清除数据命令 [设备id + 时刻]。目标设备发现自己在这里，就清空本机
    ///      全部记录并解除配对。清除同时也会写 ub（清完就走，不再同步）。
    /// sm = 每台设备的共享掩码 [设备id + k胎动 + c宫缩 + s设置 + 修改时刻t]。
    ///      owner 在管理界面单独控制「同步哪类数据给这台设备」；关闭的类别
    ///      在对方设备上不再落地、已有的也会被移除。合并按设备 LWW（t 大者胜）。
    struct ACL: Codable, Equatable {
        struct Req: Codable, Equatable {
            var id: String    // 申请设备的 deviceId
            var t: Int64      // 申请时间（毫秒），用于排序展示 / 撤销比较
        }
        /// 设备的数据同步掩码：k = 胎动，c = 宫缩，s = 共享设置（预产期等）。
        /// 1 = 同步，0 = 不同步。t = owner 最后修改时刻（毫秒），合并 LWW 用。
        struct Mask: Codable, Equatable {
            var id: String
            var k: Int
            var c: Int
            var s: Int
            var t: Int64
        }
        var owner: String
        var writers: [String] = []
        var req: [Req] = []
        /// 已撤销（本机放弃）或被忽略的申请：id + 撤销时刻。
        /// 没有它，「撤销申请」会被两端并集合并规则原样并回来，表现就是点了没反应。
        var rv: [Req] = []
        /// owner 强制解绑的设备（v5.3）
        var ub: [Req] = []
        /// owner 下发的「清除数据」命令（v5.3），清除时会一并写 ub
        var wp: [Req] = []
        /// 每台设备的数据同步掩码（v5.3）
        var sm: [Mask] = []

        enum CodingKeys: String, CodingKey { case owner, writers, req, rv, ub, wp, sm }

        init(owner: String, writers: [String] = [], req: [Req] = [], rv: [Req] = [],
             ub: [Req] = [], wp: [Req] = [], sm: [Mask] = []) {
            self.owner = owner
            self.writers = writers
            self.req = req
            self.rv = rv
            self.ub = ub
            self.wp = wp
            self.sm = sm
        }

        /// 手写解码：rv/ub/wp/sm 都是后加的字段，旧快照里没有，必须能缺省
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
            writers = try c.decodeIfPresent([String].self, forKey: .writers) ?? []
            req = try c.decodeIfPresent([Req].self, forKey: .req) ?? []
            rv = try c.decodeIfPresent([Req].self, forKey: .rv) ?? []
            ub = try c.decodeIfPresent([Req].self, forKey: .ub) ?? []
            wp = try c.decodeIfPresent([Req].self, forKey: .wp) ?? []
            sm = try c.decodeIfPresent([Mask].self, forKey: .sm) ?? []
        }

        /// 本机设备是否已被 owner 强制解绑
        func unbound(deviceID: String) -> Bool {
            ub.contains { $0.id == deviceID }
        }
        /// 指向本机的「清除数据」命令（有的话返回最新那条）
        func wipeCommand(deviceID: String) -> Req? {
            wp.filter { $0.id == deviceID }.max { $0.t < $1.t }
        }
        /// 本机设备的共享掩码（没有条目 = 全部同步）
        func mask(deviceID: String) -> Mask? {
            sm.filter { $0.id == deviceID }.max { $0.t < $1.t }
        }
    }

    var v: Int = 1
    var ks: [KS] = []
    var ke: [KE] = []
    var cs: [CS] = []
    var ce: [CE] = []
    var cl: Int64 = 0
    var del: [Del] = []
    var acl: ACL?         // nil = 旧版本配对（全员可写，向后兼容）
    var st: ST?           // nil = 旧版本快照，没有共享设置（预产期）

    /// 本机从头到尾没有任何数据（全新安装）。此时只拉不推，避免空快照盖掉对方。
    var isEmpty: Bool {
        ks.isEmpty && ke.isEmpty && cs.isEmpty && ce.isEmpty && cl == 0 && del.isEmpty
    }
}

// MARK: - 墓碑 id 约定（与安卓一致）

enum SyncTombstone {
    static let ttlMs: Int64 = 180 * 86400 * 1000   // 180 天过期

    static func kick(_ occurredAtMs: Int64) -> String { "ke@\(occurredAtMs)" }
    static func ctn(_ startedAtMs: Int64) -> String { "ce@\(startedAtMs)" }
}

// MARK: - 权限（acl）合并 —— 两端规则一致，保证收敛

enum SyncACLResolver {
    /// 撤销记录保留 180 天（与墓碑一致），之后自动修剪
    static let revokeTTLms: Int64 = 180 * 86400 * 1000
    private static let revokeCap = 200
    /// 强制解绑 / 清除数据记录的保留期与上限（同撤销记录）
    private static let adminCap = 200

    /// 撤销时刻用「对应申请时间 + 1ms」：两端时钟有偏差也不会让撤销失效
    static func revokeTime(requester: String, in acl: SyncSnapshot.ACL?) -> Int64 {
        let reqT = acl?.req.first { $0.id == requester }?.t ?? 0
        let rvT = acl?.rv.first { $0.id == requester }?.t ?? 0
        let ubT = acl?.ub.first { $0.id == requester }?.t ?? 0
        return max(SnapshotIO.ms(Date()), max(reqT, max(rvT, ubT)) + 1)
    }

    /// [id, t] 列表的并集合并：同设备取较大的 t，过期修剪 + 数量上限。
    /// 用于 req/rv，也用于 v5.3 的 ub（强制解绑）/ wp（清除数据）——
    /// 这两类记录只增不减，被解绑的设备不能用「并回旧值」的方式混进来。
    private static func mergeReqs(_ l: [SyncSnapshot.ACL.Req]?, _ r: [SyncSnapshot.ACL.Req]?) -> [SyncSnapshot.ACL.Req] {
        var map: [String: Int64] = [:]
        for q in (l ?? []) + (r ?? []) { map[q.id] = max(map[q.id] ?? 0, q.t) }
        let cutoff = SnapshotIO.ms(Date()) - revokeTTLms
        return map
            .filter { $0.value >= cutoff }
            .sorted { ($0.key, $0.value) < ($1.key, $1.value) }
            .suffix(adminCap)
            .map { SyncSnapshot.ACL.Req(id: $0.key, t: $0.value) }
    }

    /// 掩码合并：每台设备一条，LWW（t 大者胜，t 相同按掩码值字典序决胜，两端必收敛）
    private static func mergeMasks(_ l: [SyncSnapshot.ACL.Mask]?, _ r: [SyncSnapshot.ACL.Mask]?) -> [SyncSnapshot.ACL.Mask] {
        var map: [String: SyncSnapshot.ACL.Mask] = [:]
        for m in (l ?? []) + (r ?? []) {
            if let old = map[m.id] {
                if m.t != old.t { if m.t > old.t { map[m.id] = m } }
                else if maskKey(m) > maskKey(old) { map[m.id] = m }
            } else {
                map[m.id] = m
            }
        }
        return map.values.sorted { $0.id < $1.id }
    }

    private static func maskKey(_ m: SyncSnapshot.ACL.Mask) -> String {
        "\(m.k)|\(m.c)|\(m.s)"
    }

    static func merge(local: SyncSnapshot.ACL?, remote: SyncSnapshot.ACL?, pendingOwner: String?) -> SyncSnapshot.ACL? {
        if local == nil && remote == nil {
            guard let owner = pendingOwner else { return nil }
            return SyncSnapshot.ACL(owner: owner, writers: [owner], req: [])
        }
        // 归属以云端（远端）为准；两端都没有时用本端待登记的创建者
        let owner = remote?.owner ?? local?.owner ?? pendingOwner ?? ""
        var writers = Set((local?.writers ?? []) + (remote?.writers ?? []))
        if !owner.isEmpty { writers.insert(owner) }
        // 申请并集（同设备保留最新时间）
        var reqMap: [String: Int64] = [:]
        for q in (local?.req ?? []) + (remote?.req ?? []) {
            reqMap[q.id] = max(reqMap[q.id] ?? 0, q.t)
        }
        // 撤销并集：撤销过就压住更早的申请，否则并集会把已撤销的申请又并回来
        var rvMap: [String: Int64] = [:]
        for q in (local?.rv ?? []) + (remote?.rv ?? []) {
            rvMap[q.id] = max(rvMap[q.id] ?? 0, q.t)
        }
        let cutoff = SnapshotIO.ms(Date()) - revokeTTLms
        let rv = rvMap
            .filter { $0.value >= cutoff }
            .sorted { $0.value < $1.value }
            .suffix(revokeCap)
            .map { SyncSnapshot.ACL.Req(id: $0.key, t: $0.value) }
        let rvSet = Dictionary(uniqueKeysWithValues: rv.map { ($0.id, $0.t) })
        // 未被授权、且没有被更新的一次撤压倒的申请才算待审批
        let req = reqMap
            .filter { !writers.contains($0.key) && (rvSet[$0.key] ?? 0) < $0.value }
            .sorted { $0.value < $1.value }
            .map { SyncSnapshot.ACL.Req(id: $0.key, t: $0.value) }
        // v5.3 设备管理：强制解绑 / 清除命令 / 共享掩码（只增不减，规则两端一致）
        let ub = mergeReqs(local?.ub, remote?.ub)
        let wp = mergeReqs(local?.wp, remote?.wp)
        let sm = mergeMasks(local?.sm, remote?.sm)
        // 被解绑的设备不再算 writer（解绑记录压住 writers 并集）
        let ubSet = Set(ub.map(\.id))
        let finalWriters = writers.filter { !ubSet.contains($0) }.sorted()
        return SyncSnapshot.ACL(owner: owner, writers: finalWriters, req: req, rv: rv, ub: ub, wp: wp, sm: sm)
    }
}

// MARK: - 导出 / 合并 / 应用

enum SnapshotIO {

    static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    }
    static func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    /// 日期文案（日志用）
    static func dayText(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date(ms))
    }

    // MARK: 导出：SwiftData → 快照

    /// 本机共享设置 → 快照。什么都没设置过就返回 nil，不带这段字段。
    static func localSettings() -> SyncSnapshot.ST? {
        let d = UserDefaults.standard
        let sec = d.double(forKey: PrefKey.edd)
        let t = Int64(d.double(forKey: PrefKey.eddT).rounded())
        let edd = sec > 0 ? ms(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: sec))) : 0
        let rm = Prefs.roundMin
        let win = Prefs.windowMin
        let risksRaw = d.string(forKey: PrefKey.risks) ?? ""
        let prov = d.string(forKey: PrefKey.provider) ?? ""
        let phone = d.string(forKey: PrefKey.phone) ?? ""
        if edd == 0 && t == 0 && risksRaw.isEmpty && prov.isEmpty && phone.isEmpty {
            return nil
        }
        return SyncSnapshot.ST(edd: edd, t: t,
                               rm: rm, win: win,
                               risks: risksRaw.isEmpty ? nil : risksRaw,
                               prov: prov.isEmpty ? nil : prov,
                               phone: phone.isEmpty ? nil : phone)
    }

    static func export(from ctx: ModelContext) throws -> SyncSnapshot {
        var snap = SyncSnapshot()
        snap.st = localSettings()
        for s in try ctx.fetch(FetchDescriptor<KickSession>()) {
            snap.ks.append(SyncSnapshot.KS(id: s.id.uuidString,
                                           s: ms(s.startedAt),
                                           e: s.endedAt.map(ms),
                                           t: s.targetCount,
                                           src: s.sourceRaw,
                                           fr: s.finishedReason,
                                           ltu: s.lessThanUsualRaw,
                                           cel: s.celebrated))
        }
        for e in try ctx.fetch(FetchDescriptor<KickEvent>()) {
            snap.ke.append(SyncSnapshot.KE(id: e.id.uuidString,
                                           sid: e.sessionID.uuidString,
                                           at: ms(e.occurredAt),
                                           src: e.sourceRaw,
                                           note: e.note))
        }
        for s in try ctx.fetch(FetchDescriptor<ContractionSession>()) {
            snap.cs.append(SyncSnapshot.CS(id: s.id.uuidString,
                                           s: ms(s.startedAt),
                                           e: s.endedAt.map(ms),
                                           src: s.sourceRaw))
        }
        for e in try ctx.fetch(FetchDescriptor<ContractionEvent>()) {
            snap.ce.append(SyncSnapshot.CE(id: e.id.uuidString,
                                           sid: e.sessionID.uuidString,
                                           s: ms(e.startedAt),
                                           e: e.endedAt.map(ms),
                                           src: e.sourceRaw,
                                           ir: e.interruptedReason,
                                           gap: e.gap,
                                           sus: e.isSuspect))
        }
        return snap
    }

    // MARK: 合并（纯函数，两端算出的结果一致）

    static func merge(local: SyncSnapshot, remote: SyncSnapshot) -> SyncSnapshot {
        var out = local
        out.v = 1
        out.cl = max(local.cl, remote.cl)
        // 共享设置：取最后一次修改（LWW），t 相同再比 edd
        out.st = mergeST(local.st, remote.st)

        // 墓碑并集 + 过期修剪
        var del = Dictionary(uniqueKeysWithValues: local.del.map { ($0.id, $0) })
        for d in remote.del where del[d.id] == nil { del[d.id] = d }
        let cutoff = ms(Date()) - SyncTombstone.ttlMs
        out.del = del.values.filter { $0.t >= cutoff }.sorted { $0.id < $1.id }
        let delIDs = Set(out.del.map(\.id))

        // 胎动轮次：按 id 并集 + 字段融合
        var ks = Dictionary(uniqueKeysWithValues: local.ks.map { ($0.id, $0) })
        for r in remote.ks { ks[r.id] = (ks[r.id].map { mergeKS($0, r) }) ?? r }
        out.ks = ks.values.filter { $0.s >= out.cl }.sorted { $0.s < $1.s }

        // 宫缩周期：按 id 并集
        var cs = Dictionary(uniqueKeysWithValues: local.cs.map { ($0.id, $0) })
        for r in remote.cs { cs[r.id] = (cs[r.id].map { mergeCS($0, r) }) ?? r }
        out.cs = cs.values.filter { $0.s >= out.cl }.sorted { $0.s < $1.s }

        // 胎动事件：按 id 并集；锚点（occurredAt）是跨端互认键
        var ke = Dictionary(uniqueKeysWithValues: local.ke.map { ($0.id, $0) })
        for r in remote.ke { ke[r.id] = (ke[r.id].map { mergeKE($0, r) }) ?? r }
        out.ke = ke.values
            .filter { $0.at >= out.cl && !delIDs.contains(SyncTombstone.kick($0.at)) }
            .sorted { $0.at < $1.at }

        // 宫缩事件：按 id 并集；锚点（startedAt）
        var ce = Dictionary(uniqueKeysWithValues: local.ce.map { ($0.id, $0) })
        for r in remote.ce { ce[r.id] = (ce[r.id].map { mergeCE($0, r) }) ?? r }
        out.ce = ce.values
            .filter { $0.s >= out.cl && !delIDs.contains(SyncTombstone.ctn($0.s)) }
            .sorted { $0.s < $1.s }

        return out
    }

    /// 共享设置合并：t 大者胜；t 相同按决胜键比大小（纯函数，两端规则一致）
    static func mergeST(_ l: SyncSnapshot.ST?, _ r: SyncSnapshot.ST?) -> SyncSnapshot.ST? {
        guard let l else { return r }
        guard let r else { return l }
        if l.t != r.t { return l.t > r.t ? l : r }
        return l.tieBreakKey >= r.tieBreakKey ? l : r
    }

    private static func mergeKS(_ l: SyncSnapshot.KS, _ r: SyncSnapshot.KS) -> SyncSnapshot.KS {        var out = l
        out.s = min(l.s, r.s)
        switch (l.e, r.e) {
        case (nil, let e?): out.e = e
        case (let e?, nil): out.e = e
        case (let a?, let b?): out.e = max(a, b)
        default: out.e = nil
        }
        out.t = max(l.t, r.t)
        out.fr = l.fr ?? r.fr
        if l.ltu == -1 { out.ltu = r.ltu }
        else if r.ltu == -1 { out.ltu = l.ltu }
        else { out.ltu = max(l.ltu, r.ltu) }
        out.cel = l.cel || r.cel
        return out
    }

    private static func mergeKE(_ l: SyncSnapshot.KE, _ r: SyncSnapshot.KE) -> SyncSnapshot.KE {
        var out = l
        out.at = min(l.at, r.at)
        out.note = l.note ?? r.note
        return out
    }

    private static func mergeCS(_ l: SyncSnapshot.CS, _ r: SyncSnapshot.CS) -> SyncSnapshot.CS {
        var out = l
        out.s = min(l.s, r.s)
        switch (l.e, r.e) {
        case (nil, let e?): out.e = e
        case (let e?, nil): out.e = e
        case (let a?, let b?): out.e = max(a, b)
        default: out.e = nil
        }
        return out
    }

    private static func mergeCE(_ l: SyncSnapshot.CE, _ r: SyncSnapshot.CE) -> SyncSnapshot.CE {
        var out = l
        out.s = min(l.s, r.s)
        switch (l.e, r.e) {
        case (nil, let e?): out.e = e
        case (let e?, nil): out.e = e
        case (let a?, let b?): out.e = max(a, b)
        default: out.e = nil
        }
        out.ir = l.ir ?? r.ir
        out.gap = l.gap > 0 ? l.gap : r.gap
        out.sus = l.sus || r.sus
        return out
    }

    // MARK: 应用：快照 → SwiftData（按 id 增量更新，不重建容器）

    /// 把快照落进本机数据库。maskedFor = 本机设备 id：
    /// 非 owner 且 acl.sm 里有本机掩码时，按掩码过滤数据类别 ——
    /// owner 关掉「胎动」后，对方设备上胎动记录不再落地、已有的也会被清掉。
    /// 快照对象本身不改动（filtered 是副本），推送内容不受影响。
    static func apply(_ snap0: SyncSnapshot, to ctx: ModelContext, maskedFor deviceID: String? = nil) throws {
        var snap = snap0
        if let deviceID = deviceID,
           let acl = snap.acl, acl.owner != deviceID,
           let mask = acl.mask(deviceID: deviceID) {
            if mask.k == 0 { snap.ks = []; snap.ke = [] }
            if mask.c == 0 { snap.cs = []; snap.ce = [] }
            if mask.s == 0 { snap.st = nil }
        }
        // 胎动轮次
        let remoteKS = Dictionary(snap.ks.map { (UUID(uuidString: $0.id) ?? UUID(), $0) },
                                  uniquingKeysWith: { a, _ in a })
        for s in try ctx.fetch(FetchDescriptor<KickSession>()) {
            guard let r = remoteKS[s.id] else { ctx.delete(s); continue }
            s.startedAt = date(r.s)
            s.endedAt = r.e.map(date)
            s.targetCount = r.t
            s.sourceRaw = r.src
            s.finishedReason = r.fr
            s.lessThanUsualRaw = r.ltu
            s.celebrated = r.cel
        }
        for r in snap.ks {
            let id = UUID(uuidString: r.id) ?? UUID()
            guard (try ctx.fetch(FetchDescriptor<KickSession>(predicate: #Predicate { $0.id == id }))).isEmpty else { continue }
            let s = KickSession()
            s.id = id
            s.startedAt = date(r.s)
            s.endedAt = r.e.map(date)
            s.targetCount = r.t
            s.sourceRaw = r.src
            s.finishedReason = r.fr
            s.lessThanUsualRaw = r.ltu
            s.celebrated = r.cel
            ctx.insert(s)
        }

        // 胎动事件
        let remoteKE = Dictionary(snap.ke.map { (UUID(uuidString: $0.id) ?? UUID(), $0) },
                                  uniquingKeysWith: { a, _ in a })
        for e in try ctx.fetch(FetchDescriptor<KickEvent>()) {
            guard let r = remoteKE[e.id] else { ctx.delete(e); continue }
            e.sessionID = UUID(uuidString: r.sid) ?? e.sessionID
            e.occurredAt = date(r.at)
            e.sourceRaw = r.src
            e.note = r.note
        }
        for r in snap.ke {
            let id = UUID(uuidString: r.id) ?? UUID()
            guard (try ctx.fetch(FetchDescriptor<KickEvent>(predicate: #Predicate { $0.id == id }))).isEmpty else { continue }
            let e = KickEvent(sessionID: UUID(uuidString: r.sid) ?? UUID())
            e.id = id
            e.occurredAt = date(r.at)
            e.sourceRaw = r.src
            e.note = r.note
            ctx.insert(e)
        }

        // 宫缩周期
        let remoteCS = Dictionary(snap.cs.map { (UUID(uuidString: $0.id) ?? UUID(), $0) },
                                  uniquingKeysWith: { a, _ in a })
        for s in try ctx.fetch(FetchDescriptor<ContractionSession>()) {
            guard let r = remoteCS[s.id] else { ctx.delete(s); continue }
            s.startedAt = date(r.s)
            s.endedAt = r.e.map(date)
            s.sourceRaw = r.src
        }
        for r in snap.cs {
            let id = UUID(uuidString: r.id) ?? UUID()
            guard (try ctx.fetch(FetchDescriptor<ContractionSession>(predicate: #Predicate { $0.id == id }))).isEmpty else { continue }
            let s = ContractionSession()
            s.id = id
            s.startedAt = date(r.s)
            s.endedAt = r.e.map(date)
            s.sourceRaw = r.src
            ctx.insert(s)
        }

        // 宫缩事件
        let remoteCE = Dictionary(snap.ce.map { (UUID(uuidString: $0.id) ?? UUID(), $0) },
                                  uniquingKeysWith: { a, _ in a })
        for e in try ctx.fetch(FetchDescriptor<ContractionEvent>()) {
            guard let r = remoteCE[e.id] else { ctx.delete(e); continue }
            e.sessionID = UUID(uuidString: r.sid) ?? e.sessionID
            e.startedAt = date(r.s)
            e.endedAt = r.e.map(date)
            e.sourceRaw = r.src
            e.interruptedReason = r.ir
            e.gap = r.gap
            e.isSuspect = r.sus
        }
        for r in snap.ce {
            let id = UUID(uuidString: r.id) ?? UUID()
            guard (try ctx.fetch(FetchDescriptor<ContractionEvent>(predicate: #Predicate { $0.id == id }))).isEmpty else { continue }
            let e = ContractionEvent(sessionID: UUID(uuidString: r.sid) ?? UUID())
            e.id = id
            e.startedAt = date(r.s)
            e.endedAt = r.e.map(date)
            e.sourceRaw = r.src
            e.interruptedReason = r.ir
            e.gap = r.gap
            e.isSuspect = r.sus
            ctx.insert(e)
        }

        // 共享设置（预产期 / 每轮时长 / 计数窗口 / 高风险因素 / 产科联系方式）：
        // 落到 UserDefaults，界面上的 @AppStorage 会自动刷新。
        // 比本机记录更旧的不覆盖（防止刚设好就被对方旧值盖掉）
        if let st = snap.st {
            let d = UserDefaults.standard
            let localT = Int64(d.double(forKey: PrefKey.eddT).rounded())
            if st.t >= localT {
                // 预产期
                let sec = st.edd > 0
                    ? Calendar.current.startOfDay(for: date(st.edd)).timeIntervalSince1970
                    : 0
                if abs(d.double(forKey: PrefKey.edd) - sec) > 0.5 {
                    d.set(sec, forKey: PrefKey.edd)
                    let text = st.edd > 0 ? dayText(st.edd) : "未设置"
                    AppLog.i("Sync", "预产期已按配对设备更新：\(text)")
                }
                // 每轮时长 / 计数窗口（只在合法值时落地）
                if let rm = st.rm, [5, 10, 15, 30, 45, 60, 75].contains(rm),
                   d.integer(forKey: PrefKey.roundMin) != rm {
                    d.set(rm, forKey: PrefKey.roundMin)
                    AppLog.i("Sync", "每轮时长已按配对设备更新：\(rm) 分钟")
                }
                if let win = st.win, [60, 120, 180].contains(win),
                   d.integer(forKey: PrefKey.windowMin) != win {
                    d.set(win, forKey: PrefKey.windowMin)
                    AppLog.i("Sync", "计数窗口已按配对设备更新：\(win) 分钟")
                }
                // 高风险因素 / 产科联系方式
                if let risks = st.risks, d.string(forKey: PrefKey.risks) != risks {
                    d.set(risks, forKey: PrefKey.risks)
                }
                if let prov = st.prov, d.string(forKey: PrefKey.provider) != prov {
                    d.set(prov, forKey: PrefKey.provider)
                }
                if let phone = st.phone, d.string(forKey: PrefKey.phone) != phone {
                    d.set(phone, forKey: PrefKey.phone)
                }
                if localT != st.t { d.set(Double(st.t), forKey: PrefKey.eddT) }
            }
        }

        try ctx.save()
    }
}
