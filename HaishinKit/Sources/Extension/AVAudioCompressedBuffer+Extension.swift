import AVFoundation
import Foundation

extension AVAudioCompressedBuffer {
    @discardableResult
    @inline(__always)
    final func copy(_ buffer: AVAudioBuffer) -> Bool {
        guard let buffer = buffer as? AVAudioCompressedBuffer else {
            return false
        }
        if let packetDescriptions = buffer.packetDescriptions {
            self.packetDescriptions?.pointee = packetDescriptions.pointee
        }
        packetCount = buffer.packetCount
        byteLength = buffer.byteLength
        data.copyMemory(from: buffer.data, byteCount: Int(buffer.byteLength))
        return true
    }

    package final func clone() -> AVAudioCompressedBuffer {
        let buffer = AVAudioCompressedBuffer(
            format: format,
            packetCapacity: packetCapacity,
            maximumPacketSize: maximumPacketSize
        )
        buffer.copy(self)
        return buffer
    }

    package func encode(to data: inout Data) {
        guard let config = AudioSpecificConfig(formatDescription: format.formatDescription) else {
            return
        }
        config.encode(to: &data, length: Int(byteLength))
        data.withUnsafeMutableBytes {
            guard let baseAddress = $0.baseAddress else {
                return
            }
            memcpy(baseAddress.advanced(by: AudioSpecificConfig.adtsHeaderSize), self.data, Int(self.byteLength))
        }
    }
}
