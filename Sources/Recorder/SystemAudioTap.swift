import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate
import os

final class SystemAudioTap {
    var onLevelDB: ((Float) -> Void)?

    var onFatalError: ((Error) -> Void)?

    enum TapError: LocalizedError {
        case createTapFailed(OSStatus)
        case noDefaultOutputDevice(OSStatus)
        case readDeviceUIDFailed(OSStatus)
        case createAggregateFailed(OSStatus)
        case readTapFormatFailed(OSStatus)
        case invalidTapFormat
        case createIOProcFailed(OSStatus)
        case startDeviceFailed(OSStatus)
        case fileOpenFailed(String)

        var errorDescription: String? {
            switch self {
            case .createTapFailed(let s):
                return "AudioHardwareCreateProcessTap failed (OSStatus \(s)). System Audio Recording permission may be denied."
            case .noDefaultOutputDevice(let s):
                return "Could not read the default system output device (OSStatus \(s))."
            case .readDeviceUIDFailed(let s):
                return "Could not read the output device UID (OSStatus \(s))."
            case .createAggregateFailed(let s):
                return "AudioHardwareCreateAggregateDevice failed (OSStatus \(s))."
            case .readTapFormatFailed(let s):
                return "Could not read kAudioTapPropertyFormat (OSStatus \(s))."
            case .invalidTapFormat:
                return "The tap returned an unusable audio format."
            case .createIOProcFailed(let s):
                return "AudioDeviceCreateIOProcIDWithBlock failed (OSStatus \(s))."
            case .startDeviceFailed(let s):
                return "AudioDeviceStart failed (OSStatus \(s))."
            case .fileOpenFailed(let m):
                return "Could not open the desktop capture file: \(m)"
            }
        }
    }

    private let lock = OSAllocatedUnfairLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID = UUID()

    private var file: AVAudioFile?

    private var writeFormat: AVAudioFormat?

    private var tapFormat: AVAudioFormat?

    private var destinationURL: URL?
    private var started = false

    private var firstHostTime: UInt64?
    private var capturedSampleRate: Double = 0

    private var capturedFrames: AVAudioFramePosition = 0

    private var ring: FloatRingBuffer?

    private var scratch: UnsafeMutablePointer<Float>?
    private let scratchCapacity = 16_384

    private var writerThread: Thread?

    private let writerShouldStop = OSAllocatedUnfairLock<Bool>(initialState: false)

    private static let log = Logger(subsystem: "com.tobi.Recorder", category: "SystemAudioTap")

    private let paused = OSAllocatedUnfairLock<Bool>(initialState: false)

