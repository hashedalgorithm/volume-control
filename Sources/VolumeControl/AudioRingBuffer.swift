import CoreAudio
import Foundation

/// Minimal lock-protected ring buffer moving non-interleaved Float32 frames from a
/// CoreAudio IOProc (capture thread) to an `AVAudioSourceNode` render callback
/// (playback thread). Channel count is fixed on first write; later writes with a
/// different channel count are dropped rather than corrupting the layout.
final class AudioRingBuffer {
    private let lock = NSLock()
    private var channelBuffers: [[Float]] = []
    private var writeIndex = 0
    private var readIndex = 0
    private var filled = 0
    private let capacityFrames: Int

    init(capacityFrames: Int) {
        self.capacityFrames = capacityFrames
    }

    func write(from bufferList: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard abl.count > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        if channelBuffers.count != abl.count {
            channelBuffers = (0..<abl.count).map { _ in [Float](repeating: 0, count: capacityFrames) }
            writeIndex = 0
            readIndex = 0
            filled = 0
        }

        let frameCount = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
        for channel in 0..<abl.count {
            guard let data = abl[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frameCount {
                channelBuffers[channel][(writeIndex + frame) % capacityFrames] = data[frame]
            }
        }
        writeIndex = (writeIndex + frameCount) % capacityFrames
        filled = min(capacityFrames, filled + frameCount)
    }

    func read(frameCount: Int, into bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)

        lock.lock()
        let available = min(frameCount, filled)
        let channels = channelBuffers
        let start = readIndex
        readIndex = (readIndex + available) % max(capacityFrames, 1)
        filled -= available
        lock.unlock()

        for (channel, destBuffer) in abl.enumerated() {
            guard let dest = destBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let source = channel < channels.count ? channels[channel] : []
            for frame in 0..<frameCount {
                if frame < available, !source.isEmpty {
                    dest[frame] = source[(start + frame) % capacityFrames]
                } else {
                    dest[frame] = 0 // underrun: emit silence rather than stale/garbage samples
                }
            }
        }
    }
}
