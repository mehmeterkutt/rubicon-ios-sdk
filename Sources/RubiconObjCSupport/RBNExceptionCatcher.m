#import "RBNExceptionCatcher.h"

id RBNCallReturningObject(id (^NS_NOESCAPE block)(id), id argument, NSException **exception) {
    @try {
        return block(argument);
    } @catch (NSException *raised) {
        *exception = raised;
        return nil;
    }
}

void RBNCallWithObject(void (^NS_NOESCAPE block)(id), id argument, NSException **exception) {
    @try {
        block(argument);
    } @catch (NSException *raised) {
        *exception = raised;
    }
}

void RBNCallLogger(
    void (^NS_NOESCAPE block)(NSInteger, NSString *, NSError *), NSInteger level, NSString *message, NSError *error,
    NSException **exception) {
    @try {
        block(level, message, error);
    } @catch (NSException *raised) {
        *exception = raised;
    }
}
