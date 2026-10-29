import Foundation
import Network

/// `_4noha-audio._udp` を NWBrowser で探す薄いラッパ。見つかった endpoint を
/// `PingVerifier` に渡して unicast PING で到達性を確認する 2 段構成。
///
/// NWEndpoint からは name + (host, port) が直接得られないので、resolve は
/// NWConnection を一瞬作って ready 時に取り出す。
@available(iOS 17.0, *)
final class BonjourBrowser {
    typealias OnResolved = (_ name: String, _ host: NWEndpoint.Host, _ port: NWEndpoint.Port) -> Void
    typealias OnLost = (_ name: String) -> Void

    private let q = DispatchQueue(label: "audiorouter.bonjour", qos: .userInitiated)
    private var browser: NWBrowser?
    private var onResolved: OnResolved?
    private var onLost: OnLost?
    private var resolveConns: [String: NWConnection] = [:]

    /// 診断用カウンタ。UI で見られるようにする (デバッグ用)。
    struct Diag: Equatable {
        var browserState: String = "init"
        var rawDiscoveredCount: Int = 0    // browseResultsChangedHandler の最新セットの数
        var resolveAttempts: Int = 0       // resolveOnce 呼んだ累積
        var resolvedCount: Int = 0         // .ready で endpoint 取れた累積
        var lastError: String?
    }
    private let diagLock = NSLock()
    private var _diag = Diag()
    var diag: Diag { diagLock.lock(); defer { diagLock.unlock() }; return _diag }
    private func mutateDiag(_ block: (inout Diag) -> Void) {
        diagLock.lock(); block(&_diag); diagLock.unlock()
    }

    func start(onResolved: @escaping OnResolved, onLost: @escaping OnLost) {
        if browser != nil { return }
        self.onResolved = onResolved
        self.onLost = onLost
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: "_4noha-audio._udp", domain: "local.")
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: descriptor, using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.mutateDiag { $0.rawDiscoveredCount = results.count }
            self?.handleResults(results)
        }
        b.stateUpdateHandler = { [weak self] state in
            switch state {
            case .setup: self?.mutateDiag { $0.browserState = "setup" }
            case .ready: self?.mutateDiag { $0.browserState = "ready" }
            case .waiting(let e):
                self?.mutateDiag { $0.browserState = "waiting"; $0.lastError = "\(e)" }
            case .failed(let e):
                self?.mutateDiag { $0.browserState = "failed"; $0.lastError = "\(e)" }
                print("BonjourBrowser failed: \(e)")
            case .cancelled: self?.mutateDiag { $0.browserState = "cancelled" }
            @unknown default: break
            }
        }
        b.start(queue: q)
        browser = b
    }

    func stop() {
        browser?.cancel(); browser = nil
        for (_, c) in resolveConns { c.cancel() }
        resolveConns.removeAll()
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        // 名前を一覧化しつつ resolve をかける。
        let names = Set(results.compactMap { r -> String? in
            if case .service(let n, _, _, _) = r.endpoint { return n }
            return nil
        })
        // lost 通知
        for old in resolveConns.keys where !names.contains(old) {
            resolveConns[old]?.cancel(); resolveConns.removeValue(forKey: old)
            onLost?(old)
        }
        // 新規 resolve
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint else { continue }
            if resolveConns[name] != nil { continue }
            resolveOnce(endpoint: r.endpoint, name: name)
        }
    }

    private func resolveOnce(endpoint: NWEndpoint, name: String) {
        // 一瞬 UDP NWConnection を作って resolve させ、ready で host/port を抜く。
        let conn = NWConnection(to: endpoint, using: .udp)
        resolveConns[name] = conn
        mutateDiag { $0.resolveAttempts += 1 }
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let path = conn.currentPath,
                   case .hostPort(let host, let port) = path.remoteEndpoint
                        ?? endpoint {
                    self?.mutateDiag { $0.resolvedCount += 1 }
                    self?.onResolved?(name, host, port)
                }
                conn.cancel()
            case .failed(let e):
                self?.mutateDiag { $0.lastError = "resolve failed: \(e)" }
                if self?.resolveConns[name] === conn {
                    self?.resolveConns.removeValue(forKey: name)
                }
            case .cancelled:
                if self?.resolveConns[name] === conn {
                    self?.resolveConns.removeValue(forKey: name)
                }
            default: break
            }
        }
        conn.start(queue: q)
    }
}
