#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Objective-C side of the wrapper: calls a developer's block inside `@try` and hands back the
/// `NSException` it raised instead of letting it reach the app's call site (iOS Public API 6, iOS
/// Logging 2). Swift cannot catch an exception, and an exception must not unwind through a Swift
/// frame that holds a lock or an exclusivity access (it would leave the access record dangling and
/// crash later), so each helper takes the block itself and calls it directly: nothing of the SDK's
/// sits between the `@try` and the developer's code except the compiler's bridging thunk.

/// Calls `block(argument)` and returns its result; when the block raises, returns `nil` and stores
/// the exception in `*exception`.
FOUNDATION_EXPORT id _Nullable RBNCallReturningObject(
    id _Nullable (^NS_NOESCAPE block)(id), id argument, NSException *_Nullable *_Nonnull exception);

/// Calls `block(argument)`; when the block raises, stores the exception in `*exception`.
FOUNDATION_EXPORT void RBNCallWithObject(
    void (^NS_NOESCAPE block)(id), id argument, NSException *_Nullable *_Nonnull exception);

/// Calls `block(level, message, error)`; when the block raises, stores the exception in `*exception`.
FOUNDATION_EXPORT void RBNCallLogger(
    void (^NS_NOESCAPE block)(NSInteger, NSString *, NSError *_Nullable), NSInteger level, NSString *message,
    NSError *_Nullable error, NSException *_Nullable *_Nonnull exception);

NS_ASSUME_NONNULL_END
