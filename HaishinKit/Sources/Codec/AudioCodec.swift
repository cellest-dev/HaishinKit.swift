import AVFoundation
import Foundation

/// The AudioCodec translate audio data to another format.
/// - seealso: https://developer.apple.com/library/ios/technotes/tn2236/_index.html
final class AudioCodec {
    static let defaultFrameCapacity: UInt32 = 1024
    static let defaultInputBuffersCursor = 0

    var settings: AudioCodecSettings = .default {
        didSet {
            if settings.invalidateConverter(oldValue) {
                inputFormat = nil
            } else {
                settings.apply(audioConverter, oldValue: oldValue)
            }
        }
    }

    var outputFormat: AVAudioFormat? {
        return audioConverter?.outputFormat
    }

    @AsyncStreamedFlow
    var outputStream: AsyncStream<(AVAudioBuffer, AVAudioTime)>

    /// This instance is running to process(true) or not(false).
    private(set) var isRunning = false
    private(set) var inputFormat: AVAudioFormat? {
        didSet {
            guard inputFormat != oldValue else {
                return
            }
            inputBuffers.removeAll()
            inputBuffersCursor = Self.defaultInputBuffersCursor
            outputBuffers.removeAll()
            audioConverter = makeAudioConverter()
            for _ in 0..<settings.format.inputBufferCounts {
                if let inputBuffer = makeInputBuffer() {
                    inputBuffers.append(inputBuffer)
                }
            }
        }
    }
    private var audioTime = AudioTime()
    private var ringBuffer: AudioRingBuffer?
    private var inputBuffers: [AVAudioBuffer] = []
    private var outputBuffers: [AVAudioBuffer] = []
    private var audioConverter: AVAudioConverter?
    private var inputBuffersCursor = AudioCodec.defaultInputBuffersCursor
    private var diagAppendCount = 0
    private var diagOutputCount = 0
    private var diagLastOutputStatus: AVAudioConverterOutputStatus?

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            return
        }
        switch settings.format {
        case .pcm:
            if let formatDescription = sampleBuffer.formatDescription, inputFormat?.formatDescription != formatDescription {
                inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
            }
            var offset = 0
            var presentationTimeStamp = sampleBuffer.presentationTimeStamp
            for i in 0..<sampleBuffer.numSamples {
                guard let buffer = makeInputBuffer() as? AVAudioCompressedBuffer else {
                    continue
                }
                let sampleSize = CMSampleBufferGetSampleSize(sampleBuffer, at: i)
                let byteCount = sampleSize - ADTSHeader.size
                buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(byteCount))
                buffer.packetCount = 1
                buffer.byteLength = UInt32(byteCount)
                if let blockBuffer = sampleBuffer.dataBuffer {
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: offset + ADTSHeader.size, dataLength: byteCount, destination: buffer.data)
                    append(buffer, when: presentationTimeStamp.makeAudioTime())
                    presentationTimeStamp = CMTimeAdd(presentationTimeStamp, CMTime(value: CMTimeValue(1024), timescale: sampleBuffer.presentationTimeStamp.timescale))
                    offset += sampleSize
                }
            }
        default:
            break
        }
    }

    func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        let isFormatChange = (inputFormat != audioBuffer.format)
        inputFormat = audioBuffer.format
        if isFormatChange {
            hkdiag("[HKDIAG] AudioCodec.append format change new=%@",
                  String(describing: audioBuffer.format))
        }
        guard let audioConverter, isRunning else {
            if isRunning {
                hkdiag("[HKDIAG] AudioCodec.append SKIP audioConverter=nil")
            }
            return
        }
        diagAppendCount += 1
        if diagAppendCount <= 5 || diagAppendCount % 100 == 0 {
            hkdiag("[HKDIAG] AudioCodec.append count=%d input=%@ converterInput=%@ converterOutput=%@",
                  diagAppendCount,
                  String(describing: audioBuffer.format),
                  String(describing: audioConverter.inputFormat),
                  String(describing: audioConverter.outputFormat))
        }
        var error: NSError?
        if let audioBuffer = audioBuffer as? AVAudioPCMBuffer {
            ringBuffer?.append(audioBuffer, when: when)
            if !audioTime.hasAnchor {
                audioTime.anchor(when.makeTime(), sampleRate: audioConverter.outputFormat.sampleRate)
            }
        }
        var outputStatus: AVAudioConverterOutputStatus = .endOfStream
        repeat {
            let outputBuffer = self.outputBuffer
            outputStatus = audioConverter.convert(to: outputBuffer, error: &error) { inNumberFrames, inputStatus in
                switch self.inputBuffer {
                case let inputBuffer as AVAudioCompressedBuffer:
                    inputBuffer.copy(audioBuffer)
                    inputStatus.pointee = .haveData
                    return inputBuffer
                case let inputBuffer as AVAudioPCMBuffer:
                    if self.ringBuffer?.isDataAvailable(inNumberFrames) == true {
                        inputBuffer.frameLength = inNumberFrames
                        _ = self.ringBuffer?.render(inNumberFrames, ioData: inputBuffer.mutableAudioBufferList)
                        inputStatus.pointee = .haveData
                        return inputBuffer
                    } else {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                default:
                    inputStatus.pointee = .noDataNow
                    return nil
                }
            }
            switch outputStatus {
            case .haveData:
                diagLastOutputStatus = outputStatus
                diagOutputCount += 1
                if diagOutputCount <= 5 || diagOutputCount % 100 == 0 {
                    let stats = pcmStats(outputBuffer)
                    hkdiag("[HKDIAG] AudioCodec.output count=%d frames=%d format=%@ rms=%f peak=%f nonZero=%d",
                          diagOutputCount,
                          Int((outputBuffer as? AVAudioPCMBuffer)?.frameLength ?? 0),
                          String(describing: outputBuffer.format),
                          stats.rms,
                          stats.peak,
                          stats.nonZero)
                }
                if audioTime.hasAnchor {
                    audioTime.advanced(AVAudioFramePosition(audioConverter.outputFormat.streamDescription.pointee.mFramesPerPacket))
                    _outputStream.yield((outputBuffer, audioTime.at))
                } else {
                    _outputStream.yield((outputBuffer, audioTime.at))
                }
                inputBuffersCursor += 1
                if inputBuffersCursor == inputBuffers.count {
                    inputBuffersCursor = Self.defaultInputBuffersCursor
                }
            case .error:
                hkdiag("[HKDIAG] AudioCodec.output status=error append=%d output=%d error=%@",
                      diagAppendCount,
                      diagOutputCount,
                      error?.localizedDescription ?? "nil")
                audioConverter.reset()
                diagLastOutputStatus = outputStatus
                releaseOutputBuffer(outputBuffer)
            default:
                if diagAppendCount <= 5 || diagAppendCount % 100 == 0 || diagLastOutputStatus != outputStatus {
                    hkdiag("[HKDIAG] AudioCodec.output status=%@ append=%d output=%d error=%@",
                          String(describing: outputStatus),
                          diagAppendCount,
                          diagOutputCount,
                          error?.localizedDescription ?? "nil")
                }
                diagLastOutputStatus = outputStatus
                releaseOutputBuffer(outputBuffer)
            }
        } while(outputStatus == .haveData && settings.format != .pcm)
    }

    private func makeInputBuffer() -> AVAudioBuffer? {
        guard let inputFormat else {
            return nil
        }
        switch inputFormat.formatDescription.mediaSubType {
        case .linearPCM:
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: Self.defaultFrameCapacity)
            buffer?.frameLength = Self.defaultFrameCapacity
            return buffer
        default:
            return AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: 1024)
        }
    }

    private func makeAudioConverter() -> AVAudioConverter? {
        guard
            let inputFormat,
            let outputFormat = settings.format.makeOutputAudioFormat(inputFormat, sampleRate: settings.sampleRate, channelMap: settings.channelMap) else {
            return nil
        }
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        settings.apply(converter, oldValue: nil)
        if inputFormat.formatDescription.mediaSubType == .linearPCM {
            ringBuffer = AudioRingBuffer(inputFormat)
        }
        if self.outputFormat?.sampleRate != outputFormat.sampleRate {
            audioTime.reset()
        }
        if logger.isEnabledFor(level: .info) {
            logger.info("converter:", converter ?? "nil", ",inputFormat:", inputFormat, ",outputFormat:", outputFormat)
        }
        return converter
    }

    private func pcmStats(_ buffer: AVAudioBuffer) -> (rms: Double, peak: Double, nonZero: Int) {
        guard
            let buffer = buffer as? AVAudioPCMBuffer,
            let channelData = buffer.floatChannelData else {
            return (-1, -1, 0)
        }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard 0 < channels, 0 < frames else {
            return (0, 0, 0)
        }
        var sumSquares = 0.0
        var peak = 0.0
        var nonZero = 0
        for channel in 0..<channels {
            let samples = channelData[channel]
            for frame in 0..<frames {
                let value = Double(samples[frame])
                let absValue = abs(value)
                sumSquares += value * value
                peak = max(peak, absValue)
                if 0.000001 < absValue {
                    nonZero += 1
                }
            }
        }
        let sampleCount = max(1, channels * frames)
        return (sqrt(sumSquares / Double(sampleCount)), peak, nonZero)
    }
}

extension AudioCodec: Codec {
    // MARK: Codec
    typealias Buffer = AVAudioBuffer

    var outputBuffer: AVAudioBuffer {
        guard let outputFormat = audioConverter?.outputFormat else {
            return .init()
        }
        if outputBuffers.isEmpty {
            for _ in 0..<settings.format.outputBufferCounts {
                outputBuffers.append(settings.format.makeAudioBuffer(outputFormat) ?? .init())
            }
        }
        return outputBuffers.removeFirst()
    }

    func releaseOutputBuffer(_ buffer: AVAudioBuffer) {
        outputBuffers.append(buffer)
    }

    private var inputBuffer: AVAudioBuffer {
        return inputBuffers[inputBuffersCursor]
    }
}

extension AudioCodec: Runner {
    // MARK: Running
    func startRunning() {
        guard !isRunning else {
            return
        }
        audioTime.reset()
        ringBuffer?.reset()
        audioConverter?.reset()
        diagAppendCount = 0
        diagOutputCount = 0
        diagLastOutputStatus = nil
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        _outputStream.finish()
    }
}
