import Foundation
import OpenFlowObjC

/// Turns an Objective-C exception raised inside `body` into a thrown Swift
/// error. AVFoundation raises NSException (not NSError) for programmer-level
/// checks such as a tap format that no longer matches the input device, and
/// Swift's `do/catch` cannot intercept those.
public enum ObjCExceptionGuard {
    public static func run(_ body: () -> Void) throws {
        if let error = OFCatchException(body) {
            throw error
        }
    }

    /// Raises a real NSException. Exists so the test target, which cannot
    /// import Foundation next to Swift Testing under the Command Line Tools,
    /// can still exercise the guard end to end.
    public static func raiseExceptionForTesting(reason: String) {
        NSException(name: .genericException, reason: reason, userInfo: nil).raise()
    }
}
