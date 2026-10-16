#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
@interface FSMediaRenderer : NSObject
@property(readonly) IOSurfaceRef surface;
@property(readonly) CALayer *layer;
@property(readonly) NSUInteger frameCount;
@property(readonly) NSInteger loopCount;
@property(readonly) BOOL suspended;
@property(readonly) NSUInteger scopedFileCount;
@property(readonly) NSUInteger activeScopeCount;
@property(readonly) double playbackTime;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height configuration:(NSDictionary *)configuration
                 fileWrappers:(NSArray *)wrappers error:(NSError **)error;
- (void)setPlaybackSuspended:(BOOL)suspended;
- (void)dispose;
@end
