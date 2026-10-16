#import "Provider.h"
#import "MediaRenderer.h"
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Original Flua prototype. Uses only dynamically loaded Apple classes.
// Never registers itself or edits the user's wallpaper selection.
@interface FSCaptureCoder : NSCoder
@property NSMutableDictionary *objects;
@end
@implementation FSCaptureCoder
- (instancetype)init {
    if ((self = [super init]))
        _objects = NSMutableDictionary.new;
    return self;
}
- (BOOL)allowsKeyedCoding {
    return YES;
}
- (BOOL)requiresSecureCoding {
    return YES;
}
- (void)encodeObject:(id)object forKey:(NSString *)key {
    if (object)
        self.objects[key] = object;
}
@end
@interface FSInputCoder : NSCoder
@property NSDictionary *objects;
@end
@implementation FSInputCoder
- (BOOL)allowsKeyedCoding {
    return YES;
}
- (BOOL)requiresSecureCoding {
    return YES;
}
- (id)decodeObjectOfClass:(Class)cls forKey:(NSString *)key {
    id obj = self.objects[key];
    return [obj isKindOfClass:cls] ? obj : nil;
}
- (NSArray *)decodeArrayOfObjectsOfClasses:(NSSet *)classes forKey:(NSString *)key {
    return self.objects[key] ?: @[];
}
- (void)failWithError:(NSError *)error {
    NSLog(@"Flua payload: %@", error);
}
@end
// WallpaperSnapshotXPC requires an NSXPCCoder and the XPC key "surface".
@interface FSXPCBridgeCoder : NSXPCCoder
@property(strong) xpc_object_t payload;
@end
@implementation FSXPCBridgeCoder
- (BOOL)allowsKeyedCoding {
    return YES;
}
- (BOOL)requiresSecureCoding {
    return YES;
}
- (xpc_object_t)decodeXPCObjectForKey:(NSString *)key {
    return [key isEqualToString:@"surface"] ? self.payload : nil;
}
- (void)encodeXPCObject:(xpc_object_t)object forKey:(NSString *)key {
    if ([key isEqualToString:@"surface"])
        self.payload = object;
}
@end
NSDictionary *FSInspectSnapshot(id snapshot) {
    FSXPCBridgeCoder *c = FSXPCBridgeCoder.new;
    [snapshot encodeWithCoder:c];
    IOSurfaceRef surface = c.payload ? IOSurfaceLookupFromXPCObject(c.payload) : NULL;
    if (!surface)
        return nil;
    IOSurfaceLock(surface,kIOSurfaceLockReadOnly,NULL);
    const uint8_t *bytes=IOSurfaceGetBaseAddress(surface); uint64_t checksum=1469598103934665603ULL;
    for (size_t y=0;y<IOSurfaceGetHeight(surface);y++) for(size_t x=0;x<IOSurfaceGetWidth(surface)*4;x++) { checksum^=bytes[y*IOSurfaceGetBytesPerRow(surface)+x]; checksum*=1099511628211ULL; }
    IOSurfaceUnlock(surface,kIOSurfaceLockReadOnly,NULL);
    NSDictionary *out = @{
        @"checksum": @(checksum),
        @"width" : @(IOSurfaceGetWidth(surface)),
        @"height" : @(IOSurfaceGetHeight(surface)),
        @"surfaceID" : @(IOSurfaceGetID(surface))
    };
    CFRelease(surface);
    return out;
}
static NSDictionary *FSJSON(id object, NSString *key) {
    FSCaptureCoder *c = FSCaptureCoder.new;
    [object encodeWithCoder:c];
    NSData *d = c.objects[key];
    if (!d)
        return nil;
    return [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingFragmentsAllowed error:nil];
}
static id FSBox(NSString *className, NSString *key, id value) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
    FSInputCoder *c = FSInputCoder.new;
    c.objects = @{key : d ?: NSData.data, @"files" : @[]};
    return [[NSClassFromString(className) alloc] initWithCoder:c];
}
id FSCreateRequest(NSDictionary *creation, NSArray<NSURL *> *files) {
    NSMutableArray *wrappers=NSMutableArray.new;
    for (NSURL *url in files) {
        id wrapper=((id (*)(id,SEL,id,BOOL))objc_msgSend)([NSClassFromString(@"NSSecurityScopedURLWrapper") alloc],NSSelectorFromString(@"initWithURL:readonly:"),url,YES);
        if (wrapper) [wrappers addObject:wrapper];
    }
    FSInputCoder *coder=FSInputCoder.new;
    coder.objects=@{@"codable":[NSJSONSerialization dataWithJSONObject:creation options:0 error:nil],@"files":wrappers};
    return [[NSClassFromString(@"WallpaperCreationRequestXPC") alloc] initWithCoder:coder];
}
NSDictionary *FSInspectCreation(id request) {
    FSCaptureCoder *coder=FSCaptureCoder.new; [request encodeWithCoder:coder];
    NSMutableArray *urls=NSMutableArray.new;
    for(id wrapper in coder.objects[@"files"]) {
        NSURL *url=((id (*)(id,SEL))objc_msgSend)(wrapper,NSSelectorFromString(@"url"));
        if(url) [urls addObject:url.absoluteString];
    }
    return @{@"files":urls,@"payload":FSJSON(request,@"codable") ?: @{}};
}
static NSError *FSError(NSString *message) {
    return [NSError errorWithDomain:@"org.flua.WallpaperPrototype"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}
NSDictionary *FSSettingsModel(void) {
    NSURL *thumbnail = [NSBundle.mainBundle URLForResource:@"PrototypeThumbnail" withExtension:@"png"];
    if (!thumbnail)
        thumbnail = [[NSBundle.mainBundle.executableURL URLByDeletingLastPathComponent]
            URLByAppendingPathComponent:@"PrototypeThumbnail.png"];
    NSDictionary *image = @{@"image" : @{@"url" : thumbnail.absoluteString ?: @""}};
    NSDictionary *choice = @{
        @"id" : @{
            @"descriptor" :
                @{@"provider" : @"org.flua.wallpaper.prototype", @"files" : @[], @"configuration" : @""}
        },
        @"localizedDescription" : @"Original Flua procedural gradient",
        @"thumbnail" : image,
        @"isDownloaded" : @YES,
        @"options" : @[]
    };
    NSDictionary *item = @{
        @"id" : @{@"id" : @"org.flua.prototype.gradient"},
        @"groupID" : @{@"id" : @"org.flua.prototype"},
        @"localizedName" : @"Flua Gradient",
        @"thumbnail" : image,
        @"choice" : choice,
        @"contentBadge" : @{@"none" : @{}},
        @"showInTopLevel" : @YES,
        @"sortOrder" : @0,
        @"disposability" : @{@"none" : @{}},
        @"contextMenu" : @{@"items" : @[]}
    };
    NSMutableArray *items=[NSMutableArray arrayWithObject:item];
    for (NSString *kind in @[@"image",@"video"]) {
        NSString *name=[kind isEqual:@"video"] ? @"Flua Motion" : @"Flua Still";
        NSDictionary *configuration=@{@"version":@1,@"kind":kind,@"source":@"bundle",@"fit":@"fill"};
        NSString *encoded=[[NSJSONSerialization dataWithJSONObject:configuration options:0 error:nil] base64EncodedStringWithOptions:0];
        NSMutableDictionary *mediaChoice=[choice mutableCopy];
        mediaChoice[@"id"]=@{@"descriptor":@{@"provider":@"org.flua.wallpaper.prototype",@"files":@[],@"configuration":encoded}};
        mediaChoice[@"localizedDescription"]=name;
        NSMutableDictionary *mediaItem=[item mutableCopy];
        mediaItem[@"id"]=@{@"id":[@"org.flua.prototype." stringByAppendingString:kind]};
        mediaItem[@"localizedName"]=name;
        mediaItem[@"choice"]=mediaChoice;
        mediaItem[@"sortOrder"]=@(items.count);
        [items addObject:mediaItem];
    }
    NSDictionary *group = @{
        @"id" : @{@"id" : @"org.flua.prototype"},
        @"localizedName" : @"Flua",
        @"disposability" : @{@"none" : @{}},
        @"sortID" : @{@"id" : @"org.flua.prototype"},
        @"sortOrder" : @0,
        @"shouldHideItemLabels" : @NO,
        @"items" : items
    };
    NSDictionary *model =
        @{@"groups" : @[ group ],
          @"refreshPolicy" : @{@"default" : @{}},
          @"isModificationDisabled" : @NO};
    return @{@"desktop" : model, @"screenSaver" : model};
}
NSDictionary *FSInspectSettings(id settings) { return FSJSON(settings, @"WallpaperSettingsViewModels"); }
@interface FSSession : NSObject
@property id context;
@property CALayer *root;
@property NSDictionary *request;
@property NSString *mode;
@property FSMediaRenderer *renderer;
@end
@implementation FSSession
- (void)dealloc {
    [self.renderer dispose];
    if (self.context)
        ((void (*)(id, SEL))objc_msgSend)(self.context, NSSelectorFromString(@"invalidate"));
}
@end
@interface FSProvider : NSObject
@property NSMutableDictionary<NSString *, FSSession *> *sessions;
@end
@implementation FSProvider
- (instancetype)init {
    if ((self = [super init]))
        _sessions = NSMutableDictionary.new;
    return self;
}
- (NSString *)key:(id)ident {
    return FSJSON(ident, @"WallpaperID")[@"id"] ?: @"unknown";
}
- (void)acquireWithId:(id)ident request:(id)request reply:(void (^)(id, NSError *))reply {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self acquireWithId:ident request:request reply:reply];
        });
        return;
    }
    @try {
        NSDictionary *payload = FSJSON(request, @"codable");
        NSArray *size = payload[@"destination"][@"size"];
        if (size.count != 2) {
            reply(nil, FSError(@"Invalid creation destination"));
            return;
        }
        // Size is preserved as the framework supplied it. Pixel/point scale
        // semantics need real-host confirmation before exposing this prototype as a
        // product.
        double w = [size[0] doubleValue], h = [size[1] doubleValue];
        if (!isfinite(w) || !isfinite(h) || w < 1 || h < 1 || w > 8192 || h > 8192) {
            reply(nil, FSError(@"Unsupported destination dimensions"));
            return;
        }
        FSCaptureCoder *captured = FSCaptureCoder.new;
        [request encodeWithCoder:captured];
        NSData *configurationData = [[NSData alloc] initWithBase64EncodedString:payload[@"configuration"] ?: @"" options:0];
        NSDictionary *configuration = configurationData.length ? [NSJSONSerialization JSONObjectWithData:configurationData options:0 error:nil] : @{};
        if (![configuration isKindOfClass:NSDictionary.class]) { reply(nil,FSError(@"Invalid Flua configuration JSON")); return; }
        if (configuration.count && [configuration[@"version"] integerValue] != 1) { reply(nil,FSError(@"Unsupported Flua configuration version")); return; }
        NSError *mediaError;
        FSMediaRenderer *renderer = [[FSMediaRenderer alloc] initWithWidth:(NSUInteger)w height:(NSUInteger)h configuration:configuration fileWrappers:captured.objects[@"files"] ?: @[] error:&mediaError];
        if (!renderer) { reply(nil,mediaError ?: FSError(@"Cannot create renderer")); return; }
        FSSession *s = FSSession.new;
        s.request = payload;
        s.mode = [payload[@"presentationMode"] allKeys].firstObject ?: @"default";
        s.renderer = renderer;
        s.root = renderer.layer;
        [renderer setPlaybackSuspended:payload[@"activityState"][@"suspended"] != nil];
        s.context = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAContext"),
                                                        NSSelectorFromString(@"remoteContextWithOptions:"), @{});
        if (!s.context) {
            reply(nil, FSError(@"CAContext unavailable"));
            return;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(s.context, NSSelectorFromString(@"setLayer:"), s.root);
        [CATransaction flush];
        uint32_t cid = ((uint32_t (*)(id, SEL))objc_msgSend)(s.context, NSSelectorFromString(@"contextId"));
        id box = FSBox(@"WallpaperRemoteContextXPC", @"UInt32", @(cid));
        if (!box) {
            reply(nil, FSError(@"Remote context serialization failed"));
            return;
        }
        self.sessions[[self key:ident]] = s;
        reply(box, nil);
    } @catch (NSException *e) {
        reply(nil, FSError(e.reason));
    }
}
- (void)updateWithId:(id)ident request:(id)request reply:(void (^)(NSError *))reply {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateWithId:ident request:request reply:reply];
        });
        return;
    }
    NSDictionary *p = FSJSON(request, @"WallpaperUpdateRequest");
    FSSession *s = self.sessions[[self key:ident]];
    if (!s || !p) {
        reply(FSError(@"Unknown session or update"));
        return;
    }
    s.mode = [p[@"presentationMode"] allKeys].firstObject ?: @"default";
    BOOL suspended = p[@"activityState"][@"suspended"] != nil;
    s.root.speed = suspended ? 0 : 1;
    [s.renderer setPlaybackSuspended:suspended];
    reply(nil);
}
- (void)invalidateWithId:(id)ident reply:(void (^)(NSError *))reply {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self invalidateWithId:ident reply:reply];
        });
        return;
    }
    [self.sessions[[self key:ident]].renderer dispose];
    [self.sessions removeObjectForKey:[self key:ident]];
    reply(nil);
}
- (void)snapshotWithId:(id)ident reply:(void (^)(id, NSError *))reply {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self snapshotWithId:ident reply:reply];
        });
        return;
    }
    FSSession *s = self.sessions[[self key:ident]];
    if (!s || !s.root.contents) {
        reply(nil, FSError(@"No snapshot session"));
        return;
    }
    FSXPCBridgeCoder *c = FSXPCBridgeCoder.new;
    c.payload = IOSurfaceCreateXPCObject((__bridge IOSurfaceRef)s.root.contents);
    id wrapped = [[NSClassFromString(@"WallpaperSnapshotXPC") alloc] initWithCoder:c];
    reply(wrapped, wrapped ? nil : FSError(@"Snapshot serialization failed"));
}
- (void)provideSettingsViewModelsWithContentTypes:(id)types reply:(void (^)(id, NSError *))reply {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self provideSettingsViewModelsWithContentTypes:types reply:reply];
        });
        return;
    }
    reply(FSBox(@"WallpaperSettingsViewModelsXPC", @"WallpaperSettingsViewModels", FSSettingsModel()), nil);
}
- (void)addChoiceRequestWithChoiceRequest:(id)request
                        onBehalfOfProcess:(id)process
                                    reply:(void (^)(id, NSError *))reply {
    reply(nil, FSError(@"Adding external choices is not supported by this prototype"));
}
- (void)removeChoiceRequestWithChoiceRequest:(id)request reply:(void (^)(NSError *))reply {
    reply(FSError(@"Removing external choices is not supported by this prototype"));
}
- (void)selectedChoicesDidChangeFor:(id)choices reply:(void (^)(NSError *))reply {
    reply(nil);
}
- (void)invokeContextMenuActionWithMenuItemID:(id)item groupItemID:(id)group reply:(void (^)(NSError *))reply {
    reply(FSError(@"No context-menu actions"));
}
- (void)isChoiceDownloadedWith:(id)choice reply:(void (^)(BOOL, NSError *))reply {
    reply(YES, nil);
}
- (id)downloadWithChoiceID:(id)choice reply:(void (^)(NSError *))reply {
    reply(nil);
    return nil;
}
- (void)pauseDownloadFor:(id)choice reply:(void (^)(NSError *))reply {
    reply(nil);
}
- (void)cancelDownloadFor:(id)choice reply:(void (^)(NSError *))reply {
    reply(nil);
}
- (void)resumeDownloadFor:(id)choice reply:(void (^)(NSError *))reply {
    reply(nil);
}
- (void)removeDownloadFor:(id)choice reply:(void (^)(NSError *))reply {
    reply(FSError(@"Built-in prototype content cannot be removed"));
}
- (void)migrateSelectedChoiceFor:(id)choice reply:(void (^)(NSError *))reply {
    reply(FSError(@"Migration is not implemented"));
}
- (void)migrateFrom:(id)from to:(id)to reply:(void (^)(NSError *))reply {
    reply(FSError(@"Migration is not implemented"));
}
- (void)skipShuffledContentWithId:(id)ident reply:(void (^)(NSError *))reply {
    reply(nil);
}
- (void)canSkipShuffledContentWithId:(id)ident reply:(void (^)(BOOL, NSError *))reply {
    reply(NO, nil);
}
- (void)handleDebugRequestFor:(id)request reply:(void (^)(id, NSError *))reply {
    reply(nil, FSError(@"Debug request unsupported"));
}
- (void)handleNotificationWithNamed:(id)name reply:(void (^)(NSError *))reply {
    reply(nil);
}

