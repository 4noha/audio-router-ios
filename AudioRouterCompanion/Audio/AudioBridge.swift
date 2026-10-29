import Foundation
import AVFoundation
import Network

/// iOS ↔ Mac の双方向 UDP オーディオブリッジ。Android 版 `AudioBridge.kt` と
/// 同じ責務。**1 つのソケット**を送受信で共有し、Mac の `lastConn` 経由で
/// 戻ってくるパケットを同じ port で受ける。
///
///  - 送信: AVAudioEngine inputNode tap → Float32 mono 48k → Opus encode → UDP
///  - 受信: UDP recv → Opus decode → AVAudioPlayerNode で再生
///  - 接続宣言: 開始時に HELLO (slot=0, payload=端末名) を送出。Mac から
///    hello-ack (type=HELLO) を受け取ったら **割当された slot** で audio
///    送信開始。paired 後も 10秒毎の keep-alive HELLO で Mac 再起動に追随。
@available(iOS 17.0, *)
final class AudioBridge: @unchecked Sendable {
    private let host: NWEndpoint.Host
    private var port: NWEndpoint.Port    // hello-ack で 端末専用 port に切替
    private let deviceName: String
    private let onPaired: (UInt8) -> Void
    private let onError: (Error) -> Void

    private let frameSamples: AVAudioFrameCount = 960

    private var sock: Int32 = -1
    private let q = DispatchQueue(label: "audiorouter.bridge", qos: .userInteractive)
    private var sendQ: DispatchQueue { q }
    private var helloTimer: DispatchSourceTimer?
    private var recvSource: DispatchSourceRead?
    private let engine = AVAudioEngine()
    private var encoder: OpusEncoder?
    private var decoder: OpusDecoder?
    private var playerNode: AVAudioPlayerNode?

    private var running = false
    private var paired = false
    private var assignedSlot: UInt8 = 0
    private var seq: UInt32 = 0

