import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// System audio (remote call participants) -> "them" frames.
/// ScreenCaptureKit audio-only capture: excludes our own process audio, keeps
/// the video stream tiny and unconsumed. Requires the Screen Recording
/// permission.
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "org.leetio.livecall.sysaudio")
    private let videoQueue = DispatchQueue(label: "org.leetio.livecall.sysvideo")
    private let converter = PCMConverter { data in
        FrameWriter.shared.write(source: 1, data)
    }

    func start() async throws {
        // Touching shareable content triggers / validates the Screen Recording grant.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "livecall", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no display available for system-audio capture"])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // Video is captured by SCStream but we don't consume it; keep it tiny/cheap.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        // SCStream always produces video; with no output registered for it,
        // ScreenCaptureKit logs "stream output NOT found. Dropping frame" once
        // a second forever. Take the (2x2, 1fps) frames and drop them here.
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.numSamples > 0, let pcm = sampleBuffer.asPCMBuffer else { return }
        converter.push(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("system audio stopped: \(error.localizedDescription)")
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }
}

/// CMSampleBuffer -> AVAudioPCMBuffer (the standard ScreenCaptureKit-audio bridge).
extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? withAudioBufferList { list, _ -> AVAudioPCMBuffer? in
            guard let absd = formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate,
                                             channels: absd.mChannelsPerFrame)
            else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer)
        }
    }
}
