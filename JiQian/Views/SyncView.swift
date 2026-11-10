import SwiftUI

// MARK: - 配对同步页
//
// 一台手机创建配对码，另一台输入同一个码，之后双方联网就自动双向同步全部记录。
// 从「设置 → ☁️ 配对同步」进入（在设置的 NavigationStack 内被 push）。

struct SyncView: View {
    @ObservedObject private var sync = SyncManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var joinText = ""
    @State private var running = false
    @State private var toast: String?
    /// 设备管理：待确认的动作目标（强制解绑 / 清除数据）
    @State private var unbindTarget: String?
    @State private var wipeTarget: String?
    /// 撤销编辑权限申请前先确认：误触一次这台手机就变只读，而且不会有人提醒
    @State private var confirmCancelRequest = false
    /// 「忽略」别人申请前也确认：对方会立刻变只读
    @State private var denyTarget: String?

    private var code: String? { sync.pairedCode }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let code {
                    pairedSection(code)
                } else {
                    howToCard
                    createCard
                    joinCard
                }
                notesCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .background(Pal.bg.ignoresSafeArea())
        .navigationTitle("☁️ 配对同步")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("强制解绑设备 \(unbindTarget ?? "")？",
                            isPresented: Binding(get: { unbindTarget != nil },
                                                 set: { if !$0 { unbindTarget = nil } }),
                            titleVisibility: .visible) {
            Button("强制解绑", role: .destructive) {
                if let d = unbindTarget { run { sync.forceUnbind(d) } }
                unbindTarget = nil
            }
            Button("取消", role: .cancel) { unbindTarget = nil }
        } message: {
            Text("对方将立即停止同步（对方本机已同步的数据保留），且无法再用这个配对码加入。")
        }
        .confirmationDialog("清除设备 \(wipeTarget ?? "") 的数据？",
                            isPresented: Binding(get: { wipeTarget != nil },
                                                 set: { if !$0 { wipeTarget = nil } }),
                            titleVisibility: .visible) {
            Button("清除对方数据", role: .destructive) {
                if let d = wipeTarget { run { sync.wipeDevice(d) } }
                wipeTarget = nil
            }
            Button("取消", role: .cancel) { wipeTarget = nil }
        } message: {
            Text("对方手机联网后会清空全部胎动与宫缩记录并自动解除配对；本机与云端的记录不受影响。")
        }
        .confirmationDialog("撤销编辑权限申请？",
                            isPresented: $confirmCancelRequest,
                            titleVisibility: .visible) {
            Button("撤销申请", role: .destructive) {
                confirmCancelRequest = false
                run { sync.cancelEditPermission() }
            }
            Button("取消", role: .cancel) { confirmCancelRequest = false }
        } message: {
            Text("撤销后这台手机会变成「查看模式」：不能记录胎动/宫缩/体重，直到你在另一端重新同意。")
        }
        .confirmationDialog("忽略设备 \(denyTarget ?? "") 的申请？",
                            isPresented: Binding(get: { denyTarget != nil },
                                                 set: { if !$0 { denyTarget = nil } }),
                            titleVisibility: .visible) {
            Button("忽略申请", role: .destructive) {
                if let d = denyTarget { run { sync.denyRequest(d) } }
                denyTarget = nil
            }
            Button("取消", role: .cancel) { denyTarget = nil }
        } message: {
            Text("对方会保持「查看模式」，无法记录胎动；对方之后仍可再次申请。")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .padding(.bottom, 40)
                    .transition(.opacity)
            }
        }
    }

    // MARK: 未配对

    private var howToCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("怎么用").font(.system(size: 13, weight: .bold)).foregroundStyle(Pal.ink)
                Text("① 这台手机点「创建配对码」\n② 家人手机装好胎动后输入同一个码\n③ 之后所有手机联网就自动同步全部记录\n（准爸爸、长辈的手机都可以加，数量不限）")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Pal.ink2)
                    .lineSpacing(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var createCard: some View {
        card {
            Button {
                run { sync.createPairing() }
            } label: {
                Text(running ? "正在创建…" : "创建配对码")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Pal.brand))
            }
            .buttonStyle(.plain)
            .disabled(running)
        }
    }

    private var joinCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("已有配对码？").font(.system(size: 13, weight: .bold)).foregroundStyle(Pal.ink)
                TextField("输入对方的 6 位配对码", text: $joinText)
                    .keyboardType(.numberPad)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Pal.brandSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button {
                    run { sync.joinPairing(joinText) }
                } label: {
                    Text(running ? "正在配对…" : "加入配对")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(joinText.isEmpty ? Pal.ink3.opacity(0.4) : Pal.brand))
                }
                .buttonStyle(.plain)
                .disabled(running || joinText.isEmpty)
            }
        }
    }

    // MARK: 已配对

    private func pairedSection(_ code: String) -> some View {
        VStack(spacing: 14) {
            card {
                VStack(spacing: 6) {
                    Text("配对码").font(.system(size: 12)).foregroundStyle(Pal.ink3)
                    Text(code.chunked(3).joined(separator: " "))
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Pal.brand)
                        .kerning(2)
                    Text("把这个码告诉家人，任何一台手机装好胎动后在「设置 → 配对同步」输入即可加入，数量不限")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Pal.ink3)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .frame(maxWidth: .infinity)
            }

            permissionCard
            if sync.isOwner && !sync.managedDevices.isEmpty {
                deviceManageCard
            }
            syncStatusCard
        }
    }

    // MARK: 权限卡片（创建者可写；加入者默认只读，可申请编辑权限）

    private var permissionCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                if sync.canEdit {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil.and.list.clipboard")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Pal.brand)
                        Text("本机权限：可编辑")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Pal.ink)
                        Spacer()
                    }
                    Text("这台手机可以正常记录胎动和宫缩，改动会同步给所有配对的手机")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Pal.ink3)
                        .lineSpacing(3)
                    requestsList
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "eye")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Pal.ink2)
                        Text("查看模式")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Pal.ink)
                        Spacer()
                    }
                    Text("只能查看同步过来的记录，无法修改对方的数据。想修改请在下面申请编辑权限，对方同意后即可记录。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Pal.ink3)
                        .lineSpacing(3)
                    if hasRequested {
                        Button {
                            confirmCancelRequest = true
                        } label: {
                            Text("已申请，等待对方同意")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Pal.brand)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Pal.brandSoft))
                        }
                        .buttonStyle(.plain)
                        Button {
                            confirmCancelRequest = true
                        } label: {
                            Text("撤销申请")
                                .font(.system(size: 12))
                                .foregroundStyle(Pal.ink3)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            run { sync.requestEditPermission() }
                        } label: {
                            Text("申请编辑权限")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Pal.brand))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 写端看到的待审批列表
    @ViewBuilder
    private var requestsList: some View {
        let reqs = sync.acl?.req ?? []
        if !reqs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("编辑权限申请")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Pal.ink)
                ForEach(reqs, id: \.id) { req in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("设备 \(req.id)")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Pal.ink)
                            Text(reqTime(req.t))
                                .font(.system(size: 10.5))
                                .foregroundStyle(Pal.ink3)
                        }
                        Spacer()
                        Button {
                            run { sync.grantWriter(req.id) }
                        } label: {
                            Text("同意")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Pal.brand))
                        }
                        .buttonStyle(.plain)
                        Button {
                            denyTarget = req.id
                        } label: {
                            Text("忽略")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Pal.ink2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var hasRequested: Bool {
        sync.acl?.req.contains { $0.id == myDeviceID } ?? false
    }

    private var myDeviceID: String { SyncManager.shared.deviceID }

    // MARK: 设备管理卡（只有创建配对码的手机能看到，v5.3）

    private var deviceManageCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Pal.brand)
                    Text("设备管理")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Pal.ink)
                    Spacer()
                }
                Text("单独控制同步给每台手机的内容；也可以强制解绑，或清空对方的数据")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Pal.ink3)
                    .lineSpacing(3)
                ForEach(sync.managedDevices, id: \.self) { dev in
                    deviceRow(dev)
                }
            }
        }
    }

    private func deviceRow(_ dev: String) -> some View {
        let mask = sync.maskFor(dev)
        let kickOn = mask?.k != 0
        let ctnOn = mask?.c != 0
        let setOn = mask?.s != 0
        let weightOn = mask?.w != 0
        return VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Pal.line).frame(height: 1)
            HStack {
                Text("设备 \(dev)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Pal.ink)
                Spacer()
                Text((mask == nil || (kickOn && ctnOn && setOn && weightOn)) ? "全部同步" : "部分同步")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Pal.ink3)
            }
            // 同步范围开关：点一下即切换，约 6 秒内对对方生效
            HStack(spacing: 8) {
                maskChip("胎动", on: kickOn) {
                    run { sync.setShareMask(dev, kick: !kickOn, contraction: ctnOn,
                                            settings: setOn, weight: weightOn) }
                }
                maskChip("宫缩", on: ctnOn) {
                    run { sync.setShareMask(dev, kick: kickOn, contraction: !ctnOn,
                                            settings: setOn, weight: weightOn) }
                }
                maskChip("设置", on: setOn) {
                    run { sync.setShareMask(dev, kick: kickOn, contraction: ctnOn,
                                            settings: !setOn, weight: weightOn) }
                }
                maskChip("体重", on: weightOn) {
                    run { sync.setShareMask(dev, kick: kickOn, contraction: ctnOn,
                                            settings: setOn, weight: !weightOn) }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button {
                    unbindTarget = dev
                } label: {
                    Text("强制解绑")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Pal.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Pal.danger.opacity(0.55), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button {
                    wipeTarget = dev
                } label: {
                    Text("清除数据")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Pal.danger))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func maskChip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(on ? Pal.brand : Pal.ink3)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(on ? Pal.brandSoft : Pal.bg))
            .overlay(Capsule().strokeBorder(Pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func reqTime(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "申请于 " + f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private var syncStatusCard: some View {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("上次同步").font(.system(size: 12.5)).foregroundStyle(Pal.ink2)
                            Text(lastSyncText)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Pal.ink3)
                        }
                        Spacer()
                        if sync.busy || running {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                    if let msg = sync.lastMessage {
                        Text(msg).font(.system(size: 11.5)).foregroundStyle(Pal.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        run { sync.syncNow(manual: true) }
                    } label: {
                        Text(sync.busy || running ? "同步中…" : "立即同步")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Pal.brand))
                    }
                    .buttonStyle(.plain)
                    .disabled(sync.busy || running)

                    Button {
                        run { sync.unlink() }
                    } label: {
                        Text("解除配对")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Pal.danger)
                    }
                    .buttonStyle(.plain)
                    Text("解除后：本机和云端的记录都不会消失，只是不再同步；重新输入配对码可再次加入")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Pal.ink3)
                        .multilineTextAlignment(.center)
                }
    }

    private var lastSyncText: String {
        guard sync.lastSyncAt > 0 else { return "还没同步过" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: sync.lastSyncAt))
    }

    private var notesCard: some View {
        card {
            Text("* 一个配对码可以加到多部手机，大家看到的是同一份记录\n* 权限：创建配对码的手机可编辑；加入的手机默认只能查看，点「申请编辑权限」并等对方同意后才能记录\n* 对方申请编辑权限时，这台手机会弹通知，首页顶部也会出现「点此审批」横幅；点开即可同意或忽略\n* 一台手机记了数据：约 2 秒内自动上传；其他手机开着 App 时约 6 秒内自动拉取，切回 App 会立刻同步\n* 同步内容：胎动、宫缩、体重记录（含轮次、间隔、备注）与共享设置\n* 各自新增的记录都会保留；同一处改动，后改的生效\n* 「撤销上一次」也会同步：对端同一条会被删掉\n* 「清空全部记录」也会同步：所有设备上的对应记录一起清空\n* 解除配对只会停止同步：本机与云端的记录都保留\n* 设备管理（创建者专属）：可单独控制同步给某台手机的胎动 / 宫缩 / 设置 / 体重，也可强制解绑或清空对方的数据；被解绑的设备不能用原码再加入\n* 端到端加密：记录在手机上用配对码加密后才上传，云端只存密文，服务器也读不到内容\n* 配对码就是唯一的钥匙，请只告诉家人")
                .font(.system(size: 11))
                .foregroundStyle(Pal.ink3)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 工具

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func run(_ block: @escaping () -> SyncOutcome) {
        running = true
        DispatchQueue.global().async {
            let outcome = block()
            DispatchQueue.main.async {
                running = false
                withAnimation { toast = outcome.message }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                    withAnimation { toast = nil }
                }
            }
        }
    }
}

extension String {
    func chunked(_ size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map {
            let start = index(startIndex, offsetBy: $0)
            let end = index(start, offsetBy: min(size, count - $0))
            return String(self[start..<end])
        }
    }
}
