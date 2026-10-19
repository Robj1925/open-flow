#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C @try. Returns nil on success, or an
/// NSError (domain "OpenFlow.ObjCException") carrying the exception's name
/// and reason. Swift cannot catch NSException on its own: an uncaught one
/// aborts the whole process, which is how AVAudioEngine's tap-install
/// assertions were killing the app.
NSError * _Nullable OFCatchException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
