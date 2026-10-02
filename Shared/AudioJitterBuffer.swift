import Foundation

/// Mono 48 kHz PCM. The caller serializes access. Storage is fixed-size so the
/// audio callback never shifts or grows an array while consuming samples.
struct AudioJitterBuffer {
    private var storage: [Int16]
    private var readIndex = 0
    private(set) var count = 0
    private(set) var isBuffering = true
    private(set) var underruns = 0
    private(set) var droppedFrames = 0
    let targetFrames: Int
    private let fadeFrames: Int
    private var fadeRemaining = 0

    init(targetFrames: Int = 28_800, maximumFrames: Int = 144_000, fadeFrames: Int = 240) {
        precondition(targetFrames > 0 && maximumFrames >= targetFrames && fadeFrames >= 0)
        self.targetFrames = targetFrames
        self.fadeFrames = fadeFrames
        storage = [Int16](repeating: 0, count: maximumFrames)
    }

    mutating func append(_ pcm: Data) {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { return }
        let incoming = pcm.count / 2
        // After a long stall, catch up to a fresh target-sized window rather
        // than speaking several seconds of stale microphone audio.
        let overflow = count + incoming > storage.count
        if overflow {
            let keepExisting = max(0, targetFrames - incoming)
            discard(max(0, count - keepExisting))
            isBuffering = true
        }
        let first = overflow ? max(0, incoming - targetFrames) : 0
        droppedFrames += first
        pcm.withUnsafeBytes { bytes in
            for frame in first..<incoming {
                let bits = UInt16(bytes[frame * 2]) | (UInt16(bytes[frame * 2 + 1]) << 8)
                storage[(readIndex + count) % storage.count] = Int16(bitPattern: bits)
                count += 1
            }
        }
    }

    /// Duplicates mono into the interleaved stereo BlackHole output.
    mutating func render(into output: UnsafeMutablePointer<Int16>, frames: Int) {
        output.update(repeating: 0, count: frames * 2)
        if isBuffering {
            guard count >= targetFrames else { return }
            isBuffering = false
            fadeRemaining = fadeFrames
        }
        let available = min(frames, count)
        let drainsBuffer = available == count
        for frame in 0..<available {
            var gain = 1.0
            if fadeRemaining > 0 {
                gain *= Double(fadeFrames - fadeRemaining + 1) / Double(fadeFrames)
                fadeRemaining -= 1
            }
            if drainsBuffer && fadeFrames > 0 {
                gain *= min(1, Double(available - frame - 1) / Double(fadeFrames))
            }
            let sample = Int16(Double(storage[(readIndex + frame) % storage.count]) * gain)
            output[frame * 2] = sample
            output[frame * 2 + 1] = sample
        }
        readIndex = (readIndex + available) % storage.count
        count -= available
        if count == 0 {
            underruns += 1
            isBuffering = true
        }
    }

    mutating func clear() {
        count = 0
        readIndex = 0
        isBuffering = true
        fadeRemaining = 0
    }

    private mutating func discard(_ frames: Int) {
        readIndex = (readIndex + frames) % storage.count
        count -= frames
        droppedFrames += frames
    }
}
