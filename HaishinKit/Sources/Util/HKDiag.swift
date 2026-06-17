import Foundation
import os.log

/// iOS 26 で純 NSLog が idevicesyslog から取得できない事象を回避するため、
/// 診断ログは subsystem を明示した OSLog 経由で出す。
///
/// idevicesyslog 側では subsystem フィルタを掛けなくても拾える。
/// 引数値は `%{public}@` で出すため privacy ガードに引っかからない。
@usableFromInline
let hkdiagOSLog = OSLog(subsystem: "com.cellest.haishinkit", category: "diag")

@inlinable
@inline(__always)
public func hkdiag(_ message: String) {
    os_log("%{public}@", log: hkdiagOSLog, type: .info, message as NSString)
}

@inlinable
@inline(__always)
public func hkdiag(_ format: String, _ args: CVarArg...) {
    let s = String(format: format, arguments: args)
    os_log("%{public}@", log: hkdiagOSLog, type: .info, s as NSString)
}
