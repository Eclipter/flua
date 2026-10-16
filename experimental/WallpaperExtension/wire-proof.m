#import "Provider.h"
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <objc/runtime.h>

@protocol FSWireProxy
- (void)acquireWithId:(id)identifier request:(id)request reply:(void (^)(id, NSError *))reply;
- (void)updateWithId:(id)identifier request:(id)request reply:(void (^)(NSError *))reply;
- (void)snapshotWithId:(id)identifier reply:(void (^)(id, NSError *))reply;
- (void)provideSettingsViewModelsWithContentTypes:(id)types reply:(void (^)(id, NSError *))reply;
- (void)invalidateWithId:(id)identifier reply:(void (^)(NSError *))reply;
- (void)isChoiceDownloadedWith:(id)choice reply:(void (^)(NSNumber *, NSError *))reply;
@end

@interface WireCoder : NSCoder
@property NSDictionary *objects;
@end
@implementation WireCoder
- (BOOL)allowsKeyedCoding {
    return YES;
}
- (BOOL)requiresSecureCoding {
    return YES;
}
- (id)decodeObjectOfClass:(Class)cls forKey:(NSString *)key {
    id object = self.objects[key];
    return [object isKindOfClass:cls] ? object : nil;
}
- (NSArray *)decodeArrayOfObjectsOfClasses:(NSSet *)classes forKey:(NSString *)key {
    return @[];
}
@end

static id Box(NSString *name, NSString *key, id value) {
    WireCoder *coder = WireCoder.new;
    coder.objects =
        @{key : [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil]};
    return [[NSClassFromString(name) alloc] initWithCoder:coder];
}

@interface Listener : NSObject <NSXPCListenerDelegate>
@end
@implementation Listener
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    return FSConfigureConnection(connection);
}
@end

static BOOL Wait(dispatch_semaphore_t semaphore) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) != 0) {
        if (deadline.timeIntervalSinceNow <= 0)
            return NO;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return YES;
}

