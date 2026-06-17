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

    @discardableResult
    func connect(_ playerNode: AudioPlayerNode, format: AVAudioFormat?, force: Bool = false) -> Bool {
        guard let audioEngine, let avPlayerNode = playerNodes[playerNode] else {
            hkdiag("[HKDIAG] AudioPlayer.connect ABORT engine=%@ playerNodes[node]=%@",
                  audioEngine == nil ? "nil" : "set",
                  playerNodes[playerNode] == nil ? "nil" : "set")
            return false
        }
        if let format {
            guard avPlayerNode.engine === audioEngine else {
                connected[playerNode] = nil
                hkdiag("[HKDIAG] AudioPlayer.connect ABORT detached node=%p", avPlayerNode)
                return false
            }
            if connected[playerNode] == true, audioEngine.isRunning, !force {
                return true
            }
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
            connected[playerNode] = audioEngine.isRunning
            hkdiag("[HKDIAG] AudioPlayer.connect DONE connected=%@ outFmt=%@",
                  connected[playerNode] == true ? "true" : "false",
                  String(describing: audioEngine.outputNode.outputFormat(forBus: 0)))
            return connected[playerNode] == true
        } else {
            hkdiag("[HKDIAG] AudioPlayer.connect disconnect (format=nil)")
            connected[playerNode] = nil
            guard avPlayerNode.engine === audioEngine else {
                hkdiag("[HKDIAG] AudioPlayer.connect disconnect SKIP detached node=%p", avPlayerNode)
                return false
            }
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.disconnectNodeOutput(avPlayerNode)
            return false
        }
    }

    func detach(_ playerNode: AudioPlayerNode) {
        connected[playerNode] = nil
        guard let avPlayerNode = playerNodes[playerNode] else {
            return
        }
        playerNodes[playerNode] = nil
        guard let audioEngine, avPlayerNode.engine === audioEngine else {
            hkdiag("[HKDIAG] AudioPlayer.detach SKIP detached node=%p", avPlayerNode)
            return
        }
        hkdiag("[HKDIAG] AudioPlayer.detach node=%p engineRunning=%@",
              avPlayerNode,
              audioEngine.isRunning ? "true" : "false")
        audioEngine.detach(avPlayerNode)
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
