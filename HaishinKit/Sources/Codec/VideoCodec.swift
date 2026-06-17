import AVFoundation
import CoreFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

final class VideoCodec {
    static let frameInterval: Double = 0.0

    var settings: VideoCodecSettings = .default {
        didSet {
            let invalidateSession = settings.invalidateSession(oldValue)
            if invalidateSession {
                self.invalidateSession = invalidateSession
            } else {
                settings.apply(self, rhs: oldValue)
            }
        }
    }
    var passthrough = true
    var outputStream: AsyncStream<CMSampleBuffer> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    var frameInterval = VideoCodec.frameInterval
    private var startedAt: CMTime = .zero
    private var continuation: AsyncStream<CMSampleBuffer>.Continuation?
    private var invalidateSession = true
    private var presentationTimeStamp: CMTime = .zero
    private var diagInputCount = 0
    private var diagDroppedCount = 0
    private(set) var isRunning = false
    private(set) var inputFormat: CMFormatDescription? {
        didSet {
            guard inputFormat != oldValue else {
                return
            }
            invalidateSession = true
            outputFormat = nil
        }
    }
    private(set) var session: (any VTSessionConvertible)? {
        didSet {
            oldValue?.invalidate()
            invalidateSession = false
        }
    }
    private(set) var outputFormat: CMFormatDescription?

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            return
        }
        do {
            diagInputCount += 1
            let isCompressed = sampleBuffer.formatDescription?.isCompressed == true
            if diagInputCount <= 5 || diagInputCount % 100 == 0 {
                hkdiag("[HKDIAG] VideoCodec.append input count=%d compressed=%@ pts=%f dts=%f duration=%f key=%@ fmt=%@",
                      diagInputCount,
                      isCompressed ? "true" : "false",
                      sampleBuffer.presentationTimeStamp.seconds,
                      sampleBuffer.decodeTimeStamp.seconds,
                      sampleBuffer.duration.seconds,
                      sampleBuffer.isNotSync ? "false" : "true",
                      String(describing: sampleBuffer.formatDescription))
            }
            inputFormat = sampleBuffer.formatDescription
            if invalidateSession {
                if sampleBuffer.formatDescription?.isCompressed == true {
                    session = try VTSessionMode.decompression.makeSession(self)
                } else {
                    session = try VTSessionMode.compression.makeSession(self)
                }
                hkdiag("[HKDIAG] VideoCodec.session created mode=%@ inputFmt=%@",
                      isCompressed ? "decompression" : "compression",
                      String(describing: sampleBuffer.formatDescription))
            }
            guard let session, let continuation else {
                diagDroppedCount += 1
                hkdiag("[HKDIAG] VideoCodec.append DROP sessionOrContinuationNil input=%d dropped=%d hasSession=%@ hasContinuation=%@",
                      diagInputCount,
                      diagDroppedCount,
                      session == nil ? "false" : "true",
                      continuation == nil ? "false" : "true")
                return
            }
            if sampleBuffer.formatDescription?.isCompressed == true {
                try session.convert(sampleBuffer, continuation: continuation)
            } else {
                if useFrame(sampleBuffer.presentationTimeStamp) {
                    try session.convert(sampleBuffer, continuation: continuation)
                    presentationTimeStamp = sampleBuffer.presentationTimeStamp
                } else {
                    diagDroppedCount += 1
                    if diagDroppedCount <= 5 || diagDroppedCount % 100 == 0 {
                        hkdiag("[HKDIAG] VideoCodec.append DROP useFrame=false dropped=%d pts=%f previousPts=%f frameInterval=%f",
                              diagDroppedCount,
                              sampleBuffer.presentationTimeStamp.seconds,
                              presentationTimeStamp.seconds,
                              frameInterval)
                    }
                }
            }
        } catch {
            hkdiag("[HKDIAG] VideoCodec.append ERROR input=%d pts=%f error=%@",
                  diagInputCount,
                  sampleBuffer.presentationTimeStamp.seconds,
                  String(describing: error))
            logger.warn(error)
        }
    }

    func makeImageBufferAttributes(_ mode: VTSessionMode) -> [NSString: AnyObject]? {
        switch mode {
        case .compression:
            var attributes: [NSString: AnyObject] = [:]
            if let inputFormat {
                // Specify the pixel format of the uncompressed video.
                attributes[kCVPixelBufferPixelFormatTypeKey] = inputFormat.mediaType.rawValue as CFNumber
            }
            return attributes.isEmpty ? nil : attributes
        case .decompression:
            return [
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue
            ]
        }
    }

    private func useFrame(_ presentationTimeStamp: CMTime) -> Bool {
        guard startedAt <= presentationTimeStamp else {
            return false
        }
        guard self.presentationTimeStamp < presentationTimeStamp else {
            return false
        }
        guard Self.frameInterval < frameInterval else {
            return true
        }
        return frameInterval <= presentationTimeStamp.seconds - self.presentationTimeStamp.seconds
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    @objc
    private func applicationWillEnterForeground(_ notification: Notification) {
        invalidateSession = true
    }

    @objc
    private func didAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo: [AnyHashable: Any] = notification.userInfo,
            let value: NSNumber = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type = AVAudioSession.InterruptionType(rawValue: value.uintValue) else {
            return
        }
        switch type {
        case .ended:
            invalidateSession = true
        default:
            break
        }
    }
    #endif
}

extension VideoCodec: Runner {
    // MARK: Running
    func startRunning() {
        guard !isRunning else {
            return
        }
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.didAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
        startedAt = passthrough ? .zero : CMClockGetTime(CMClockGetHostTimeClock())
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        session = nil
        invalidateSession = true
        inputFormat = nil
        outputFormat = nil
        presentationTimeStamp = .zero
        diagInputCount = 0
        diagDroppedCount = 0
        continuation?.finish()
        startedAt = .zero
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }
}