int main(void) {
    @autoreleasepool {
        if (!dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit",
                    RTLD_LAZY))
            return 1;
        Listener *delegate = Listener.new;
        NSXPCListener *listener = NSXPCListener.anonymousListener;
        listener.delegate = delegate;
        [listener resume];
        NSXPCConnection *client = [[NSXPCConnection alloc] initWithListenerEndpoint:listener.endpoint];
        Protocol *protocol = objc_getProtocol("WallpaperExtensionKit.WallpaperExtensionXPCProtocol");
        client.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:protocol];
        FSConfigureInterface(client.remoteObjectInterface);
        [client resume];

        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        id propertyList = CFBridgingRelease(CGColorSpaceCopyPropertyList(colorSpace));
        CFRelease(colorSpace);
        NSData *colorData = [NSPropertyListSerialization dataWithPropertyList:propertyList
                                                                       format:NSPropertyListBinaryFormat_v1_0
                                                                      options:0
                                                                        error:nil];
        NSDictionary *destination = @{
            @"size" : @[ @32, @32 ],
            @"scaleFactor" : @1,
            @"colorSpace" : [colorData base64EncodedStringWithOptions:0]
        };
        NSDictionary *creation = @{
            @"configuration" : @"",
            @"destination" : destination,
            @"isPreview" : @YES,
            @"presentationMode" : @{@"default" : @{}},
            @"activityState" : @{@"active" : @{}},
            @"systemAppearance" : @{@"light" : @{}},
            @"debugBackgrounds" : @NO
        };
        id identifier = Box(@"WallpaperIDXPC", @"WallpaperID", @{@"id" : @"12345678-1234-1234-1234-123456789ABC"});
        id request = Box(@"WallpaperCreationRequestXPC", @"codable", creation);
        __block dispatch_semaphore_t pending = dispatch_semaphore_create(0);
        __block NSString *failure = @"";
        __block BOOL acquired = NO, updated = NO, snapshotted = NO, catalog = NO, invalidated = NO;
        __block BOOL downloaded = NO;
        id<FSWireProxy> proxy = [client remoteObjectProxyWithErrorHandler:^(NSError *error) {
            failure = error.description;
            dispatch_semaphore_signal(pending);
        }];

        [proxy acquireWithId:identifier
                     request:request
                       reply:^(id remote, NSError *error) {
                           acquired = remote != nil && error == nil;
                           if (!acquired)
                               failure = error.description ?: @"No remote context";
                           dispatch_semaphore_signal(pending);
                       }];
        BOOL complete = Wait(pending);

        if (complete && acquired) {
            pending = dispatch_semaphore_create(0);
            NSMutableDictionary *update = [creation mutableCopy];
            [update removeObjectForKey:@"configuration"];
            [update removeObjectForKey:@"isPreview"];
            update[@"presentationMode"] = @{@"locked" : @{}};
            update[@"activityState"] = @{@"suspended" : @{}};
            [proxy updateWithId:identifier
                        request:Box(@"WallpaperUpdateRequestXPC", @"WallpaperUpdateRequest", update)
                          reply:^(NSError *error) {
                              updated = error == nil;
                              if (!updated)
                                  failure = error.description;
                              dispatch_semaphore_signal(pending);
                          }];
            complete = Wait(pending);
        }
        if (complete && updated) {
            pending = dispatch_semaphore_create(0);
            [proxy snapshotWithId:identifier
                            reply:^(id snapshot, NSError *error) {
                                NSDictionary *info = FSInspectSnapshot(snapshot);
                                snapshotted =
                                    error == nil && [info[@"width"] intValue] == 32 && [info[@"height"] intValue] == 32;
                                if (!snapshotted)
                                    failure = error.description ?: @"Invalid snapshot dimensions";
                                dispatch_semaphore_signal(pending);
                            }];
            complete = Wait(pending);
        }
        if (complete && snapshotted) {
            pending = dispatch_semaphore_create(0);
            [proxy provideSettingsViewModelsWithContentTypes:nil
                                                       reply:^(id settings, NSError *error) {
                                                           NSDictionary *model = FSInspectSettings(settings);
                                                           catalog = error == nil &&
                                                                     [model[@"desktop"][@"groups"] count] == 1 &&
                                                                     [model[@"screenSaver"][@"groups"] count] == 1;
                                                           if (!catalog)
                                                               failure =
                                                                   error.description ?: @"Invalid settings catalog";
                                                           dispatch_semaphore_signal(pending);
                                                       }];
            complete = Wait(pending);
        }
        if (complete && catalog) {
            pending = dispatch_semaphore_create(0);
            [proxy invalidateWithId:identifier
                              reply:^(NSError *error) {
                                  invalidated = error == nil;
                                  if (!invalidated)
                                      failure = error.description;
                                  dispatch_semaphore_signal(pending);
                              }];
            complete = Wait(pending);
        }
        if (complete && catalog) {
            pending = dispatch_semaphore_create(0);
            NSDictionary *choice = FSSettingsModel()[@"desktop"][@"groups"][0][@"items"][0][@"choice"][@"id"];
            [proxy isChoiceDownloadedWith:Box(@"WallpaperChoiceIDXPC", @"WallpaperChoiceID", choice)
                                    reply:^(NSNumber *value, NSError *error) {
                                        downloaded = error == nil && [value isKindOfClass:NSNumber.class] && value.boolValue;
                                        if (!downloaded)
                                            failure = error.description ?: @"Invalid download status";
                                        dispatch_semaphore_signal(pending);
                                    }];
            complete = Wait(pending);
        }
        [client invalidate];
        [listener invalidate];
        BOOL ok = complete && acquired && updated && snapshotted && catalog && invalidated && downloaded;
        if (!complete && failure.length == 0)
            failure = @"Timed out";
        NSDictionary *result = @{
            @"anonymousXPCPrivatePayloadRoundtrip" : @(ok),
            @"acquireContextRoundtrip" : @(acquired),
            @"updateLockedSuspendedRoundtrip" : @(updated),
            @"snapshotSurfaceRoundtrip" : @(snapshotted),
            @"settingsCatalogRoundtrip" : @(catalog),
            @"downloadStatusRoundtrip" : @(downloaded),
            @"invalidateRoundtrip" : @(invalidated),
            @"failure" : failure,
            @"systemActivationPerformed" : @NO
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        puts("");
        return ok ? 0 : 1;
    }
}
