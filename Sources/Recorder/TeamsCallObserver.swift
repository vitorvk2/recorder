import CoreAudio
import Foundation
import Observation
import os

@MainActor
protocol TeamsAudioActivity: AnyObject {
    var isTeamsCapturing: Bool { get }
    func start(onChange: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

@MainActor
final class CoreAudioTeamsActivity: TeamsAudioActivity {
    nonisolated static let bundlePrefix = "com.microsoft.teams"

    private let pollInterval: TimeInterval
    private var onChange: (@MainActor @Sendable () -> Void)?
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var pollTimer: Timer?
    private var teamsProcesses: [AudioObjectID] = []

    init(pollInterval: TimeInterval = 2) {
        self.pollInterval = pollInterval
    }

    var isTeamsCapturing: Bool {
        teamsProcesses.contains { Self.uint32(kAudioProcessPropertyIsRunningInput, of: $0) != 0 }
    }

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        stop()
        self.onChange = onChange
        refreshTeamsProcesses()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refreshTeamsProcesses()
                self?.onChange?()
            }
        }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        if status == noErr {
            processListListener = block
        } else {
            TeamsCallObserver.logger.error("Cannot observe audio processes: \(status)")
        }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        if let processListListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, processListListener)
        }
        processListListener = nil
        pollTimer?.invalidate()
        pollTimer = nil
        onChange = nil
    }

    private func refreshTeamsProcesses() {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            teamsProcesses = []
            return
        }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else {
            teamsProcesses = []
            return
        }
        teamsProcesses = processes.filter { Self.bundleID(of: $0).hasPrefix(Self.bundlePrefix) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func bundleID(of process: AudioObjectID) -> String {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return "" }
        return value.takeRetainedValue() as String
    }
}

@MainActor
@Observable
final class TeamsCallObserver {
    nonisolated static let logger = Logger(subsystem: "com.tobi.Recorder", category: "teams")

    private(set) var isInCall = false

    var onFirstCall: (() -> Void)?
    var onAllCallsEnded: (() -> Void)?
    var onChange: (() -> Void)?

    @ObservationIgnored private let activity: TeamsAudioActivity
    @ObservationIgnored private let startDelay: TimeInterval
    @ObservationIgnored private let stopGrace: TimeInterval
    @ObservationIgnored private var transitionTimer: Timer?

    init(activity: TeamsAudioActivity? = nil, startDelay: TimeInterval = 3, stopGrace: TimeInterval = 8) {
        self.activity = activity ?? CoreAudioTeamsActivity()
        self.startDelay = startDelay
        self.stopGrace = stopGrace
    }

    func start() {
        stop()
        isInCall = false
        activity.start { [weak self] in self?.evaluate() }
        Self.logger.notice("Watching Teams microphone use")
        evaluate()
    }

    func stop() {
        activity.stop()
        transitionTimer?.invalidate()
        transitionTimer = nil
    }

    private func evaluate() {
        let capturing = activity.isTeamsCapturing
        if capturing == isInCall {
            transitionTimer?.invalidate()
            transitionTimer = nil
        } else if transitionTimer == nil {
            let timer = Timer(timeInterval: capturing ? startDelay : stopGrace, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.settle() }
            }
            RunLoop.main.add(timer, forMode: .common)
            transitionTimer = timer
        }
    }

    private func settle() {
        transitionTimer = nil
        let capturing = activity.isTeamsCapturing
        guard capturing != isInCall else { return }
        isInCall = capturing
        if capturing {
            Self.logger.notice("Teams call started")
            onFirstCall?()
        } else {
            Self.logger.notice("Teams call ended")
            onAllCallsEnded?()
        }
        onChange?()
    }
}
