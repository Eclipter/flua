#import "PlaybackPolicy.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ColorSync/ColorSync.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <dlfcn.h>
#import <math.h>

static BOOL FSIsBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL FSBoolean(id value, BOOL defaultValue) {
    return FSIsBoolean(value) ? [value boolValue] : defaultValue;
}

static BOOL FSIsNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFNumberGetTypeID();
}

static NSArray<NSString *> *FSFullscreenDisplaysFromSnapshot(id snapshot) {
    if (![snapshot isKindOfClass:NSArray.class]) return @[];
    NSMutableOrderedSet<NSString *> *fullscreenDisplays = NSMutableOrderedSet.new;
    for (id value in (NSArray *)snapshot) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *display = value;
        id identifier = display[@"Display Identifier"];
        id currentSpace = display[@"Current Space"];
        if (![identifier isKindOfClass:NSString.class] || ![currentSpace isKindOfClass:NSDictionary.class]) continue;
        id type = currentSpace[@"type"];
        if (!FSIsNumber(type) || [type integerValue] != 4) continue;
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
        if (uuid) [fullscreenDisplays addObject:uuid.UUIDString];
    }
    return fullscreenDisplays.array;
}

// shortcut: fullscreen uses private Space type 4 on macOS 27, recheck when its format changes.
NSArray<NSString *> *FSFullscreenDisplays(void) {
    typedef int32_t (*FSMainConnectionIDFunction)(void);
    typedef CFArrayRef (*FSCopyManagedDisplaySpacesFunction)(int32_t);
    static dispatch_once_t once;
    static void *coreGraphics;
    static FSMainConnectionIDFunction mainConnectionID;
    static FSCopyManagedDisplaySpacesFunction copyManagedDisplaySpaces;
    dispatch_once(&once, ^{
        coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL);
        if (!coreGraphics) return;
        mainConnectionID = (FSMainConnectionIDFunction)dlsym(coreGraphics, "CGSMainConnectionID");
        copyManagedDisplaySpaces = (FSCopyManagedDisplaySpacesFunction)dlsym(coreGraphics, "CGSCopyManagedDisplaySpaces");
    });
    if (!mainConnectionID || !copyManagedDisplaySpaces) return @[];
    CFArrayRef snapshot = copyManagedDisplaySpaces(mainConnectionID());
    return snapshot ? FSFullscreenDisplaysFromSnapshot(CFBridgingRelease(snapshot)) : @[];
}

static NSString *FSDisplayUUID(NSNumber *displayID) {
    if (!FSIsNumber(displayID)) return nil;
    double value = displayID.doubleValue;
    if (!isfinite(value) || value < 0 || value > UINT32_MAX || floor(value) != value) return nil;
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID((CGDirectDisplayID)value);
    if (!uuid) return nil;
    CFStringRef string = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    return string ? CFBridgingRelease(string) : nil;
}

static NSInteger FSLowPowerThreshold(id value) {
    if (!FSIsNumber(value) || !isfinite([value doubleValue])) return 20;
    return (NSInteger)fmin(100, fmax(0, floor([value doubleValue])));
}

static NSNumber *FSBatteryPercent(NSDictionary *environment) {
    id value = environment[@"batteryPercent"];
    if (!FSIsNumber(value)) return nil;
    double percent = [value doubleValue];
    return isfinite(percent) && percent >= 0 && percent <= 100 ? value : nil;
}

static BOOL FSContainsDisplay(NSDictionary *environment, NSString *displayUUID) {
    id displays = environment[@"fullscreenDisplays"];
    if (![displays isKindOfClass:NSArray.class] || !displayUUID) return NO;
    for (id value in displays) {
        if ([value isKindOfClass:NSString.class] && [value isEqualToString:displayUUID]) return YES;
    }
    return NO;
}

static BOOL FSPlaybackShouldPauseForDisplayUUID(NSDictionary *policy, NSDictionary *environment,
                                                NSString *displayUUID, NSString *presentation,
                                                BOOL preview, BOOL hostSuspended) {
    if (hostSuspended) return YES;
    if (preview || ![policy isKindOfClass:NSDictionary.class] || ![environment isKindOfClass:NSDictionary.class]) return NO;

    BOOL onBattery = FSBoolean(environment[@"onBattery"], NO);
    if (FSBoolean(policy[@"pauseOnBattery"], NO) && onBattery) return YES;

    if (FSBoolean(policy[@"pauseOnLowPower"], NO) && FSBoolean(environment[@"lowPower"], NO)) return YES;

    BOOL pauseOnLowBattery = FSBoolean(policy[@"pauseOnLowBattery"], FSBoolean(policy[@"pauseOnLowPower"], NO));
    NSNumber *percent = onBattery && pauseOnLowBattery ? FSBatteryPercent(environment) : nil;
    if (percent && percent.doubleValue <= FSLowPowerThreshold(policy[@"lowPowerThreshold"])) return YES;

    return FSBoolean(policy[@"pauseOnFullscreen"], YES)
        && [presentation isEqualToString:@"default"]
        && FSContainsDisplay(environment, displayUUID);
}