@end
static BOOL FSLoad(void) {
    static void *h;
    h = dlopen("/System/Library/PrivateFrameworks/"
               "WallpaperExtensionKit.framework/WallpaperExtensionKit",
               RTLD_LAZY | RTLD_LOCAL);
    return h != NULL;
}
void FSConfigureInterface(NSXPCInterface *interface) {
    NSSet *ids = [NSSet setWithObject:NSClassFromString(@"WallpaperIDXPC")];
    for (NSString *method in @[
             @"acquireWithId:request:reply:", @"updateWithId:request:reply:", @"invalidateWithId:reply:",
             @"snapshotWithId:reply:"
         ])
        [interface setClasses:ids forSelector:NSSelectorFromString(method) argumentIndex:0 ofReply:NO];
    [interface setClasses:[NSSet setWithObject:NSClassFromString(@"WallpaperCreationRequestXPC")]
              forSelector:NSSelectorFromString(@"acquireWithId:request:reply:")
            argumentIndex:1
                  ofReply:NO];
    [interface setClasses:[NSSet setWithObject:NSClassFromString(@"WallpaperUpdateRequestXPC")]
              forSelector:NSSelectorFromString(@"updateWithId:request:reply:")
            argumentIndex:1
                  ofReply:NO];
    [interface setClasses:[NSSet setWithObject:NSClassFromString(@"WallpaperSettingsViewModelsXPC")]
              forSelector:NSSelectorFromString(@"provideSettingsViewModelsWithContentTypes:reply:")
            argumentIndex:0
                  ofReply:YES];
    [interface setClasses:[NSSet setWithObject:NSClassFromString(@"WallpaperSnapshotXPC")]
              forSelector:NSSelectorFromString(@"snapshotWithId:reply:")
            argumentIndex:0
                  ofReply:YES];
    [interface setClasses:[NSSet setWithObject:NSClassFromString(@"WallpaperRemoteContextXPC")]
              forSelector:NSSelectorFromString(@"acquireWithId:request:reply:")
            argumentIndex:0
                  ofReply:YES];
}
BOOL FSConfigureConnection(NSXPCConnection *connection) {
    if (!FSLoad())
        return NO;
    Protocol *p = objc_getProtocol("WallpaperExtensionKit.WallpaperExtensionXPCProtocol");
    if (!p)
        return NO;
    class_addProtocol(FSProvider.class, p);
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:p];
    FSConfigureInterface(connection.exportedInterface);
    connection.exportedObject = FSProvider.new;
    [connection resume];
    return YES;
}
int FSProviderSelfTest(void) {
    @autoreleasepool {
        if (!FSLoad())
            return 1;
        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        id cs = (__bridge_transfer id)CGColorSpaceCopyPropertyList(colorSpace);
        CFRelease(colorSpace);
        NSData *cp = [NSPropertyListSerialization dataWithPropertyList:cs
                                                                format:NSPropertyListBinaryFormat_v1_0
                                                               options:0
                                                                 error:nil];
        NSDictionary *destination =
            @{@"size" : @[ @64, @64 ],
              @"scaleFactor" : @1,
              @"colorSpace" : [cp base64EncodedStringWithOptions:0]};
        NSDictionary *create = @{
            @"configuration" : @"",
            @"destination" : destination,
            @"isPreview" : @YES,
            @"presentationMode" : @{@"default" : @{}},
            @"activityState" : @{@"active" : @{}},
            @"systemAppearance" : @{@"light" : @{}},
            @"debugBackgrounds" : @NO
        };
        id ident = FSBox(@"WallpaperIDXPC", @"WallpaperID", @{@"id" : @"12345678-1234-1234-1234-123456789ABC"});
        id request = FSBox(@"WallpaperCreationRequestXPC", @"codable", create);
        FSProvider *p = FSProvider.new;
        __block BOOL acquired = NO, updated = NO, invalidated = NO, snapshotted = NO, settingsOK = NO;
        [p acquireWithId:ident
                 request:request
                   reply:^(id result, NSError *error) {
                       acquired = result != nil && error == nil;
                   }];
        NSMutableDictionary *update = [create mutableCopy];
        [update removeObjectForKey:@"configuration"];
        [update removeObjectForKey:@"isPreview"];
        update[@"presentationMode"] = @{@"locked" : @{}};
        update[@"activityState"] = @{@"suspended" : @{}};
        [p updateWithId:ident
                request:FSBox(@"WallpaperUpdateRequestXPC", @"WallpaperUpdateRequest", update)
                  reply:^(NSError *error) {
                      updated = error == nil && [p.sessions.allValues.firstObject.mode isEqualToString:@"locked"] &&
                                p.sessions.allValues.firstObject.root.speed == 0;
                  }];
        [p snapshotWithId:ident
                    reply:^(id snapshot, NSError *error) {
                        NSDictionary *info = FSInspectSnapshot(snapshot);
                        snapshotted =
                            error == nil && [info[@"width"] intValue] == 64 && [info[@"height"] intValue] == 64;
                    }];
        [p invalidateWithId:ident
                      reply:^(NSError *error) {
                          invalidated = error == nil && p.sessions.count == 0;
                      }];
        [p provideSettingsViewModelsWithContentTypes:nil
                                               reply:^(id result, NSError *error) {
                                                   NSDictionary *model = FSInspectSettings(result);
                                                   settingsOK = error == nil &&
                                                                [model[@"desktop"][@"groups"] count] == 1 &&
                                                                [model[@"screenSaver"][@"groups"] count] == 1;
                                               }];
        NSDictionary *out = @{
            @"settingsCatalog" : @(settingsOK),
            @"acquire" : @(acquired),
            @"updateLockedSuspended" : @(updated),
            @"invalidate" : @(invalidated),
            @"systemActivationPerformed" : @NO,
            @"snapshotImplemented" : @(snapshotted)
        };
        NSData *d = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(d.bytes, 1, d.length, stdout);
        puts("");
        return acquired && updated && invalidated && snapshotted && settingsOK ? 0 : 2;
    }
}
#ifdef FS_SELF_TEST
int main() { return FSProviderSelfTest(); }
#endif