    // 診断: 送受信カウンタ。ViewModel から periodically 読み出して UI 表示。
    struct Stats: Equatable {
        var sentPackets: UInt64 = 0
        var sentBytes: UInt64 = 0
        var recvPackets: UInt64 = 0
        var recvBytes: UInt64 = 0
        var lastSendError: String?
        var lastDecodeError: String?
    }
    private let statsLock = NSLock()
    private var _stats = Stats()
    var stats: Stats { statsLock.lock(); defer { statsLock.unlock() }; return _stats }
    private func bumpSent(_ n: Int) {
        statsLock.lock()
        _stats.sentPackets &+= 1; _stats.sentBytes &+= UInt64(n)
        statsLock.unlock()
    }
    private func bumpRecv(_ n: Int) {
        statsLock.lock()
        _stats.recvPackets &+= 1; _stats.recvBytes &+= UInt64(n)
        statsLock.unlock()
    }

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, deviceName: String,
         onPaired: @escaping (UInt8) -> Void,
         onError: @escaping (Error) -> Void = { _ in }) {
        self.host = host; self.port = port; self.deviceName = deviceName
        self.onPaired = onPaired; self.onError = onError
    }

    func start() {
        if running { return }
        running = true
        do {
            try configureAudioSession()
            try setupSocket()
            try setupAudioEngine()
            startRecvLoop()
            sendInitialHello()
            startHelloKeepAlive()
        } catch {
            onError(error)
            stop()
        }
    }

    func stop() {
        running = false
        // bye を送って Mac 側の row 状態をクリーンに（best-effort）。
        if sock >= 0, paired, assignedSlot != 0 {
            let bye = NetAudio.encode(NetAudio.Header(
                type: .bye, slot: assignedSlot, codec: .opus,
                seq: seq, tsUs: NetAudio.nowMicros(), payloadLen: 0),
                payload: Data())
            sendPacket(bye)
        }
        helloTimer?.cancel(); helloTimer = nil
        recvSource?.cancel(); recvSource = nil
        engine.stop()
        if engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }
        if let p = playerNode { p.stop() }
        if sock >= 0 { close(sock); sock = -1 }
    }

    // MARK: AVAudioSession

    private func configureAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        // allowBluetoothHFP = ヘッドフリー BT (mic+spk)。allowBluetooth は iOS 8 で
        // deprecated だが同じ意味。A2DP は再生のみで mic を奪うので入れない。
        try s.setCategory(.playAndRecord,
                           mode: .voiceChat,
                           options: [.defaultToSpeaker, .allowBluetoothHFP])
        try s.setPreferredSampleRate(48_000)
        try s.setPreferredIOBufferDuration(0.02)  // 20ms
        try s.setActive(true, options: [])
    }

    // MARK: socket

    private func setupSocket() throws {
        // dual-stack v6 socket。Bonjour で resolve した host が v4/v6 どちら
        // でも対応し、Mac から戻る IPv4-mapped 応答も同 socket で受ける。
        sock = Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            throw NSError(domain: "AudioBridge", code: -1,
                           userInfo: [NSLocalizedDescriptionKey: "socket failed errno=\(errno)"])
        }
        var v6only: Int32 = 0
        setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &v6only,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = 0
        addr.sin6_addr = in6addr_any
        let r = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        if r != 0 { close(sock); sock = -1
            throw NSError(domain: "AudioBridge", code: -2,
                           userInfo: [NSLocalizedDescriptionKey: "bind failed errno=\(errno)"])
        }
    }

    /// (host, port) 宛に UDP 送出。v4/v6 dual-stack。
    private func sendPacket(_ data: Data) {
        guard sock >= 0 else { return }
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
                statsLock.lock(); _stats.lastSendError = "getaddrinfo failed"; statsLock.unlock()
                return
            }
        default:
            statsLock.lock(); _stats.lastSendError = "unsupported host"; statsLock.unlock()
            return
        }
        let sent = data.withUnsafeBytes { buf -> ssize_t in
            withUnsafePointer(to: &storage) { ptr -> ssize_t in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sock, buf.baseAddress, buf.count, 0, sa, addrLen)
                }
            }
        }
        if sent > 0 {
            bumpSent(Int(sent))
        } else {
            statsLock.lock(); _stats.lastSendError = "sendto errno=\(errno)"; statsLock.unlock()
        }
    }

    // MARK: HELLO

    private func makeHello(seq: UInt32) -> Data {
        // payload: "deviceName\0appVersion" (null 区切り、デバッグ用に version 同梱)
        let ver = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String) ?? ""
        var body = Data(deviceName.utf8)
        body.append(0x00)
        body.append(contentsOf: ver.utf8)
        return NetAudio.encode(NetAudio.Header(
            type: .hello, slot: 0, codec: .opus,
            seq: seq, tsUs: NetAudio.nowMicros(),
            payloadLen: UInt16(body.count)), payload: body)
    }

    private func sendInitialHello() {
        sendPacket(makeHello(seq: 0))
    }

    private func startHelloKeepAlive() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + .seconds(2),
                   repeating: .seconds(2), leeway: .milliseconds(200))
        var n: UInt32 = 1
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.running { return }
            // 未 paired: 2秒毎、paired 後: 10秒毎 → 単純化で 2秒毎+カウンタ
            if !self.paired || n % 5 == 0 {
                self.sendPacket(self.makeHello(seq: n))
            }
            n &+= 1
        }
        t.resume()
        helloTimer = t
    }

    // MARK: 受信

    private func startRecvLoop() {
        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: q)
        src.setEventHandler { [weak self] in self?.drainRecv() }
        src.resume()
        recvSource = src
    }

    private func drainRecv() {
        var buf = [UInt8](repeating: 0, count: NetAudio.maxPacketBytes)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { bp -> ssize_t in
                withUnsafeMutablePointer(to: &from) { ptr -> ssize_t in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(sock, bp.baseAddress, bp.count,
                                 MSG_DONTWAIT, sa, &fromLen)
                    }
                }
            }
            if n <= 0 { return }
            bumpRecv(Int(n))
            let data = Data(buf.prefix(Int(n)))
            guard let (h, payload) = NetAudio.decode(data) else { continue }
            switch h.type {
            case .hello:
                // hello-ack payload = [port BE u16][Mac 名 UTF-8]
                // Mac が割当てた端末専用 port に切替える。
                if payload.count >= 2 {
                    let newPort = (UInt16(payload[0]) << 8) | UInt16(payload[1])
                    if newPort != 0, newPort != port.rawValue,
                       let np = NWEndpoint.Port(rawValue: newPort) {
                        port = np
                    }
                }
                if !paired || assignedSlot != h.slot {
                    assignedSlot = h.slot
                    paired = true
                    onPaired(h.slot)
                }
            case .audio:
                handleAudio(h: h, payload: payload)
            default: break
            }
        }
    }

    private func handleAudio(h: NetAudio.Header, payload: Data) {
        guard let dec = decoder, let player = playerNode else { return }
        do {
            let pcm: AVAudioPCMBuffer
            if h.codec == .opus {
                pcm = try dec.decode(payload)
            } else {
                // PCM16 LE → Float32 mono
                let n = payload.count / 2
                guard let b = AVAudioPCMBuffer(pcmFormat: dec.pcmFormat,
                                                 frameCapacity: AVAudioFrameCount(n)) else { return }
                b.frameLength = AVAudioFrameCount(n)
                if let dst = b.floatChannelData?[0] {
                    payload.withUnsafeBytes { rb in
                        let s = rb.bindMemory(to: Int16.self)
                        for i in 0..<n {
                            dst[i] = Float(Int16(littleEndian: s[i])) / 32768.0
                        }
                    }
                }
                pcm = b
            }
            player.scheduleBuffer(pcm, completionHandler: nil)
            if !player.isPlaying { player.play() }
        } catch {
            // decode 失敗は drop
        }
    }

    // MARK: AVAudioEngine

    private func setupAudioEngine() throws {
        // 出力 (再生)
        let dec = try OpusDecoder()
        decoder = dec
        let player = AVAudioPlayerNode()
        playerNode = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: dec.pcmFormat)
        // 入力 (キャプチャ) — input フォーマットに合わせて encoder を後付け。
        let inputFmt = engine.inputNode.inputFormat(forBus: 0)
        let enc = try OpusEncoder()
        encoder = enc
        // Float32 mono 48k に再サンプルするためのコンバータ。
        let inputBus: AVAudioNodeBus = 0
        let bufFrames: AVAudioFrameCount = 1024  // ~21ms (実機 IO buffer に近い)
        engine.inputNode.installTap(onBus: inputBus,
                                     bufferSize: bufFrames,
                                     format: inputFmt) { [weak self] buf, _ in
            guard let self = self else { return }
            self.handleMicBuffer(buf, inputFmt: inputFmt)
        }
        engine.prepare()
        try engine.start()
        try AVAudioSession.sharedInstance().setActive(true, options: [])
    }

    /// 入力バッファを 48k mono Float32 に整え、960 frame 単位で encoder へ。
    private var micAccum: [Float] = []
    private var resampler: AVAudioConverter?

    private func handleMicBuffer(_ src: AVAudioPCMBuffer, inputFmt: AVAudioFormat) {
        guard let enc = encoder else { return }
        // 48k mono Float32 に変換（既に同じなら no-op に近い）
        let targetFmt = enc.pcmFormat
        let conv: AVAudioConverter
        if let r = resampler { conv = r }
        else {
            guard let c = AVAudioConverter(from: inputFmt, to: targetFmt) else { return }
            resampler = c; conv = c
        }
        let outCap = AVAudioFrameCount(Double(src.frameLength) *
                                        (targetFmt.sampleRate / inputFmt.sampleRate)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: outCap)
        else { return }
        var nsErr: NSError?
        var provided = false
        let st = conv.convert(to: out, error: &nsErr) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return src
        }
        if st == .error { return }
        let nFrames = Int(out.frameLength)
        guard nFrames > 0, let ch = out.floatChannelData?[0] else { return }
        micAccum.append(contentsOf: UnsafeBufferPointer(start: ch, count: nFrames))
        // 960 frame 単位で encode + send
        while micAccum.count >= Int(enc.frameSamples) {
            let take = Int(enc.frameSamples)
            guard let frame = AVAudioPCMBuffer(pcmFormat: targetFmt,
                                                frameCapacity: AVAudioFrameCount(take))
            else { break }
            frame.frameLength = AVAudioFrameCount(take)
            if let dst = frame.floatChannelData?[0] {
                for i in 0..<take { dst[i] = micAccum[i] }
            }
            micAccum.removeFirst(take)

            // 未 paired = slot 未確定の間は audio 送信しない（Mac が捨てる）
            if assignedSlot == 0 { continue }
            do {
                let opus = try enc.encode(frame)
                let pkt = NetAudio.encode(NetAudio.Header(
                    type: .audio, slot: assignedSlot, codec: .opus,
                    seq: seq, tsUs: NetAudio.nowMicros(),
                    payloadLen: UInt16(opus.count)), payload: opus)
                sendPacket(pkt)
                seq &+= 1
            } catch {
                // encode 失敗は drop
            }
        }
    }
}
