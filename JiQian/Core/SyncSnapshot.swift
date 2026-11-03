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

    /// 配对权限（端到端加密，随快照同步）：
    /// owner = 创建配对码的设备；writers = 允许修改数据的设备；
    /// req = 「申请编辑权限」的待审批列表。不在 writers 里 = 只读（查看模式）。
    /// 两端对 acl 的合并规则一致（owner 以云端为准、writers 并集、req 并集减去已授权），
    /// 保证各端算出同一结果，不会互推死循环。
    struct ACL: Codable, Equatable {
        struct Req: Codable, Equatable {
            var id: String    // 申请设备的 deviceId
            var t: Int64      // 申请时间（毫秒），用于排序展示 / 撤销比较
        }
        var owner: String
        var writers: [String] = []
        var req: [Req] = []
        /// 已撤销（本机放弃）或被忽略的申请：id + 撤销时刻。
        /// 没有它，「撤销申请」会被两端并集合并规则原样并回来，表现就是点了没反应。
        var rv: [Req] = []

        enum CodingKeys: String, CodingKey { case owner, writers, req, rv }

        init(owner: String, writers: [String] = [], req: [Req] = [], rv: [Req] = []) {
            self.owner = owner
            self.writers = writers
            self.req = req
            self.rv = rv
        }

        /// 手写解码：rv 是后加的字段，旧快照里没有，必须能缺省
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
            writers = try c.decodeIfPresent([String].self, forKey: .writers) ?? []
            req = try c.decodeIfPresent([Req].self, forKey: .req) ?? []
            rv = try c.decodeIfPresent([Req].self, forKey: .rv) ?? []
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

    /// 撤销时刻用「对应申请时间 + 1ms」：两端时钟有偏差也不会让撤销失效
    static func revokeTime(requester: String, in acl: SyncSnapshot.ACL?) -> Int64 {
        let reqT = acl?.req.first { $0.id == requester }?.t ?? 0
        let rvT = acl?.rv.first { $0.id == requester }?.t ?? 0
        return max(SnapshotIO.ms(Date()), max(reqT, rvT) + 1)
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
        return SyncSnapshot.ACL(owner: owner, writers: writers.sorted(), req: req, rv: rv)
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

    // MARK: 导出：SwiftData → 快照

    static func export(from ctx: ModelContext) throws -> SyncSnapshot {
        var snap = SyncSnapshot()
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

    private static func mergeKS(_ l: SyncSnapshot.KS, _ r: SyncSnapshot.KS) -> SyncSnapshot.KS {
        var out = l
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

    static func apply(_ snap: SyncSnapshot, to ctx: ModelContext) throws {
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

        try ctx.save()
    }
}
