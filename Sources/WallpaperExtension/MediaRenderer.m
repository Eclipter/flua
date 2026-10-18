#import "MediaRenderer.h"
#import <float.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>

@interface FSMediaRenderer ()
@property IOSurfaceRef surface;
@property IOSurfaceRef backSurface;
@property CVPixelBufferRef targetBuffer;
@property CALayer *layer;
@property CIContext *imageContext;
@property AVQueuePlayer *player;
@property AVPlayerLooper *looper;
@property AVPlayerItemVideoOutput *videoOutput;
@property dispatch_source_t timer;
@property NSArray *fileWrappers;
@property NSArray<NSURL *> *accessedURLs;
@property NSUInteger frameCount;
@property BOOL suspended;
@property BOOL disposed;
@property NSString *fit;
@property NSString *kind;
@property NSString *desktopMode;
@property NSString *lockMode;
@property(nonatomic) NSString *presentation;
@property CIImage *sourceImage;
@property AVURLAsset *asset;
@property double speed;
@property double dimming;
@property double trimStart;
@property double trimEnd;
@property double stillTime;
@property double sceneTime;
@property CFTimeInterval sceneTick;
@property BOOL hasTrim;
@property BOOL holdsStill;
@property BOOL reportedPlaybackFailure;
@end
BOOL FSIsSceneKind(NSString *kind) {
    return [kind isEqual:@"aurora"] || [kind isEqual:@"cosmos"] || [kind isEqual:@"ocean"] || [kind isEqual:@"ember"];
}
static double FSClamped(id value, double fallback, double lo, double hi) {
    if (![value isKindOfClass:NSNumber.class]) return fallback;
    double number = [(NSNumber *)value doubleValue];
    if (!isfinite(number)) return fallback;
    return MIN(MAX(number, lo), hi);
}
@implementation FSMediaRenderer {
    CGContextRef _sceneCanvas;
}
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height configuration:(NSDictionary *)configuration
                 fileWrappers:(NSArray *)wrappers error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _fileWrappers = [wrappers copy]; // Retain the framework's scope-bearing wrappers for the whole session.
    NSMutableArray *leases = NSMutableArray.new;
    NSMutableArray *urls = NSMutableArray.new;
    for (id wrapper in wrappers) {
        if (![wrapper respondsToSelector:NSSelectorFromString(@"url")]) continue;
        NSURL *url = ((id (*)(id, SEL))objc_msgSend)(wrapper, NSSelectorFromString(@"url"));
        if (![url isKindOfClass:NSURL.class] || !url.isFileURL) continue;
        [urls addObject:url];
        if ([url startAccessingSecurityScopedResource]) [leases addObject:url];
    }
    _accessedURLs = leases;
    _fit = [configuration[@"fit"] isEqual:@"fit"] ? @"fit" : @"fill";
    _speed = FSClamped(configuration[@"speed"], 1, 0.25, 2);
    _dimming = FSClamped(configuration[@"dimming"], 0, 0, 0.85);
    NSArray *trim = configuration[@"trim"];
    if ([trim isKindOfClass:NSArray.class] && trim.count >= 2 && [trim[0] isKindOfClass:NSNumber.class] && [trim[1] isKindOfClass:NSNumber.class]) {
        double start = [trim[0] doubleValue], end = [trim[1] doubleValue];
        if (isfinite(start) && isfinite(end) && start >= 0 && end > start) {
            _hasTrim = YES; _trimStart = start; _trimEnd = end;
        }
    }
    if ([configuration[@"still"] isKindOfClass:NSNumber.class]) _stillTime = FSClamped(configuration[@"still"], 0, 0, DBL_MAX);
    else _stillTime = _hasTrim ? _trimStart : 0;
    if (_hasTrim) _stillTime = MIN(MAX(_stillTime, _trimStart), MAX(_trimStart, _trimEnd - 1.0 / 600));
    NSDictionary *modes = [configuration[@"modes"] isKindOfClass:NSDictionary.class] ? configuration[@"modes"] : @{};
    _desktopMode = [modes[@"desktop"] isEqual:@"still"] ? @"still" : @"animated";
    _lockMode = [modes[@"lockScreen"] isEqual:@"still"] ? @"still" : @"animated";
    NSString *presentation = configuration[@"presentation"];
    _presentation = [presentation isEqual:@"locked"] || [presentation isEqual:@"idle"] ? presentation : @"default";
    _kind = configuration[@"kind"] ?: @"gradient";
    _surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kIOSurfaceWidth:@(width), (__bridge NSString *)kIOSurfaceHeight:@(height),
        (__bridge NSString *)kIOSurfaceBytesPerElement:@4, (__bridge NSString *)kIOSurfacePixelFormat:@(kCVPixelFormatType_32BGRA)
    });
    if (!_surface || CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, _surface, NULL, &_targetBuffer) != kCVReturnSuccess) {
        if (error) *error = [NSError errorWithDomain:@"org.flua.media" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Cannot allocate destination surface"}];
        return nil;
    }
    _imageContext = [CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
    _layer = CALayer.layer;
    _layer.frame = CGRectMake(0,0,width,height);
    _layer.contents = (__bridge id)_surface;
    if (FSIsSceneKind(_kind) && ![configuration[@"still"] isKindOfClass:NSNumber.class]) _stillTime = 7;
    if ([_kind isEqual:@"gradient"]) {
        IOSurfaceLock(_surface,0,NULL);
        uint8_t *bytes=IOSurfaceGetBaseAddress(_surface); size_t stride=IOSurfaceGetBytesPerRow(_surface);
        for (NSUInteger y=0;y<height;y++) for (NSUInteger x=0;x<width;x++) {
            uint8_t *p=bytes+y*stride+x*4; p[0]=x*255/width;p[1]=y*255/height;p[2]=90;p[3]=255;
        }
        IOSurfaceUnlock(_surface,0,NULL);
        return self;
    }
    if (FSIsSceneKind(_kind)) {
        if (!NSClassFromString(@"FSSceneFrame")) {
            if (error) *error=[NSError errorWithDomain:@"org.flua.media" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Scene renderer unavailable"}];
            return nil;
        }
        [self applySurfaceMode:YES error:NULL];
        return self;
    }
    NSURL *url;
    if ([configuration[@"source"] isEqual:@"bundle"]) {
        // Only the two original bundled fixtures are accepted; arbitrary paths are never read from JSON.
        NSString *name = [_kind isEqual:@"video"] ? @"FluaMotion.mov" : @"FluaStill.png";
        url=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:name];
        if (![[NSFileManager defaultManager] fileExistsAtPath:url.path])
            url=[[NSBundle.mainBundle.executableURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:name];
    } else {
        NSInteger index=[configuration[@"fileIndex"] integerValue];
        if (index>=0 && index<(NSInteger)urls.count) url=urls[index];
    }
    if (!url || ![[NSFileManager defaultManager] isReadableFileAtPath:url.path]) {
        if (error) *error=[NSError errorWithDomain:@"org.flua.media" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Configuration requires an accessible scoped fileIndex or bundled fixture"}];
        return nil;
    }
    if ([_kind isEqual:@"image"]) {
        _sourceImage=[CIImage imageWithContentsOfURL:url options:@{kCIImageApplyOrientationProperty:@YES}];
        if (!_sourceImage) {
            if (error) *error=[NSError errorWithDomain:@"org.flua.media" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Cannot decode image"}];
            return nil;
        }
        [self applySurfaceMode:YES error:NULL];
    } else if ([_kind isEqual:@"video"]) {
        _asset=[AVURLAsset URLAssetWithURL:url options:nil];
        NSError *frameError;
        if (![self applySurfaceMode:YES error:&frameError]) {
            if (error) *error=frameError ?: [NSError errorWithDomain:@"org.flua.media" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Cannot decode video frame"}];
            return nil;
        }
    } else {
        if (error) *error=[NSError errorWithDomain:@"org.flua.media" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Unknown media kind"}];
        return nil;
    }
    return self;
}
- (void)drawImage:(CIImage *)image {
    CGRect input=image.extent;
    CGFloat width=IOSurfaceGetWidth(_surface),height=IOSurfaceGetHeight(_surface);
    if (CGRectIsEmpty(input) || !isfinite(input.size.width) || !isfinite(input.size.height)) return;
    CGFloat scale=[_fit isEqual:@"fit"] ? MIN(width/input.size.width,height/input.size.height) : MAX(width/input.size.width,height/input.size.height);
    image=[image imageByApplyingTransform:CGAffineTransformMakeTranslation(-input.origin.x,-input.origin.y)];
    image=[image imageByApplyingTransform:CGAffineTransformMakeScale(scale,scale)];
    image=[image imageByApplyingTransform:CGAffineTransformMakeTranslation((width-input.size.width*scale)/2,(height-input.size.height*scale)/2)];
    CIImage *black=[[CIImage imageWithColor:CIColor.blackColor] imageByCroppingToRect:CGRectMake(0,0,width,height)];
    image=[[image imageByCompositingOverImage:black] imageByCroppingToRect:black.extent];
    if (_dimming > 0) {
        CGFloat keep = 1 - _dimming;
        image = [image imageByApplyingFilter:@"CIColorMatrix" withInputParameters:@{
            @"inputRVector": [CIVector vectorWithX:keep Y:0 Z:0 W:0],
            @"inputGVector": [CIVector vectorWithX:0 Y:keep Z:0 W:0],
            @"inputBVector": [CIVector vectorWithX:0 Y:0 Z:keep W:0],
            @"inputAVector": [CIVector vectorWithX:0 Y:0 Z:0 W:1],
            @"inputBiasVector": [CIVector vectorWithX:0 Y:0 Z:0 W:0]
        }];
    }
    [_imageContext render:image toCVPixelBuffer:_targetBuffer];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _layer.contents=nil; _layer.contents=(__bridge id)_surface;
    [CATransaction commit]; [CATransaction flush];
    _frameCount++;
    if (_frameCount == 2 || _frameCount == 90)
        NSLog(@"Flua frames=%lu loops=%ld time=%.3f scopedFiles=%lu activeScopes=%lu",
              (unsigned long)_frameCount, (long)self.loopCount, self.playbackTime,
              (unsigned long)self.scopedFileCount, (unsigned long)self.activeScopeCount);
}
- (BOOL)surfaceModeIsStill {
    // shortcut: idle uses the Lock Screen mode, split it when the host requires its own.
    BOOL lock = [_presentation isEqual:@"locked"] || [_presentation isEqual:@"idle"];
    return [(lock ? _lockMode : _desktopMode) isEqual:@"still"];
}
- (BOOL)drawVideoFrameAtTime:(double)seconds error:(NSError **)error {
    AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:_asset];
    generator.appliesPreferredTrackTransform = YES;
    NSError *local = nil;
    CGImageRef preview = [generator copyCGImageAtTime:CMTimeMakeWithSeconds(seconds, 600) actualTime:NULL error:&local];
    if (!preview) {
        if (error) *error = local ?: [NSError errorWithDomain:@"org.flua.media" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Cannot decode video frame"}];
        return NO;
    }
    [self drawImage:[CIImage imageWithCGImage:preview]];
    CGImageRelease(preview);
    return YES;
}
- (void)ensureVideoPlayer {
    if (_player) return;
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:_asset];
    _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    }];
    [item addOutput:_videoOutput];
    _player = AVQueuePlayer.new;
    _player.muted = YES;
    if (_hasTrim) {
        CMTime start = CMTimeMakeWithSeconds(_trimStart, 600);
        CMTime end = CMTimeMakeWithSeconds(_trimEnd, 600);
        _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:item timeRange:CMTimeRangeFromTimeToTime(start, end)];
    } else {
        _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:item];
    }
    __weak FSMediaRenderer *weakSelf = self;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / 30, NSEC_PER_SEC / 300);
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
    dispatch_resume(_timer);
}
- (BOOL)applySurfaceMode:(BOOL)force error:(NSError **)error {
    BOOL still = [self surfaceModeIsStill];
    if (!force && still == _holdsStill) return YES;
    _holdsStill = still;
    if (FSIsSceneKind(_kind)) {
        if (still) {
            [self stopSceneClock];
            [self drawSceneAtTime:_stillTime];
        } else {
            _sceneTick = CACurrentMediaTime();
            [self drawSceneAtTime:_sceneTime];
            if (!_suspended) [self startSceneClock];
        }
        return YES;
    }
    if ([_kind isEqual:@"image"]) {
        if (_sourceImage) [self drawImage:_sourceImage];
        return _sourceImage != nil;
    }
    if (![_kind isEqual:@"video"]) return YES;
    if (still) {
        [_player pause];
        return [self drawVideoFrameAtTime:_stillTime error:error];
    }
    [self ensureVideoPlayer];
    if (force && ![self drawVideoFrameAtTime:(_hasTrim ? _trimStart : 0) error:error]) return NO;
    if (!_suspended) [_player playImmediatelyAtRate:_speed];
    return YES;
}
- (void)setPresentation:(NSString *)presentation {
    NSString *next = [presentation isEqual:@"locked"] || [presentation isEqual:@"idle"] ? presentation : @"default";
    if ([next isEqual:_presentation]) return;
    _presentation = next;
    [self applySurfaceMode:NO error:NULL];
}
- (BOOL)playbackFailed {
    return _player.status == AVPlayerStatusFailed || _player.currentItem.status == AVPlayerItemStatusFailed ||
        _looper.status == AVPlayerLooperStatusFailed;
}
- (void)tick {
    if (_disposed || _suspended || _holdsStill) return;
    if (_player.currentItem.status == AVPlayerItemStatusReadyToPlay && fabs(_player.rate - _speed) > 0.05)
        _player.rate = _speed;
    if (!_reportedPlaybackFailure && _player.currentItem.status == AVPlayerItemStatusFailed) {
        _reportedPlaybackFailure = YES;
        NSError *error = _player.currentItem.error;
        NSLog(@"Flua playback failed: %@ (%ld)", error.domain, (long)error.code);
    }
    // AVPlayerLooper does not preserve template output attachments on every clone.
    // Attach an independent output to each item as it becomes current.
    AVPlayerItemVideoOutput *output;
    for (AVPlayerItemOutput *candidate in _player.currentItem.outputs)
        if ([candidate isKindOfClass:AVPlayerItemVideoOutput.class]) { output=(id)candidate; break; }
    if (!output && _player.currentItem) {
        output=[[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
            (NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}
        }];
        [_player.currentItem addOutput:output];
        _videoOutput=output;
        return;
    }
    if (!output) return;
    CMTime time=[output itemTimeForHostTime:CACurrentMediaTime()];
    if (![output hasNewPixelBufferForItemTime:time]) return;
    CVPixelBufferRef pixels=[output copyPixelBufferForItemTime:time itemTimeForDisplay:NULL];
    if (!pixels) return;
    CIImage *image=[CIImage imageWithCVPixelBuffer:pixels];
    // Honor track orientation for portrait/custom files as the static preview does.
    AVAssetTrack *track=[_player.currentItem.asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (track) image=[image imageByApplyingTransform:track.preferredTransform];
    [self drawImage:image]; CVPixelBufferRelease(pixels);
}
- (NSUInteger)scopedFileCount { return _fileWrappers.count; }
- (NSUInteger)activeScopeCount { return _accessedURLs.count; }
- (NSInteger)loopCount { return _looper.loopCount; }
- (double)playbackTime {
    if (FSIsSceneKind(_kind)) return _sceneTime;
    return _player ? CMTimeGetSeconds(_player.currentTime) : 0;
}
- (float)playbackRate {
    if (_holdsStill || _suspended) return 0;
    if (FSIsSceneKind(_kind)) return (float)_speed;
    if (!_player) return 0;
    return _player.rate;
}
- (void)setPlaybackSuspended:(BOOL)suspended {
    if (FSIsSceneKind(_kind)) {
        _suspended = suspended;
        if (_holdsStill || suspended) [self stopSceneClock];
        else { _sceneTick = CACurrentMediaTime(); [self startSceneClock]; }
        return;
    }
    _suspended=suspended;
    if (_holdsStill || suspended) [_player pause];
    else [_player playImmediatelyAtRate:_speed];
}
- (void)startSceneClock {
    if (_timer || _disposed) return;
    _sceneTick = CACurrentMediaTime();
    __weak FSMediaRenderer *weakSelf = self;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / 24, NSEC_PER_SEC / 300);
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tickScene]; });
    dispatch_resume(_timer);
}
- (void)stopSceneClock {
    if (!_timer) return;
    dispatch_source_cancel(_timer);
    _timer = nil;
}
- (void)tickScene {
    if (_disposed || _suspended || _holdsStill) return;
    double now = CACurrentMediaTime();
    double delta = MIN(MAX(now - _sceneTick, 0), 0.1);
    _sceneTick = now;
    _sceneTime += delta * _speed;
    [self drawSceneAtTime:_sceneTime];
}
- (void)drawSceneAtTime:(double)time {
    size_t width = IOSurfaceGetWidth(_surface), height = IOSurfaceGetHeight(_surface);
    Class sceneClass = NSClassFromString(@"FSSceneFrame");
    if (!width || !height || !sceneClass) return;
    // Full-size in-place drawing tears and misses 24 fps on Retina; draw at the desktop cap, then copy onto an unpublished surface.
    // shortcut: two surfaces; add a third if a host snapshot is still visible when its surface is reused.
    double scale = MIN(1, 1280.0 / MAX((double)width, (double)height));
    size_t canvasWidth = MAX(1, (size_t)ceil(width * scale));
    size_t canvasHeight = MAX(1, (size_t)ceil(height * scale));
    if (!_sceneCanvas || (size_t)CGBitmapContextGetWidth(_sceneCanvas) != canvasWidth || (size_t)CGBitmapContextGetHeight(_sceneCanvas) != canvasHeight) {
        CGContextRelease(_sceneCanvas);
        CGColorSpaceRef canvasSpace = CGColorSpaceCreateDeviceRGB();
        _sceneCanvas = CGBitmapContextCreate(NULL, canvasWidth, canvasHeight, 8, 0, canvasSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(canvasSpace);
    }
    if (!_sceneCanvas) return;
    ((void (*)(id, SEL, id, double, double, CGContextRef, NSInteger, NSInteger))objc_msgSend)(
        sceneClass, @selector(drawScene:time:dimming:context:width:height:),
        _kind, time, _dimming, _sceneCanvas, (NSInteger)canvasWidth, (NSInteger)canvasHeight);
    if (!_backSurface) {
        _backSurface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
            (__bridge NSString *)kIOSurfaceWidth:@(width), (__bridge NSString *)kIOSurfaceHeight:@(height),
            (__bridge NSString *)kIOSurfaceBytesPerElement:@4, (__bridge NSString *)kIOSurfacePixelFormat:@(kCVPixelFormatType_32BGRA)
        });
        if (!_backSurface) return;
    }
    IOSurfaceRef frame = _backSurface;
    IOSurfaceLock(frame, 0, NULL);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef dest = CGBitmapContextCreate(IOSurfaceGetBaseAddress(frame), width, height, 8,
        IOSurfaceGetBytesPerRow(frame), space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGImageRef picture = CGBitmapContextCreateImage(_sceneCanvas);
    BOOL drew = dest && picture;
    if (drew) {
        CGContextSetInterpolationQuality(dest, kCGInterpolationHigh);
        CGContextDrawImage(dest, CGRectMake(0, 0, width, height), picture);
    }
    CGImageRelease(picture);
    CGContextRelease(dest);
    CGColorSpaceRelease(space);
    IOSurfaceUnlock(frame, 0, NULL);
    if (!drew) return;
    _backSurface = _surface;
    _surface = frame;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _layer.contents = (__bridge id)_surface;
    [CATransaction commit]; [CATransaction flush];
    _frameCount++;
    if (_frameCount == 2 || _frameCount == 90)
        NSLog(@"Flua frames=%lu loops=%ld time=%.3f scopedFiles=%lu activeScopes=%lu",
              (unsigned long)_frameCount, (long)self.loopCount, self.playbackTime,
              (unsigned long)self.scopedFileCount, (unsigned long)self.activeScopeCount);
}
- (void)dispose {
    if (_disposed) return;
    _disposed=YES;
    if (_timer) { dispatch_source_cancel(_timer); _timer=nil; }
    [_player pause]; [_looper disableLooping]; [_player removeAllItems];
    _player=nil; _looper=nil; _videoOutput=nil;
    for (NSURL *url in _accessedURLs) [url stopAccessingSecurityScopedResource];
    _accessedURLs=@[]; _fileWrappers=@[];
}
- (void)dealloc {
    [self dispose];
    if (_targetBuffer) CVPixelBufferRelease(_targetBuffer);
    if (_surface) CFRelease(_surface);
    if (_backSurface) CFRelease(_backSurface);
    CGContextRelease(_sceneCanvas);
}
@end
