#import "MediaRenderer.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>

@interface FSMediaRenderer ()
@property IOSurfaceRef surface;
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
@end
@implementation FSMediaRenderer
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
    NSString *kind = configuration[@"kind"] ?: @"gradient";
    if ([kind isEqual:@"gradient"]) {
        IOSurfaceLock(_surface,0,NULL);
        uint8_t *bytes=IOSurfaceGetBaseAddress(_surface); size_t stride=IOSurfaceGetBytesPerRow(_surface);
        for (NSUInteger y=0;y<height;y++) for (NSUInteger x=0;x<width;x++) {
            uint8_t *p=bytes+y*stride+x*4; p[0]=x*255/width;p[1]=y*255/height;p[2]=90;p[3]=255;
        }
        IOSurfaceUnlock(_surface,0,NULL);
        return self;
    }
    NSURL *url;
    if ([configuration[@"source"] isEqual:@"bundle"]) {
        // Only the two original bundled fixtures are accepted; arbitrary paths are never read from JSON.
        NSString *name = [kind isEqual:@"video"] ? @"FluaMotion.mov" : @"FluaStill.png";
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
    if ([kind isEqual:@"image"]) {
        CIImage *image=[CIImage imageWithContentsOfURL:url options:@{kCIImageApplyOrientationProperty:@YES}];
        if (!image) {
            if (error) *error=[NSError errorWithDomain:@"org.flua.media" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Cannot decode image"}];
            return nil;
        }
        [self drawImage:image];
    } else if ([kind isEqual:@"video"]) {
        AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:nil];
        AVAssetImageGenerator *first=[[AVAssetImageGenerator alloc] initWithAsset:asset];
        first.appliesPreferredTrackTransform=YES;
        CGImageRef preview=[first copyCGImageAtTime:kCMTimeZero actualTime:NULL error:error];
        if (!preview) return nil;
        [self drawImage:[CIImage imageWithCGImage:preview]];
        CGImageRelease(preview);
        AVPlayerItem *item=[AVPlayerItem playerItemWithAsset:asset];
        _videoOutput=[[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
            (NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}
        }];
        [item addOutput:_videoOutput];
        _player=AVQueuePlayer.new; _player.muted=YES;
        _looper=[AVPlayerLooper playerLooperWithPlayer:_player templateItem:item];
        __weak FSMediaRenderer *weakSelf=self;
        _timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
        dispatch_source_set_timer(_timer,dispatch_time(DISPATCH_TIME_NOW,0),NSEC_PER_SEC/30,NSEC_PER_SEC/300);
        dispatch_source_set_event_handler(_timer,^{ [weakSelf tick]; });
        dispatch_resume(_timer);
        [_player play];
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
    [_imageContext render:image toCVPixelBuffer:_targetBuffer];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _layer.contents=nil; _layer.contents=(__bridge id)_surface;
    [CATransaction commit]; [CATransaction flush];
    _frameCount++;
}
- (void)tick {
    if (_disposed || _suspended) return;
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
- (double)playbackTime { return _player ? CMTimeGetSeconds(_player.currentTime) : 0; }
- (void)setPlaybackSuspended:(BOOL)suspended {
    _suspended=suspended;
    if (suspended) [_player pause]; else [_player play];
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
}
@end
