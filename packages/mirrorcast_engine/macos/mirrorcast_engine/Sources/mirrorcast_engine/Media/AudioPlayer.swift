import AVFoundation
import Foundation

/// Plays the phone's audio (48 kHz, 16-bit, stereo PCM in 10 ms chunks) with
/// as little buffering as possible.
///
/// **Drift protection.** Network jitter can make chunks arrive in bursts. We
/// keep at most `maxQueued` chunks (about 50 ms) scheduled; extra chunks are
/// dropped so audio snaps back to real time instead of slowly drifting behind
/// the video. A larger backlog (after a stall) is flushed entirely.
///
/// **Underrun cushion.** After the queue runs dry, we wait for two chunks
/// before resuming, which avoids crackles on a jittery link at the cost of
/// 10 ms.
///
/// Call `enqueue` from one queue (the receiver queue).
final class AudioPlayer {
    private struct State {
        var queued = 0
        var generation = 0
    }

    static let maxQueued = 5
    static let flushThreshold = 10

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let state = Locked(State())
    private let queue: DispatchQueue
    private var primingBuffer: AVAudioPCMBuffer?
    private var configurationObserver: NSObjectProtocol?
    private var isRunning = false

    private(set) var droppedChunks = 0

    var isMuted = false {
        didSet { player.volume = isMuted ? 0 : 1 }
    }

    /// Milliseconds of audio currently waiting to be played.
    var bufferedMilliseconds: Int { state.withLock { $0.queued } * 10 }

    init(queue: DispatchQueue) {
        self.queue = queue
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Output device changed (headphones plugged in, AirPods connected...).
            self?.queue.async { self?.restart() }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine.stop()
    }

    func start() {
        guard !isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
            player.play()
            isRunning = true
        } catch {
            NSLog("MirrorCast: audio engine failed to start: \(error)")
        }
    }

    func stop() {
        flush()
        player.stop()
        engine.stop()
        isRunning = false
    }

    /// Drops everything that's queued (for example when the phone turns audio off).
    func flush() {
        state.withLock { state in
            state.generation += 1
            state.queued = 0
        }
        primingBuffer = nil
        if isRunning {
            player.stop()
            player.play()
        }
    }

    func enqueue(_ pcm: Data) {
        guard isRunning else { return }
        let frameCount = pcm.count / 4 // 2 channels * 2 bytes
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channels = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        // Interleaved Int16 little-endian -> two planar Float32 channels.
        let left = channels[0]
        let right = channels[1]
        pcm.withUnsafeBytes { raw in
            for frame in 0..<frameCount {
                let l = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: frame * 4, as: Int16.self))
                let r = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: frame * 4 + 2, as: Int16.self))
                left[frame] = Float(l) / 32_768
                right[frame] = Float(r) / 32_768
            }
        }

        let queued = state.withLock { $0.queued }
        if queued >= Self.flushThreshold {
            flush() // long stall: jump straight back to real time
        } else if queued >= Self.maxQueued {
            droppedChunks += 1
            return
        }

        if state.withLock({ $0.queued }) == 0 {
            // Underrun: wait for a second chunk before resuming.
            guard let first = primingBuffer else {
                primingBuffer = buffer
                return
            }
            primingBuffer = nil
            schedule(first)
        }
        schedule(buffer)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let generation = state.withLock { state -> Int in
            state.queued += 1
            return state.generation
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            self?.state.withLock { state in
                if state.generation == generation { state.queued = max(0, state.queued - 1) }
            }
        }
    }

    private func restart() {
        let wasRunning = isRunning
        isRunning = false
        state.withLock { state in
            state.generation += 1
            state.queued = 0
        }
        primingBuffer = nil
        engine.stop()
        if wasRunning { start() }
    }
}
