@preconcurrency import AVFoundation
import Foundation

final actor AudioPlayerNode {
    static let bufferCounts: Int = 10

    var currentTime: TimeInterval {
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
    private var isBuffering = true
    private weak var player: AudioPlayer?
    private var format: AVAudioFormat? {
        didSet {
            guard format != oldValue else {
                return
            }
            Task { [format] in
                await player?.connect(self, format: format)
            }
        }
    }

    init(player: AudioPlayer, playerNode: AVAudioPlayerNode) {
        self.player = player
        self.playerNode = playerNode
    }

    func setSoundTransfrom(_ soundTransfrom: SoundTransform) {
        soundTransfrom.apply(playerNode)
    }

    func enqueue(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) async {
        let isFormatChange = (format != audioBuffer.format)
        format = audioBuffer.format
        let isConn = (await player?.isConnected(self) == true)
        let isPCM = (audioBuffer is AVAudioPCMBuffer)
        if isFormatChange || !isConn {
            NSLog("[HKDIAG] AudioPlayerNode.enqueue formatChange=%@ isConnected=%@ isPCM=%@ buffered=%d",
                  isFormatChange ? "true" : "false",
                  isConn ? "true" : "false",
                  isPCM ? "true" : "false",
                  scheduledAudioBuffers)
        }
        guard let audioBuffer = audioBuffer as? AVAudioPCMBuffer, isConn else {
            return
        }
        if !audioTime.hasAnchor {
            audioTime.anchor(playerNode.lastRenderTime ?? AVAudioTime(hostTime: 0))
        }
        scheduledAudioBuffers += 1
        if !isPaused && !playerNode.isPlaying && Self.bufferCounts <= scheduledAudioBuffers {
            NSLog("[HKDIAG] AudioPlayerNode.enqueue playerNode.play() buffered=%d",
                  scheduledAudioBuffers)
            playerNode.play()
        }
        Task {
            audioTime.advanced(Int64(audioBuffer.frameLength))
            await playerNode.scheduleBuffer(audioBuffer, at: audioTime.at)
            scheduledAudioBuffers -= 1
            if scheduledAudioBuffers == 0 {
                isBuffering = true
            }
        }
    }

    func detach() async {
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
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        if playerNode.isPlaying {
            playerNode.stop()
            playerNode.reset()
        }
        audioTime.reset()
        format = nil
        isRunning = false
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
