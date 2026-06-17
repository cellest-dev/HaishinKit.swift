import CoreMedia
import HaishinKit

extension IncomingStream {
    func append(_ message: RTMPVideoMessage, presentationTimeStamp: CMTime, formatDesciption: CMFormatDescription?) {
        guard let buffer = message.makeSampleBuffer(presentationTimeStamp, formatDesciption: formatDesciption) else {
            hkdiag("[HKDIAG] RTMPVideoMessage.makeSampleBuffer nil packetType=%d ex=%@ pts=%f cts=%d payload=%d formatSet=%@",
                  Int(message.packetType),
                  message.isExHeader ? "true" : "false",
                  presentationTimeStamp.seconds,
                  Int(message.compositionTime),
                  message.payload.count,
                  formatDesciption == nil ? "false" : "true")
            return
        }
        if buffer.presentationTimeStamp.isValid {
            hkdiag("[HKDIAG] RTMPVideoMessage.makeSampleBuffer OK packetType=%d pts=%f dts=%f duration=%f key=%@ bytes=%d",
                  Int(message.packetType),
                  buffer.presentationTimeStamp.seconds,
                  buffer.decodeTimeStamp.seconds,
                  buffer.duration.seconds,
                  buffer.isNotSync ? "false" : "true",
                  buffer.dataBuffer?.dataLength ?? 0)
        }
        append(buffer)
    }
}
