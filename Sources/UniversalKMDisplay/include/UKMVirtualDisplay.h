#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A virtual display of the Mac (openspec/changes/add-android-second-display, design D1): CoreGraphics'
/// private CGVirtualDisplay, the same API DeskPad and BetterDisplay use. The display exists while this object
/// lives; releasing it removes the display and brings its windows back to the other monitors.
@interface UKMVirtualDisplay : NSObject

/// nil when the system refused to create it (the private API is gone or changed).
+ (nullable instancetype)displayWithName:(NSString *)name
                                   width:(unsigned int)width
                                  height:(unsigned int)height
                                  serial:(unsigned int)serial;

@property(nonatomic, readonly) CGDirectDisplayID displayID;

/// Changes the mode (the device was rotated); the display and its windows stay.
- (BOOL)setWidth:(unsigned int)width height:(unsigned int)height;

/// Removes the display now.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
