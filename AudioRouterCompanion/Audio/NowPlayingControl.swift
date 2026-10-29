import Foundation
import MediaPlayer
import UIKit

/// iOS のロック画面 / コントロールセンター / Dynamic Island の「再生中」
/// 領域に **AudioRouter 送信中** と表示し、**停止ボタン**を提供する。
///
/// Android の Foreground Service 常駐通知 + 停止ボタンに相当する iOS UX。
/// アプリがバックグラウンドでも `AVAudioSession.playAndRecord` を保持する
/// 限りこの「再生中」UI は表示され続け、ユーザは画面ロックしていても
/// 停止できる。
@MainActor
final class NowPlayingControl {
    static let shared = NowPlayingControl()
    private var stopHandler: (() -> Void)?

    /// AudioBridge 起動と同時に呼ぶ。`peerName` は Mac 名。
    func activate(peerName: String, deviceName: String, onStop: @escaping () -> Void) {
        self.stopHandler = onStop
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = "AudioRouter 送信中"
        info[MPMediaItemPropertyArtist] = "\(deviceName) → \(peerName)"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        let cc = MPRemoteCommandCenter.shared()
        // 既存ハンドラ全クリア (重複登録防止)
        cc.stopCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.playCommand.removeTarget(nil)

        cc.stopCommand.isEnabled = true
        cc.stopCommand.addTarget { _ in
            Task { @MainActor in NowPlayingControl.shared.fireStop() }
            return .success
        }
        // 再生ボタン押下は no-op (ステータス維持)
        cc.playCommand.isEnabled = false
        // 一時停止 = 停止扱い
        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { _ in
            Task { @MainActor in NowPlayingControl.shared.fireStop() }
            return .success
        }
    }

    func deactivate() {
        stopHandler = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let cc = MPRemoteCommandCenter.shared()
        cc.stopCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.playCommand.removeTarget(nil)
    }

    private func fireStop() {
        let h = stopHandler
        deactivate()
        h?()
    }
}
