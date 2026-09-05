import Foundation
import AVFoundation
import CoreAudio

enum StereoMixer {
    private static let outputSampleRate: Double = 48_000

    private static let outputBitRate: Int = 128_000

    private static let writeChunkFrames: AVAudioFrameCount = 16_384

    enum MixError: LocalizedError {
        case couldNotCreateFormat
        case couldNotCreateConverter
        case couldNotAllocateBuffer
        case bothSourcesEmpty
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .couldNotCreateFormat:    return "Could not create an audio format for mixing."
            case .couldNotCreateConverter: return "Could not create a sample-rate converter."
            case .couldNotAllocateBuffer:  return "Could not allocate an audio buffer for mixing."
            case .bothSourcesEmpty:        return "Both audio sources were empty — nothing to mix."
            case .writeFailed(let why):    return "Failed to write the mixed file: \(why)"
            }
        }
    }

    static func mix(
        desktopURL: URL,
        micURL: URL,
        desktopResult: CaptureResult,
        micResult: CaptureResult,
        outputURL: URL
    ) throws {
        let desktopSamples = loadResampledMono(url: desktopURL)
        let micSamples     = loadResampledMono(url: micURL)

        if (desktopSamples?.isEmpty ?? true) && (micSamples?.isEmpty ?? true) {
            throw MixError.bothSourcesEmpty
        }

        let (desktopLeadFrames, micLeadFrames) = leadingSilenceFrames(
            desktopHostTime: desktopResult.firstHostTime,
            micHostTime: micResult.firstHostTime
        )

        let desktopChannel = channel(from: desktopSamples, leadingSilence: desktopLeadFrames)
        let micChannel     = channel(from: micSamples,     leadingSilence: micLeadFrames)

        try encodeStereoM4A(
            left: desktopChannel,
            right: micChannel,
            to: outputURL
        )
    }

    private static func loadResampledMono(url: URL) -> [Float]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let inFile: AVAudioFile
        do {
            inFile = try AVAudioFile(forReading: url)
        } catch {
            return nil
        }

        let inFormat = inFile.processingFormat
        let inLength = inFile.length
        guard inLength > 0, inFormat.sampleRate > 0 else { return nil }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        if inFormat.sampleRate == outputSampleRate,
           inFormat.channelCount == 1,
           inFormat.commonFormat == .pcmFormatFloat32 {
            return readAllMono(from: inFile, format: inFormat)
        }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            return readAllMono(from: inFile, format: inFormat)
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inFormat,
            frameCapacity: AVAudioFrameCount(inLength)
        ) else {
            return nil
        }
        do {
            try inFile.read(into: inputBuffer)
        } catch {
            return nil
        }
        guard inputBuffer.frameLength > 0 else { return nil }

        let ratio = outputSampleRate / inFormat.sampleRate
        let estimatedFrames = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 4096
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outFormat,
            frameCapacity: estimatedFrames
        ) else {
            return nil
        }

        var fed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        var convError: NSError?
        let status = converter.convert(to: outputBuffer, error: &convError, withInputFrom: inputBlock)
        if status == .error || convError != nil {
            return readAllMono(from: inFile, format: inFormat)
        }

        return samples(from: outputBuffer)
    }

    private static func readAllMono(from file: AVAudioFile, format: AVAudioFormat) -> [Float]? {
        let length = file.length
        guard length > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(length)
        ) else {
            return nil
        }

        file.framePosition = 0
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        return samples(from: buffer)
    }

    private static func samples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return nil }

        let channelCount = Int(buffer.format.channelCount)
        if channelCount <= 1 {
            let ptr = channels[0]
            return Array(UnsafeBufferPointer(start: ptr, count: frames))
        }

        var out = [Float](repeating: 0, count: frames)
        let inv = 1.0 / Float(channelCount)
        for ch in 0..<channelCount {
            let ptr = channels[ch]
            for i in 0..<frames {
                out[i] += ptr[i] * inv
            }
        }
        return out
    }

    private static func leadingSilenceFrames(
        desktopHostTime: UInt64?,
        micHostTime: UInt64?
    ) -> (desktop: Int, mic: Int) {
        guard let d = desktopHostTime, let m = micHostTime else {
            return (0, 0)
        }

        let deltaFrames: Int
        if d == m {
            deltaFrames = 0
        } else if d < m {
            let nanos = AudioConvertHostTimeToNanos(m - d)
            deltaFrames = framesForNanos(nanos)
        } else {
            let nanos = AudioConvertHostTimeToNanos(d - m)
            deltaFrames = framesForNanos(nanos)
        }

        if d <= m {
            return (0, deltaFrames)
        } else {
            return (deltaFrames, 0)
        }
    }

    private static func framesForNanos(_ nanos: UInt64) -> Int {
        let seconds = Double(nanos) / 1_000_000_000.0
        let frames = (seconds * outputSampleRate).rounded()
        guard frames > 0, frames.isFinite else { return 0 }
        return Int(frames)
    }

    private static func channel(from samples: [Float]?, leadingSilence: Int) -> [Float] {
        let lead = max(0, leadingSilence)
        guard let samples, !samples.isEmpty else {
            return [Float](repeating: 0, count: lead)
        }
        if lead == 0 { return samples }
        var out = [Float](repeating: 0, count: lead + samples.count)

        samples.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                (dst.baseAddress! + lead).update(from: src.baseAddress!, count: samples.count)
            }
        }
        return out
    }

    private static func encodeStereoM4A(
        left: [Float],
        right: [Float],
        to outputURL: URL
    ) throws {
        let totalFrames = max(left.count, right.count)
        guard totalFrames > 0 else { throw MixError.bothSourcesEmpty }

        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw MixError.couldNotCreateFormat
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: outputBitRate
        ]

        try? FileManager.default.removeItem(at: outputURL)

        let outFile: AVAudioFile
        do {
            outFile = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw MixError.writeFailed(error.localizedDescription)
        }

        var frameOffset = 0
        while frameOffset < totalFrames {
            let chunk = min(Int(writeChunkFrames), totalFrames - frameOffset)

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: pcmFormat,
                frameCapacity: AVAudioFrameCount(chunk)
            ) else {
                throw MixError.couldNotAllocateBuffer
            }
            buffer.frameLength = AVAudioFrameCount(chunk)

            guard let channelData = buffer.floatChannelData else {
                throw MixError.couldNotAllocateBuffer
            }
            let dstL = channelData[0]
            let dstR = channelData[1]

            for i in 0..<chunk {
                let idx = frameOffset + i
                dstL[i] = idx < left.count  ? left[idx]  : 0
                dstR[i] = idx < right.count ? right[idx] : 0
            }

            do {
                try outFile.write(from: buffer)
            } catch {
                throw MixError.writeFailed(error.localizedDescription)
            }

            frameOffset += chunk
        }
    }
}
