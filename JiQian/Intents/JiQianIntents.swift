import Foundation
import AppIntents
import SwiftData

// MARK: - 记一次胎动

struct RecordKickIntent: AppIntent {
    static var title: LocalizedStringResource = "记一次胎动"
    static var description: IntentDescription? = IntentDescription("立刻记录一次胎动，不需要打开应用。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = try await MainActor.run { () throws -> KickOutcome in
            try KickRecorder.record(source: .shortcut)
        }
        if outcome.duplicate {
            let text = "这看起来是重复点按，没有重复记录。"
            return .result(dialog: "\(text)")
        }
        let remaining = max(0, outcome.target - outcome.count)
        let suffix = outcome.count >= outcome.target ? "已达到本轮目标。" : "距目标还差 \(remaining) 次。"
        let text = "已记录一次胎动，本轮第 \(outcome.count) 次。" + suffix
        return .result(dialog: "\(text)")
    }
}

// MARK: - 开始数胎动

struct StartKickCountIntent: AppIntent {
    static var title: LocalizedStringResource = "开始数胎动"
    static var description: IntentDescription? = IntentDescription("开始一轮新的胎动计数。")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try await MainActor.run { () throws -> Int in
            try KickRecorder.startNewSession(source: .shortcut).targetCount
        }
        let text = "已开始新一轮胎动计数，目标 \(target) 次。"
        return .result(dialog: "\(text)")
    }
}

// MARK: - 宫缩：开始 / 结束（一个动作两个状态）

enum ContractionStep: Sendable {
    case started
    case ended(duration: TimeInterval, gap: TimeInterval)
    case busy
}

struct ToggleContractionIntent: AppIntent {
    static var title: LocalizedStringResource = "宫缩开始或结束"
    static var description: IntentDescription? = IntentDescription("没有在计时就开始，正在计时就结束。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let step = try await MainActor.run { () throws -> ContractionStep in
            let context = JiQianStore.context
            let open = (try? ContractionRecorder.openEvent(in: context)) ?? nil
            if open != nil {
                let outcome = try ContractionRecorder.end()
                return .ended(duration: outcome.duration, gap: outcome.gap)
            }
            let outcome = try ContractionRecorder.start(source: .shortcut)
            return outcome.started ? .started : .busy
        }

        switch step {
        case .started:
            let text = "已开始宫缩计时。结束时再触发一次即可保存。本应用不做任何医学判断。"
            return .result(dialog: "\(text)")
        case let .ended(duration, gap):
            let gapText = gap > 0 ? "，与上次间隔 \(Fmt.clock(gap))" : ""
            let text = "已保存本次收缩，持续 \(Fmt.clock(duration))" + gapText + "。"
            return .result(dialog: "\(text)")
        case .busy:
            let text = "计时状态异常，请打开胎动确认。"
            return .result(dialog: "\(text)")
        }
    }
}

// MARK: - 明确开始

struct StartContractionIntent: AppIntent {
    static var title: LocalizedStringResource = "开始宫缩计时"
    static var description: IntentDescription? = IntentDescription("开始记录一次宫缩的起始时间。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started = try await MainActor.run { () throws -> Bool in
            try ContractionRecorder.start(source: .shortcut).started
        }
        let text = started ? "已开始宫缩计时。" : "已经有一次宫缩在计时，本次没有重复开始。"
        return .result(dialog: "\(text)")
    }
}

// MARK: - 明确结束

struct EndContractionIntent: AppIntent {
    static var title: LocalizedStringResource = "结束宫缩计时"
    static var description: IntentDescription? = IntentDescription("结束当前这次宫缩并保存。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let step = try await MainActor.run { () throws -> ContractionStep in
            let context = JiQianStore.context
            let open = (try? ContractionRecorder.openEvent(in: context)) ?? nil
            guard open != nil else { return .busy }
            let outcome = try ContractionRecorder.end()
            return .ended(duration: outcome.duration, gap: outcome.gap)
        }
        switch step {
        case let .ended(duration, gap):
            let gapText = gap > 0 ? "，与上次间隔 \(Fmt.clock(gap))" : ""
            let text = "已保存本次收缩，持续 \(Fmt.clock(duration))" + gapText + "。"
            return .result(dialog: "\(text)")
        default:
            let text = "当前没有正在进行的宫缩计时。"
            return .result(dialog: "\(text)")
        }
    }
}

// MARK: - 打开摘要

struct OpenSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "打开就诊摘要"
    static var description: IntentDescription? = IntentDescription("打开可以直接念给医生的记录摘要。")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

// MARK: - 注册到系统（Siri / 快捷指令 / 聚焦搜索）

struct JiQianShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordKickIntent(),
            phrases: [
                "\(.applicationName)记一笔",
                "\(.applicationName)记一次胎动",
                "\(.applicationName)胎动加一"
            ],
            shortTitle: "记一次胎动",
            systemImageName: "waveform.path.ecg"
        )
        AppShortcut(
            intent: StartKickCountIntent(),
            phrases: [
                "\(.applicationName)开始计数",
                "\(.applicationName)开始数胎动"
            ],
            shortTitle: "开始数胎动",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: ToggleContractionIntent(),
            phrases: [
                "\(.applicationName)记录宫缩",
                "\(.applicationName)宫缩开始或结束"
            ],
            shortTitle: "宫缩开始 / 结束",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: EndContractionIntent(),
            phrases: [
                "\(.applicationName)结束宫缩",
                "\(.applicationName)结束宫缩计时"
            ],
            shortTitle: "结束宫缩",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: OpenSummaryIntent(),
            phrases: [
                "\(.applicationName)打开就诊摘要",
                "\(.applicationName)就诊摘要"
            ],
            shortTitle: "就诊摘要",
            systemImageName: "doc.text"
        )
    }
}
