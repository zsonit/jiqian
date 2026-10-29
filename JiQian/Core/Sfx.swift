import AVFoundation
import Foundation

/// 点击提示音：使用打包的自定义 WAV，AVAudioPlayer 播放，
/// 音量跟随设置里的「提示音音量」滑杆；会话类别为 ambient，跟随静音拨片。
enum Sfx {
    private static let session: AVAudioSession = {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.ambient, options: [.mixWithOthers])
        try? s.setActive(true)
        return s
    }()

    private static func player(_ name: String) -> AVAudioPlayer? {
        _ = session
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        return try? AVAudioPlayer(contentsOf: url)
    }

    private static let tapPlayer = player("tap")
    private static let chimePlayer = player("chime")

    private static func play(_ p: AVAudioPlayer?) {
        guard Prefs.soundOn else { return }
        guard let p else { return }
        p.volume = Float(Prefs.soundVolume)
        p.currentTime = 0
        p.play()
    }

    static func tap() { play(tapPlayer) }
    static func success() { play(chimePlayer) }
}
