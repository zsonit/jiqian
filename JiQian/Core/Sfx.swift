import AudioToolbox
import Foundation

/// 点击提示音：使用 iOS 系统音效，无需打包音频文件，跟随静音拨片。
enum Sfx {
    static func tap() {
        guard Prefs.soundOn else { return }
        AudioServicesPlaySystemSound(1104) // 短促的 tick
    }

    static func success() {
        guard Prefs.soundOn else { return }
        AudioServicesPlaySystemSound(1025) // 轻快的「叮」
    }
}
