#import "OFExceptionGuard.h"

NSError * _Nullable OFCatchException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: @"(no reason)";
        return [NSError errorWithDomain:@"OpenFlow.ObjCException"
                                   code:1
                               userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", exception.name, reason],
            @"ExceptionName": exception.name,
            @"ExceptionReason": reason,
        }];
    }
}
