import Foundation
import AVFoundation
import os

final class MicCapture {
    var onLevelDB: ((Float) -> Void)?

    var onFatalError: ((Error) -> Void)?

    enum MicError: LocalizedError {
        case couldNotCreateFile(URL, underlying: Error)
        case invalidInputFormat

        var errorDescription: String? {
            switch self {
            case .couldNotCreateFile(let url, let underlying):
                return "Could not open mic file at \(url.lastPathComponent): \(underlying.localizedDescription)"
            case .invalidInputFormat:
                return "Microphone reported an unusable input format (0 channels or 0 Hz)."
            }
        }
    }

    private let engine = AVAudioEngine()

    private let lock = OSAllocatedUnfairLock()

    private var file: AVAudioFile?

    private var paused = false

    private var firstHostTime: UInt64?

    private var sampleRate: Double = 0

    private var frameCount: AVAudioFramePosition = 0

    private var running = false

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start(writingTo url: URL) throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw MicError.invalidInputFormat
        }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MicError.invalidInputFormat
        }

        let outFile: AVAudioFile
        do {
            outFile = try AVAudioFile(
                forWriting: url,
                settings: monoFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw MicError.couldNotCreateFile(url, underlying: error)
        }

        lock.withLock {
            self.file = outFile
            self.paused = false
            self.firstHostTime = nil
            self.sampleRate = inputFormat.sampleRate
            self.frameCount = 0
            self.running = true
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, when in
            self?.handleBuffer(buffer, when: when, monoFormat: monoFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            lock.withLock {
                self.file = nil
                self.running = false
            }
            throw error
        }
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer, when: AVAudioTime, monoFormat: AVAudioFormat) {
        let db = RMSMeter.dBFS(buffer)
        onLevelDB?(db)

        let hostTime = when.isHostTimeValid ? when.hostTime : mach_absolute_time()

        let frames = buffer.frameLength
        guard frames > 0 else { return }

        let writeBuffer: AVAudioPCMBuffer
        if buffer.format.channelCount == 1 && buffer.format.commonFormat == .pcmFormatFloat32 {
            writeBuffer = buffer
        } else if let mono = MicCapture.downmixToMono(buffer, monoFormat: monoFormat) {
            writeBuffer = mono
        } else {
            return
        }

        lock.withLock {
            guard self.running, !self.paused, let file = self.file else { return }
            do {
                try file.write(from: writeBuffer)
                if self.firstHostTime == nil {
                    self.firstHostTime = hostTime
                }
                self.frameCount += AVAudioFramePosition(writeBuffer.frameLength)
            } catch {
                self.running = false
                self.file = nil
                self.onFatalError?(error)
            }
        }
    }

    private static func downmixToMono(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = buffer.frameLength
        guard frames > 0 else {
            return AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 1)
        }
        guard let channels = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)

        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames) else {
            return nil
        }
        mono.frameLength = frames
        guard let dst = mono.floatChannelData?[0] else { return nil }

        let n = Int(frames)
        if channelCount == 1 {
            dst.update(from: channels[0], count: n)
        } else {
            let inv = 1.0 / Float(channelCount)
            for i in 0..<n {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += channels[ch][i]
                }
                dst[i] = sum * inv
            }
        }
        return mono
    }

    func setPaused(_ paused: Bool) {
        lock.withLock {
            self.paused = paused
        }
    }

    func stop() -> CaptureResult {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        } else {
            engine.inputNode.removeTap(onBus: 0)
        }

        return lock.withLock {
            let result = CaptureResult(
                firstHostTime: self.firstHostTime,
                sampleRate: self.sampleRate,
                frameCount: self.frameCount
            )
            self.running = false
            self.file = nil
            return result
        }
    }
}
