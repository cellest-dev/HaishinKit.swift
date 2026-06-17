#if os(iOS) || os(tvOS) || os(visionOS)
import AVFoundation
import Foundation
import UIKit

/// A view that displays a video content of a NetStream object which uses AVSampleBufferDisplayLayer api.
public class PiPHKView: UIView {
    /// The view’s background color.
    public static var defaultBackgroundColor: UIColor = .black

    /// Returns the class used to create the layer for instances of this class.
    override public class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    /// The view’s Core Animation layer used for rendering.
    override public var layer: AVSampleBufferDisplayLayer {
        super.layer as! AVSampleBufferDisplayLayer
    }

    public var videoTrackId: UInt8? = UInt8.max
    public var audioTrackId: UInt8?

    /// A value that specifies how the video is displayed within a player layer’s bounds.
    public var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet {
            layer.videoGravity = videoGravity
        }
    }
    private var diagVideoEnqueueCount = 0

    /// Initializes and returns a newly allocated view object with the specified frame rectangle.
    override public init(frame: CGRect) {
        super.init(frame: frame)
        awakeFromNib()
    }

    /// Returns an object initialized from data in a given unarchiver.
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    /// Prepares the receiver for service after it has been loaded from an Interface Builder archive, or nib file.
    override public func awakeFromNib() {
        super.awakeFromNib()
        Task { @MainActor in
            backgroundColor = Self.defaultBackgroundColor
            layer.backgroundColor = Self.defaultBackgroundColor.cgColor
            layer.videoGravity = videoGravity
        }
    }
}
#else

import AppKit
import AVFoundation

/// A view that displays a video content of a NetStream object which uses AVSampleBufferDisplayLayer api.
public class PiPHKView: NSView {
    /// The view’s background color.
    public static var defaultBackgroundColor: NSColor = .black

    /// A value that specifies how the video is displayed within a player layer’s bounds.
    public var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet {
            layer?.setValue(videoGravity, forKey: "videoGravity")
        }
    }
    private var diagVideoEnqueueCount = 0

    /// Specifies how the video is displayed with in track.
    public var videoTrackId: UInt8? = UInt8.max
    public var audioTrackId: UInt8?

    /// Initializes and returns a newly allocated view object with the specified frame rectangle.
    override public init(frame: CGRect) {
        super.init(frame: frame)
        awakeFromNib()
    }

    /// Returns an object initialized from data in a given unarchiver.
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    /// Prepares the receiver for service after it has been loaded from an Interface Builder archive, or nib file.
    override public func awakeFromNib() {
        super.awakeFromNib()
        Task { @MainActor in
            wantsLayer = true
            layer = AVSampleBufferDisplayLayer()
            layer?.backgroundColor = PiPHKView.defaultBackgroundColor.cgColor
            layer?.setValue(videoGravity, forKey: "videoGravity")
        }
    }
}

#endif

extension PiPHKView: MediaMixerOutput {
    // MARK: MediaMixerOutput
    public func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {
        switch mediaType {
        case .audio:
            break
        case .video:
            videoTrackId = id
        default:
            break
        }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        Task { @MainActor in
            self.enqueueVideo(sampleBuffer, source: "mixer")
        }
    }
}

extension PiPHKView: StreamOutput {
    // MARK: HKStreamOutput
    nonisolated public func stream(_ stream: some StreamConvertible, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
    }

    nonisolated public func stream(_ stream: some StreamConvertible, didOutput video: CMSampleBuffer) {
        Task { @MainActor in
            self.enqueueVideo(video, source: "stream")
        }
    }
}

extension PiPHKView {
    @MainActor
    private func enqueueVideo(_ sampleBuffer: CMSampleBuffer, source: String) {
        #if os(macOS)
        guard let displayLayer = layer as? AVSampleBufferDisplayLayer else {
            hkdiag("[HKDIAG] PiPHKView.enqueueVideo noDisplayLayer source=%@", source)
            return
        }
        #else
        let displayLayer = layer as AVSampleBufferDisplayLayer
        #endif

        diagVideoEnqueueCount += 1
        let readyBefore = displayLayer.isReadyForMoreMediaData
        let statusBefore = displayLayer.status.rawValue
        displayLayer.enqueue(sampleBuffer)
        let statusAfter = displayLayer.status.rawValue
        let errorText = displayLayer.error?.localizedDescription ?? "nil"
        let timebaseRate: Double
        if let timebase = displayLayer.controlTimebase {
            timebaseRate = CMTimebaseGetRate(timebase)
        } else {
            timebaseRate = -1
        }
        if diagVideoEnqueueCount <= 5 || diagVideoEnqueueCount % 100 == 0 || !readyBefore || statusAfter != statusBefore || displayLayer.status == .failed {
            hkdiag("[HKDIAG] PiPHKView.enqueueVideo source=%@ count=%d readyBefore=%@ statusBefore=%d statusAfter=%d err=%@ pts=%f dts=%f duration=%f key=%@ timebaseRate=%f",
                  source,
                  diagVideoEnqueueCount,
                  readyBefore ? "true" : "false",
                  statusBefore,
                  statusAfter,
                  errorText,
                  sampleBuffer.presentationTimeStamp.seconds,
                  sampleBuffer.decodeTimeStamp.seconds,
                  sampleBuffer.duration.seconds,
                  sampleBuffer.isNotSync ? "false" : "true",
                  timebaseRate)
        }

        #if os(macOS)
        self.needsDisplay = true
        #else
        self.setNeedsDisplay()
        #endif
    }
}
