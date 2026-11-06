import SwiftUI
import SwiftData

/// 体重记录页：只记「什么时候称、多少公斤」。
/// 不出现任何「增重过多/过少」之类的评价，也不做健康判断。
struct WeightView: View {
    @Query(sort: \WeightEntry.at, order: .forward) private var entries: [WeightEntry]
    @ObservedObject private var sync = SyncManager.shared
    @AppStorage(PrefKey.edd) private var eddStamp: Double = 0

    @State private var input: String = ""
    @State private var day: Date = Date()
    @State private var toast: String?
    @State private var deleteTarget: WeightEntry?
    @State private var confirmClear = false
    @FocusState private var typing: Bool

    private var stats: WeightStats { WeightRecorder.stats(entries) }

    private var gestation: String? {
        guard eddStamp > 0 else { return nil }
        return PregnancyClock.gestation(for: Date(timeIntervalSince1970: eddStamp))?.label
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryCard
                if entries.count >= 2 { chartCard }
                inputCard
                listCard
                Text("只记录称重的时间和公斤数，供你和产科沟通时参考。本应用不对体重做任何评价或建议。")
                    .font(.system(size: 12))
                    .foregroundStyle(Pal.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Pal.card2)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Pal.line, lineWidth: 1))
                DisclaimerCard()
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background(Pal.bg.ignoresSafeArea())
        .navigationTitle("⚖️ 体重记录")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if input.isEmpty, let latest = stats.latest {
                input = WeightRecorder.text(latest.kg)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Pal.teal.opacity(0.96)))
                    .shadow(color: Pal.teal.opacity(0.3), radius: 12, x: 0, y: 5)
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("删除这条记录？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget { performDelete(target) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("配对的手机会同步删掉同一条记录。")
        }
    }

    // MARK: 概况

    private var summaryCard: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("最近一次")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(Pal.ink3)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(stats.latest.map { WeightRecorder.text($0.kg) } ?? "—")
                                .font(.system(size: 38, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Pal.teal)
                            Text("kg")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Pal.ink2)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if let gained = stats.gained {
                            HStack(spacing: 4) {
                                Text("较首次")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Pal.ink3)
                                Text("\(WeightRecorder.deltaText(gained)) kg")
                                    .font(.system(size: 13, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(gained >= 0 ? Pal.teal : Pal.gold)
                            }
                        }
                        Text("共 \(stats.count) 次记录")
                            .font(.system(size: 11))
                            .foregroundStyle(Pal.ink3)
                        if let gestation {
                            Text("孕 \(gestation)")
                                .font(.system(size: 11))
                                .foregroundStyle(Pal.ink3)
                        }
                    }
                }
                Text(stats.latest.map { "最近记录：\(Fmt.longDate($0.at)) \(Fmt.hhmm($0.at))" }
                     ?? "还没有记录，把今天称的数字填到下面就行")
                    .font(.system(size: 12))
                    .foregroundStyle(Pal.ink2)
            }
        }
    }

    // MARK: 曲线

    private var chartPoints: [(date: Date, kg: Double)] {
        entries.suffix(30).map { (date: $0.at, kg: $0.kg) }
    }

    private var chartCard: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("体重变化")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Pal.ink)
                    Spacer()
                    Text("最近 \(chartPoints.count) 次")
                        .font(.system(size: 11))
                        .foregroundStyle(Pal.ink3)
                }
                WeightChart(points: chartPoints)
                HStack {
                    Text(chartPoints.first.map { "\(Fmt.md($0.date)) · \(WeightRecorder.text($0.kg))" } ?? "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Pal.ink3)
                    Spacer()
                    Text(chartPoints.last.map { "\(Fmt.md($0.date)) · \(WeightRecorder.text($0.kg))" } ?? "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Pal.ink3)
                }
            }
        }
    }

    // MARK: 录入

    private var inputCard: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("记一次体重")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Pal.ink)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("例如 62.4", text: $input)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 30, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Pal.ink)
                        .focused($typing)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Pal.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text("kg")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Pal.ink2)
                }
                HStack(spacing: 8) {
                    stepChip("-0.5") { adjust(-0.5) }
                    stepChip("-0.1") { adjust(-0.1) }
                    stepChip("+0.1") { adjust(0.1) }
                    stepChip("+0.5") { adjust(0.5) }
                    Spacer()
                }
                DatePicker("称重日期", selection: $day, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .font(.system(size: 13))
                    .tint(Pal.teal)
                Button(action: save) {
                    Text(sync.canEdit ? "记录这次体重" : "查看模式不能记录")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 48)
                        .background(sync.canEdit ? Pal.teal : Pal.ink3)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!sync.canEdit)
                if !sync.canEdit {
                    Text("这台手机是查看模式：体重记录由可编辑的手机同步过来。想自己记录请在「设置 → 配对同步」申请编辑权限。")
                        .font(.system(size: 11))
                        .foregroundStyle(Pal.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func stepChip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Pal.teal)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Capsule().fill(Pal.tealSoft))
                .overlay(Capsule().strokeBorder(Pal.teal.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: 列表

    private struct Row: Identifiable {
        var id: UUID
        var entry: WeightEntry
        var delta: Double?
    }

    private var rows: [Row] {
        Array(entries.enumerated().map { index, entry in
            Row(id: entry.id,
                entry: entry,
                delta: index > 0 ? entry.kg - entries[index - 1].kg : nil)
        }.reversed())
    }

    private var listCard: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("全部记录")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Pal.ink)
                    Spacer()
                    if !entries.isEmpty && sync.canEdit {
                        Button { confirmClear = true } label: {
                            Text("清空")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Pal.danger)
                        }
                        .buttonStyle(.plain)
                        .alert("清空全部体重记录？", isPresented: $confirmClear) {
                            Button("清空", role: .destructive) { performClear() }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("本机与配对手机上的体重记录都会被删除，无法恢复。胎动、宫缩记录不受影响。")
                        }
                    }
                }
                if entries.isEmpty {
                    Text("还没有记录")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Pal.ink2)
                        .padding(.top, 10)
                }
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.longDate(row.entry.at))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Pal.ink)
                            Text(Fmt.hhmm(row.entry.at))
                                .font(.system(size: 11))
                                .foregroundStyle(Pal.ink3)
                        }
                        Spacer()
                        if let delta = row.delta, abs(delta) >= 0.05 {
                            Text("\(WeightRecorder.deltaText(delta))")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(delta > 0 ? Pal.teal : Pal.gold)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Pal.tealSoft))
                        }
                        Text(WeightRecorder.text(row.entry.kg))
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Pal.ink)
                        Text("kg")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Pal.ink3)
                        if sync.canEdit {
                            Button { deleteTarget = row.entry } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Pal.ink3.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 2)
                        }
                    }
                    .padding(.vertical, 9)
                    Rectangle().fill(Pal.line).frame(height: 1)
                }
            }
        }
    }

    // MARK: 动作

    private func adjust(_ delta: Double) {
        let base = Double(input.replacingOccurrences(of: "，", with: ".").replacingOccurrences(of: ",", with: ".")) ?? stats.latest?.kg ?? 0
        guard base > 0 else { return }
        let next = min(max(base + delta, WeightRecorder.minKg), WeightRecorder.maxKg)
        input = WeightRecorder.text(next)
    }

    private func save() {
        let raw = input.replacingOccurrences(of: "，", with: ".").replacingOccurrences(of: ",", with: ".")
        guard let kg = Double(raw), kg >= WeightRecorder.minKg, kg <= WeightRecorder.maxKg else {
            show("请填 30–200 之间的公斤数")
            return
        }
        // 选的是今天就用当下时刻；选了过去某天就保留现在的钟点，方便回填
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        let now = cal.dateComponents([.hour, .minute], from: Date())
        comps.hour = now.hour
        comps.minute = now.minute
        let at = cal.date(from: comps) ?? day
        do {
            if try WeightRecorder.record(kg: kg, at: at) != nil {
                typing = false
                day = Date()
                show("已记录 \(WeightRecorder.text(kg)) kg")
                Haptic.success()
            } else {
                show("查看模式不能记录")
            }
        } catch {
            AppLog.e("Weight", "保存失败：\(error)")
            show("保存失败，请再试一次")
        }
    }

    private func performDelete(_ entry: WeightEntry) {
        do {
            if try WeightRecorder.delete(entry) { show("已删除") }
            else { show("查看模式不能删除") }
        } catch {
            AppLog.e("Weight", "删除失败：\(error)")
            show("删除失败，请再试一次")
        }
    }

    private func performClear() {
        do {
            try WeightRecorder.clearAll()
            show("体重记录已清空")
        } catch {
            AppLog.e("Weight", "清空失败：\(error)")
            show("清空失败，请再试一次")
        }
    }

    private func show(_ text: String) {
        withAnimation(.easeOut(duration: 0.18)) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }
}

