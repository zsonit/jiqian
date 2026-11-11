import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage(PrefKey.edd) private var eddTimestamp: Double = 0
    @AppStorage(PrefKey.windowMin) private var windowMin: Int = 120
    @AppStorage(PrefKey.holdMode) private var holdMode: Bool = false
    @AppStorage(PrefKey.roundMin) private var roundMin: Int = 60
    @AppStorage(PrefKey.sound) private var soundOn: Bool = true
    @AppStorage(PrefKey.soundVolume) private var soundVolume: Double = 1.0
    @AppStorage(PrefKey.haptic) private var hapticOn: Bool = true
    @AppStorage(PrefKey.provider) private var provider: String = ""
    @AppStorage(PrefKey.phone) private var phone: String = ""
    @AppStorage(PrefKey.risks) private var risksRaw: String = ""

    @Environment(\.modelContext) private var context
    @Query private var kickEvents: [KickEvent]
    @Query private var contractions: [ContractionEvent]
    @Query private var weightEntries: [WeightEntry]
    @ObservedObject private var sync = SyncManager.shared

    @State private var showWipeConfirm = false
    @State private var showWipeConfirm2 = false
    // v5.13 备份与恢复
    @State private var backupMsg: String = ""
    @State private var showBackupMsg = false
    @State private var showRestoreBackupConfirm = false
    @State private var showRestoreCloudConfirm = false
    /// 运行日志独立开关（排查用）：默认关，不参与配对同步
    @AppStorage(AppLog.enabledKey) private var diagLogOn: Bool = false

    private var eddBinding: Binding<Date> {
        Binding(
            get: {
                eddTimestamp > 0
                    ? Date(timeIntervalSince1970: eddTimestamp)
                    : Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
            },
            set: { newValue in
                // 查看模式：预产期是两端共享的设置，改不了（要改先申请编辑权限）
                guard sync.canEdit else { return }
                let day = Calendar.current.startOfDay(for: newValue)
                eddTimestamp = day.timeIntervalSince1970
                SharedSettings.touch()
            }
        )
    }

    /// 共享设置的通用绑定：写入后记一次修改时刻并触发同步
    private func sharedBinding<T>(for key: String, _ get: @escaping () -> T) -> Binding<T> {
        Binding(
            get: get,
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: key)
                SharedSettings.touch()
            }
        )
    }

    private var roundMinBinding: Binding<Int> {
        sharedBinding(for: PrefKey.roundMin) { roundMin }
    }

    private var windowMinBinding: Binding<Int> {
        sharedBinding(for: PrefKey.windowMin) { windowMin }
    }

    private var providerBinding: Binding<String> {
        sharedBinding(for: PrefKey.provider) { provider }
    }

    private var phoneBinding: Binding<String> {
        sharedBinding(for: PrefKey.phone) { phone }
    }

    private var riskSet: Set<String> {
        Set(risksRaw.split(separator: ",").map(String.init))
    }

    private var gestationLabel: String {
        guard let gestation = PregnancyClock.gestation(for: eddTimestamp > 0 ? Date(timeIntervalSince1970: eddTimestamp) : nil) else {
            return "未设定"
        }
        return gestation.label
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("预产期", selection: eddBinding, displayedComponents: .date)
                        .disabled(!sync.canEdit)
                    HStack {
                        Text("当前孕周")
                        Spacer()
                        Text(gestationLabel).foregroundStyle(Pal.ink2)
                    }
                    Picker("每轮时长", selection: roundMinBinding) {
                        ForEach([5, 10, 15, 30, 45, 60, 75], id: \.self) { value in
                            Text("\(value) 分钟").tag(value)
                        }
                    }
                    .disabled(!sync.canEdit)
                    Picker("计数窗口", selection: windowMinBinding) {
                        ForEach([60, 120, 180], id: \.self) { value in
                            Text("\(value) 分钟").tag(value)
                        }
                    }
                    .disabled(!sync.canEdit)
                    Toggle("宫缩用按住方式", isOn: $holdMode)
                    Toggle("点击提示音", isOn: $soundOn)
                    Toggle("点击震动", isOn: $hapticOn)
                    if soundOn {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("提示音音量")
                                Spacer()
                                Text("\(Int(round(soundVolume * 100)))%")
                                    .foregroundStyle(Pal.ink2)
                                    .monospacedDigit()
                            }
                            Slider(value: $soundVolume, in: 0...1) { editing in
                                if !editing { Sfx.tap() }
                            }
                        }
                    }
                } header: {
                    Text("孕周与目标")
                } footer: {
                    Text(sync.canEdit
                         ? "预产期、每轮时长、计数窗口都随配对同步：改动后约 6 秒内同步到家人的手机，孕周与摘要按同一套设置算。"
                         : "查看模式下不能改这些设置。要修改请向配对设备申请编辑权限（设置 → 配对同步）。")
                }

                Section("快捷指令") {
                    NavigationLink {
                        ActionsView()
                    } label: {
                        HStack {
                            Image(systemName: "bolt")
                                .foregroundStyle(Pal.brand)
                            Text("桌面快捷指令创建指南")
                            Spacer()
                        }
                    }
                }

                Section {
                    NavigationLink {
                        SyncView()
                    } label: {
                        HStack {
                            Image(systemName: "cloud.fill")
                                .foregroundStyle(Pal.brand)
                            Text("配对同步")
                            Spacer()
                            if pendingCount > 0 {
                                // 有人申请编辑权限：红点角标，进来看得到
                                Text("\(pendingCount) 待审批")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(Capsule().fill(Pal.danger))
                            }
                            Text(syncStatusText)
                                .font(.caption)
                                .foregroundStyle(Pal.ink2)
                        }
                    }
                } header: {
                    Text("同步")
                } footer: {
                    Text("用 6 位配对码把这台手机和家人的手机连起来，记录端到端加密后自动双向同步。不配对则一切只存本机。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        guideLine("1", "长按锁屏空白处 → 自定义 → 锁定屏幕 → 添加小组件")
                        guideLine("2", "在组件列表里搜「胎动」，选「胎动 · 锁屏开关」或「宫缩 · 锁屏开关」")
                        guideLine("3", "桌面组件：长按桌面空白处 → 左上角「+」→ 搜「胎动」→ 选「胎动 / 宫缩 快捷开关」")
                        Text("两个开关各自独立：点「胎动」记一次，点「宫缩」开始计时、再点一下结束保存。点完会直接打开 App 完成记录并给出提示。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Pal.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("锁屏 / 桌面组件")
                } footer: {
                    Text("组件只做入口，记录仍然写在本机（配对时同时加密同步），不会上传到任何第三方。")
                }

                Section("产科联系方式") {
                    TextField("机构名称", text: providerBinding)
                        .textInputAutocapitalization(.never)
                        .disabled(!sync.canEdit)
                    TextField("联系电话", text: phoneBinding)
                        .keyboardType(.phonePad)
                        .disabled(!sync.canEdit)
                }

                Section {
                    ForEach(Prefs.allRisks, id: \.self) { tag in
                        Toggle(tag, isOn: binding(for: tag))
                            .disabled(!sync.canEdit)
                    }
                } header: {
                    Text("高风险因素")
                } footer: {
                    Text(sync.canEdit
                         ? "勾选不代表有问题，只是让提示更早出现。是否属于高危，以你的产科医生判断为准。勾选状态随配对同步。"
                         : "查看模式下不能改，勾选状态由可编辑端同步过来。")
                }

                Section {
                    HStack {
                        Text("胎动记录")
                        Spacer()
                        Text("\(kickEvents.count) 条").foregroundStyle(Pal.ink2)
                    }
                    HStack {
                        Text("宫缩记录")
                        Spacer()
                        Text("\(contractions.filter { $0.endedAt != nil }.count) 次").foregroundStyle(Pal.ink2)
                    }
                    if sync.canEdit {
                        Button(role: .destructive) {
                            showWipeConfirm = true
                        } label: {
                            Text("清空全部记录")
                        }
                    } else {
                        // 查看模式：数据是同步来的，清空入口整个不出现，防误触
                        Text("查看模式：记录由配对设备同步而来，不能在这里清空")
                            .font(.footnote)
                            .foregroundStyle(Pal.ink2)
                    }
                } header: {
                    Text("数据")
                } footer: {
                    Text(sync.canEdit
                         ? "不配对时全部数据只存在这台设备上，没有账号，也不会上传。卸载应用即删除。开启配对同步后，记录会在你的配对设备间加密同步。"
                         : "查看模式下没有清空入口；需要清空请在可编辑的那台手机上操作（会同步删除所有配对设备的记录）。")
                }

                if sync.canEdit {
                    Section {
                        HStack {
                            Text("上次备份")
                            Spacer()
                            Text("\(backupTimeText) · \(BackupManager.fileSizeText())").foregroundStyle(Pal.ink2)
                        }
                        Button {
                            backupMsg = BackupManager.backupNow()
                            showBackupMsg = true
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.down").foregroundStyle(Pal.brand)
                                Text("立即备份")
                            }
                        }
                        if BackupManager.hasBackup {
                            ShareLink(item: BackupManager.fileURL) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up").foregroundStyle(Pal.brand)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("导出备份文件")
                                        Text("存到「文件」、发微信或存到电脑")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Pal.ink3)
                                    }
                                }
                            }
                        }
                        HStack {
                            Text("备份位置")
                            Spacer()
                            Text("「文件」App → 我的 iPhone → 胎动记录 → 备份")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Pal.ink2)
                                .multilineTextAlignment(.trailing)
                        }
                        Button(role: .destructive) {
                            showRestoreBackupConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Pal.brand)
                                Text("从备份恢复")
                            }
                        }
                        Button(role: .destructive) {
                            showRestoreCloudConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "icloud.and.arrow.down").foregroundStyle(Pal.brand)
                                Text("从云端恢复")
                            }
                        }
                    } header: {
                        Text("备份与恢复")
                    } footer: {
                        Text("每天自动备份 3 次（8 小时一次），只保留最新一份。备份文件可以直接用系统「文件」App 打开查看、拷到电脑或发给别人。误清空/误删后可一键恢复：恢复会用备份或云端的数据整体重置本机记录，可写端还会把恢复的数据推回云端。")
                    }
                }

                Section {
                    Toggle("运行日志（排查用）", isOn: $diagLogOn)
                        .onChange(of: diagLogOn) { _, on in
                            // 开关走 @AppStorage 不经过 AppLog.isEnabled，这里补一条记录
                            if on { AppLog.i("Log", "运行日志已开启") } else { AppLog.clear() }
                        }
                    if diagLogOn {
                        NavigationLink {
                            LogView()
                        } label: {
                            HStack {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .foregroundStyle(Pal.brand)
                                Text("查看日志")
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("运行日志")
                } footer: {
                    Text("打开后 App 会把同步、配对等关键动作记进本机日志（最近 600 条），排查问题时可在日志页复制全部，或导出成 txt 文件发给开发者。日志只存在这台手机的内存里，不落盘、不同步、不上传；关闭开关即清空。")
                }

                Section {
                    Text("胎动 v\(appVersion) · 本地优先，无账号、无上传、无广告。")
                        .font(.footnote)
                        .foregroundStyle(Pal.ink2)
                    Text("规则阈值仅用于教育提示与联系触发，不替代医生评估；实际随访与入院方案以建档机构指示为准。")
                        .font(.footnote)
                        .foregroundStyle(Pal.ink2)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            // 两道确认：先提醒会删什么，再给一次无法挽回的最后确认
            .confirmationDialog("清空全部记录？", isPresented: $showWipeConfirm, titleVisibility: .visible) {
                Button("继续", role: .destructive) { showWipeConfirm2 = true }
                Button("取消", role: .cancel) {}
            } message: {
                Text("本机的胎动、宫缩与体重记录都会被删除，无法恢复。")
            }
            .confirmationDialog("最后确认一次", isPresented: $showWipeConfirm2, titleVisibility: .visible) {
                Button("彻底清空，无法恢复", role: .destructive) { wipe() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除胎动 \(kickEvents.count) 条、宫缩 \(contractions.filter { $0.endedAt != nil }.count) 次、体重 \(weightEntries.count) 条，包括轮次和间隔信息，删除后无法找回。")
            }
            .confirmationDialog("从备份恢复？", isPresented: $showRestoreBackupConfirm, titleVisibility: .visible) {
                Button("恢复", role: .destructive) {
                    backupMsg = BackupManager.restoreFromBackup()
                    showBackupMsg = true
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("本机当前记录会被整体替换为备份时的数据（胎动/宫缩/体重全部以备份为准），可写端会把恢复的数据推回云端。")
            }
            .confirmationDialog("从云端恢复？", isPresented: $showRestoreCloudConfirm, titleVisibility: .visible) {
                Button("恢复", role: .destructive) {
                    backupMsg = sync.restoreFromCloud()
                    showBackupMsg = true
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("本机当前记录会被整体替换为云端当前的数据。适合误触「清空全部记录」后把数据救回来。")
            }
            .alert("备份与恢复", isPresented: $showBackupMsg) {
                Button("好", role: .cancel) {}
            } message: {
                Text(backupMsg)
            }
        }
    }

    private var backupTimeText: String {
        guard let d = BackupManager.lastBackupAt() else { return "还没有备份" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.1"
    }

    private var syncStatusText: String {
        if let code = sync.pairedCode {
            return sync.canEdit ? "已配对 \(code.prefix(3))···" : "已配对 \(code.prefix(3))···（查看）"
        }
        return "未配对"
    }

    /// 组件添加步骤的一行：序号圆点 + 说明
    private func guideLine(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Pal.brand))
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Pal.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// 待我审批的编辑权限申请数量（只读端没有审批权，不显示）
    private var pendingCount: Int {
        guard sync.canEdit else { return 0 }
        return sync.acl?.req.count ?? 0
    }

    private func binding(for tag: String) -> Binding<Bool> {
        Binding(
            get: { riskSet.contains(tag) },
            set: { isOn in
                guard sync.canEdit else { return }
                var set = riskSet
                if isOn { set.insert(tag) } else { set.remove(tag) }
                risksRaw = Prefs.allRisks.filter { set.contains($0) }.joined(separator: ",")
                SharedSettings.touch()
            }
        )
    }

    private func wipe() {
        // 查看模式：不能清空同步来的数据
        guard sync.canEdit else { return }
        for event in kickEvents { context.delete(event) }
        for event in contractions { context.delete(event) }
        for entry in weightEntries { context.delete(entry) }
        if let sessions = try? context.fetch(FetchDescriptor<KickSession>()) {
            for session in sessions { context.delete(session) }
        }
        if let sessions = try? context.fetch(FetchDescriptor<ContractionSession>()) {
            for session in sessions { context.delete(session) }
        }
        try? context.save()
        // 清空也要跨端生效：写清空时间戳，对端锚点早于它的记录一并删除
        SyncManager.markCleared()
        SyncManager.shared.onDataChanged()
        Haptic.success()
    }
}
