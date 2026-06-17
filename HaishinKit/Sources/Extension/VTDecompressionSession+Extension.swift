import Foundation
import VideoToolbox

private enum VTDecompressionDiag {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var inputCount = 0
    nonisolated(unsafe) private static var outputCount = 0
    nonisolated(unsafe) private static var nilOutputCount = 0

    static func nextInput(_ sampleBuffer: CMSampleBuffer) -> Int {
        lock.lock()
        defer { lock.unlock() }
        inputCount += 1
        if inputCount <= 5 || inputCount % 100 == 0 {
            hkdiag("[HKDIAG] VTDecompression.input count=%d pts=%f dts=%f duration=%f key=%@",
                  inputCount,
                  sampleBuffer.presentationTimeStamp.seconds,
                  sampleBuffer.decodeTimeStamp.seconds,
                  sampleBuffer.duration.seconds,
                  sampleBuffer.isNotSync ? "false" : "true")
        }
        return inputCount
    }

    static func output(status: OSStatus, hasImageBuffer: Bool, presentationTimeStamp: CMTime, duration: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        if hasImageBuffer {
            outputCount += 1
        } else {
            nilOutputCount += 1
        }
        if outputCount <= 5 || outputCount % 100 == 0 || status != noErr || !hasImageBuffer {
            hkdiag("[HKDIAG] VTDecompression.output out=%d nil=%d status=%d hasImage=%@ pts=%f duration=%f",
                  outputCount,
                  nilOutputCount,
                  Int(status),
                  hasImageBuffer ? "true" : "false",
                  presentationTimeStamp.seconds,
                  duration.seconds)
        }
    }
}

extension VTDecompressionSession: VTSessionConvertible {
    static let defaultDecodeFlags: VTDecodeFrameFlags = [
        ._EnableAsynchronousDecompression,
        ._EnableTemporalProcessing
    ]

    @inline(__always)
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: AsyncStream<CMSampleBuffer>.Continuation?) throws {
        let inputCount = VTDecompressionDiag.nextInput(sampleBuffer)
        var flagsOut: VTDecodeInfoFlags = []
        var _: VTEncodeInfoFlags = []
        let status = VTDecompressionSessionDecodeFrame(
            self,
            sampleBuffer: sampleBuffer,
            flags: Self.defaultDecodeFlags,
            infoFlagsOut: &flagsOut,
            outputHandler: { status, _, imageBuffer, presentationTimeStamp, duration in
                VTDecompressionDiag.output(
                    status: status,
                    hasImageBuffer: imageBuffer != nil,
                    presentationTimeStamp: presentationTimeStamp,
                    duration: duration
                )
                guard let imageBuffer else {
                    return
                }
                var status = noErr
                var outputFormat: CMFormatDescription?
                status = CMVideoFormatDescriptionCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: imageBuffer,
                    formatDescriptionOut: &outputFormat
                )
                guard let outputFormat, status == noErr else {
                    return
                }
                var timingInfo = CMSampleTimingInfo(
                    duration: duration,
                    presentationTimeStamp: presentationTimeStamp,
                    decodeTimeStamp: .invalid
                )
                var sampleBuffer: CMSampleBuffer?
                status = CMSampleBufferCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: imageBuffer,
                    dataReady: true,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: outputFormat,
                    sampleTiming: &timingInfo,
                    sampleBufferOut: &sampleBuffer
                )
                if let sampleBuffer {
                    continuation?.yield(sampleBuffer)
                }
            }
        )
        if status != noErr {
            hkdiag("[HKDIAG] VTDecompression.decodeFrame ERROR input=%d status=%d flags=%@",
                  inputCount,
                  Int(status),
                  String(describing: flagsOut))
            throw VTSessionError.failedToConvert(status: status)
        }
        if inputCount <= 5 || inputCount % 100 == 0 {
            hkdiag("[HKDIAG] VTDecompression.decodeFrame submitted input=%d status=%d flags=%@",
                  inputCount,
                  Int(status),
                  String(describing: flagsOut))
        }
    }

    func invalidate() {
        VTDecompressionSessionInvalidate(self)
    }
}
