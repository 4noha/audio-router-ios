import Foundation
import AVFoundation
import AudioToolbox

/// iOS 17+ の AVAudioConverter (`kAudioFormatOpus`) を使った Opus encoder /
/// decoder ラッパ。mono 48k 専用、20ms フレーム (960 samples) 固定。
///
/// 注: iOS の `kAudioFormatOpus` は AudioToolbox の標準 codec として
/// macOS 14 / iOS 17 から利用可能。libopus を別途 vendor する必要なし。
@available(iOS 17.0, *)
final class OpusEncoder {
    let pcmFormat: AVAudioFormat
    let opusFormat: AVAudioFormat
    private let converter: AVAudioConverter
    let frameSamples: AVAudioFrameCount = 960
    let maxPacketBytes = 4000

    enum OpusError: Error { case formatFailed, convertFailed(NSError) }

    init(bitrate: Int = 32_000) throws {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 48_000, channels: 1,
                                       interleaved: false)
        else { throw OpusError.formatFailed }
        self.pcmFormat = pcm
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(frameSamples),
            mBytesPerFrame: 0, mChannelsPerFrame: 1,
            mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &asbd)
        else { throw OpusError.formatFailed }
        self.opusFormat = opus
        guard let c = AVAudioConverter(from: pcm, to: opus)
        else { throw OpusError.formatFailed }
        c.bitRate = bitrate
        self.converter = c
    }

    /// `pcm` は frameSamples (960) の Float32 mono。返り値は encoded Opus byte。
    func encode(_ pcm: AVAudioPCMBuffer) throws -> Data {
        let out = AVAudioCompressedBuffer(format: opusFormat,
                                           packetCapacity: 1,
                                           maximumPacketSize: maxPacketBytes)
        var provided = false
        var nsErr: NSError?
        let status = converter.convert(to: out, error: &nsErr) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return pcm
        }
        if status == .error { throw OpusError.convertFailed(nsErr ?? NSError(domain: "Opus", code: -1)) }
        // 1 packet 分のバイト列を取り出す。
        let pktDesc = out.packetDescriptions
        let byteSize: Int
        if let pd = pktDesc, out.packetCount >= 1 {
            byteSize = Int(pd.pointee.mDataByteSize)
        } else {
            byteSize = Int(out.byteLength)
        }
        return Data(bytes: out.data, count: byteSize)
    }
}

@available(iOS 17.0, *)
final class OpusDecoder {
    let pcmFormat: AVAudioFormat
    let opusFormat: AVAudioFormat
    private let converter: AVAudioConverter
    let frameSamples: AVAudioFrameCount = 960

    enum OpusError: Error { case formatFailed, convertFailed(NSError) }

    init() throws {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 48_000, channels: 1,
                                       interleaved: false)
        else { throw OpusError.formatFailed }
        self.pcmFormat = pcm
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(frameSamples),
            mBytesPerFrame: 0, mChannelsPerFrame: 1,
            mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &asbd)
        else { throw OpusError.formatFailed }
        self.opusFormat = opus
        guard let c = AVAudioConverter(from: opus, to: pcm)
        else { throw OpusError.formatFailed }
        self.converter = c
    }

    /// Opus packet 1 つを PCM Float32 (mono) に変換。空 buffer なら無音。
    func decode(_ opus: Data) throws -> AVAudioPCMBuffer {
        let inBuf = AVAudioCompressedBuffer(format: opusFormat,
                                             packetCapacity: 1,
                                             maximumPacketSize: opus.count)
        _ = opus.withUnsafeBytes { src in
            memcpy(inBuf.data, src.baseAddress, opus.count)
        }
        inBuf.byteLength = UInt32(opus.count)
        inBuf.packetCount = 1
        let pd = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(opus.count))
        inBuf.packetDescriptions?.pointee = pd

        guard let outBuf = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                             frameCapacity: frameSamples * 6) else {
            throw OpusError.formatFailed
        }
        var provided = false
        var nsErr: NSError?
        let status = converter.convert(to: outBuf, error: &nsErr) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if status == .error { throw OpusError.convertFailed(nsErr ?? NSError(domain: "Opus", code: -1)) }
        return outBuf
    }
}
