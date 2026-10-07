import Foundation

/// Debug build only: the full contents of an error, for MeldError.detail.
enum MeldDebugError {
    static func describe(_ error: Error) -> String {
        var dumped = ""
        dump(error, to: &dumped, maxDepth: 12)
        let ns = error as NSError
        return "\(ns.domain) #\(ns.code) | \(String(reflecting: error)) | userInfo=\(ns.userInfo) | dump=\(dumped)"
    }
}
