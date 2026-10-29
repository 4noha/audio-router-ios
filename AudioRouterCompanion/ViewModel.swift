import Foundation
import Network
import Combine
import UIKit

/// SwiftUI と protocol/audio 層の橋渡し。Bonjour 発見 → PING 検証 →
/// AudioBridge への自動接続を担う。Android `MainActivity` 相当の責務。
@available(iOS 17.0, *)
@MainActor
final class ViewModel: ObservableObject {
    struct Peer: Hashable, Identifiable {
        let id: String        // "host:port"
        let name: String
        let host: NWEndpoint.Host
        let port: NWEndpoint.Port
    }

    @Published var peers: [Peer] = []
    @Published var selectedPeerID: String? = nil
    @Published var status: String = "未接続"
    @Published var deviceName: String = ViewModel.defaultDeviceName()

    /// 1) hostname (Bonjour 由来、`Takuyas-iPhone.local` 等) があればそれ
    /// 2) フォールバック: `UIDevice.current.name` + identifierForVendor 末4桁
    /// iOS 16+ で UIDevice.name は機種名のみに制限されているため複合戦略。
    /// Android 版同様、ユーザ手動編集は提供しない（自動取得のみ）。
    static func defaultDeviceName() -> String {
        let host = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .trimmingCharacters(in: .whitespaces)
        let generic = ["", "localhost", "iphone", "ipad", "ipod"]
        if !host.isEmpty && !generic.contains(host.lowercased()) {
            return host
        }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? "0000"
        let suffix = String(id.suffix(4))
        return "\(UIDevice.current.name)-\(suffix)"
    }
    @Published var paired: Bool = false
    @Published var assignedSlot: UInt8 = 0
    private var browser: BonjourBrowser?
    private var verifier: PingVerifier?
    private var bridge: AudioBridge?

    func onAppear() {
        if browser != nil { return }
        let v = PingVerifier()
        verifier = v
        v.start { [weak self] verified in
            DispatchQueue.main.async { self?.refreshPeers(verified) }
        }
        let b = BonjourBrowser()
        browser = b
        b.start(
            onResolved: { [weak self] name, host, port in
                self?.verifier?.addCandidate(name: name, host: host, port: port)
            },
            onLost: { [weak self] name in
                self?.verifier?.removeCandidate(name: name)
            }
        )
    }

    func rescan() {
        bridge?.stop(); bridge = nil
        verifier?.stop()
        browser?.stop()
        browser = nil
        verifier = nil
        peers.removeAll()
        selectedPeerID = nil
        paired = false; assignedSlot = 0
        status = "再スキャン中…"
        onAppear()
    }

    func onDisappear() {
        // バックグラウンドでも継続するので Bridge は停止しない（明示停止のみ）。
    }

    func stopBridge() {
        bridge?.stop(); bridge = nil
        paired = false
        assignedSlot = 0
        status = "未接続"
        NowPlayingControl.shared.deactivate()
    }

    private func refreshPeers(_ verified: [PingVerifier.VerifiedPeer]) {
        let mapped = verified.map { v in
            Peer(id: "\(v.host):\(v.port.rawValue)",
                 name: v.name, host: v.host, port: v.port)
        }
        let setBefore = Set(peers.map { $0.id })
        let setAfter = Set(mapped.map { $0.id })
        peers = mapped
        // 自動接続: peer 未選択かつ peer がある → 先頭に接続
        if selectedPeerID == nil, let first = peers.first {
            select(first)
        }
        // 選択中 peer が消えた
        if let sel = selectedPeerID, !setAfter.contains(sel) {
            if paired {
                // ペアリング済なら維持（lost は瞬断の可能性、Bridge が継続中）
            } else {
                selectedPeerID = nil
                stopBridge()
            }
        }
        _ = setBefore
    }

    func select(_ peer: Peer) {
        if selectedPeerID == peer.id, bridge != nil { return }
        bridge?.stop(); bridge = nil
        paired = false
        assignedSlot = 0
        selectedPeerID = peer.id
        status = "接続中..."
        let name = deviceName
        let b = AudioBridge(
            host: peer.host, port: peer.port, deviceName: name,
            onPaired: { [weak self] slot in
                Task { @MainActor in
                    self?.paired = true
                    self?.assignedSlot = slot
                    self?.status = "ペアリング済 (slot \(slot)): \(peer.name)"
                }
            },
            onError: { [weak self] err in
                Task { @MainActor in
                    self?.status = "エラー: \(err.localizedDescription)"
                    self?.stopBridge()
                }
            }
        )
        b.start()
        bridge = b
        status = "送信中: \(peer.name)"
        // ロック画面 / コントロールセンターに「停止ボタン」を出して
        // Android の常駐通知 + 停止ボタンと同等の UX に揃える。
        NowPlayingControl.shared.activate(
            peerName: peer.name, deviceName: deviceName
        ) { [weak self] in
            Task { @MainActor in self?.stopBridge() }
        }
    }
}
