import Foundation
import Network

/// BonjourBrowser から渡された候補に **unicast PING** を定期送信し、PONG が
/// 返ったものだけを「到達性確認済 Peer」として公開する。Spinner に出すのは
/// このリスト。Bonjour で見えても UDP が実際に通らない端末は除外される。
@available(iOS 17.0, *)
final class PingVerifier: @unchecked Sendable {

    struct VerifiedPeer: Hashable {
        let name: String       // PONG payload (= Mac の localizedName)
        let host: NWEndpoint.Host
        let port: NWEndpoint.Port
    }
    typealias OnPeers = ([VerifiedPeer]) -> Void

    private struct Candidate {
        let host: NWEndpoint.Host
        let port: NWEndpoint.Port
        let nsdName: String
    }

    private let q = DispatchQueue(label: "audiorouter.ping", qos: .userInitiated)
    private let lock = NSLock()
    private var candidates: [String: Candidate] = [:]      // key = "host:port"
    private var verified: [String: (VerifiedPeer, Date)] = [:]
    private var listener: OnPeers?
    private var sock: Int32 = -1
    private var sendTimer: DispatchSourceTimer?
    private var recvSource: DispatchSourceRead?

    /// 診断 (UI で見られるようにする)。
    struct Diag: Equatable {
        var candidateCount: Int = 0
        var verifiedCount: Int = 0
        var pingsSent: Int = 0
        var pingsSkipped: Int = 0   // IPv6 等で send をスキップした件数
        var pongsReceived: Int = 0
        var lastCandidate: String = ""   // 候補ホスト表示
        var lastError: String?
    }
    var diag: Diag {
        lock.lock(); defer { lock.unlock() }
        let last = candidates.values.first.map { "\($0.host):\($0.port.rawValue)" } ?? ""
        return Diag(candidateCount: candidates.count,
                    verifiedCount: verified.count,
                    pingsSent: _pingsSent,
                    pingsSkipped: _pingsSkipped,
                    pongsReceived: _pongsReceived,
                    lastCandidate: last,
                    lastError: _lastError)
    }
    private var _pingsSent = 0
    private var _pingsSkipped = 0
    private var _pongsReceived = 0
    private var _lastError: String?

