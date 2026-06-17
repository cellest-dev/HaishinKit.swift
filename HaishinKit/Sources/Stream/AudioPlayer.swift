@preconcurrency import AVFoundation
import Foundation

/// An object that provides the interface to control audio playback.
public final actor AudioPlayer {
    private var connected: [AudioPlayerNode: Bool] = [:]
    private var audioEngine: AVAudioEngine?
    private var playerNodes: [AudioPlayerNode: AVAudioPlayerNode] = [:]

    /// Create an audio player object.
    public init(audioEngine: AVAudioEngine) {
        self.audioEngine = audioEngine
        hkdiag("[HKDIAG] AudioPlayer.init engine=%p", audioEngine)
    }

    func isConnected(_ playerNode: AudioPlayerNode) -> Bool {
        return connected[playerNode] == true
    }

    func connect(_ playerNode: AudioPlayerNode, format: AVAudioFormat?) {
        guard let audioEngine, let avPlayerNode = playerNodes[playerNode] else {
            hkdiag("[HKDIAG] AudioPlayer.connect ABORT engine=%@ playerNodes[node]=%@",
                  audioEngine == nil ? "nil" : "set",
                  playerNodes[playerNode] == nil ? "nil" : "set")
            return
        }
        if let format {
            hkdiag("[HKDIAG] AudioPlayer.connect pre format=%@ isRunning=%@",
                  String(describing: format),
                  audioEngine.isRunning ? "true" : "false")
            audioEngine.connect(avPlayerNode, to: audioEngine.outputNode, format: format)
            if !audioEngine.isRunning {
                do {
                    try audioEngine.start()
                    hkdiag("[HKDIAG] AudioPlayer.connect engine.start OK isRunning=%@",
                          audioEngine.isRunning ? "true" : "false")
                } catch {
                    hkdiag("[HKDIAG] AudioPlayer.connect engine.start FAILED %@",
                          error.localizedDescription)
                }
            } else {
                hkdiag("[HKDIAG] AudioPlayer.connect engine already running")
            }
            connected[playerNode] = true
            hkdiag("[HKDIAG] AudioPlayer.connect DONE connected=true outFmt=%@",
                  String(describing: audioEngine.outputNode.outputFormat(forBus: 0)))
        } else {
            hkdiag("[HKDIAG] AudioPlayer.connect disconnect (format=nil)")
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.disconnectNodeOutput(avPlayerNode)
            connected[playerNode] = nil
        }
    }

    func detach(_ playerNode: AudioPlayerNode) {
        if let playerNode = playerNodes[playerNode] {
            audioEngine?.detach(playerNode)
        }
        playerNodes[playerNode] = nil
    }

    func makePlayerNode() -> AudioPlayerNode {
        let avAudioPlayerNode = AVAudioPlayerNode()
        audioEngine?.attach(avAudioPlayerNode)
        let playerNode = AudioPlayerNode(player: self, playerNode: avAudioPlayerNode)
        playerNodes[playerNode] = avAudioPlayerNode
        hkdiag("[HKDIAG] AudioPlayer.makePlayerNode attached node=%p engineSet=%@",
              avAudioPlayerNode, audioEngine == nil ? "false" : "true")
        return playerNode
    }
}