// MARK: - 折线（自己画，避免引入额外框架）

private struct WeightChart: View {
    let points: [(date: Date, kg: Double)]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let values = points.map(\.kg)
            let lo = floor(((values.min() ?? 0) - 0.4) * 2) / 2
            let hi = ceil(((values.max() ?? 0) + 0.4) * 2) / 2
            let span = max(hi - lo, 0.5)
            let t0 = points.first?.date.timeIntervalSince1970 ?? 0
            let t1 = points.last?.date.timeIntervalSince1970 ?? 1
            let spanT = max(t1 - t0, 1)

            ZStack(alignment: .topLeading) {
                ForEach(0..<3, id: \.self) { i in
                    Path { p in
                        let y = h * CGFloat(i) / 2
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(Pal.line, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                Path { p in
                    for (i, item) in points.enumerated() {
                        let pt = position(item, w: w, h: h, lo: lo, span: span, t0: t0, spanT: spanT)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(LinearGradient(colors: [Pal.teal.opacity(0.75), Pal.brand.opacity(0.9)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                ForEach(points.indices, id: \.self) { i in
                    let item = points[i]
                    Circle()
                        .fill(Pal.card)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Pal.teal, lineWidth: 1.8))
                        .position(position(item, w: w, h: h, lo: lo, span: span, t0: t0, spanT: spanT))
                }
            }
        }
        .frame(height: 130)
    }

    private func position(_ item: (date: Date, kg: Double),
                          w: CGFloat, h: CGFloat,
                          lo: Double, span: Double,
                          t0: TimeInterval, spanT: TimeInterval) -> CGPoint {
        let x = w * CGFloat((item.date.timeIntervalSince1970 - t0) / spanT)
        let y = h * CGFloat(1 - (item.kg - lo) / span)
        return CGPoint(x: min(max(x, 3), max(w - 3, 3)),
                       y: min(max(y, 4), max(h - 4, 4)))
    }
}