BOOL FSPlaybackPowerEnabled(NSDictionary *policy) {
    return [policy isKindOfClass:NSDictionary.class] &&
        (FSBoolean(policy[@"pauseOnBattery"], NO) || FSBoolean(policy[@"pauseOnLowPower"], NO) ||
         FSBoolean(policy[@"pauseOnLowBattery"], FSBoolean(policy[@"pauseOnLowPower"], NO)));
}

BOOL FSPlaybackFullscreenEnabled(NSDictionary *policy) {
    return [policy isKindOfClass:NSDictionary.class] && FSBoolean(policy[@"pauseOnFullscreen"], YES);
}

NSDictionary *FSPlaybackPowerEnvironment(void) {
    CFTypeRef snapshot = IOPSCopyPowerSourcesInfo();
    CFStringRef provider = snapshot ? IOPSGetProvidingPowerSourceType(snapshot) : NULL;
    BOOL onBattery = provider && CFEqual(provider, CFSTR(kIOPMBatteryPowerKey));
    double currentTotal = 0;
    double maximumTotal = 0;
    BOOL foundBattery = NO;
    BOOL invalidBatteryCapacity = NO;
    CFArrayRef sources = snapshot ? IOPSCopyPowerSourcesList(snapshot) : NULL;
    if (sources) {
        for (CFIndex index = 0; index < CFArrayGetCount(sources); index++) {
            CFDictionaryRef source = IOPSGetPowerSourceDescription(snapshot, CFArrayGetValueAtIndex(sources, index));
            if (!source) continue;
            CFTypeRef type = CFDictionaryGetValue(source, CFSTR(kIOPSTypeKey));
            if (!type || !CFEqual(type, CFSTR(kIOPSInternalBatteryType))) continue;
            CFTypeRef present = CFDictionaryGetValue(source, CFSTR(kIOPSIsPresentKey));
            if (!present || CFGetTypeID(present) != CFBooleanGetTypeID() || !CFBooleanGetValue((CFBooleanRef)present)) continue;
            foundBattery = YES;
            CFTypeRef current = CFDictionaryGetValue(source, CFSTR(kIOPSCurrentCapacityKey));
            CFTypeRef maximum = CFDictionaryGetValue(source, CFSTR(kIOPSMaxCapacityKey));
            if (!current || !maximum || CFGetTypeID(current) != CFNumberGetTypeID() || CFGetTypeID(maximum) != CFNumberGetTypeID()) {
                invalidBatteryCapacity = YES;
                continue;
            }
            double currentValue = 0;
            double maximumValue = 0;
            if (!CFNumberGetValue((CFNumberRef)current, kCFNumberDoubleType, &currentValue)
                || !CFNumberGetValue((CFNumberRef)maximum, kCFNumberDoubleType, &maximumValue)
                || !isfinite(currentValue) || !isfinite(maximumValue) || currentValue < 0 || maximumValue <= 0) {
                invalidBatteryCapacity = YES;
                continue;
            }
            currentTotal += currentValue;
            maximumTotal += maximumValue;
        }
        CFRelease(sources);
    }
    if (snapshot) CFRelease(snapshot);

    NSMutableDictionary *environment = [@{
        @"onBattery" : @(onBattery),
        @"lowPower" : @([NSProcessInfo processInfo].lowPowerModeEnabled),
        @"fullscreenDisplays" : @[]
    } mutableCopy];
    if (foundBattery && !invalidBatteryCapacity && maximumTotal > 0) {
        environment[@"batteryPercent"] = @(fmin(100, fmax(0, currentTotal * 100 / maximumTotal)));
    }
    return environment;
}

NSDictionary *FSPlaybackEnvironment(void) {
    NSMutableDictionary *environment = [FSPlaybackPowerEnvironment() mutableCopy];
    environment[@"fullscreenDisplays"] = FSFullscreenDisplays();
    return environment;
}

