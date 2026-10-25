#import "MediaRenderer.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

@interface FSImageTestFile : NSObject
@property NSURL *url;
@end
@implementation FSImageTestFile
@end

int main(void) {
    @autoreleasepool {
        NSFileManager *files = NSFileManager.defaultManager;
        NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        NSCAssert([files createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:NULL], @"Create fixture directory");
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef canvas = CGBitmapContextCreate(NULL, 16, 16, 8, 64, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(space);
        CGContextSetRGBFillColor(canvas, 1, 0, 0, 1);
        CGContextFillRect(canvas, CGRectMake(0, 0, 16, 16));
        CGImageRef image = CGBitmapContextCreateImage(canvas);
        NSArray *extensions = @[@"png", @"jpg", @"tiff", @"svg"];
        NSArray *types = @[@"public.png", @"public.jpeg", @"public.tiff"];
        for (NSUInteger i = 0; i < extensions.count; i++) {
            NSURL *url = [root URLByAppendingPathComponent:[@"image." stringByAppendingString:extensions[i]]];
            if (i < types.count) {
                CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)types[i], 1, NULL);
                NSCAssert(destination, @"Create raster fixture");
                CGImageDestinationAddImage(destination, image, NULL);
                NSCAssert(CGImageDestinationFinalize(destination), @"Write raster fixture");
                CFRelease(destination);
            } else {
                NSString *svg = @"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\"><rect width=\"16\" height=\"16\" fill=\"red\"/></svg>";
                NSCAssert([svg writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL], @"Write SVG fixture");
            }
            NSData *original = [NSData dataWithContentsOfURL:url];
            FSImageTestFile *wrapper = FSImageTestFile.new;
            wrapper.url = url;
            NSError *error;
            FSMediaRenderer *renderer = [[FSMediaRenderer alloc] initWithWidth:16 height:16
                configuration:@{@"kind":@"image", @"fileIndex":@0} fileWrappers:@[wrapper] error:&error];
            if (i < types.count) {
                NSCAssert(renderer && !error && renderer.frameCount > 0, @"Render supported raster %@: %@", extensions[i], error);
                IOSurfaceLock(renderer.surface, kIOSurfaceLockReadOnly, NULL);
                const uint8_t *pixel = IOSurfaceGetBaseAddress(renderer.surface);
                NSCAssert(pixel[2] > 200 && pixel[1] < 30 && pixel[0] < 30 && pixel[3] == 255, @"Raster must render red pixels");
                IOSurfaceUnlock(renderer.surface, kIOSurfaceLockReadOnly, NULL);
                [renderer dispose];
            } else {
                NSCAssert(!renderer && error.code == 3, @"Provider must reject unsupported SVG");
            }
            NSCAssert([[NSData dataWithContentsOfURL:url] isEqualToData:original], @"Provider changed source bytes");
        }
        CGImageRelease(image);
        CGContextRelease(canvas);
        NSCAssert([files removeItemAtURL:root error:NULL], @"Remove fixtures");
        puts("PASS: provider image decoder rejects SVG and renders PNG/JPEG/TIFF without changing source bytes");
    }
    return 0;
}
