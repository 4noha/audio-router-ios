import Foundation

/// AudioRouter ↔ iOS (および Android) 間 UDP パケット仕様。
/// `audio-router/Sources/AudioRouterCore/NetAudioProtocol.swift` および
/// `audio-router-android/.../NetAudio.kt` と **byte 一致**で保つ。
///
/// パケット = 22 byte header + payload。すべて big-endian。
///
/// ```
///   0   4  magic  = "4NHA" (0x34 0x4E 0x48 0x41)
///   4   1  version = 1
///   5   1  type    (0=audio, 1=hello, 2=bye, 3=ping)
///   6   1  slot    (1..4)
///   7   1  codec   (0=pcm16le, 1=opus)
///   8   4  seq     uint32 BE
///  12   8  ts_us   int64 BE  (送信側 monotonic μs)
///  20   2  payload_len uint16 BE
///  22   N  payload
/// ```
enum NetAudio {
    static let magic: [UInt8] = [0x34, 0x4E, 0x48, 0x41]   // "4NHA"
    static let version: UInt8 = 1
    static let headerBytes = 22
    static let maxPacketBytes = 1400

    enum PacketType: UInt8 { case audio = 0, hello = 1, bye = 2, ping = 3 }
    enum Codec: UInt8 { case pcm16le = 0, opus = 1 }

    struct Header {
        var type: PacketType
        var slot: UInt8
        var codec: Codec
        var seq: UInt32
        var tsUs: Int64
        var payloadLen: UInt16
    }

    static func encode(_ h: Header, payload: Data) -> Data {
        var d = Data(capacity: headerBytes + payload.count)
        d.append(contentsOf: magic)
        d.append(version)
        d.append(h.type.rawValue)
        d.append(h.slot)
        d.append(h.codec.rawValue)
        d.append(UInt8((h.seq >> 24) & 0xff))
        d.append(UInt8((h.seq >> 16) & 0xff))
        d.append(UInt8((h.seq >>  8) & 0xff))
        d.append(UInt8( h.seq        & 0xff))
        let ts = UInt64(bitPattern: h.tsUs)
        d.append(UInt8((ts >> 56) & 0xff))
        d.append(UInt8((ts >> 48) & 0xff))
        d.append(UInt8((ts >> 40) & 0xff))
        d.append(UInt8((ts >> 32) & 0xff))
        d.append(UInt8((ts >> 24) & 0xff))
        d.append(UInt8((ts >> 16) & 0xff))
        d.append(UInt8((ts >>  8) & 0xff))
        d.append(UInt8( ts        & 0xff))
        d.append(UInt8((h.payloadLen >> 8) & 0xff))
        d.append(UInt8( h.payloadLen       & 0xff))
        d.append(payload)
        return d
    }

    static func decode(_ data: Data) -> (Header, Data)? {
        guard data.count >= headerBytes else { return nil }
        return data.withUnsafeBytes { rb -> (Header, Data)? in
            let p = rb.bindMemory(to: UInt8.self)
            for i in 0..<4 where p[i] != magic[i] { return nil }
            guard p[4] == version else { return nil }
            guard let type = PacketType(rawValue: p[5]) else { return nil }
            guard let codec = Codec(rawValue: p[7]) else { return nil }
            let slot = p[6]
            let seq = (UInt32(p[8]) << 24) | (UInt32(p[9]) << 16)
                | (UInt32(p[10]) << 8) | UInt32(p[11])
            var ts: UInt64 = 0
            for i in 0..<8 { ts = (ts << 8) | UInt64(p[12 + i]) }
            let plen = (UInt16(p[20]) << 8) | UInt16(p[21])
            guard headerBytes + Int(plen) <= data.count else { return nil }
            let h = Header(type: type, slot: slot, codec: codec,
                           seq: seq, tsUs: Int64(bitPattern: ts),
                           payloadLen: plen)
            let payload = data.subdata(
                in: headerBytes..<(headerBytes + Int(plen)))
            return (h, payload)
        }
    }

    static func nowMicros() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1_000_000 + Int64(ts.tv_nsec) / 1_000
    }
}
