import Foundation
import AVFoundation
import Accelerate

enum RMSMeter {
    static let floorDB: Float = -120

    static func dBFS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return floorDB }

        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0 else { return floorDB }

        var rms: Float = 0
        vDSP_rmsqv(channels[0], 1, &rms, frameCount)

        guard rms > 1e-7, rms.isFinite else { return floorDB }

        let db = 20 * log10(rms)
        return db.isFinite ? max(db, floorDB) : floorDB
    }
}

final class SilenceMonitor {
    var thresholdDB: Float

    var timeout: TimeInterval

    private let onTimeout: () -> Void

    private let lock = OSAllocatedUnfairLock(initialState: Date())

    private var ticker: Timer?

    private let pollInterval: TimeInterval = 5

    init(thresholdDB: Float, timeout: TimeInterval, onTimeout: @escaping () -> Void) {
        self.thresholdDB = thresholdDB
        self.timeout = timeout
        self.onTimeout = onTimeout
    }

    func noteLevel(_ db: Float) {
        guard db > thresholdDB else { return }
        let now = Date()
        lock.withLock { $0 = now }
    }

    func start() {
        let now = Date()
        lock.withLock { $0 = now }

        ticker?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }

        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        let lastLoud = lock.withLock { $0 }
        guard Date().timeIntervalSince(lastLoud) >= timeout else { return }

        stop()
        onTimeout()
    }
}
