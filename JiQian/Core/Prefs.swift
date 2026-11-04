import Foundation

enum PrefKey {
    static let target = "kickTarget"
    static let windowMin = "kickWindowMinutes"
    static let holdMode = "contractionHoldMode"
    static let edd = "eddTimestamp"
    /// 共享设置的最后修改时间（毫秒）。预产期、每轮时长、计数窗口、高风险因素、
    /// 产科联系方式都会随配对同步，靠它判断哪一端最新
    static let eddT = "eddUpdatedAt"
    static let provider = "providerName"
    static let phone = "providerPhone"
    static let risks = "highRiskTags"
    static let sound = "tapSoundEnabled"
    static let soundVolume = "tapSoundVolume"
    static let haptic = "tapHapticEnabled"
    static let roundMin = "kickRoundMinutes"
}

/// 设置项统一走 UserDefaults，视图侧用 @AppStorage 双向绑定，
/// 意图侧直接读取，保证 Siri 记录时用的是同一套参数。
enum Prefs {
    static var target: Int {
        let v = UserDefaults.standard.integer(forKey: PrefKey.target)
        return v > 0 ? v : 10
    }

    static var windowMin: Int {
        let v = UserDefaults.standard.integer(forKey: PrefKey.windowMin)
        return v > 0 ? v : 120
    }

    static var holdMode: Bool {
        UserDefaults.standard.bool(forKey: PrefKey.holdMode)
    }

    /// 每轮时长（分钟），默认 60，可选 5/10/15/30/45/60/75
    static var roundMin: Int {
        let v = UserDefaults.standard.integer(forKey: PrefKey.roundMin)
        return [5, 10, 15, 30, 45, 60, 75].contains(v) ? v : 60
    }

    static var edd: Date? {
        let t = UserDefaults.standard.double(forKey: PrefKey.edd)
        guard t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    static var provider: String {
        UserDefaults.standard.string(forKey: PrefKey.provider) ?? ""
    }

    static var phone: String {
        UserDefaults.standard.string(forKey: PrefKey.phone) ?? ""
    }

    static var risks: [String] {
        let raw = UserDefaults.standard.string(forKey: PrefKey.risks) ?? ""
        guard !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map(String.init)
    }

    static var soundOn: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: PrefKey.sound) == nil { return true } // 默认开
        return d.bool(forKey: PrefKey.sound)
    }

    static var hapticOn: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: PrefKey.haptic) == nil { return true } // 默认开
        return d.bool(forKey: PrefKey.haptic)
    }

    /// 提示音音量 0...1，默认拉满
    static var soundVolume: Double {
        let d = UserDefaults.standard
        if d.object(forKey: PrefKey.soundVolume) == nil { return 1.0 }
        return min(1.0, max(0.0, d.double(forKey: PrefKey.soundVolume)))
    }

    static let allRisks = [
        "孕周不足 37 周",
        "多胎",
        "既往早产或急产",
        "已计划剖宫产",
        "胎动异常史",
        "曾有出血"
    ]
}

/// 随配对同步的共享设置（预产期、每轮时长、计数窗口、高风险因素、产科联系方式）。
/// 界面改动统一走 touch()：记一次修改时刻并触发同步；查看模式下直接挡住。
enum SharedSettings {
    static func touch() {
        guard SyncManager.shared.canEdit else { return }
        let d = UserDefaults.standard
        let prev = d.double(forKey: PrefKey.eddT)
        // +1ms 兜底：同一毫秒连改两次也不会被判成「没变」
        d.set(max(Date().timeIntervalSince1970 * 1000, prev + 1), forKey: PrefKey.eddT)
        SyncManager.shared.onDataChanged()
    }
}
