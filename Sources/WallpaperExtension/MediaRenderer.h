#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
BOOL FSIsSceneKind(NSString *kind);
@interface FSMediaRenderer : NSObject
@property(readonly) IOSurfaceRef surface;
@property(readonly) CALayer *layer;
@property(readonly) NSUInteger frameCount;
@property(readonly) NSInteger loopCount;
@property(readonly) BOOL suspended;
@property(readonly) NSUInteger scopedFileCount;
@property(readonly) NSUInteger activeScopeCount;
@property(readonly) double playbackTime;
@property(readonly) float playbackRate;
@property(readonly) BOOL holdsStill;
@property(readonly) BOOL playbackFailed;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height configuration:(NSDictionary *)configuration
                 fileWrappers:(NSArray *)wrappers error:(NSError **)error;
- (void)setPresentation:(NSString *)presentation;
- (void)setPlaybackSuspended:(BOOL)suspended;
- (void)dispose;
@end