BOOL FSPlaybackShouldPause(NSDictionary *policy, NSDictionary *environment, NSNumber *displayID,
                           NSString *presentation, BOOL preview, BOOL hostSuspended) {
    return FSPlaybackShouldPauseForDisplayUUID(policy, environment, FSDisplayUUID(displayID),
                                                presentation, preview, hostSuspended);
}

BOOL FSPlaybackPolicySelfTest(void) {
    if (FSPlaybackPowerEnabled(nil) || FSPlaybackPowerEnabled(@{}) ||
        FSPlaybackPowerEnabled(@{@"pauseOnBattery":@1, @"pauseOnLowPower":@NO, @"pauseOnLowBattery":@NO})) return NO;
    for (NSString *key in @[@"pauseOnBattery", @"pauseOnLowPower", @"pauseOnLowBattery"]) {
        if (!FSPlaybackPowerEnabled(@{key:@YES})) return NO;
    }
    NSString *fullscreenDisplay = @"A5B06E21-D3B0-4A71-A3D8-59CF109A1A30";
    NSArray *fullscreenDisplays = FSFullscreenDisplaysFromSnapshot(@[
        @{@"Display Identifier" : fullscreenDisplay, @"Current Space" : @{@"ManagedSpaceID" : @40, @"type" : @4}},
        @{@"Display Identifier" : @"B5B06E21-D3B0-4A71-A3D8-59CF109A1A30", @"Current Space" : @{@"ManagedSpaceID" : @41, @"type" : @0}},
        @{@"Display Identifier" : @"C5B06E21-D3B0-4A71-A3D8-59CF109A1A30", @"Current Space" : @{@"ManagedSpaceID" : @42, @"type" : @YES}},
        @{@"Display Identifier" : @"invalid", @"Current Space" : @{@"ManagedSpaceID" : @43, @"type" : @4}},
        @"malformed display"
    ]);
    if (![fullscreenDisplays isEqualToArray:@[fullscreenDisplay]]) return NO;

    NSDictionary *allPolicies = @{
        @"pauseOnBattery" : @YES,
        @"pauseOnLowPower" : @YES,
        @"pauseOnLowBattery" : @YES,
        @"pauseOnFullscreen" : @YES,
        @"lowPowerThreshold" : @20
    };
    NSDictionary *batteryAtThreshold = @{
        @"onBattery" : @YES,
        @"lowPower" : @NO,
        @"batteryPercent" : @20,
        @"fullscreenDisplays" : @[]
    };
    NSDictionary *acPower = @{
        @"onBattery" : @NO,
        @"lowPower" : @NO,
        @"fullscreenDisplays" : @[]
    };

    if (!FSPlaybackShouldPause(@{}, @{}, nil, @"default", YES, YES)) return NO;
    if (FSPlaybackShouldPause(allPolicies, batteryAtThreshold, @1, @"default", YES, NO)) return NO;
    if (!FSPlaybackShouldPause(@{@"pauseOnBattery" : @YES}, batteryAtThreshold, nil, @"default", NO, NO)) return NO;
    if (FSPlaybackShouldPause(@{@"pauseOnBattery" : @YES}, acPower, nil, @"default", NO, NO)) return NO;
    if (FSPlaybackShouldPause(@{@"pauseOnBattery" : @YES, @"pauseOnLowPower" : @YES}, acPower, nil, @"default", NO, NO)) return NO;
    if (!FSPlaybackShouldPause(@{@"pauseOnLowPower" : @YES}, @{@"onBattery" : @NO, @"lowPower" : @YES}, nil, @"default", NO, NO)) return NO;
    if (!FSPlaybackShouldPause(allPolicies, batteryAtThreshold, nil, @"default", NO, NO)) return NO;
    if (!FSPlaybackShouldPause(@{@"pauseOnLowBattery" : @YES}, batteryAtThreshold, nil, @"default", NO, NO)) return NO;
    if (FSPlaybackShouldPause(@{@"pauseOnLowBattery" : @YES}, @{@"onBattery" : @YES, @"lowPower" : @NO, @"batteryPercent" : @20.01}, nil, @"default", NO, NO)) return NO;
    if (!FSPlaybackShouldPause(@{@"pauseOnLowBattery" : @YES}, @{@"onBattery" : @YES, @"lowPower" : @NO, @"batteryPercent" : @19}, nil, @"default", NO, NO)) return NO;
    if (FSPlaybackShouldPause(@{@"pauseOnLowBattery" : @YES}, @{@"onBattery" : @YES, @"lowPower" : @NO, @"batteryPercent" : @"19"}, nil, @"default", NO, NO)) return NO;
    if (FSPlaybackShouldPause(@{@"pauseOnLowBattery" : @YES}, @{@"onBattery" : @YES, @"lowPower" : @NO, @"batteryPercent" : @101}, nil, @"default", NO, NO)) return NO;
    if (!FSPlaybackShouldPause(@{@"pauseOnLowBattery" : @YES, @"lowPowerThreshold" : @-1},
                               @{@"onBattery" : @YES, @"lowPower" : @NO, @"batteryPercent" : @0}, nil, @"default", NO, NO)) return NO;
    if (!FSPlaybackShouldPause(@{@"pauseOnLowBattery" : @YES, @"lowPowerThreshold" : @101},
                               @{@"onBattery" : @YES, @"lowPower" : @NO, @"batteryPercent" : @100}, nil, @"default", NO, NO)) return NO;
    if (FSPlaybackShouldPause(@{@"pauseOnLowPower" : @YES, @"pauseOnLowBattery" : @NO}, batteryAtThreshold, nil, @"default", NO, NO)) return NO;
    if (!FSPlaybackShouldPause(@{@"pauseOnLowPower" : @NO, @"pauseOnLowBattery" : @YES}, batteryAtThreshold, nil, @"default", NO, NO)) return NO;
    if (FSPlaybackShouldPause(@{@"pauseOnLowPower" : @NO, @"pauseOnLowBattery" : @NO},
                              @{@"onBattery" : @NO, @"lowPower" : @YES, @"batteryPercent" : @0}, nil, @"default", NO, NO)) return NO;
    if (FSPlaybackShouldPause(@{@"pauseOnLowPower" : @NO, @"pauseOnLowBattery" : @YES},
                              @{@"onBattery" : @YES, @"lowPower" : @YES, @"batteryPercent" : @20.01}, nil, @"default", NO, NO)) return NO;
    if (!FSPlaybackShouldPause(@{@"pauseOnLowPower" : @YES, @"pauseOnLowBattery" : @YES},
                               @{@"onBattery" : @YES, @"lowPower" : @YES, @"batteryPercent" : @20.01}, nil, @"default", NO, NO)) return NO;
    if (!FSPlaybackShouldPause(@{@"pauseOnLowPower" : @YES}, batteryAtThreshold, nil, @"default", NO, NO)) return NO;
    if (!FSPlaybackShouldPause(@{@"pauseOnLowPower" : @YES}, @{@"onBattery" : @NO, @"lowPower" : @YES}, nil, @"default", NO, NO)) return NO;
    if (FSPlaybackShouldPause(@{@"pauseOnBattery" : @YES}, @{@"onBattery" : @1}, nil, @"default", NO, NO)) return NO;
    if (FSPlaybackShouldPause(@{@"pauseOnBattery" : @1}, batteryAtThreshold, nil, @"default", NO, NO)) return NO;
    if (!FSPlaybackShouldPauseForDisplayUUID(@{@"pauseOnFullscreen" : @YES},
                                              @{@"fullscreenDisplays" : @[@"display-A"]},
                                              @"display-A", @"default", NO, NO)) return NO;
    if (FSPlaybackShouldPauseForDisplayUUID(@{@"pauseOnFullscreen" : @YES},
                                             @{@"fullscreenDisplays" : @[@"display-B"]},
                                             @"display-A", @"default", NO, NO)) return NO;
    if (FSPlaybackShouldPauseForDisplayUUID(@{@"pauseOnFullscreen" : @YES},
                                             @{@"fullscreenDisplays" : @[@"display-A"]},
                                             @"display-A", @"locked", NO, NO)) return NO;
    if (FSPlaybackShouldPauseForDisplayUUID(@{@"pauseOnFullscreen" : @YES},
                                             @{@"fullscreenDisplays" : @[@"display-A"]},
                                             @"display-A", @"idle", NO, NO)) return NO;
    if (FSPlaybackShouldPauseForDisplayUUID(@{@"pauseOnFullscreen" : @NO},
                                             @{@"fullscreenDisplays" : @[@"display-A"]},
                                             @"display-A", @"default", NO, NO)) return NO;
    if (FSPlaybackShouldPause(@{@"pauseOnFullscreen" : @YES},
                               @{@"fullscreenDisplays" : @[@"display-A"]},
                               nil, @"default", NO, NO)) return NO;
    return YES;
}