    func start(onPeers: @escaping OnPeers) {
        if sendTimer != nil { return }
        self.listener = onPeers
        // dual-stack v6 socket: V6ONLY=0 で IPv4 (::ffff:a.b.c.d) も受ける
        sock = Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }
        var v6only: Int32 = 0
        setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &v6only,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = 0  // ephemeral
        addr.sin6_addr = in6addr_any
        let bindRet = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        if bindRet != 0 {
            _lastError = "bind errno=\(errno)"
            close(sock); sock = -1; return
        }
        startRecv()
        startTimer()
    }

    func stop() {
        sendTimer?.cancel(); sendTimer = nil
        recvSource?.cancel(); recvSource = nil
        if sock >= 0 { close(sock); sock = -1 }
        lock.lock(); candidates.removeAll(); verified.removeAll(); lock.unlock()
    }

    func addCandidate(name: String, host: NWEndpoint.Host, port: NWEndpoint.Port) {
        let key = "\(host):\(port.rawValue)"
        lock.lock()
        candidates[key] = Candidate(host: host, port: port, nsdName: name)
        lock.unlock()
    }
    func removeCandidate(name: String) {
        lock.lock()
        candidates = candidates.filter { $0.value.nsdName != name }
        lock.unlock()
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + .milliseconds(500),
                   repeating: .seconds(2), leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in
            self?.tickSend()
            self?.expirePeers()
        }
        t.resume()
        sendTimer = t
    }

    private func tickSend() {
        let cs: [Candidate]
        lock.lock(); cs = Array(candidates.values); lock.unlock()
        guard !cs.isEmpty, sock >= 0 else { return }
        let ping = makePing()
        var ok = 0, skipped = 0
        for c in cs {
            if sendPacket(ping, to: c.host, port: c.port) { ok += 1 }
            else { skipped += 1 }
        }
        lock.lock(); _pingsSent += ok; _pingsSkipped += skipped; lock.unlock()
    }

    @discardableResult
    private func sendPacket(_ data: Data, to host: NWEndpoint.Host, port: NWEndpoint.Port) -> Bool {
        // IPv4 と IPv6 の両方を扱う。Bonjour で resolve した host が link-local
        // IPv6 (fe80::...) になるケースがあるので両方 try。
        var storage = sockaddr_storage()
        var addrLen: socklen_t = 0
        switch host {
        case .ipv4(let v4):
            withUnsafeMutablePointer(to: &storage) { sptr in
                sptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { a in
                    a.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    a.pointee.sin_family = sa_family_t(AF_INET)
                    a.pointee.sin_port = port.rawValue.bigEndian
                    _ = v4.rawValue.withUnsafeBytes { buf in
                        memcpy(&a.pointee.sin_addr, buf.baseAddress!, 4)
                    }
                }
            }
            addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        case .ipv6(let v6):
            withUnsafeMutablePointer(to: &storage) { sptr in
                sptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a in
                    a.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                    a.pointee.sin6_family = sa_family_t(AF_INET6)
                    a.pointee.sin6_port = port.rawValue.bigEndian
                    _ = v6.rawValue.withUnsafeBytes { buf in
                        memcpy(&a.pointee.sin6_addr, buf.baseAddress!, 16)
                    }
                    if let intf = v6.interface {
                        a.pointee.sin6_scope_id = UInt32(intf.index)
                    }
                }
            }
            addrLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
        case .name(let s, _):
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC,
                                  ai_socktype: SOCK_DGRAM, ai_protocol: 0,
                                  ai_addrlen: 0, ai_canonname: nil,
                                  ai_addr: nil, ai_next: nil)
            var res: UnsafeMutablePointer<addrinfo>? = nil
            if getaddrinfo(s, nil, &hints, &res) == 0, let r = res {
                memcpy(&storage, r.pointee.ai_addr, Int(r.pointee.ai_addrlen))
                if r.pointee.ai_family == AF_INET {
                    withUnsafeMutablePointer(to: &storage) { sptr in
                        sptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                            $0.pointee.sin_port = port.rawValue.bigEndian
                        }
                    }
                } else if r.pointee.ai_family == AF_INET6 {
                    withUnsafeMutablePointer(to: &storage) { sptr in
                        sptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                            $0.pointee.sin6_port = port.rawValue.bigEndian
                        }
                    }
                }
                addrLen = socklen_t(r.pointee.ai_addrlen)
                freeaddrinfo(r)
            } else {
                return false
            }
        default: return false
        }
        let sent = data.withUnsafeBytes { buf -> ssize_t in
            withUnsafePointer(to: &storage) { ptr -> ssize_t in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sock, buf.baseAddress, buf.count, 0, sa, addrLen)
                }
            }
        }
        if sent < 0 {
            lock.lock(); _lastError = "sendto errno=\(errno)"; lock.unlock()
            return false
        }
        return true
    }

    private func startRecv() {
        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: q)
        src.setEventHandler { [weak self] in self?.drainRecv() }
        src.resume()
        recvSource = src
    }

    private func drainRecv() {
        var buf = [UInt8](repeating: 0, count: NetAudio.maxPacketBytes)
        var storage = sockaddr_storage()
        var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = buf.withUnsafeMutableBufferPointer { bp -> ssize_t in
            withUnsafeMutablePointer(to: &storage) { ptr -> ssize_t in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(sock, bp.baseAddress, bp.count, 0, sa, &fromLen)
                }
            }
        }
        if n <= 0 { return }
        lock.lock(); _pongsReceived += 1; lock.unlock()
        let data = Data(buf.prefix(Int(n)))
        guard let (h, payload) = NetAudio.decode(data),
              h.type == .ping else { return }
        // 送信元 IP を文字列化。**zone (%enX) は再構築不可**なので、これは
        // candidate を引くキーにだけ使い、最終的な host はオリジナル候補
        // (= NWBrowser が resolve した zone 付き NWEndpoint.Host) を採用する。
        let srcIP: String
        let portRaw: UInt16
        switch Int32(storage.ss_family) {
        case AF_INET:
            var a4 = withUnsafePointer(to: &storage) { sptr -> sockaddr_in in
                sptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a4.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            srcIP = String(cString: ipBuf)
            portRaw = UInt16(bigEndian: a4.sin_port)
        case AF_INET6:
            var a6 = withUnsafePointer(to: &storage) { sptr -> sockaddr_in6 in
                sptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            }
            // IPv4-mapped (::ffff:a.b.c.d) は v4 として扱う
            let octets = withUnsafeBytes(of: &a6.sin6_addr) {
                Array($0.bindMemory(to: UInt8.self))
            }
            let isMapped = octets.prefix(10).allSatisfy { $0 == 0 }
                && octets[10] == 0xff && octets[11] == 0xff
            if isMapped {
                srcIP = "\(octets[12]).\(octets[13]).\(octets[14]).\(octets[15])"
            } else {
                var ipBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &a6.sin6_addr, &ipBuf, socklen_t(INET6_ADDRSTRLEN))
                srcIP = String(cString: ipBuf)
            }
            portRaw = UInt16(bigEndian: a6.sin6_port)
        default:
            return
        }
        let port = NWEndpoint.Port(rawValue: portRaw) ?? .any
        // 候補マップを引いて、**zone 付きの元 host** を採用する。link-local
        // ペイロード (fe80::...) では zone が無いと sendto が EHOSTUNREACH。
        let matchedHost: NWEndpoint.Host
        lock.lock()
        let m = candidates.values.first { c in
            // \(c.host) は "fe80::xxx%en0" や "192.168.x.y" を出す
            "\(c.host)".hasPrefix(srcIP)
        }
        lock.unlock()
        if let m { matchedHost = m.host }
        else if srcIP.contains(".") {
            guard let v4 = IPv4Address(srcIP) else { return }
            matchedHost = .ipv4(v4)
        } else {
            guard let v6 = IPv6Address(srcIP) else { return }
            matchedHost = .ipv6(v6)
        }
        let host = matchedHost
        let key = "\(host):\(port.rawValue)"
        let name = String(data: payload, encoding: .utf8)?
            .trimmingCharacters(in: .whitespaces) ?? "Mac"
        let peer = VerifiedPeer(name: name.isEmpty ? "Mac" : name,
                                host: host, port: port)
        lock.lock()
        let prev = verified[key]?.0
        verified[key] = (peer, Date())
        let changed = prev != peer
        let list = verified.values.map { $0.0 }.sorted { $0.name < $1.name }
        lock.unlock()
        if changed { DispatchQueue.main.async { self.listener?(list) } }
    }

    private func expirePeers() {
        lock.lock()
        let now = Date()
        var changed = false
        for (k, v) in verified where now.timeIntervalSince(v.1) > 10 {
            verified.removeValue(forKey: k); changed = true
        }
        if !changed { lock.unlock(); return }
        let list = verified.values.map { $0.0 }.sorted { $0.name < $1.name }
        lock.unlock()
        DispatchQueue.main.async { self.listener?(list) }
    }

    private func makePing() -> Data {
        NetAudio.encode(NetAudio.Header(
            type: .ping, slot: 0, codec: .pcm16le,
            seq: 0, tsUs: NetAudio.nowMicros(), payloadLen: 0), payload: Data())
    }
}
