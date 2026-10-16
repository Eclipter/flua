#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
static void Fill(CVPixelBufferRef pixels, int frame) {
    CVPixelBufferLockBaseAddress(pixels,0);
    size_t w=CVPixelBufferGetWidth(pixels),h=CVPixelBufferGetHeight(pixels),stride=CVPixelBufferGetBytesPerRow(pixels);
    uint8_t *data=CVPixelBufferGetBaseAddress(pixels);
    for(size_t y=0;y<h;y++) for(size_t x=0;x<w;x++) {
        uint8_t *p=data+y*stride+x*4;
        p[0]=(x*255/w+frame*17)%256; p[1]=(y*255/h+frame*9)%256;
        p[2]=((x+frame*3)%w<w/3)?230:35; p[3]=255;
    }
    CVPixelBufferUnlockBaseAddress(pixels,0);
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2) return 1;
    NSURL *dir=[NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
    NSURL *movie=[dir URLByAppendingPathComponent:@"FluaMotion.mov"];
    [[NSFileManager defaultManager] removeItemAtURL:movie error:nil];
    NSError *error;
    AVAssetWriter *writer=[[AVAssetWriter alloc] initWithURL:movie fileType:AVFileTypeQuickTimeMovie error:&error];
    AVAssetWriterInput *input=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey:AVVideoCodecTypeH264,AVVideoWidthKey:@96,AVVideoHeightKey:@64
    }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor=[AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:@{
        (NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey:@96,(NSString *)kCVPixelBufferHeightKey:@64,
        (NSString *)kCVPixelBufferCGImageCompatibilityKey:@YES,(NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES
    }];
    [writer addInput:input]; if(![writer startWriting]) { NSLog(@"%@",writer.error);return 2; }
    [writer startSessionAtSourceTime:kCMTimeZero];
    for(int frame=0;frame<30;frame++) {
        while(!input.readyForMoreMediaData) [NSThread sleepForTimeInterval:0.002];
        CVPixelBufferRef pixels; CVPixelBufferPoolCreatePixelBuffer(NULL,adaptor.pixelBufferPool,&pixels);
        Fill(pixels,frame);
        if(frame==0) {
            CIImage *image=[CIImage imageWithCVPixelBuffer:pixels];
            CGImageRef cg=[[CIContext context] createCGImage:image fromRect:image.extent];
            CGImageDestinationRef output=CGImageDestinationCreateWithURL((__bridge CFURLRef)[dir URLByAppendingPathComponent:@"FluaStill.png"],(__bridge CFStringRef)UTTypePNG.identifier,1,NULL);
            CGImageDestinationAddImage(output,cg,NULL); CGImageDestinationFinalize(output); CFRelease(output);CGImageRelease(cg);
        }
        BOOL ok=[adaptor appendPixelBuffer:pixels withPresentationTime:CMTimeMake(frame,15)]; CVPixelBufferRelease(pixels);
        if(!ok) { NSLog(@"%@",writer.error);return 3; }
    }
    [input markAsFinished];dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{dispatch_semaphore_signal(done);}];
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))) return 4;
    return writer.status==AVAssetWriterStatusCompleted?0:5;
} }
