#import "UKMVirtualDisplay.h"

// CoreGraphics' private classes, declared here and looked up at run time (NSClassFromString): nothing is linked
// against them, so a macOS without them gives nil instead of a launch failure.
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

/// The most a mode may have on a side: the display is created for this so a rotation never exceeds it.
static const unsigned int kMaxSide = 2560;
static const unsigned int kVendorID = 0x756B;
static const double kRefreshRate = 60;

@implementation UKMVirtualDisplay {
    CGVirtualDisplay *_display;
}

+ (nullable instancetype)displayWithName:(NSString *)name
                                   width:(unsigned int)width
                                  height:(unsigned int)height
                                  serial:(unsigned int)serial {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !displayClass || !NSClassFromString(@"CGVirtualDisplaySettings")
        || !NSClassFromString(@"CGVirtualDisplayMode")) {
        return nil;
    }
    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    descriptor.name = name;
    descriptor.maxPixelsWide = MAX(width * 2, kMaxSide * 2);
    descriptor.maxPixelsHigh = MAX(height * 2, kMaxSide * 2);
    // About 110 pixels per inch.
    descriptor.sizeInMillimeters = CGSizeMake(width / 110.0 * 25.4, height / 110.0 * 25.4);
    descriptor.vendorID = kVendorID;
    descriptor.productID = 0x4B44;
    descriptor.serialNum = serial;
    [descriptor setDispatchQueue:dispatch_get_main_queue()];

    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display || display.displayID == 0) return nil;

    UKMVirtualDisplay *result = [[UKMVirtualDisplay alloc] init];
    result->_display = display;
    if (![result setWidth:width height:height]) return nil;
    return result;
}

+ (BOOL)isVirtualDisplayID:(CGDirectDisplayID)displayID {
    return CGDisplayVendorNumber(displayID) == kVendorID;
}

- (CGDirectDisplayID)displayID {
    return _display ? _display.displayID : 0;
}

- (BOOL)setWidth:(unsigned int)width height:(unsigned int)height {
    if (!_display) return NO;
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = 1; // twice the pixels of the points (design D9)
    settings.modes = @[ [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width
                                                                                   height:height
                                                                              refreshRate:kRefreshRate] ];
    return [_display applySettings:settings];
}

- (void)invalidate {
    _display = nil;
}

@end