    private let lastLoudHostTime = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    private let lastCallbackHostTime = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    private var watchdogTimer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "systemaudiotap.watchdog")

    private let watchdogSilenceThreshold: TimeInterval = 3.0
    private var rebuilding = false

    private(set) var rebuildCount = 0

    private var lastMeterPostHostTime: UInt64 = 0
    private static let meterIntervalNanos: UInt64 = 66_000_000

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    private static func hostTimeToNanos(_ hostTime: UInt64) -> UInt64 {
        let tb = timebase

        return hostTime / UInt64(tb.denom) * UInt64(tb.numer)
            + (hostTime % UInt64(tb.denom)) * UInt64(tb.numer) / UInt64(tb.denom)
    }

    func start(writingTo url: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !started else { return }

        destinationURL = url
        tapUUID = UUID()
        firstHostTime = nil
        capturedFrames = 0

        let built = try buildTapAndAggregateLocked()

        guard let writeFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: built.tapFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            destroyTapAndAggregateLocked()
            throw TapError.invalidTapFormat
        }

        do {
            let f = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: writeFmt.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            self.file = f
        } catch {
            destroyTapAndAggregateLocked()
            throw TapError.fileOpenFailed(error.localizedDescription)
        }

        self.writeFormat = writeFmt
        self.tapFormat = built.tapFormat
        self.capturedSampleRate = built.tapFormat.sampleRate

        let ringFrames = max(Int(writeFmt.sampleRate * 4), 48_000)
        let newRing = FloatRingBuffer(capacityFrames: ringFrames)
        self.ring = newRing
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        writerShouldStop.withLock { $0 = false }
        startWriterThread(file: self.file!, writeFormat: writeFmt, ring: newRing)

        do {
            try installIOProcAndStartLocked()
        } catch {
            stopWriterThreadAndDrain()
            self.ring = nil
            self.scratch?.deallocate()
            self.scratch = nil
            file = nil
            destroyTapAndAggregateLocked()
            throw error
        }

        started = true

        rebuildCount = 0

        let now = mach_absolute_time()
        lastLoudHostTime.withLock { $0 = now }
        lastCallbackHostTime.withLock { $0 = now }
        startWatchdog()
    }

    func setPaused(_ isPaused: Bool) {
        paused.withLock { $0 = isPaused }
    }

    func stop() -> CaptureResult {
        stopWatchdog()

        lock.lock()
        defer { lock.unlock() }

        guard started else {
            return CaptureResult(
                firstHostTime: firstHostTime,
                sampleRate: capturedSampleRate,
                frameCount: capturedFrames
            )
        }
        started = false

        destroyTapAndAggregateLocked()

        stopWriterThreadAndDrain()

        if let dropped = ring?.totalDropped, dropped > 0 {
            Self.log.error("desktop tap dropped \(dropped) frames (consumer fell behind)")
        }
        ring = nil
        scratch?.deallocate()
        scratch = nil

        file = nil
        writeFormat = nil
        tapFormat = nil

        return CaptureResult(
            firstHostTime: firstHostTime,
            sampleRate: capturedSampleRate,
            frameCount: capturedFrames
        )
    }

    private struct BuildResult {
        var tapFormat: AVAudioFormat
    }

    @discardableResult
    private func buildTapAndAggregateLocked() throws -> BuildResult {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = tapUUID
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError.createTapFailed(tapStatus)
        }
        self.tapID = newTapID

        let outputDevice: AudioObjectID
        do {
            outputDevice = try Self.defaultSystemOutputDevice()
        } catch {
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = kAudioObjectUnknown
            throw error
        }

        let outputUID: String
        do {
            outputUID = try Self.deviceUID(outputDevice)
        } catch {
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = kAudioObjectUnknown
            throw error
        }

        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Recorder System Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: 0
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: 1
                ]
            ]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID
        )
        guard aggStatus == noErr, newAggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = kAudioObjectUnknown
            throw TapError.createAggregateFailed(aggStatus)
        }
        self.aggregateID = newAggregateID

        let format: AVAudioFormat
        do {
            format = try Self.tapStreamFormat(newTapID)
        } catch {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            self.aggregateID = kAudioObjectUnknown
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = kAudioObjectUnknown
            throw error
        }

        return BuildResult(tapFormat: format)
    }

    private func installIOProcAndStartLocked() throws {
        guard aggregateID != kAudioObjectUnknown else {
            throw TapError.createIOProcFailed(kAudioHardwareBadObjectError)
        }
        guard let tapFmt = tapFormat else {
            throw TapError.invalidTapFormat
        }

        var newProcID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, inInputTime, _, _ in
            guard let self else { return }
            self.handleIO(inputData: inInputData, inputTime: inInputTime, tapFormat: tapFmt)
        }

        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, aggregateID, nil, ioBlock
        )
        guard createStatus == noErr, let procID = newProcID else {
            throw TapError.createIOProcFailed(createStatus)
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.ioProcID = nil
            throw TapError.startDeviceFailed(startStatus)
        }
    }

    private func destroyTapAndAggregateLocked() {
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func handleIO(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>,
        tapFormat: AVAudioFormat
    ) {
        let now = mach_absolute_time()
        lastCallbackHostTime.withLock { $0 = now }

        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: inputData,
            deallocator: nil
        ) else {
            return
        }

        let frameCount = pcm.frameLength
        guard frameCount > 0, let channelData = pcm.floatChannelData else { return }

        let channelCount = Int(tapFormat.channelCount)
        let n = vDSP_Length(frameCount)

        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, n)
        if rms > 0.000_03 {
            lastLoudHostTime.withLock { $0 = now }
        }
        let db: Float = rms > 0 ? 20 * log10(rms) : -120

        if Self.hostTimeToNanos(now &- lastMeterPostHostTime) >= Self.meterIntervalNanos {
            lastMeterPostHostTime = now
            onLevelDB?(db)
        }

        if paused.withLock({ $0 }) {
            return
        }

        guard let ring = self.ring else { return }

        if firstHostTime == nil {
            firstHostTime = inputTime.pointee.mHostTime
        }

        if channelCount <= 1 {
            ring.write(channelData[0], count: Int(frameCount))
        } else if let scratch = self.scratch {
            let interleaved = tapFormat.isInterleaved
            let total = Int(frameCount)
            var offset = 0
            while offset < total {
                let chunk = min(total - offset, scratchCapacity)
                let cn = vDSP_Length(chunk)

                if interleaved {
                    let base = channelData[0] + offset * channelCount
                    memcpy_stride(dst: scratch, src: base, stride: channelCount, count: chunk)
                    for ch in 1..<channelCount {
                        vDSP_vadd(scratch, 1, base + ch, vDSP_Stride(channelCount),
                                  scratch, 1, cn)
                    }
                } else {
                    memcpy(scratch, channelData[0] + offset, chunk * MemoryLayout<Float>.stride)
                    for ch in 1..<channelCount {
                        vDSP_vadd(scratch, 1, channelData[ch] + offset, 1, scratch, 1, cn)
                    }
                }

                var scale = 1.0 / Float(channelCount)
                vDSP_vsmul(scratch, 1, &scale, scratch, 1, cn)
                ring.write(scratch, count: chunk)
                offset += chunk
            }
        }
    }

    @inline(__always)
    private func memcpy_stride(
        dst: UnsafeMutablePointer<Float>,
        src: UnsafePointer<Float>,
        stride: Int,
        count: Int
    ) {
        cblas_scopy(Int32(count), src, Int32(stride), dst, 1)
    }

    private func startWriterThread(file: AVAudioFile, writeFormat: AVAudioFormat, ring: FloatRingBuffer) {
        let chunkFrames = 4096
        let thread = Thread { [weak self] in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: writeFormat,
                frameCapacity: AVAudioFrameCount(chunkFrames)
            ), let dst = buffer.floatChannelData?[0] else { return }

            while true {
                let stopRequested = self?.writerShouldStop.withLock { $0 } ?? true
                let n = ring.read(into: dst, maxCount: chunkFrames)
                if n > 0 {
                    buffer.frameLength = AVAudioFrameCount(n)
                    do {
                        try file.write(from: buffer)
                        self?.capturedFrames += AVAudioFramePosition(n)
                    } catch {
                        self?.onFatalError?(error)
                    }
                } else if stopRequested {
                    break
                } else {
                    usleep(5_000)
                }
            }
        }
        thread.name = "com.tobi.Recorder.desktopWriter"
        thread.qualityOfService = .userInitiated
        writerThread = thread
        thread.start()
    }

    private func stopWriterThreadAndDrain() {
        writerShouldStop.withLock { $0 = true }
        if let thread = writerThread {
            while !thread.isFinished { usleep(2_000) }
        }
        writerThread = nil
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func watchdogTick() {
        if paused.withLock({ $0 }) { return }

        lock.lock()
        let isRunning = started && !rebuilding
        let outDevice = lock_currentOutputDeviceLocked()
        lock.unlock()
        guard isRunning else { return }

        guard let outDevice, Self.deviceIsRunningSomewhere(outDevice) else { return }

        let now = mach_absolute_time()
        let lastLoud = lastLoudHostTime.withLock { $0 }
        let elapsedNanos = Self.hostTimeToNanos(now &- lastLoud)
        let elapsedSeconds = Double(elapsedNanos) / 1_000_000_000.0

        if elapsedSeconds >= watchdogSilenceThreshold {
            rebuildCount += 1
            rebuildTapAndAggregate()
        }
    }

    private func lock_currentOutputDeviceLocked() -> AudioObjectID? {
        return try? Self.defaultSystemOutputDevice()
    }

    private func rebuildTapAndAggregate() {
        lock.lock()

        guard started, !rebuilding else {
            lock.unlock()
            return
        }
        rebuilding = true

        destroyTapAndAggregateLocked()

        tapUUID = UUID()

        do {
            let built = try buildTapAndAggregateLocked()

            self.tapFormat = built.tapFormat
            if writeFormat == nil {
                self.writeFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: built.tapFormat.sampleRate,
                    channels: 1,
                    interleaved: false
                )
            }
            try installIOProcAndStartLocked()
        } catch {
            rebuilding = false
            lock.unlock()

            onFatalError?(error)
            return
        }

        let now = mach_absolute_time()
        lastLoudHostTime.withLock { $0 = now }
        lastCallbackHostTime.withLock { $0 = now }

        rebuilding = false
        lock.unlock()
    }

    private static func defaultSystemOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw TapError.noDefaultOutputDevice(status)
        }
        return deviceID
    }

    private static func deviceUID(_ deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfUID)
        guard status == noErr, let uid = cfUID?.takeRetainedValue() else {
            throw TapError.readDeviceUIDFailed(status)
        }
        return uid as String
    }

    private static func tapStreamFormat(_ tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw TapError.readTapFormatFailed(status)
        }
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.invalidTapFormat
        }
        return format
    }

    private static func deviceIsRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running)
        guard status == noErr else { return false }
        return running != 0
    }
}
