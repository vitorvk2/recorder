import Foundation
import Synchronization

final class FloatRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int

    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let droppedFrames = Atomic<Int>(0)

    init(capacityFrames: Int) {
        precondition(capacityFrames > 0)
        capacity = capacityFrames
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames)
        storage.initialize(repeating: 0, count: capacityFrames)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    var totalDropped: Int { droppedFrames.load(ordering: .relaxed) }

    @discardableResult
    func write(_ src: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return true }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let free = capacity - (w - r)
        if count > free {
            droppedFrames.wrappingAdd(count, ordering: .relaxed)
            return false
        }
        let start = w % capacity
        let first = min(count, capacity - start)
        memcpy(storage + start, src, first * MemoryLayout<Float>.stride)
        if first < count {
            memcpy(storage, src + first, (count - first) * MemoryLayout<Float>.stride)
        }

        writeIndex.store(w + count, ordering: .releasing)
        return true
    }

    func read(into dst: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)

        let w = writeIndex.load(ordering: .acquiring)
        let available = w - r
        if available <= 0 { return 0 }
        let count = min(available, maxCount)
        let start = r % capacity
        let first = min(count, capacity - start)
        memcpy(dst, storage + start, first * MemoryLayout<Float>.stride)
        if first < count {
            memcpy(dst + first, storage, (count - first) * MemoryLayout<Float>.stride)
        }
        readIndex.store(r + count, ordering: .releasing)
        return count
    }
}
