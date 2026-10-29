import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage(PrefKey.edd) private var eddTimestamp: Double = 0
    @AppStorage(PrefKey.target) private var target: Int = 10
    @AppStorage(PrefKey.windowMin) private var windowMin: Int = 120
    @AppStorage(PrefKey.holdMode) private var holdMode: Bool = false
    @AppStorage(PrefKey.provider) private var provider: String = ""
    @AppStorage(PrefKey.phone) private var phone: String = ""
    @AppStorage(PrefKey.risks) private var risksRaw: String = ""

    @Environment(\.modelContext) private var context
    @Query private var kickEvents: [KickEvent]
    @Query private var contractions: [ContractionEvent]

    @State private var showWipeConfirm = false

    private var eddBinding: Binding<Date> {
        Binding(
            get: {
                eddTimestamp > 0
                    ? Date(timeIntervalSince1970: eddTimestamp)
                    : Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
            },
            set: { eddTimestamp = $0.timeIntervalSince1970 }
        )
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
                Section("孕周与目标") {
                    DatePicker("预产期", selection: eddBinding, displayedComponents: .date)
                    HStack {
                        Text("当前孕周")
                        Spacer()
                        Text(gestationLabel).foregroundStyle(Pal.ink2)
                    }
                    Picker("每轮目标", selection: $target) {
                        ForEach([6, 8, 10, 12, 14], id: \.self) { value in
                            Text("\(value) 次").tag(value)
                        }
                    }
                    Picker("计数窗口", selection: $windowMin) {
                        ForEach([60, 120, 180], id: \.self) { value in
                            Text("\(value) 分钟").tag(value)
                        }
                    }
                    Toggle("宫缩用按住方式", isOn: $holdMode)
                }

                Section("产科联系方式") {
                    TextField("机构名称", text: $provider)
                        .textInputAutocapitalization(.never)
                    TextField("联系电话", text: $phone)
                        .keyboardType(.phonePad)
                }

                Section {
                    ForEach(Pref.allRisks, id: \.self) { tag in
                        Toggle(tag, isOn: binding(for: tag))
                    }
                } header: {
                    Text("高风险因素")
                } footer: {
                    Text("勾选不代表有问题，只是让提示更早出现。是否属于高危，以你的产科医生判断为准。")
                }

                Section {
                    HStack {
                        Text("胎动事件")
                        Spacer()
                        Text("\(kickEvents.count) 条").foregroundStyle(Pal.ink2)
                    }
                    HStack {
                        Text("宫缩记录")
                        Spacer()
                        Text("\(contractions.filter { $0.endedAt != nil }.count) 次").foregroundStyle(Pal.ink2)
                    }
                    Button(role: .destructive) {
                        showWipeConfirm = true
                    } label: {
                        Text("清空全部记录")
                    }
                } header: {
                    Text("数据")
                } footer: {
                    Text("全部数据只存在这台设备上，没有账号，也不会上传。卸载应用即删除。")
                }

                Section {
                    Text("记签 1.0 · 本地优先，无账号、无上传、无广告。")
                        .font(.footnote)
                        .foregroundStyle(Pal.ink2)
                    Text("规则阈值仅用于教育提示与联系触发，不替代医生评估；实际随访与入院方案以建档机构指示为准。")
                        .font(.footnote)
                        .foregroundStyle(Pal.ink2)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("清空全部记录？", isPresented: $showWipeConfirm, titleVisibility: .visible) {
                Button("确认清空", role: .destructive) { wipe() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("本机的胎动与宫缩记录都会被删除，无法恢复。")
            }
        }
    }

    private func binding(for tag: String) -> Binding<Bool> {
        Binding(
            get: { riskSet.contains(tag) },
            set: { isOn in
                var set = riskSet
                if isOn { set.insert(tag) } else { set.remove(tag) }
                risksRaw = Pref.allRisks.filter { set.contains($0) }.joined(separator: ",")
            }
        )
    }

    private func wipe() {
        for event in kickEvents { context.delete(event) }
        for event in contractions { context.delete(event) }
        if let sessions = try? context.fetch(FetchDescriptor<KickSession>()) {
            for session in sessions { context.delete(session) }
        }
        if let sessions = try? context.fetch(FetchDescriptor<ContractionSession>()) {
            for session in sessions { context.delete(session) }
        }
        try? context.save()
        Haptic.success()
    }
}
