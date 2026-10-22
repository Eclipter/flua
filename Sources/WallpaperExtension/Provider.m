#import "Provider.h"
#import "MediaRenderer.h"
#import "PlaybackPolicy.h"
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pwd.h>

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
        @"origin": bytes ? @[@(bytes[0]), @(bytes[1]), @(bytes[2]), @(bytes[3])] : @[],
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
static NSString *FSProviderIdentifier(void) {
    NSString *ident = NSBundle.mainBundle.bundleIdentifier;
    return ident.length ? ident : @"org.flua.wallpaper.prototype";
}
static NSString *FSEncodeConfiguration(NSDictionary *configuration) {
    return [[NSJSONSerialization dataWithJSONObject:configuration options:0 error:nil] base64EncodedStringWithOptions:0] ?: @"";
}
// A library file is accepted only as Media/<name> inside the catalog root.
// shortcut: rows reuse the bundled prototype thumbnail, replace it when still frames exist.
static NSURL *FSActiveCatalogURL;
static NSDictionary *FSActivePlaybackPolicy;
static NSMutableArray *FSHeldCatalogAccess;
@protocol FSHostProxy <NSObject>
- (void)updateSettingsViewModels:(id)models reply:(void (^)(NSError *error))reply;
- (void)requestReadOnlyAccessTo:(NSURL *)url reply:(void (^)(id token, NSError *error))reply;
@end
// Env wins for tests. A bundled catalog.json is next. A running appex otherwise
// reads FLUACatalogPath or the live library catalog beside library.json.
static NSURL *FSCatalogURL(BOOL *bundledOut) {
    NSString *env = NSProcessInfo.processInfo.environment[@"FLUA_CATALOG"];
    if (env.length) {
        if (bundledOut) *bundledOut = NO;
        return [NSURL fileURLWithPath:env];
    }
    NSURL *bundled = [NSBundle.mainBundle URLForResource:@"catalog" withExtension:@"json"];
    if (bundled) {
        if (bundledOut) *bundledOut = YES;
        return bundled;
    }
    NSString *configured = NSBundle.mainBundle.infoDictionary[@"FLUACatalogPath"];
    if ([configured isKindOfClass:NSString.class] && [configured hasPrefix:@"/"]) {
        if (bundledOut) *bundledOut = NO;
        return [NSURL fileURLWithPath:configured];
    }
    if ([NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"appex"]) {
        struct passwd *pw = getpwuid(getuid());
        if (pw && pw->pw_dir) {
            if (bundledOut) *bundledOut = NO;
            return [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/Library/Application Support/Flua/catalog.json", pw->pw_dir]];
        }
    }
    return nil;
}
static BOOL FSAcceptCatalogToken(id token) {
    if (!token) return NO;
    NSURL *url = [token isKindOfClass:NSURL.class] ? token : nil;
    if (!url && [token respondsToSelector:@selector(url)])
        url = ((id (*)(id, SEL))objc_msgSend)(token, @selector(url));
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL ||
        ![url.URLByStandardizingPath isEqual:FSActiveCatalogURL.URLByStandardizingPath]) return NO;
    BOOL accessed = [url startAccessingSecurityScopedResource];
    if (![NSFileManager.defaultManager isReadableFileAtPath:url.path]) {
        if (accessed) [url stopAccessingSecurityScopedResource];
        return NO;
    }
    if (!FSHeldCatalogAccess) FSHeldCatalogAccess = NSMutableArray.new;
    [FSHeldCatalogAccess addObject:token];
    return YES;
}
static NSURL *FSContainedMediaURL(NSString *root, NSString *relative) {
    if (![relative isKindOfClass:NSString.class] || relative.length < 7 || ![relative hasPrefix:@"Media/"]) return nil;
    if ([relative rangeOfString:@".."].location != NSNotFound || [relative containsString:@"//"]) return nil;
    NSString *name = relative.lastPathComponent;
    if (!name.length || [name isEqual:@"."] || [name isEqual:@".."]) return nil;
    if (![relative isEqualToString:[@"Media" stringByAppendingPathComponent:name]]) return nil;
    NSString *media = [root.stringByStandardizingPath stringByAppendingPathComponent:@"Media"];
    NSString *full = [media stringByAppendingPathComponent:name].stringByStandardizingPath;
    if (![full hasPrefix:[media.stringByStandardizingPath stringByAppendingString:@"/"]]) return nil;
    return [NSURL fileURLWithPath:full];
}
static NSArray *FSLibraryChoices(NSString **directRead) {
    BOOL bundled = NO;
    NSURL *catalogURL = FSCatalogURL(&bundled);
    FSActiveCatalogURL = catalogURL;
    NSString *path = catalogURL.path;
    NSData *data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:NSDictionary.class] || [json[@"version"] integerValue] != 1 || ![json[@"items"] isKindOfClass:NSArray.class])
        return @[];
    NSString *parent = path.stringByDeletingLastPathComponent.stringByStandardizingPath;
    NSString *root = json[@"root"];
    if ([root isKindOfClass:NSString.class] && root.length) {
        if (![root hasPrefix:@"/"] || [root rangeOfString:@".."].location != NSNotFound) return @[];
        root = root.stringByStandardizingPath;
        if (!bundled && ![root isEqualToString:parent]) return @[];
    } else root = parent;
    FSActivePlaybackPolicy = [json[@"playbackPolicy"] isKindOfClass:NSDictionary.class] ? json[@"playbackPolicy"] : nil;
    NSMutableArray *choices = NSMutableArray.new;
    for (id entry in json[@"items"]) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *kind = entry[@"kind"], *ident = entry[@"id"], *title = entry[@"title"];
        BOOL scene = FSIsSceneKind(kind);
        if (!scene && ![kind isEqual:@"image"] && ![kind isEqual:@"video"]) continue;
        if (![ident isKindOfClass:NSString.class] || !ident.length) continue;
        if (![title isKindOfClass:NSString.class] || !title.length) title = ident;
        NSURL *file = scene ? nil : FSContainedMediaURL(root, entry[@"file"]);
        if (!scene && !file) continue;
        NSMutableDictionary *choice = [@{@"id" : ident, @"title" : title, @"kind" : kind,
                                        @"fit" : [entry[@"fit"] isEqual:@"fit"] ? @"fit" : @"fill",
                                        @"speed" : [entry[@"speed"] isKindOfClass:NSNumber.class] ? entry[@"speed"] : @1,
                                        @"dimming" : [entry[@"dimming"] isKindOfClass:NSNumber.class] ? entry[@"dimming"] : @0,
                                        @"desktop" : [entry[@"desktop"] isEqual:@"still"] ? @"still" : @"animated",
                                        @"lockScreen" : [entry[@"lockScreen"] isEqual:@"still"] ? @"still" : @"animated"} mutableCopy];
        if (file) choice[@"url"] = file;
        if ([entry[@"trimStart"] isKindOfClass:NSNumber.class] && [entry[@"trimEnd"] isKindOfClass:NSNumber.class]) {
            choice[@"trimStart"] = entry[@"trimStart"];
            choice[@"trimEnd"] = entry[@"trimEnd"];
        }
        if ([entry[@"still"] isKindOfClass:NSNumber.class]) choice[@"still"] = entry[@"still"];
        [choices addObject:choice];
    }
    if (directRead && choices.count) {
        NSURL *url = choices[0][@"url"];
        *directRead = [url isKindOfClass:NSURL.class] && [[NSFileManager defaultManager] isReadableFileAtPath:url.path] ? @"yes" : @"no";
    }
    return choices;
}
static NSDictionary *FSBuildSettingsModel(BOOL libraryOnly) {
    NSURL *thumbnail = [NSBundle.mainBundle URLForResource:@"PrototypeThumbnail" withExtension:@"png"];
    if (!thumbnail)
        thumbnail = [[NSBundle.mainBundle.executableURL URLByDeletingLastPathComponent]
            URLByAppendingPathComponent:@"PrototypeThumbnail.png"];
    NSDictionary *image = @{@"image" : @{@"url" : thumbnail.absoluteString ?: @""}};
    NSString *provider = FSProviderIdentifier();
    NSString *groupID = libraryOnly ? provider : @"org.flua.prototype";
    NSDictionary *choice = @{
        @"id" : @{
            @"descriptor" :
                @{@"provider" : provider, @"files" : @[], @"configuration" : @""}
        },
        @"localizedDescription" : @"Original Flua procedural gradient",
        @"thumbnail" : image,
        @"isDownloaded" : @YES,
        @"options" : @[]
    };
    NSDictionary *item = @{
        @"id" : @{@"id" : @"org.flua.prototype.gradient"},
        @"groupID" : @{@"id" : groupID},
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
        NSString *encoded=FSEncodeConfiguration(configuration);
        NSMutableDictionary *mediaChoice=[choice mutableCopy];
        mediaChoice[@"id"]=@{@"descriptor":@{@"provider":provider,@"files":@[],@"configuration":encoded}};
        mediaChoice[@"localizedDescription"]=name;
        NSMutableDictionary *mediaItem=[item mutableCopy];
        mediaItem[@"id"]=@{@"id":[@"org.flua.prototype." stringByAppendingString:kind]};
        mediaItem[@"localizedName"]=name;
        mediaItem[@"choice"]=mediaChoice;
        mediaItem[@"sortOrder"]=@(items.count);
        // The settings host plays a `video` badge on the Lock Screen. `none` stays on the desktop only.
        if ([kind isEqual:@"video"]) mediaItem[@"contentBadge"]=@{@"video":@{}};
        [items addObject:mediaItem];
    }
    if (libraryOnly) [items removeAllObjects];
    NSUInteger fixtureCount = items.count;
    NSString *directRead = nil;
    for (NSDictionary *library in FSLibraryChoices(&directRead)) {
        NSMutableDictionary *playback = [@{@"version":@1, @"kind":library[@"kind"], @"fit":library[@"fit"],
                                           @"speed":library[@"speed"], @"dimming":library[@"dimming"],
                                           @"modes":@{@"desktop":library[@"desktop"], @"lockScreen":library[@"lockScreen"]}} mutableCopy];
        if (FSActivePlaybackPolicy) playback[@"playbackPolicy"] = FSActivePlaybackPolicy;
        if (library[@"url"]) playback[@"fileIndex"] = @0;
        if (library[@"trimStart"] && library[@"trimEnd"]) playback[@"trim"] = @[library[@"trimStart"], library[@"trimEnd"]];
        if (library[@"still"]) playback[@"still"] = library[@"still"];
        else if (FSIsSceneKind(library[@"kind"])) playback[@"still"] = @7;
        NSString *encoded = FSEncodeConfiguration(playback);
        NSArray *files = library[@"url"] ? @[((NSURL *)library[@"url"]).absoluteString] : @[];
        NSMutableDictionary *mediaChoice=[choice mutableCopy];
        mediaChoice[@"id"]=@{@"descriptor":@{@"provider":provider,@"files":files,@"configuration":encoded}};
        mediaChoice[@"localizedDescription"]=library[@"title"];
        NSMutableDictionary *mediaItem=[item mutableCopy];
        mediaItem[@"id"]=@{@"id":[@"org.flua.library." stringByAppendingString:library[@"id"]]};
        mediaItem[@"localizedName"]=library[@"title"];
        mediaItem[@"choice"]=mediaChoice;
        mediaItem[@"sortOrder"]=@(items.count);
        if ([library[@"kind"] isEqual:@"video"] || FSIsSceneKind(library[@"kind"])) mediaItem[@"contentBadge"]=@{@"video":@{}};
        [items addObject:mediaItem];
    }
    if (directRead) NSLog(@"Flua catalog items=%lu directRead=%@", (unsigned long)(items.count - fixtureCount), directRead);
    NSDictionary *group = @{
        @"id" : @{@"id" : groupID},
        @"localizedName" : @"Flua",
        @"disposability" : @{@"none" : @{}},
        @"sortID" : @{@"id" : groupID},
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
NSDictionary *FSSettingsModel(void) {
    return FSBuildSettingsModel([NSBundle.mainBundle.infoDictionary[@"FLUALibraryOnly"] boolValue]);
}
NSDictionary *FSInspectSettings(id settings) { return FSJSON(settings, @"WallpaperSettingsViewModels"); }
@interface FSSession : NSObject
@property id context;
@property CALayer *root;
@property NSDictionary *request;
@property NSString *mode;
@property FSMediaRenderer *renderer;
@property NSDictionary *configuration;
@property NSDictionary *renderConfiguration;
@property NSArray *fileWrappers;
@property BOOL needsRecovery;
@property BOOL suspended;
@property BOOL playbackSuspended;
@property NSNumber *displayID;
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
@property(weak) NSXPCConnection *hostConnection;
@property dispatch_source_t catalogWatch;
@property BOOL askedForCatalog;
@property dispatch_source_t recoveryTimer;
@property dispatch_source_t playbackTimer;
@property NSDictionary *playbackEnvironment;
@property CFTimeInterval powerSampleTime;
@end
@implementation FSProvider
- (instancetype)init {
    if ((self = [super init]))
        _sessions = NSMutableDictionary.new;
    return self;
}
- (void)dealloc {
    if (_catalogWatch) dispatch_source_cancel(_catalogWatch);
    if (_recoveryTimer) dispatch_source_cancel(_recoveryTimer);
    if (_playbackTimer) dispatch_source_cancel(_playbackTimer);
}
- (void)applyPlaybackToSession:(FSSession *)session environment:(NSDictionary *)environment {
    NSDictionary *policy = FSActivePlaybackPolicy ?: session.configuration[@"playbackPolicy"];
    BOOL suspended = FSPlaybackShouldPause(policy, environment, session.displayID, session.mode,
        [session.request[@"isPreview"] boolValue], session.suspended);
    if (suspended != session.playbackSuspended) {
        NSLog(@"Flua playback suspended=%d hostSuspended=%d display=%@ mode=%@ frames=%lu",
            suspended, session.suspended, session.displayID, session.mode, (unsigned long)session.renderer.frameCount);
    }
    session.playbackSuspended = suspended;
    session.root.speed = suspended ? 0 : 1;
    if (session.renderer.suspended != suspended) [session.renderer setPlaybackSuspended:suspended];
}
- (NSDictionary *)currentPlaybackEnvironment {
    CFTimeInterval now = CACurrentMediaTime();
    // Space visibility must update within a frame; power sampling can stay at one second.
    if (!self.playbackEnvironment || now - self.powerSampleTime >= 1) {
        self.playbackEnvironment = FSPlaybackEnvironment();
        self.powerSampleTime = now;
    } else {
        NSMutableDictionary *environment = [self.playbackEnvironment mutableCopy];
        environment[@"fullscreenDisplays"] = FSFullscreenDisplays();
        self.playbackEnvironment = environment;
    }
    return self.playbackEnvironment;
}
- (void)refreshPlayback {
    NSDictionary *environment = [self currentPlaybackEnvironment];
    for (FSSession *session in self.sessions.allValues)
        [self applyPlaybackToSession:session environment:environment];
}
- (void)startPlaybackMonitoring {
    if (self.playbackTimer) return;
    __weak FSProvider *host = self;
    self.playbackTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.playbackTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.playbackTimer, ^{ [host refreshPlayback]; });
    dispatch_resume(self.playbackTimer);
}
- (NSDictionary *)renderConfiguration:(NSDictionary *)configuration presentation:(NSString *)presentation {
    if (!configuration.count || [configuration[@"version"] integerValue] == 1) return configuration;
    if ([configuration[@"version"] integerValue] != 2) return nil;
    NSDictionary *surfaces = [configuration[@"surfaces"] isKindOfClass:NSDictionary.class] ? configuration[@"surfaces"] : nil;
    NSDictionary *selected = [presentation isEqual:@"locked"] || [presentation isEqual:@"idle"] ? surfaces[@"lockScreen"] : surfaces[@"desktop"];
    return [selected isKindOfClass:NSDictionary.class] ? selected : nil;
}
- (BOOL)validConfiguration:(NSDictionary *)configuration wrappers:(NSArray *)wrappers {
    if (!configuration.count) return YES;
    NSInteger version = [configuration[@"version"] integerValue];
    NSDictionary *surfaces = [configuration[@"surfaces"] isKindOfClass:NSDictionary.class] ? configuration[@"surfaces"] : nil;
    NSArray *contents = version == 2 ? @[surfaces[@"desktop"] ?: NSNull.null, surfaces[@"lockScreen"] ?: NSNull.null] : @[configuration];
    if (version != 1 && version != 2) return NO;
    if (version == 2) {
        SEL urlSelector = NSSelectorFromString(@"url");
        for (id wrapper in wrappers) {
            if (![wrapper respondsToSelector:urlSelector]) return NO;
            NSURL *url = ((id (*)(id, SEL))objc_msgSend)(wrapper, urlSelector);
            if (![url isKindOfClass:NSURL.class] || !url.isFileURL) return NO;
        }
    }
    for (id content in contents) {
        if (![content isKindOfClass:NSDictionary.class]) return NO;
        if (version == 2 && [content[@"version"] integerValue] != 1) return NO;
        NSString *kind = content[@"kind"];
        if (![kind isKindOfClass:NSString.class] ||
            (![kind isEqual:@"image"] && ![kind isEqual:@"video"] && !FSIsSceneKind(kind))) return NO;
        if ([kind isEqual:@"image"] || [kind isEqual:@"video"]) {
            if ([content[@"source"] isEqual:@"bundle"]) continue;
            id index = content[@"fileIndex"];
            if (![index isKindOfClass:NSNumber.class] || [index doubleValue] != [index integerValue] ||
                [index integerValue] < 0 || (version == 2 && [index integerValue] >= (NSInteger)wrappers.count)) return NO;
        }
        if (content[@"source"] && ![content[@"source"] isEqual:@"bundle"]) return NO;
    }
    NSDictionary *policy = version == 2 ? configuration[@"playbackPolicy"] : nil;
    return !policy || [policy isKindOfClass:NSDictionary.class];
}
- (void)recoverSessions {
    for (FSSession *session in self.sessions.allValues) {
        if ((!session.needsRecovery && !session.renderer.playbackFailed) || session.playbackSuspended) continue;
        NSMutableDictionary *configuration = [[self renderConfiguration:session.configuration presentation:session.mode] mutableCopy];
        if (!configuration) continue;
        configuration[@"presentation"] = session.mode;
        BOOL alreadyShowingFallback = session.needsRecovery;
        NSError *mediaError;
        FSMediaRenderer *renderer = [[FSMediaRenderer alloc] initWithWidth:(NSUInteger)session.root.bounds.size.width
            height:(NSUInteger)session.root.bounds.size.height configuration:configuration
            fileWrappers:session.fileWrappers error:&mediaError];
        BOOL recovered = renderer != nil;
        if (!renderer && alreadyShowingFallback) continue;
        if (!renderer && ([configuration[@"kind"] isEqual:@"image"] || [configuration[@"kind"] isEqual:@"video"])) {
            renderer = [[FSMediaRenderer alloc] initWithWidth:(NSUInteger)session.root.bounds.size.width
                height:(NSUInteger)session.root.bounds.size.height configuration:@{@"kind":@"gradient"}
                fileWrappers:@[] error:NULL];
            if (renderer) NSLog(@"Flua media recovery failed; showing static fallback and retrying original host files: %@",
                                mediaError.localizedDescription ?: @"unknown error");
        }
        if (!renderer) continue;
        renderer.layer.speed = session.playbackSuspended ? 0 : 1;
        [renderer setPlaybackSuspended:session.playbackSuspended];
        ((void (*)(id, SEL, id))objc_msgSend)(session.context, NSSelectorFromString(@"setLayer:"), renderer.layer);
        [session.renderer dispose];
        session.renderer = renderer;
        session.renderConfiguration = [self renderConfiguration:session.configuration presentation:session.mode];
        session.root = renderer.layer;
        session.needsRecovery = !recovered;
        NSLog(@"Flua recovered media kind=%@ locked=%d idle=%d", configuration[@"kind"],
              [session.mode isEqual:@"locked"], [session.mode isEqual:@"idle"]);
        [CATransaction flush];
        if (recovered) NSLog(@"Flua recovered original media session");
    }
}
- (void)startRecovery {
    if (self.recoveryTimer) return;
    __weak FSProvider *host = self;
    self.recoveryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.recoveryTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
        5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(self.recoveryTimer, ^{
        [host recoverSessions];
        [host refreshCatalog];
    });
    dispatch_resume(self.recoveryTimer);
}
- (void)pushCatalog {
    NSXPCConnection *connection = self.hostConnection;
    if (!connection || !FSActiveCatalogURL) return;
    id models = FSBox(@"WallpaperSettingsViewModelsXPC", @"WallpaperSettingsViewModels", FSSettingsModel());
    id<FSHostProxy> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        NSLog(@"Flua catalog refresh: %@", error.localizedDescription);
    }];
    [proxy updateSettingsViewModels:models reply:^(NSError *error) {
        if (error) NSLog(@"Flua catalog refresh: %@", error.localizedDescription);
    }];
}
- (void)watchCatalog:(NSURL *)url {
    if (self.catalogWatch) return;
    int fd = open(url.path.fileSystemRepresentation, O_EVTONLY);
    __weak FSProvider *host = self;
    if (fd < 0) return;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_DELETE, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        FSProvider *provider = host;
        if (!provider) return;
        unsigned long flags = dispatch_source_get_data(provider.catalogWatch);
        if (flags & (DISPATCH_VNODE_RENAME | DISPATCH_VNODE_DELETE)) {
            dispatch_source_cancel(provider.catalogWatch);
            provider.catalogWatch = nil;
        }
        [provider pushCatalog];
        [provider refreshPlayback];
        // Atomic saves replace the inode; watch the new catalog with the same file-only grant.
        [provider watchCatalog:url];
    });
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    self.catalogWatch = source;
    dispatch_resume(source);
    [self pushCatalog];
}
- (void)refreshCatalog {
    NSURL *url = FSActiveCatalogURL;
    if (!url || !self.hostConnection) return;
    [self startRecovery];
    if ([NSFileManager.defaultManager isReadableFileAtPath:url.path]) {
        [self watchCatalog:url];
        return;
    }
    if (self.askedForCatalog) return;
    self.askedForCatalog = YES;
    NSXPCConnection *connection = self.hostConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        id<FSHostProxy> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ self.askedForCatalog = NO; });
            NSLog(@"Flua catalog access: %@", error.localizedDescription);
        }];
        [proxy requestReadOnlyAccessTo:url reply:^(id token, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.askedForCatalog = NO;
                if (error || !FSAcceptCatalogToken(token)) {
                    NSLog(@"Flua catalog access failed: %@", error.localizedDescription);
                    return;
                }
                [self pushCatalog];
                [self watchCatalog:url];
            });
        }];
    });
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
        NSArray *wrappers = captured.objects[@"files"] ?: @[];
        if (![self validConfiguration:configuration wrappers:wrappers]) {
            reply(nil, FSError(@"Invalid or incomplete Flua surface configuration")); return;
        }
        NSMutableDictionary *renderConfig = [[self renderConfiguration:configuration
            presentation:[payload[@"presentationMode"] allKeys].firstObject ?: @"default"] mutableCopy];
        if (!renderConfig) { reply(nil, FSError(@"Missing Flua surface configuration")); return; }
        renderConfig[@"presentation"] = [payload[@"presentationMode"] allKeys].firstObject ?: @"default";
        NSError *mediaError;
        FSMediaRenderer *renderer = [[FSMediaRenderer alloc] initWithWidth:(NSUInteger)w height:(NSUInteger)h configuration:renderConfig fileWrappers:wrappers error:&mediaError];
        BOOL needsRecovery = renderer == nil;
        if (!renderer && ([renderConfig[@"kind"] isEqual:@"image"] || [renderConfig[@"kind"] isEqual:@"video"])) {
            // Keep cached choices usable without changing their saved descriptor or reading alternate files.
            NSLog(@"Flua media unavailable; showing static fallback. Retrying original host files: %@", mediaError.localizedDescription);
            renderer = [[FSMediaRenderer alloc] initWithWidth:(NSUInteger)w height:(NSUInteger)h
                configuration:@{@"kind":@"gradient"} fileWrappers:@[] error:&mediaError];
        }
        if (!renderer) { reply(nil,mediaError ?: FSError(@"Cannot create renderer")); return; }
        FSSession *s = FSSession.new;
        s.request = payload;
        s.displayID = [payload[@"destination"][@"directDisplayID"] isKindOfClass:NSNumber.class] ? payload[@"destination"][@"directDisplayID"] : nil;
        s.configuration = configuration;
        s.mode = [payload[@"presentationMode"] allKeys].firstObject ?: @"default";
        s.renderConfiguration = [self renderConfiguration:configuration presentation:s.mode];
        s.fileWrappers = wrappers;
        s.needsRecovery = needsRecovery;
        s.suspended = payload[@"activityState"][@"suspended"] != nil;
        s.renderer = renderer;
        s.root = renderer.layer;
        [self applyPlaybackToSession:s environment:[self currentPlaybackEnvironment]];
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
        [self startRecovery];
        [self startPlaybackMonitoring];
        NSLog(@"Flua acquired kind=%@ locked=%d idle=%d preview=%d context=%u frames=%lu scopedFiles=%lu activeScopes=%lu display=%@",
              renderConfig[@"kind"], [s.mode isEqual:@"locked"], [s.mode isEqual:@"idle"], [payload[@"isPreview"] boolValue], cid, (unsigned long)renderer.frameCount,
              (unsigned long)renderer.scopedFileCount, (unsigned long)renderer.activeScopeCount, s.displayID);
        reply(box, nil);
        // The host can reuse a cached choice after relaunch without requesting settings again.
        if (!FSActiveCatalogURL) {
            FSSettingsModel();
            [self refreshCatalog];
            [self pushCatalog];
        }
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
    NSString *nextMode = [p[@"presentationMode"] allKeys].firstObject ?: @"default";
    NSDictionary *nextConfiguration = [self renderConfiguration:s.configuration presentation:nextMode];
    if (!nextConfiguration) { reply(FSError(@"Missing Flua surface configuration")); return; }
    if (![s.renderConfiguration isEqualToDictionary:nextConfiguration]) {
        NSMutableDictionary *renderConfig = [nextConfiguration mutableCopy];
        renderConfig[@"presentation"] = nextMode;
        NSError *mediaError;
        FSMediaRenderer *renderer = [[FSMediaRenderer alloc] initWithWidth:(NSUInteger)s.root.bounds.size.width
            height:(NSUInteger)s.root.bounds.size.height configuration:renderConfig
            fileWrappers:s.fileWrappers error:&mediaError];
        BOOL recovered = renderer != nil;
        if (!renderer && ([nextConfiguration[@"kind"] isEqual:@"image"] || [nextConfiguration[@"kind"] isEqual:@"video"])) {
            NSLog(@"Flua surface unavailable; showing static fallback. Retrying original host files: %@",
                  mediaError.localizedDescription ?: @"unknown error");
            renderer = [[FSMediaRenderer alloc] initWithWidth:(NSUInteger)s.root.bounds.size.width
                height:(NSUInteger)s.root.bounds.size.height configuration:@{@"kind":@"gradient", @"presentation":nextMode}
                fileWrappers:@[] error:&mediaError];
        }
        if (!renderer) { reply(mediaError ?: FSError(@"Cannot switch Flua surface content")); return; }
        renderer.layer.speed = s.playbackSuspended ? 0 : 1;
        [renderer setPlaybackSuspended:s.playbackSuspended];
        ((void (*)(id, SEL, id))objc_msgSend)(s.context, NSSelectorFromString(@"setLayer:"), renderer.layer);
        FSMediaRenderer *previous = s.renderer;
        s.renderer = renderer;
        s.root = renderer.layer;
        s.renderConfiguration = nextConfiguration;
        s.needsRecovery = !recovered;
        [previous dispose];
    }
    s.mode = nextMode;
    BOOL suspended = p[@"activityState"][@"suspended"] != nil;
    s.suspended = suspended;
    [s.renderer setPresentation:s.mode];
    if (p[@"destination"]) {
        s.displayID = [p[@"destination"][@"directDisplayID"] isKindOfClass:NSNumber.class] ? p[@"destination"][@"directDisplayID"] : nil;
    }
    [self applyPlaybackToSession:s environment:[self currentPlaybackEnvironment]];
    NSLog(@"Flua updated kind=%@ locked=%d idle=%d suspended=%d frames=%lu loops=%ld",
          s.renderConfiguration[@"kind"], [s.mode isEqual:@"locked"], [s.mode isEqual:@"idle"], suspended,
          (unsigned long)s.renderer.frameCount, (long)s.renderer.loopCount);
    reply(nil);
}
- (void)invalidateWithId:(id)ident reply:(void (^)(NSError *))reply {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self invalidateWithId:ident reply:reply];
        });
        return;
    }
    self.sessions[[self key:ident]].fileWrappers = @[];
    [self.sessions[[self key:ident]].renderer dispose];
    [self.sessions removeObjectForKey:[self key:ident]];
    if (self.sessions.count == 0 && self.playbackTimer) {
        dispatch_source_cancel(self.playbackTimer);
        self.playbackTimer = nil;
    }
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
    [self refreshCatalog];
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
- (void)isChoiceDownloadedWith:(id)choice reply:(void (^)(NSNumber *, NSError *))reply {
    reply(@YES, nil);
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
void FSConfigureHostInterface(NSXPCInterface *interface) {
    [interface setClasses:[NSSet setWithObject:NSClassFromString(@"WallpaperSettingsViewModelsXPC")]
              forSelector:@selector(updateSettingsViewModels:reply:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:[NSSet setWithObject:NSURL.class]
              forSelector:@selector(requestReadOnlyAccessTo:reply:)
            argumentIndex:0
                  ofReply:NO];
    Class wrapper = NSClassFromString(@"NSSecurityScopedURLWrapper");
    NSMutableSet *tokens = [NSMutableSet setWithObject:NSURL.class];
    if (wrapper) [tokens addObject:wrapper];
    [interface setClasses:tokens
              forSelector:@selector(requestReadOnlyAccessTo:reply:)
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
    Protocol *proxy = objc_getProtocol("WallpaperExtensionKit.WallpaperExtensionProxyXPCProtocol");
    FSProvider *provider = FSProvider.new;
    if (proxy) {
        connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:proxy];
        FSConfigureHostInterface(connection.remoteObjectInterface);
        provider.hostConnection = connection;
    }
    connection.exportedObject = provider;
    [connection resume];
    return YES;
}
#ifdef FS_SELF_TEST
@interface FSPlaybackMonitoringTestProvider : FSProvider
@property NSUInteger playbackSamples;
@end
@implementation FSPlaybackMonitoringTestProvider
- (void)refreshPlayback {
    self.playbackSamples++;
    [super refreshPlayback];
}
@end

static BOOL FSPlaybackMonitoringSelfTest(void) {
    FSPlaybackMonitoringTestProvider *provider = FSPlaybackMonitoringTestProvider.new;
    [provider refreshPlayback];
    provider.playbackEnvironment = @{@"onBattery":@YES, @"fullscreenDisplays":@[@"stale-display"]};
    [provider refreshPlayback];
    BOOL fullscreenSampleRefreshed = ![provider.playbackEnvironment[@"fullscreenDisplays"] containsObject:@"stale-display"];
    BOOL powerValueReused = [provider.playbackEnvironment[@"onBattery"] boolValue];
    CFTimeInterval firstPowerSample = provider.powerSampleTime;
    [provider startPlaybackMonitoring];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.25];
    while (deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    BOOL fastDisplayChecks = provider.playbackSamples >= 5;
    BOOL powerSampleReused = provider.powerSampleTime == firstPowerSample;
    provider.powerSampleTime -= 1;
    [provider refreshPlayback];
    BOOL powerSampleRefreshed = provider.powerSampleTime > firstPowerSample;
    dispatch_source_cancel(provider.playbackTimer);
    provider.playbackTimer = nil;
    return fastDisplayChecks && fullscreenSampleRefreshed && powerValueReused && powerSampleReused && powerSampleRefreshed;
}
#endif

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
        FSSession *policySession = p.sessions.allValues.firstObject;
        policySession.request = @{@"isPreview":@NO};
        policySession.configuration = @{@"playbackPolicy":@{@"pauseOnBattery":@YES}};
        policySession.suspended = NO;
        NSDictionary *previousPolicy = FSActivePlaybackPolicy;
        FSActivePlaybackPolicy = nil;
        [p applyPlaybackToSession:policySession environment:@{@"onBattery":@YES}];
        BOOL descriptorPolicyPaused = policySession.playbackSuspended;
        FSActivePlaybackPolicy = @{@"pauseOnBattery":@NO};
        [p applyPlaybackToSession:policySession environment:@{@"onBattery":@YES}];
        BOOL catalogOverridesDescriptor = !policySession.playbackSuspended;
        policySession.request = @{@"isPreview":@YES};
        FSActivePlaybackPolicy = @{@"pauseOnBattery":@YES};
        [p applyPlaybackToSession:policySession environment:@{@"onBattery":@YES}];
        BOOL previewIgnoresPolicy = !policySession.playbackSuspended;
        FSActivePlaybackPolicy = previousPolicy;
        BOOL policyPrecedence = descriptorPolicyPaused && catalogOverridesDescriptor && previewIgnoresPolicy;
        [p invalidateWithId:ident
                      reply:^(NSError *error) {
                          invalidated = error == nil && p.sessions.count == 0;
                      }];
        [p provideSettingsViewModelsWithContentTypes:nil
                                               reply:^(id result, NSError *error) {
                                                   NSDictionary *model = FSInspectSettings(result);
                                                   NSArray *groups = model[@"desktop"][@"groups"];
                                                   NSArray *items = groups.count ? groups[0][@"items"] : @[];
                                                   settingsOK = error == nil && items.count >= 3 &&
                                                                [model[@"desktop"][@"groups"] count] == 1 &&
                                                                [model[@"screenSaver"][@"groups"] count] == 1 &&
                                                                [items[1][@"contentBadge"][@"none"] isKindOfClass:NSDictionary.class] &&
                                                                [items[2][@"contentBadge"][@"video"] isKindOfClass:NSDictionary.class];
                                               }];
        NSDictionary *libraryOnly = FSBuildSettingsModel(YES);
        BOOL noFixtures = [libraryOnly[@"desktop"][@"groups"][0][@"items"] count] == 0 &&
            FSBox(@"WallpaperSettingsViewModelsXPC", @"WallpaperSettingsViewModels", libraryOnly) != nil;
        BOOL playbackPolicyOK = FSPlaybackPolicySelfTest();
        BOOL playbackMonitoringOK = YES;
#ifdef FS_SELF_TEST
        playbackMonitoringOK = FSPlaybackMonitoringSelfTest();
#endif
        NSDictionary *out = @{
            @"playbackMonitoring" : @(playbackMonitoringOK),
            @"playbackPolicy" : @(playbackPolicyOK),
            @"policyPrecedence" : @(policyPrecedence),
            @"libraryOnlyCatalog" : @(noFixtures),
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
        return acquired && updated && invalidated && snapshotted && settingsOK && noFixtures && playbackPolicyOK && policyPrecedence && playbackMonitoringOK ? 0 : 2;
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
static BOOL FSVerifyFreshProviderReacquire(NSURL *file, id ident, NSDictionary *creation) {
    NSMutableDictionary *savedCreation = [creation mutableCopy];
    savedCreation[@"configuration"] = FSEncodeConfiguration(@{ @"version":@1, @"kind":@"image", @"fileIndex":@0 });
    savedCreation[@"presentationMode"] = @{ @"default":@{} };
    savedCreation[@"activityState"] = @{ @"active":@{} };
    id savedRequest = FSCreateRequest(savedCreation, @[file]);
    NSDictionary *savedPayload = FSInspectCreation(savedRequest)[@"payload"];
    FSCaptureCoder *savedCoder = FSCaptureCoder.new;
    [savedRequest encodeWithCoder:savedCoder];
    id savedWrapper = [savedCoder.objects[@"files"] firstObject];

    FSProvider *firstProvider = FSProvider.new;
    __block BOOL firstAcquired = NO;
    [firstProvider acquireWithId:ident request:savedRequest reply:^(id remote, NSError *error) {
        firstAcquired = remote != nil && error == nil;
    }];
    FSSession *firstSession = firstProvider.sessions.allValues.firstObject;
    BOOL initialSessionReady = firstAcquired && firstSession.renderer.scopedFileCount == 1 &&
        firstSession.renderer.activeScopeCount == 1 && firstSession.renderer.frameCount > 0;
    [firstProvider invalidateWithId:ident reply:^(NSError *error) {}];

    id retryRequest = FSCreateRequest(savedCreation, @[file]);
    FSCaptureCoder *retryCoder = FSCaptureCoder.new;
    [retryRequest encodeWithCoder:retryCoder];
    id retryWrapper = [retryCoder.objects[@"files"] firstObject];
    FSProvider *restartedProvider = FSProvider.new;
    __block BOOL reacquired = NO;
    [restartedProvider acquireWithId:ident request:retryRequest reply:^(id remote, NSError *error) {
        reacquired = remote != nil && error == nil;
    }];
    FSSession *restartedSession = restartedProvider.sessions.allValues.firstObject;
    BOOL savedChoiceRestored = reacquired && savedWrapper && retryWrapper && savedWrapper != retryWrapper &&
        [savedPayload isEqual:FSInspectCreation(retryRequest)[@"payload"]] &&
        [restartedSession.request isEqual:savedPayload] && restartedSession.renderer.scopedFileCount == 1 &&
        restartedSession.renderer.activeScopeCount == 1 && restartedSession.renderer.frameCount > 0;
    [restartedProvider invalidateWithId:ident reply:^(NSError *error) {}];
    return initialSessionReady && savedChoiceRestored;
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
    BOOL freshProviderReacquire = FSVerifyFreshProviderReacquire([dir URLByAppendingPathComponent:@"FluaStill.png"], ident, creation);
    results[@"freshProviderReacquire"] = @{@"ok":@(freshProviderReacquire)};
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
    NSURL *stillFile = [dir URLByAppendingPathComponent:@"FluaStill.png"];
    NSURL *motionFile = [dir URLByAppendingPathComponent:@"FluaMotion.mov"];
    NSDictionary *desktopContent = @{@"version":@1, @"kind":@"image", @"fileIndex":@0,
        @"modes":@{@"desktop":@"animated", @"lockScreen":@"animated"}};
    NSDictionary *lockContent = @{@"version":@1, @"kind":@"video", @"fileIndex":@1,
        @"modes":@{@"desktop":@"animated", @"lockScreen":@"animated"}};
    NSDictionary *paired = @{@"version":@2, @"surfaces":@{@"desktop":desktopContent, @"lockScreen":lockContent},
        @"playbackPolicy":@{@"pauseOnBattery":@NO}};
    creation[@"configuration"] = FSEncodeConfiguration(paired);
    creation[@"presentationMode"] = @{@"default":@{}};
    creation[@"activityState"] = @{@"active":@{}};
    __block BOOL pairedAcquired = NO;
    [provider acquireWithId:ident request:FSCreateRequest(creation, @[stillFile, motionFile]) reply:^(id remote, NSError *error) {
        pairedAcquired = remote != nil && error == nil;
    }];
    FSSession *pairedSession = provider.sessions.allValues.firstObject;
    FSMediaRenderer *desktopRenderer = pairedSession.renderer;
    id pairedContext = pairedSession.context;
    __block NSDictionary *desktopSnapshot;
    [provider snapshotWithId:ident reply:^(id snapshot, NSError *error) { desktopSnapshot = FSInspectSnapshot(snapshot); }];
    BOOL pairedWrappers = pairedAcquired && pairedSession.fileWrappers.count == 2 &&
        desktopRenderer.scopedFileCount == 2 && desktopRenderer.activeScopeCount == 2 &&
        [pairedSession.renderConfiguration[@"kind"] isEqual:@"image"];
    NSMutableDictionary *pairedUpdate = [creation mutableCopy];
    [pairedUpdate removeObjectForKey:@"configuration"];
    [pairedUpdate removeObjectForKey:@"isPreview"];
    pairedUpdate[@"presentationMode"] = @{@"locked":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC", @"WallpaperUpdateRequest", pairedUpdate) reply:^(NSError *error) {}];
    FSMediaRenderer *lockRenderer = pairedSession.renderer;
    FSPump(0.25);
    __block NSDictionary *lockSnapshot;
    [provider snapshotWithId:ident reply:^(id snapshot, NSError *error) { lockSnapshot = FSInspectSnapshot(snapshot); }];
    BOOL switchedToLock = lockRenderer != desktopRenderer && pairedSession.context == pairedContext &&
        [pairedSession.renderConfiguration[@"kind"] isEqual:@"video"] && lockRenderer.scopedFileCount == 2 &&
        lockRenderer.activeScopeCount == 2 && desktopRenderer.activeScopeCount == 0 &&
        ![desktopSnapshot[@"checksum"] isEqual:lockSnapshot[@"checksum"]];
    pairedUpdate[@"presentationMode"] = @{@"idle":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC", @"WallpaperUpdateRequest", pairedUpdate) reply:^(NSError *error) {}];
    BOOL idleKeepsLock = pairedSession.renderer == lockRenderer && [pairedSession.mode isEqual:@"idle"];
    pairedUpdate[@"activityState"] = @{@"suspended":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC", @"WallpaperUpdateRequest", pairedUpdate) reply:^(NSError *error) {}];
    NSUInteger pairedPausedFrames = lockRenderer.frameCount;
    FSPump(0.2);
    BOOL pairedSuspension = pairedPausedFrames == lockRenderer.frameCount;
    pairedUpdate[@"activityState"] = @{@"active":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC", @"WallpaperUpdateRequest", pairedUpdate) reply:^(NSError *error) {}];
    pairedUpdate[@"presentationMode"] = @{@"default":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC", @"WallpaperUpdateRequest", pairedUpdate) reply:^(NSError *error) {}];
    FSMediaRenderer *desktopAgain = pairedSession.renderer;
    __block NSDictionary *desktopAgainSnapshot;
    [provider snapshotWithId:ident reply:^(id snapshot, NSError *error) { desktopAgainSnapshot = FSInspectSnapshot(snapshot); }];
    BOOL switchedBack = desktopAgain != lockRenderer && [pairedSession.renderConfiguration[@"kind"] isEqual:@"image"] &&
        [desktopAgainSnapshot[@"checksum"] isEqual:desktopSnapshot[@"checksum"]] && lockRenderer.activeScopeCount == 0;
    [provider invalidateWithId:ident reply:^(NSError *error) {}];
    BOOL pairedDisposed = provider.sessions.count == 0 && desktopRenderer.activeScopeCount == 0 &&
        lockRenderer.activeScopeCount == 0 && desktopAgain.scopedFileCount == 0 && desktopAgain.activeScopeCount == 0;
    NSDictionary *incompletePair = @{@"version":@2, @"surfaces":@{@"desktop":desktopContent}};
    creation[@"configuration"] = FSEncodeConfiguration(incompletePair);
    __block BOOL rejectedIncompletePair = NO;
    [provider acquireWithId:ident request:FSCreateRequest(creation, @[stillFile, motionFile]) reply:^(id remote, NSError *error) {
        rejectedIncompletePair = remote == nil && error != nil;
    }];
    BOOL surfaceSwitchOK = pairedWrappers && switchedToLock && idleKeepsLock && switchedBack && pairedSuspension &&
        pairedDisposed && rejectedIncompletePair && provider.sessions.count == 0;
    results[@"surfaceSwitch"] = @{@"ok":@(surfaceSwitchOK), @"pairedWrappers":@(pairedWrappers),
        @"switchedToLock":@(switchedToLock), @"idleKeepsLock":@(idleKeepsLock), @"switchedBack":@(switchedBack),
        @"suspendedStable":@(pairedSuspension), @"disposedScopes":@(pairedDisposed), @"rejectedIncompletePair":@(rejectedIncompletePair)};
    NSURL *missingAlternate = [dir URLByAppendingPathComponent:@"recover-alternate.mov"];
    [NSFileManager.defaultManager removeItemAtURL:missingAlternate error:nil];
    creation[@"configuration"] = FSEncodeConfiguration(paired);
    creation[@"presentationMode"] = @{@"default":@{}};
    __block BOOL alternateAcquired = NO;
    [provider acquireWithId:ident request:FSCreateRequest(creation, @[stillFile, missingAlternate]) reply:^(id remote, NSError *error) {
        alternateAcquired = remote != nil && error == nil;
    }];
    FSSession *alternateSession = provider.sessions.allValues.firstObject;
    FSMediaRenderer *desktopBeforeRecovery = alternateSession.renderer;
    pairedUpdate[@"presentationMode"] = @{@"locked":@{}};
    pairedUpdate[@"activityState"] = @{@"active":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC", @"WallpaperUpdateRequest", pairedUpdate) reply:^(NSError *error) {}];
    BOOL alternateFallback = alternateAcquired && alternateSession.needsRecovery &&
        alternateSession.renderer != desktopBeforeRecovery && [alternateSession.mode isEqual:@"locked"] &&
        [alternateSession.renderConfiguration[@"kind"] isEqual:@"video"] && desktopBeforeRecovery.activeScopeCount == 0;
    NSData *motionData = [NSData dataWithContentsOfURL:motionFile];
    [motionData writeToURL:missingAlternate atomically:YES];
    [provider recoverSessions];
    BOOL alternateRecovered = !alternateSession.needsRecovery && [alternateSession.mode isEqual:@"locked"] &&
        [alternateSession.renderConfiguration[@"kind"] isEqual:@"video"] && alternateSession.renderer.scopedFileCount == 2 &&
        alternateSession.renderer.activeScopeCount == 2;
    FSMediaRenderer *alternateRenderer = alternateSession.renderer;
    [provider invalidateWithId:ident reply:^(NSError *error) {}];
    BOOL alternateDisposed = provider.sessions.count == 0 && alternateRenderer.scopedFileCount == 0 &&
        alternateRenderer.activeScopeCount == 0;
    [NSFileManager.defaultManager removeItemAtURL:missingAlternate error:nil];
    BOOL alternateRecoveryOK = alternateFallback && alternateRecovered && alternateDisposed;
    results[@"surfaceRecovery"] = @{@"ok":@(alternateRecoveryOK), @"fallbackUsesSelectedSurface":@(alternateFallback),
        @"recoveredSelectedSurface":@(alternateRecovered), @"disposedScopes":@(alternateDisposed)};
    BOOL recoveryOK = freshProviderReacquire;
    NSURL *broken = [dir URLByAppendingPathComponent:@"broken-media"];
    [@"invalid media" writeToURL:broken atomically:YES encoding:NSUTF8StringEncoding error:nil];
    for (NSString *kind in @[@"image", @"video"]) {
        creation[@"configuration"] = FSEncodeConfiguration(@{@"version":@1, @"kind":kind, @"fileIndex":@0});
        for (NSArray *files in @[@[], @[[dir URLByAppendingPathComponent:@"missing-media"]], @[broken]]) {
            __block BOOL fallback = NO;
            [provider acquireWithId:ident request:FSCreateRequest(creation, files) reply:^(id remote, NSError *error) {
                fallback = remote != nil && error == nil;
            }];
            FSSession *session = provider.sessions.allValues.firstObject;
            __block NSNumber *before = nil, *after = nil;
            [provider snapshotWithId:ident reply:^(id snapshot, NSError *error) { before = FSInspectSnapshot(snapshot)[@"checksum"]; }];
            [session.renderer setPresentation:@"locked"];
            [session.renderer setPlaybackSuspended:YES];
            [session.renderer setPlaybackSuspended:NO];
            FSPump(0.1);
            [provider snapshotWithId:ident reply:^(id snapshot, NSError *error) { after = FSInspectSnapshot(snapshot)[@"checksum"]; }];
            recoveryOK = recoveryOK && fallback && before != nil && [before isEqual:after] && session.renderer.scopedFileCount == 0;
            [provider invalidateWithId:ident reply:^(NSError *error) {}];
        }
        NSURL *restored = [dir URLByAppendingPathComponent:[kind isEqual:@"video"] ? @"FluaMotion.mov" : @"FluaStill.png"];
        __block BOOL recovered = NO;
        [provider acquireWithId:ident request:FSCreateRequest(creation, @[restored]) reply:^(id remote, NSError *error) {
            recovered = remote != nil && error == nil;
        }];
        recoveryOK = recoveryOK && recovered && ((FSSession *)provider.sessions.allValues.firstObject).renderer.scopedFileCount == 1;
        [provider invalidateWithId:ident reply:^(NSError *error) {}];
    }
    BOOL automaticRecovery = YES;
    for (NSString *kind in @[@"image", @"video"]) {
        NSURL *original = [dir URLByAppendingPathComponent:[kind isEqual:@"video"] ? @"FluaMotion.mov" : @"FluaStill.png"];
        NSURL *missing = [dir URLByAppendingPathComponent:[kind isEqual:@"video"] ? @"recover-video.mov" : @"recover-image.png"];
        NSData *source = [NSData dataWithContentsOfURL:original];
        [NSFileManager.defaultManager removeItemAtURL:missing error:nil];
        creation[@"configuration"] = FSEncodeConfiguration(@{@"version":@1, @"kind":kind, @"fileIndex":@0,
            @"modes":@{@"desktop":@"animated", @"lockScreen":@"still"}, @"still":@0.5});
        [provider acquireWithId:ident request:FSCreateRequest(creation, @[missing]) reply:^(id remote, NSError *error) {}];
        FSSession *session = provider.sessions.allValues.firstObject;
        NSDictionary *saved = [session.request copy];
        CALayer *fallback = session.root;
        [provider recoverSessions];
        automaticRecovery = automaticRecovery && session.needsRecovery && session.root == fallback;
        NSMutableDictionary *update = [creation mutableCopy];
        [update removeObjectForKey:@"configuration"];
        [update removeObjectForKey:@"isPreview"];
        update[@"presentationMode"] = @{@"locked":@{}};
        update[@"activityState"] = @{@"suspended":@{}};
        [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC", @"WallpaperUpdateRequest", update) reply:^(NSError *error) {}];
        [source writeToURL:missing atomically:YES];
        [provider recoverSessions];
        automaticRecovery = automaticRecovery && session.needsRecovery && session.root == fallback;
        update[@"activityState"] = @{@"active":@{}};
        [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC", @"WallpaperUpdateRequest", update) reply:^(NSError *error) {}];
        // Exercise the timer too; the other kind uses the same deterministic retry path.
        if ([kind isEqual:@"image"]) FSPump(6.2);
        else [provider recoverSessions];
        automaticRecovery = automaticRecovery && !session.needsRecovery && session.root != fallback &&
            session.renderer.scopedFileCount == 1 && session.renderer.holdsStill && [session.request isEqual:saved] &&
            [source isEqual:[NSData dataWithContentsOfURL:original]];
        [provider invalidateWithId:ident reply:^(NSError *error) {}];
        [provider recoverSessions];
        automaticRecovery = automaticRecovery && provider.sessions.count == 0 && session.fileWrappers.count == 0;
    }
    recoveryOK = recoveryOK && automaticRecovery;
    BOOL activeVideoRecovery = NO;
    NSURL *sourceVideo = [dir URLByAppendingPathComponent:@"FluaMotion.mov"];
    NSData *sourceVideoData = [NSData dataWithContentsOfURL:sourceVideo];
    NSURL *activeVideo = [dir URLByAppendingPathComponent:@"active-recovery.mov"];
    if (sourceVideoData.length && [sourceVideoData writeToURL:activeVideo atomically:YES]) {
        creation[@"configuration"] = FSEncodeConfiguration(@{@"version":@1, @"kind":@"video", @"fileIndex":@0});
        creation[@"presentationMode"] = @{@"default":@{}};
        creation[@"activityState"] = @{@"active":@{}};
        [provider acquireWithId:ident request:FSCreateRequest(creation, @[activeVideo]) reply:^(id remote, NSError *error) {}];
        FSSession *session = provider.sessions.allValues.firstObject;
        NSDictionary *savedRequest = [session.request copy];
        FSMediaRenderer *originalRenderer = session.renderer;
        FSPump(0.35);
        NSFileHandle *brokenHandle = [NSFileHandle fileHandleForWritingAtPath:activeVideo.path];
        [brokenHandle truncateFileAtOffset:0];
        [brokenHandle writeData:[@"truncated video" dataUsingEncoding:NSUTF8StringEncoding]];
        [brokenHandle synchronizeFile];
        [brokenHandle closeFile];
        NSDate *failureDeadline = [NSDate dateWithTimeIntervalSinceNow:6];
        while (failureDeadline.timeIntervalSinceNow > 0 && !session.needsRecovery && !session.renderer.playbackFailed)
            FSPump(0.1);
        BOOL failureDetected = session.needsRecovery || session.renderer.playbackFailed;
        if (failureDetected && !session.needsRecovery) [provider recoverSessions];
        BOOL fallback = failureDetected && session.needsRecovery && session.renderer != originalRenderer &&
            session.renderer.scopedFileCount == 0 && [session.request isEqual:savedRequest];
        NSFileHandle *restoreHandle = [NSFileHandle fileHandleForWritingAtPath:activeVideo.path];
        [restoreHandle truncateFileAtOffset:0];
        [restoreHandle writeData:sourceVideoData];
        [restoreHandle synchronizeFile];
        [restoreHandle closeFile];
        [provider recoverSessions];
        FSPump(0.5);
        activeVideoRecovery = fallback && !session.needsRecovery && session.renderer.scopedFileCount == 1 &&
            session.renderer.frameCount > 1 && !session.renderer.playbackFailed &&
            [session.request isEqual:savedRequest] && [sourceVideoData isEqual:[NSData dataWithContentsOfURL:activeVideo]];
        [provider invalidateWithId:ident reply:^(NSError *error) {}];
        [NSFileManager.defaultManager removeItemAtURL:activeVideo error:nil];
    }
    recoveryOK = recoveryOK && activeVideoRecovery;
    creation[@"configuration"] = FSEncodeConfiguration(@{@"version":@2, @"kind":@"video", @"fileIndex":@0});
    __block BOOL rejectedConfiguration = NO;
    [provider acquireWithId:ident request:FSCreateRequest(creation, @[]) reply:^(id remote, NSError *error) {
        rejectedConfiguration = remote == nil && error != nil;
    }];
    recoveryOK = recoveryOK && rejectedConfiguration && provider.sessions.count == 0;
    NSURL *video=[dir URLByAppendingPathComponent:@"FluaMotion.mov"];
    NSURL *image=[dir URLByAppendingPathComponent:@"FluaStill.png"];
    NSData *videoBefore=[NSData dataWithContentsOfURL:video];
    NSDictionary *tuned=@{@"version":@1,@"kind":@"video",@"fileIndex":@0,@"fit":@"fill",@"speed":@2,@"dimming":@0,@"trim":@[@0.4,@1.2],@"still":@0.5,@"modes":@{@"desktop":@"animated",@"lockScreen":@"still"}};
    creation[@"configuration"]=[[NSJSONSerialization dataWithJSONObject:tuned options:0 error:nil] base64EncodedStringWithOptions:0];
    creation[@"presentationMode"]=@{@"default":@{}}; creation[@"activityState"]=@{@"active":@{}};
    __block BOOL tunedAcquired=NO;
    [provider acquireWithId:ident request:FSCreateRequest(creation,@[video]) reply:^(id remote,NSError *error){tunedAcquired=remote!=nil && !error;}];
    FSSession *tunedSession=provider.sessions.allValues.firstObject;
    FSPump(0.45);
    NSMutableArray *times=NSMutableArray.new;
    for (int i=0;i<6;i++) { FSPump(0.08); [times addObject:@(tunedSession.renderer.playbackTime)]; }
    BOOL inTrim=times.count == 6;
    BOOL moved=NO;
    for (NSUInteger i=0;i<times.count;i++) {
        double time=[times[i] doubleValue];
        if (time < 0.35 || time > 1.25) inTrim=NO;
        if (i > 0 && time > [times[i - 1] doubleValue] + 0.02) moved=YES;
    }
    BOOL rate=fabs(tunedSession.renderer.playbackRate - 2) < 0.15 && !tunedSession.renderer.holdsStill;
    NSMutableDictionary *modeUpdate=[creation mutableCopy]; [modeUpdate removeObjectForKey:@"configuration"]; [modeUpdate removeObjectForKey:@"isPreview"];
    modeUpdate[@"presentationMode"]=@{@"default":@{}}; modeUpdate[@"activityState"]=@{@"suspended":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",modeUpdate) reply:^(NSError *error){}];
    double heldTime=tunedSession.renderer.playbackTime; NSUInteger heldFrames=tunedSession.renderer.frameCount;
    FSPump(0.25);
    BOOL suspendedHoldsMode=!tunedSession.renderer.holdsStill && tunedSession.renderer.playbackRate == 0 && tunedSession.renderer.frameCount == heldFrames && fabs(tunedSession.renderer.playbackTime - heldTime) < 0.05;
    modeUpdate[@"activityState"]=@{@"active":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",modeUpdate) reply:^(NSError *error){}];
    FSPump(0.3);
    BOOL resumedSameMode=!tunedSession.renderer.holdsStill && tunedSession.renderer.frameCount > heldFrames && tunedSession.renderer.playbackRate > 1;
    modeUpdate[@"presentationMode"]=@{@"locked":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",modeUpdate) reply:^(NSError *error){}];
    NSUInteger stillFrames=tunedSession.renderer.frameCount;
    FSPump(0.35);
    BOOL lockedStill=tunedSession.renderer.holdsStill && tunedSession.renderer.playbackRate == 0 && tunedSession.renderer.frameCount == stillFrames;
    modeUpdate[@"presentationMode"]=@{@"idle":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",modeUpdate) reply:^(NSError *error){}];
    NSUInteger idleFrames=tunedSession.renderer.frameCount;
    FSPump(0.3);
    BOOL idleUsesLock=tunedSession.renderer.holdsStill && tunedSession.renderer.playbackRate==0 && tunedSession.renderer.frameCount==idleFrames;
    modeUpdate[@"activityState"]=@{@"suspended":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",modeUpdate) reply:^(NSError *error){}];
    modeUpdate[@"activityState"]=@{@"active":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",modeUpdate) reply:^(NSError *error){}];
    FSPump(0.3);
    BOOL idleResumeStill=tunedSession.renderer.holdsStill && tunedSession.renderer.playbackRate==0 && tunedSession.renderer.frameCount==idleFrames;
    modeUpdate[@"presentationMode"]=@{@"default":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",modeUpdate) reply:^(NSError *error){}];
    FSPump(0.3);
    BOOL desktopPlays=!tunedSession.renderer.holdsStill && tunedSession.renderer.frameCount > stillFrames;
    dispatch_source_cancel(provider.playbackTimer);
    provider.playbackTimer = nil;
    NSDictionary *savedPolicy = FSActivePlaybackPolicy;
    FSActivePlaybackPolicy = @{@"pauseOnBattery":@YES};
    NSMutableDictionary *liveRequest = [tunedSession.request mutableCopy];
    liveRequest[@"isPreview"] = @NO;
    tunedSession.request = liveRequest;
    [provider applyPlaybackToSession:tunedSession environment:@{@"onBattery":@YES}];
    NSUInteger powerFrames = tunedSession.renderer.frameCount;
    double powerTime = tunedSession.renderer.playbackTime;
    FSPump(0.25);
    BOOL powerPaused = tunedSession.playbackSuspended && tunedSession.renderer.playbackRate == 0 &&
        tunedSession.renderer.frameCount == powerFrames && fabs(tunedSession.renderer.playbackTime - powerTime) < 0.05;
    tunedSession.suspended = YES;
    [provider applyPlaybackToSession:tunedSession environment:@{@"onBattery":@NO}];
    BOOL hostPauseRetained = tunedSession.playbackSuspended && tunedSession.renderer.playbackRate == 0;
    tunedSession.suspended = NO;
    [provider applyPlaybackToSession:tunedSession environment:@{@"onBattery":@NO}];
    FSPump(0.3);
    BOOL powerResumed = !tunedSession.playbackSuspended && tunedSession.renderer.playbackRate > 1 &&
        tunedSession.renderer.frameCount > powerFrames && !tunedSession.renderer.holdsStill;
    FSActivePlaybackPolicy = savedPolicy;
    [provider invalidateWithId:ident reply:^(NSError *error){}];
    BOOL sourceUntouched=videoBefore.length > 0 && [videoBefore isEqual:[NSData dataWithContentsOfURL:video]];
    NSDictionary *plainImage=@{@"version":@1,@"kind":@"image",@"fileIndex":@0,@"fit":@"fill",@"dimming":@0};
    creation[@"configuration"]=[[NSJSONSerialization dataWithJSONObject:plainImage options:0 error:nil] base64EncodedStringWithOptions:0];
    creation[@"destination"]=[@{@"size":@[@96,@64],@"scaleFactor":@1,@"colorSpace":creation[@"destination"][@"colorSpace"]} mutableCopy];
    [provider acquireWithId:ident request:FSCreateRequest(creation,@[image]) reply:^(id remote,NSError *error){}];
    __block NSArray *bright=nil;
    [provider snapshotWithId:ident reply:^(id snapshot,NSError *error){bright=FSInspectSnapshot(snapshot)[@"origin"];}];
    [provider invalidateWithId:ident reply:^(NSError *error){}];
    NSMutableDictionary *dimmedImage=[plainImage mutableCopy]; dimmedImage[@"dimming"]=@0.5;
    creation[@"configuration"]=[[NSJSONSerialization dataWithJSONObject:dimmedImage options:0 error:nil] base64EncodedStringWithOptions:0];
    [provider acquireWithId:ident request:FSCreateRequest(creation,@[image]) reply:^(id remote,NSError *error){}];
    __block NSArray *dark=nil;
    [provider snapshotWithId:ident reply:^(id snapshot,NSError *error){dark=FSInspectSnapshot(snapshot)[@"origin"];}];
    [provider invalidateWithId:ident reply:^(NSError *error){}];
    creation[@"destination"][@"size"]=@[@32,@64];
    NSMutableDictionary *fillImage=[plainImage mutableCopy]; fillImage[@"fit"]=@"fill";
    creation[@"configuration"]=[[NSJSONSerialization dataWithJSONObject:fillImage options:0 error:nil] base64EncodedStringWithOptions:0];
    [provider acquireWithId:ident request:FSCreateRequest(creation,@[image]) reply:^(id remote,NSError *error){}];
    __block NSDictionary *filled=nil;
    [provider snapshotWithId:ident reply:^(id snapshot,NSError *error){filled=FSInspectSnapshot(snapshot);}];
    [provider invalidateWithId:ident reply:^(NSError *error){}];
    NSMutableDictionary *fittedImage=[plainImage mutableCopy]; fittedImage[@"fit"]=@"fit";
    creation[@"configuration"]=[[NSJSONSerialization dataWithJSONObject:fittedImage options:0 error:nil] base64EncodedStringWithOptions:0];
    [provider acquireWithId:ident request:FSCreateRequest(creation,@[image]) reply:^(id remote,NSError *error){}];
    __block NSDictionary *fitted=nil;
    [provider snapshotWithId:ident reply:^(id snapshot,NSError *error){fitted=FSInspectSnapshot(snapshot);}];
    NSArray *fillOrigin=[filled[@"origin"] isKindOfClass:NSArray.class] ? filled[@"origin"] : @[];
    NSArray *fitOrigin=[fitted[@"origin"] isKindOfClass:NSArray.class] ? fitted[@"origin"] : @[];
    int fillSum=fillOrigin.count > 2 ? [fillOrigin[0] intValue] + [fillOrigin[1] intValue] + [fillOrigin[2] intValue] : 0;
    int fitSum=fitOrigin.count > 2 ? [fitOrigin[0] intValue] + [fitOrigin[1] intValue] + [fitOrigin[2] intValue] : 0;
    BOOL fitDiffers=filled && fitted && ![filled[@"checksum"] isEqual:fitted[@"checksum"]] && fitSum < 30 && fillSum > 80;
    [provider invalidateWithId:ident reply:^(NSError *error){}];
    BOOL dimOK=bright.count > 2 && dark.count > 2 && [bright[2] intValue] > 100 && [dark[2] intValue] < [bright[2] intValue];
    BOOL playbackOK=powerPaused && hostPauseRetained && powerResumed && tunedAcquired && inTrim && moved && rate && suspendedHoldsMode && resumedSameMode && lockedStill && idleUsesLock && idleResumeStill && desktopPlays && sourceUntouched && dimOK && fitDiffers;
    results[@"playback"]=@{@"ok":@(playbackOK),@"powerPaused":@(powerPaused),@"hostPauseRetained":@(hostPauseRetained),@"powerResumed":@(powerResumed),@"acquired":@(tunedAcquired),@"inTrim":@(inTrim),@"moved":@(moved),@"rate":@(rate),@"times":times,@"suspendedHoldsMode":@(suspendedHoldsMode),@"resumedSameMode":@(resumedSameMode),@"lockedStill":@(lockedStill),@"idleUsesLock":@(idleUsesLock),@"idleResumeStill":@(idleResumeStill),@"desktopPlays":@(desktopPlays),@"sourceUntouched":@(sourceUntouched),@"dimming":@(dimOK),@"fit":@(fitDiffers),@"bright":bright ?: @[],@"dark":dark ?: @[],@"fillSum":@(fillSum),@"fitSum":@(fitSum)};
    creation[@"destination"]=[@{@"size":@[@96,@64],@"scaleFactor":@1,@"colorSpace":creation[@"destination"][@"colorSpace"]} mutableCopy];
    creation[@"presentationMode"]=@{@"default":@{}};
    creation[@"activityState"]=@{@"active":@{}};
    NSMutableDictionary *scenePlayback=[@{@"version":@1,@"kind":@"aurora",@"fit":@"fill",@"speed":@2,@"dimming":@0,@"modes":@{@"desktop":@"still",@"lockScreen":@"animated"}} mutableCopy];
    NSMutableArray *sceneSums=NSMutableArray.new;
    BOOL scenesDrawn=YES;
    for (NSString *scene in @[@"aurora",@"cosmos",@"ocean",@"ember"]) {
        scenePlayback[@"kind"]=scene;
        creation[@"configuration"]=[[NSJSONSerialization dataWithJSONObject:scenePlayback options:0 error:nil] base64EncodedStringWithOptions:0];
        __block BOOL sceneAcquired=NO;
        [provider acquireWithId:ident request:FSCreateRequest(creation,@[]) reply:^(id remote,NSError *error){sceneAcquired=remote!=nil && !error;}];
        FSSession *sceneSession=provider.sessions.allValues.firstObject;
        __block NSDictionary *sceneSnap=nil;
        [provider snapshotWithId:ident reply:^(id snapshot,NSError *error){sceneSnap=FSInspectSnapshot(snapshot);}];
        NSArray *origin=[sceneSnap[@"origin"] isKindOfClass:NSArray.class] ? sceneSnap[@"origin"] : @[];
        BOOL opaque=origin.count>3 && [origin[3] intValue]==255;
        BOOL colored=origin.count>2 && [origin[0] intValue]+[origin[1] intValue]+[origin[2] intValue]>0;
        if (!sceneAcquired || !opaque || !colored || sceneSession.renderer.scopedFileCount!=0 || !sceneSession.renderer.holdsStill) scenesDrawn=NO;
        if (sceneSnap[@"checksum"]) [sceneSums addObject:sceneSnap[@"checksum"]];
        [provider invalidateWithId:ident reply:^(NSError *error){}];
    }
    BOOL distinctScenes=sceneSums.count==4 && [NSSet setWithArray:sceneSums].count==4;
    creation[@"destination"][@"size"]=@[@3840,@2160];
    scenePlayback[@"kind"]=@"aurora";
    scenePlayback[@"modes"]=@{@"desktop":@"still",@"lockScreen":@"still"};
    creation[@"configuration"]=[[NSJSONSerialization dataWithJSONObject:scenePlayback options:0 error:nil] base64EncodedStringWithOptions:0];
    [provider acquireWithId:ident request:FSCreateRequest(creation,@[]) reply:^(id remote,NSError *error){}];
    FSSession *fullScene=provider.sessions.allValues.firstObject;
    __block NSDictionary *fullSceneSnap=nil;
    [provider snapshotWithId:ident reply:^(id snapshot,NSError *error){fullSceneSnap=FSInspectSnapshot(snapshot);}];
    NSArray *fullOrigin=[fullSceneSnap[@"origin"] isKindOfClass:NSArray.class] ? fullSceneSnap[@"origin"] : @[];
    BOOL sceneFullFrame=fullScene && [fullSceneSnap[@"width"] integerValue]==3840 &&
        [fullSceneSnap[@"height"] integerValue]==2160 && fullScene.root.frame.size.width==3840 &&
        fullScene.root.frame.size.height==2160 && fullOrigin.count>3 && [fullOrigin[3] intValue]==255 &&
        [fullOrigin[0] intValue]+[fullOrigin[1] intValue]+[fullOrigin[2] intValue]>0;
    [provider invalidateWithId:ident reply:^(NSError *error){}];
    creation[@"destination"][@"size"]=@[@96,@64];
    scenePlayback[@"modes"]=@{@"desktop":@"still",@"lockScreen":@"animated"};
    NSNumber *plainAurora=sceneSums.firstObject;
    scenePlayback[@"kind"]=@"aurora";
    scenePlayback[@"dimming"]=@0.8;
    creation[@"configuration"]=[[NSJSONSerialization dataWithJSONObject:scenePlayback options:0 error:nil] base64EncodedStringWithOptions:0];
    [provider acquireWithId:ident request:FSCreateRequest(creation,@[]) reply:^(id remote,NSError *error){}];
    __block NSNumber *dimAurora=nil;
    [provider snapshotWithId:ident reply:^(id snapshot,NSError *error){dimAurora=FSInspectSnapshot(snapshot)[@"checksum"];}];
    [provider invalidateWithId:ident reply:^(NSError *error){}];
    BOOL sceneDimmed=plainAurora && dimAurora && ![plainAurora isEqual:dimAurora];
    scenePlayback[@"kind"]=@"aurora";
    scenePlayback[@"dimming"]=@0;
    scenePlayback[@"modes"]=@{@"desktop":@"animated",@"lockScreen":@"still"};
    creation[@"configuration"]=[[NSJSONSerialization dataWithJSONObject:scenePlayback options:0 error:nil] base64EncodedStringWithOptions:0];
    __block BOOL scenePlaying=NO;
    [provider acquireWithId:ident request:FSCreateRequest(creation,@[]) reply:^(id remote,NSError *error){scenePlaying=remote!=nil && !error;}];
    FSSession *playing=provider.sessions.allValues.firstObject;
    __block NSNumber *sceneBefore=nil;
    [provider snapshotWithId:ident reply:^(id snapshot,NSError *error){sceneBefore=FSInspectSnapshot(snapshot)[@"checksum"];}];
    FSPump(0.55);
    __block NSNumber *sceneAfter=nil;
    [provider snapshotWithId:ident reply:^(id snapshot,NSError *error){sceneAfter=FSInspectSnapshot(snapshot)[@"checksum"];}];
    BOOL sceneMotion=scenePlaying && playing.renderer.frameCount>2 && playing.renderer.playbackRate>1 && sceneBefore && ![sceneBefore isEqual:sceneAfter];
    NSMutableDictionary *sceneUpdate=[creation mutableCopy];
    [sceneUpdate removeObjectForKey:@"configuration"]; [sceneUpdate removeObjectForKey:@"isPreview"];
    sceneUpdate[@"activityState"]=@{@"suspended":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",sceneUpdate) reply:^(NSError *error){}];
    NSUInteger suspendedFrames=playing.renderer.frameCount;
    __block NSNumber *heldScene=nil;
    [provider snapshotWithId:ident reply:^(id snapshot,NSError *error){heldScene=FSInspectSnapshot(snapshot)[@"checksum"];}];
    FSPump(0.3);
    __block NSNumber *heldSceneAfter=nil;
    [provider snapshotWithId:ident reply:^(id snapshot,NSError *error){heldSceneAfter=FSInspectSnapshot(snapshot)[@"checksum"];}];
    BOOL sceneSuspended=!playing.renderer.holdsStill && playing.renderer.playbackRate==0 && playing.renderer.frameCount==suspendedFrames && [heldScene isEqual:heldSceneAfter];
    sceneUpdate[@"activityState"]=@{@"active":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",sceneUpdate) reply:^(NSError *error){}];
    FSPump(0.35);
    BOOL sceneResumed=!playing.renderer.holdsStill && playing.renderer.playbackRate>1 && playing.renderer.frameCount>suspendedFrames;
    sceneUpdate[@"presentationMode"]=@{@"locked":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",sceneUpdate) reply:^(NSError *error){}];
    NSUInteger lockFrames=playing.renderer.frameCount;
    FSPump(0.3);
    BOOL sceneLockStill=playing.renderer.holdsStill && playing.renderer.playbackRate==0 && playing.renderer.frameCount==lockFrames;
    sceneUpdate[@"presentationMode"]=@{@"idle":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",sceneUpdate) reply:^(NSError *error){}];
    FSPump(0.3);
    BOOL sceneIdleStill=playing.renderer.holdsStill && playing.renderer.playbackRate==0 && playing.renderer.frameCount==lockFrames;
    sceneUpdate[@"activityState"]=@{@"suspended":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",sceneUpdate) reply:^(NSError *error){}];
    sceneUpdate[@"activityState"]=@{@"active":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",sceneUpdate) reply:^(NSError *error){}];
    FSPump(0.3);
    BOOL sceneIdleResumeStill=playing.renderer.holdsStill && playing.renderer.playbackRate==0 && playing.renderer.frameCount==lockFrames;
    sceneUpdate[@"presentationMode"]=@{@"default":@{}};
    [provider updateWithId:ident request:FSBox(@"WallpaperUpdateRequestXPC",@"WallpaperUpdateRequest",sceneUpdate) reply:^(NSError *error){}];
    FSPump(0.3);
    BOOL sceneDesktopResumed=!playing.renderer.holdsStill && playing.renderer.playbackRate>1 && playing.renderer.frameCount>lockFrames;
    [provider invalidateWithId:ident reply:^(NSError *error){}];
    BOOL sceneOK=scenesDrawn && distinctScenes && sceneFullFrame && sceneDimmed && sceneMotion && sceneSuspended && sceneResumed && sceneLockStill && sceneIdleStill && sceneIdleResumeStill && sceneDesktopResumed;
    results[@"scene"]=@{@"ok":@(sceneOK),@"drawn":@(scenesDrawn),@"distinct":@(distinctScenes),@"fullFrame":@(sceneFullFrame),@"dimmed":@(sceneDimmed),@"motion":@(sceneMotion),@"suspended":@(sceneSuspended),@"resumed":@(sceneResumed),@"lockStill":@(sceneLockStill),@"idleStill":@(sceneIdleStill),@"idleResumeStill":@(sceneIdleResumeStill),@"desktopResumed":@(sceneDesktopResumed),@"frames":@(playing.renderer.frameCount)};
    NSURL *catalogRoot=[dir URLByAppendingPathComponent:@"library" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:[catalogRoot URLByAppendingPathComponent:@"Media"] withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *catalogFile=[catalogRoot URLByAppendingPathComponent:@"catalog.json"];
    NSDictionary *catalogPolicy = @{@"pauseOnBattery":@NO, @"pauseOnLowPower":@YES, @"lowPowerThreshold":@30, @"pauseOnFullscreen":@NO};
    NSDictionary *catalog=@{@"version":@1,@"playbackPolicy":catalogPolicy,@"items":@[
        @{@"id":@"escape",@"title":@"Escape",@"kind":@"video",@"file":@"Media/../secret.mov",@"fit":@"fill"},
        @{@"id":@"plain",@"title":@"Plain",@"kind":@"image",@"file":@"Media/plain.png",@"fit":@"fill"},
        @{@"id":@"clip",@"title":@"Clip",@"kind":@"video",@"file":@"Media/clip.mov",@"fit":@"fit",@"speed":@1.5,@"dimming":@0.25,@"trimStart":@0.25,@"trimEnd":@0.75,@"still":@0.5,@"desktop":@"still",@"lockScreen":@"animated"},
        @{@"id":@"scene",@"title":@"Scene",@"kind":@"aurora",@"file":@"Media/scene.mov",@"fit":@"fill"},
        @{@"id":@"plugin",@"title":@"Plugin",@"kind":@"plugin",@"file":@"Media/plugin.mov",@"fit":@"fill"}
    ]};
    NSData *catalogData=[NSJSONSerialization dataWithJSONObject:catalog options:0 error:nil];
    [catalogData writeToURL:catalogFile atomically:YES];
    setenv("FLUA_CATALOG", catalogFile.path.UTF8String, 1);
    NSArray *listed=FSSettingsModel()[@"screenSaver"][@"groups"][0][@"items"];
    NSDictionary *clipItem=listed.count>4 ? listed[4] : @{};
    NSDictionary *descriptor=clipItem[@"choice"][@"id"][@"descriptor"];
    NSData *configData=[[NSData alloc] initWithBase64EncodedString:descriptor[@"configuration"] ?: @"" options:0];
    NSDictionary *config=configData.length ? [NSJSONSerialization JSONObjectWithData:configData options:0 error:nil] : nil;
    NSDictionary *sceneItem=listed.count>5 ? listed[5] : @{};
    NSDictionary *sceneDescriptor=sceneItem[@"choice"][@"id"][@"descriptor"];
    NSData *sceneData=[[NSData alloc] initWithBase64EncodedString:sceneDescriptor[@"configuration"] ?: @"" options:0];
    NSDictionary *listedSceneConfig=sceneData.length ? [NSJSONSerialization JSONObjectWithData:sceneData options:0 error:nil] : nil;
    NSDictionary *plainConfig=nil;
    if (listed.count > 3) {
        NSData *plainData=[[NSData alloc] initWithBase64EncodedString:listed[3][@"choice"][@"id"][@"descriptor"][@"configuration"] ?: @"" options:0];
        plainConfig=plainData.length ? [NSJSONSerialization JSONObjectWithData:plainData options:0 error:nil] : nil;
    }
    NSArray *trim=[config[@"trim"] isKindOfClass:NSArray.class] ? config[@"trim"] : nil;
    BOOL listedScene=[sceneItem[@"localizedName"] isEqual:@"Scene"] && [sceneDescriptor[@"files"] count]==0
        && [listedSceneConfig[@"kind"] isEqual:@"aurora"] && listedSceneConfig[@"fileIndex"]==nil
        && [listedSceneConfig[@"still"] doubleValue]==7 && [listedSceneConfig[@"modes"][@"desktop"] isEqual:@"animated"]
        && [sceneItem[@"contentBadge"][@"video"] isKindOfClass:NSDictionary.class];
    BOOL listedClip=listed.count==6 && [clipItem[@"localizedName"] isEqual:@"Clip"] && [descriptor[@"files"] count]==1 && listedScene
        && [config[@"kind"] isEqual:@"video"] && [config[@"fileIndex"] integerValue]==0 && ![config[@"source"] isEqual:@"bundle"]
        && fabs([config[@"speed"] doubleValue] - 1.5) < 0.001 && fabs([config[@"dimming"] doubleValue] - 0.25) < 0.001
        && [config[@"fit"] isEqual:@"fit"] && trim.count == 2 && [trim[0] doubleValue] == 0.25 && [trim[1] doubleValue] == 0.75
        && [config[@"still"] doubleValue] == 0.5 && [config[@"modes"][@"desktop"] isEqual:@"still"] && [config[@"modes"][@"lockScreen"] isEqual:@"animated"]
        && [plainConfig[@"speed"] doubleValue] == 1 && [plainConfig[@"dimming"] doubleValue] == 0 && plainConfig[@"trim"] == nil
        && [plainConfig[@"modes"][@"desktop"] isEqual:@"animated"] && [plainConfig[@"modes"][@"lockScreen"] isEqual:@"animated"]
        && [listed[1][@"contentBadge"][@"none"] isKindOfClass:NSDictionary.class]
        && [listed[2][@"contentBadge"][@"video"] isKindOfClass:NSDictionary.class]
        && [clipItem[@"contentBadge"][@"video"] isKindOfClass:NSDictionary.class];
    BOOL policyPublished = [config[@"playbackPolicy"] isEqual:catalogPolicy] && [FSActivePlaybackPolicy isEqual:catalogPolicy];
    NSMutableDictionary *foreign=[catalog mutableCopy];
    foreign[@"root"]=@"/tmp/not-the-library";
    [[NSJSONSerialization dataWithJSONObject:foreign options:0 error:nil] writeToURL:catalogFile atomically:YES];
    BOOL rejectedRoot=[FSSettingsModel()[@"desktop"][@"groups"][0][@"items"] count]==3;
    foreign[@"version"]=@2; foreign[@"root"]=catalogRoot.path;
    [[NSJSONSerialization dataWithJSONObject:foreign options:0 error:nil] writeToURL:catalogFile atomically:YES];
    BOOL rejectedVersion=[FSSettingsModel()[@"desktop"][@"groups"][0][@"items"] count]==3;
    BOOL policyRetained = [FSActivePlaybackPolicy isEqual:catalogPolicy];
    // A cached descriptor and host scope remain usable when the current catalog is incompatible or gone.
    BOOL cachedChoice = YES;
    creation[@"configuration"] = FSEncodeConfiguration(@{@"version":@1, @"kind":@"image", @"fileIndex":@0});
    for (int attempt = 0; attempt < 2; attempt++) {
        if (attempt == 1) [[NSFileManager defaultManager] removeItemAtURL:catalogFile error:nil];
        __block BOOL acquiredCached = NO;
        [provider acquireWithId:ident request:FSCreateRequest(creation, @[image]) reply:^(id remote, NSError *error) {
            acquiredCached = remote != nil && error == nil;
        }];
        cachedChoice = cachedChoice && acquiredCached && ((FSSession *)provider.sessions.allValues.firstObject).renderer.scopedFileCount == 1;
        [provider invalidateWithId:ident reply:^(NSError *error) {}];
    }
    recoveryOK = recoveryOK && cachedChoice;
    results[@"recovery"] = @{@"ok":@(recoveryOK), @"automaticMediaRecovery":@(automaticRecovery), @"activeVideoRecovery":@(activeVideoRecovery), @"cachedChoiceWithoutCatalog":@(cachedChoice), @"unsupportedConfigurationRejected":@(rejectedConfiguration)};
    unsetenv("FLUA_CATALOG");
    results[@"catalog"]=@{@"ok":@(listedClip && rejectedRoot && rejectedVersion && policyPublished && policyRetained),@"policyPublished":@(policyPublished),@"policyRetained":@(policyRetained),@"listedClip":@(listedClip),@"rejectedRoot":@(rejectedRoot),@"rejectedVersion":@(rejectedVersion)};
    results[@"systemActivationPerformed"]=@NO;
    results[@"sandboxAuthorizationVerified"]=@NO;
    NSData *json=[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");
    return recoveryOK && surfaceSwitchOK && alternateRecoveryOK && [results[@"image"][@"ok"] boolValue] && [results[@"video"][@"ok"] boolValue] && [results[@"playback"][@"ok"] boolValue] && [results[@"scene"][@"ok"] boolValue] && [results[@"catalog"][@"ok"] boolValue] ? 0:2;
} }
#endif
