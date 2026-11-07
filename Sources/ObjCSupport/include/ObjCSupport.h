#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and converts an Objective-C exception into an NSError.
/// CoreBluetooth reports some invalid GATT definitions (for example an unsupported
/// descriptor UUID) by raising NSInvalidArgumentException, which Swift cannot catch.
/// Returns nil when the block finished without an exception.
NSError * _Nullable UKMCatchObjCException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