#ifdef FS_MEDIA_TEST
static void FSPump(double seconds) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2 || !FSLoad()) return 1;
    NSURL *dir=[NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    id colorPL=CFBridgingRelease(CGColorSpaceCopyPropertyList(color));CFRelease(color);
    NSData *colorData=[NSPropertyListSerialization dataWithPropertyList:colorPL format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSMutableDictionary *creation=[@{@"configuration":@"",@"destination":@{@"size":@[@96,@64],@"scaleFactor":@1,@"colorSpace":[colorData base64EncodedStringWithOptions:0]},@"isPreview":@YES,@"presentationMode":@{@"default":@{}},@"activityState":@{@"active":@{}},@"systemAppearance":@{@"light":@{}},@"debugBackgrounds":@NO} mutableCopy];
    FSProvider *provider=FSProvider.new;
    id ident=FSBox(@"WallpaperIDXPC",@"WallpaperID",@{@"id":@"12345678-1234-1234-1234-123456789ABC"});
    NSMutableDictionary *results=NSMutableDictionary.new;
    for(NSString *kind in @[@"image",@"video"]) {
        NSDictionary *config=@{@"version":@1,@"kind":kind,@"fileIndex":@0,@"identifier":[@"org.flua.test." stringByAppendingString:kind],@"fit":@"fill"};
        creation[@"configuration"]=[[NSJSONSerialization dataWithJSONObject:config options:0 error:nil] base64EncodedStringWithOptions:0];
        NSURL *file=[dir URLByAppendingPathComponent:[kind isEqual:@"video"] ? @"FluaMotion.mov" : @"FluaStill.png"];
        id request=FSCreateRequest(creation,@[file]);
        __block BOOL acquired=NO;__block NSString *errorText=@"";
        [provider acquireWithId:ident request:request reply:^(id remote,NSError *error){acquired=remote!=nil && !error;errorText=error.description ?: @"";}];
        FSSession *session=provider.sessions.allValues.firstObject;
        BOOL wrappers=[FSInspectCreation(request)[@"files"] count]==1 && session.renderer.scopedFileCount==1;
        __block NSDictionary *before;
        [provider snapshotWithId:ident reply:^(id snapshot,NSError *error){before=FSInspectSnapshot(snapshot);}];
        if([kind isEqual:@"video"]) FSPump(0.8);
        __block NSDictionary *after;
        [provider snapshotWithId:ident reply:^(id snapshot,NSError *error){after=FSInspectSnapshot(snapshot);}];
        BOOL motion=![before[@"checksum"] isEqual:after[@"checksum"]] && session.renderer.frameCount>2;
        NSMutableDictionary *update=[creation mutableCopy];[update removeObjectForKey:@"configuration"];[update removeObjectForKey:@"isPreview"];
        update[@"activityState"]=@{@"suspended":@{}};update[@"presentationMode"]=@{@"locked":@{}};
        [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",update) reply:^(NSError *error){}];
        NSUInteger pausedFrames=session.renderer.frameCount;double pausedTime=session.renderer.playbackTime;
        FSPump(0.3);
        BOOL paused=pausedFrames==session.renderer.frameCount && fabs(pausedTime-session.renderer.playbackTime)<0.05;
        update[@"activityState"]=@{@"active":@{}};
        [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",update) reply:^(NSError *error){}];
        if([kind isEqual:@"video"]) FSPump(2.6);
        NSInteger loops=session.renderer.loopCount;NSUInteger finalFrames=session.renderer.frameCount;
        BOOL resumed=![kind isEqual:@"video"] || finalFrames>pausedFrames;
        [provider invalidateWithId:ident reply:^(NSError *error){}];
        BOOL disposed=session.renderer.scopedFileCount==0 && session.renderer.activeScopeCount==0 && provider.sessions.count==0;
        BOOL success=acquired && wrappers && before && after && paused && resumed && disposed && (![kind isEqual:@"video"] || (motion && loops>=1));
        results[kind]=@{@"ok":@(success),@"acquired":@(acquired),@"nonemptyScopedFiles":@(wrappers),@"motion":@(motion),@"suspendedStable":@(paused),@"resumed":@(resumed),@"loopCount":@(loops),@"frames":@(finalFrames),@"disposed":@(disposed),@"error":errorText,@"snapshot":after ?: @{}};
    }
    results[@"systemActivationPerformed"]=@NO;
    results[@"sandboxAuthorizationVerified"]=@NO;
    NSData *json=[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");
    return [results[@"image"][@"ok"] boolValue] && [results[@"video"][@"ok"] boolValue] ? 0:2;
} }
#endif
