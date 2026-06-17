@preconcurrency import AVFoundation
import Foundation

final actor AudioPlayerNode {
    static let bufferCounts: Int = 10

    var currentTime: TimeInterval {
        guard isRunning, playerNode.engine != nil else {
            return 0.0
        }
        if playerNode.isPlaying {
            guard
                let nodeTime = playerNode.lastRenderTime,
                let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
                return 0.0
            }
            return TimeInterval(playerTime.sampleTime) / playerTime.sampleRate
        }
        return 0.0
    }
    private(set) var isPaused = false
    private(set) var isRunning = false
    private(set) var soundTransfrom = SoundTransform()
    private let playerNode: AVAudioPlayerNode
    private var audioTime = AudioTime()
    private var scheduledAudioBuffers: Int = 0
    private var scheduledAudioBufferSequence: Int = 0
    private var completedAudioBuffers: Int = 0
    private var generation: UInt64 = 0
    private var isBuffering = true
    private weak var player: AudioPlayer?
    private var format: AVAudioFormat?

    init(player: AudioPlayer, playerNode: AVAudioPlayerNode) {
        self.player = player
        self.playerNode = playerNode
    }

    func setSoundTransfrom(_ soundTransfrom: SoundTransform) {
        soundTransfrom.apply(playerNode)
    }

    func enqueue(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) async {
        guard isRunning else {
            return
        }
        guard let audioBuffer = audioBuffer as? AVAudioPCMBuffer else {
            hkdiag("[HKDIAG] AudioPlayerNode.enqueue DROP nonPCM format=%@",
                  String(describing: audioBuffer.format))
            return
        }
        guard playerNode.engine != nil else {
            hkdiag("[HKDIAG] AudioPlayerNode.enqueue DROP detached frames=%d",
                  Int(audioBuffer.frameLength))
            return
        }
        let isFormatChange = (format != audioBuffer.format)
        format = audioBuffer.format
        let isConn = await player?.connect(self, format: audioBuffer.format, force: isFormatChange) == true
        guard isRunning else {
            hkdiag("[HKDIAG] AudioPlayerNode.enqueue DROP stopped-after-connect frames=%d",
                  Int(audioBuffer.frameLength))
            return
        }
        if isFormatChange || !isConn {
            hkdiag("[HKDIAG] AudioPlayerNode.enqueue formatChange=%@ isConnected=%@ isPCM=true buffered=%d",
                  isFormatChange ? "true" : "false",
                  isConn ? "true" : "false",
                  scheduledAudioBuffers)
        }
        guard isConn, playerNode.engine != nil else {
            hkdiag("[HKDIAG] AudioPlayerNode.enqueue DROP detached frames=%d",
                  Int(audioBuffer.frameLength))
            return
        }
        let currentGeneration = generation
        scheduledAudioBuffers += 1
        scheduledAudioBufferSequence += 1
        let sequence = scheduledAudioBufferSequence
        let duration = Double(audioBuffer.frameLength) / audioBuffer.format.sampleRate
        if sequence <= 5 || sequence % 100 == 0 {
            if playerNode.engine == nil {
                hkdiag("[HKDIAG] AudioPlayerNode.schedule enqueue seq=%d buffered=%d frames=%d duration=%f isPlaying=detached nodeSample=-1 playerSample=-1 playerRate=-1 volume=-1 pan=-1",
                      sequence,
                      scheduledAudioBuffers,
                      Int(audioBuffer.frameLength),
                      duration)
            } else {
                let nodeTime = playerNode.lastRenderTime
                let playerTime = nodeTime.flatMap { playerNode.playerTime(forNodeTime: $0) }
                hkdiag("[HKDIAG] AudioPlayerNode.schedule enqueue seq=%d buffered=%d frames=%d duration=%f isPlaying=%@ nodeSample=%lld playerSample=%lld playerRate=%f volume=%f pan=%f",
                      sequence,
                      scheduledAudioBuffers,
                      Int(audioBuffer.frameLength),
                      duration,
                      playerNode.isPlaying ? "true" : "false",
                      nodeTime?.sampleTime ?? -1,
                      playerTime?.sampleTime ?? -1,
                      playerTime?.sampleRate ?? -1,
                      playerNode.volume,
                      playerNode.pan)
            }
        }
        if !isPaused && playerNode.engine != nil && !playerNode.isPlaying && Self.bufferCounts <= scheduledAudioBuffers {
            hkdiag("[HKDIAG] AudioPlayerNode.enqueue playerNode.play() buffered=%d",
                  scheduledAudioBuffers)
            playerNode.play()
        }
        Task {
            await scheduleQueuedBuffer(audioBuffer, sequence: sequence, generation: currentGeneration)
        }
    }

    private func scheduleQueuedBuffer(_ audioBuffer: AVAudioPCMBuffer, sequence: Int, generation: UInt64) async {
        guard isRunning, generation == self.generation, playerNode.engine != nil else {
            scheduledAudioBuffers = max(0, scheduledAudioBuffers - 1)
            hkdiag("[HKDIAG] AudioPlayerNode.schedule DROP seq=%d running=%@ stale=%@ engineSet=%@ buffered=%d",
                  sequence,
                  isRunning ? "true" : "false",
                  generation == self.generation ? "false" : "true",
                  playerNode.engine == nil ? "false" : "true",
                  scheduledAudioBuffers)
            return
        }
        await playerNode.scheduleBuffer(audioBuffer, at: nil)
        scheduledAudioBuffers = max(0, scheduledAudioBuffers - 1)
        guard isRunning, generation == self.generation else {
            if scheduledAudioBuffers == 0 {
                isBuffering = true
            }
            return
        }
        completedAudioBuffers += 1
        if completedAudioBuffers <= 5 || completedAudioBuffers % 100 == 0 {
            if playerNode.engine == nil {
                hkdiag("[HKDIAG] AudioPlayerNode.schedule complete seq=%d completed=%d buffered=%d isPlaying=detached nodeSample=-1 playerSample=-1 playerRate=-1",
                      sequence,
                      completedAudioBuffers,
                      scheduledAudioBuffers)
            } else {
                let nodeTime = playerNode.lastRenderTime
                let playerTime = nodeTime.flatMap { playerNode.playerTime(forNodeTime: $0) }
                hkdiag("[HKDIAG] AudioPlayerNode.schedule complete seq=%d completed=%d buffered=%d isPlaying=%@ nodeSample=%lld playerSample=%lld playerRate=%f",
                      sequence,
                      completedAudioBuffers,
                      scheduledAudioBuffers,
                      playerNode.isPlaying ? "true" : "false",
                      nodeTime?.sampleTime ?? -1,
                      playerTime?.sampleTime ?? -1,
                      playerTime?.sampleRate ?? -1)
            }
        }
        if scheduledAudioBuffers == 0 {
            isBuffering = true
        }
    }

    func detach() async {
        hkdiag("[HKDIAG] AudioPlayerNode.detach scheduled=%d completed=%d engineSet=%@",
              scheduledAudioBuffers,
              completedAudioBuffers,
              playerNode.engine == nil ? "false" : "true")
        stopRunning()
        await player?.detach(self)
    }
}

extension AudioPlayerNode: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() {
        guard !isRunning else {
            return
        }
        scheduledAudioBuffers = 0
        scheduledAudioBufferSequence = 0
        completedAudioBuffers = 0
        generation &+= 1
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        generation &+= 1
        scheduledAudioBuffers = 0
        isBuffering = true
        audioTime.reset()
        format = nil
        guard playerNode.engine != nil else {
            Task { await player?.connect(self, format: nil) }
            hkdiag("[HKDIAG] AudioPlayerNode.stopRunning detached scheduled=%d completed=%d",
                  scheduledAudioBuffers,
                  completedAudioBuffers)
            return
        }
        playerNode.stop()
        playerNode.reset()
        Task { await player?.connect(self, format: nil) }
    }
}

extension AudioPlayerNode: Hashable {
    // MARK: Hashable
    nonisolated public static func == (lhs: AudioPlayerNode, rhs: AudioPlayerNode) -> Bool {
        lhs === rhs
    }

    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
