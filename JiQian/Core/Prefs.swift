import Foundation

enum PrefKey {
    static let target = "kickTarget"
    static let windowMin = "kickWindowMinutes"
    static let holdMode = "contractionHoldMode"
    static let edd = "eddTimestamp"
    static let provider = "providerName"
    static let phone = "providerPhone"
    static let risks = "highRiskTags"
    static let sound = "tapSoundEnabled"
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

    static let allRisks = [
        "孕周不足 37 周",
        "多胎",
        "既往早产或急产",
        "已计划剖宫产",
        "胎动异常史",
        "曾有出血"
    ]
}
