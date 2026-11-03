import AVFoundation

/// Converts arbitrary-format PCM buffers (mic: usually 48k float mono/stereo;
/// system audio: 48k float stereo deinterleaved) to 16kHz mono s16le and
/// hands the raw bytes to a sink. One instance per audio source — the
/// AVAudioConverter keeps resampler state between calls.
final class PCMConverter {
    static let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let sink: (Data) -> Void

    init(sink: @escaping (Data) -> Void) {
        self.sink = sink
    }

    func push(_ buf: AVAudioPCMBuffer) {
        // The input format is not fixed for the life of a source. A Bluetooth
        // headset taking the mic over drops it to 16kHz — 44100 -> 16000 on
        // this machine — and MicCapture comes back on the new device with the
        // new format. A converter built for the old one would keep resampling
        // by a ratio the buffers no longer have, which is speech turned into
        // sludge. Rebuilt when the format moves, and only then: the converter
        // holds resampler state that must survive between ordinary buffers.
        if converter == nil || inFormat != buf.format {
            if let old = inFormat {
                log("input format moved \(Int(old.sampleRate))Hz/\(old.channelCount)ch -> " +
                    "\(Int(buf.format.sampleRate))Hz/\(buf.format.channelCount)ch — converter rebuilt")
            }
            converter = AVAudioConverter(from: buf.format, to: Self.outFormat)
            inFormat = buf.format
        }
        guard let conv = converter else { return }

        let ratio = Self.outFormat.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: capacity) else { return }

        var fed = false
        var convError: NSError?
        conv.convert(to: out, error: &convError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if let convError {
            log("convert error: \(convError.localizedDescription)")
            return
        }
        if out.frameLength > 0, let ch = out.int16ChannelData {
            sink(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
        }
    }
}
