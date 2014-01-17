//
//  SRScreenRecorder.m
//  ScreenRecorder
//
//  Created by kishikawa katsumi on 2012/12/26.
//  Copyright (c) 2012年 kishikawa katsumi. All rights reserved.
//

#import <sys/xattr.h>
#import "SRScreenRecorder.h"
#import "KTouchPointerWindow.h"

#ifndef APPSTORE_SAFE
#if DEBUG
#define APPSTORE_SAFE 0
#else
#define APPSTORE_SAFE 1
#endif
#endif

#define DEFAULT_FRAME_INTERVAL 2
#define DEFAULT_AUTOSAVE_DURATION 600
#define TIME_SCALE 600

static NSInteger counter;

#if !APPSTORE_SAFE
CGImageRef UICreateCGImageFromIOSurface(CFTypeRef surface);
CVReturn CVPixelBufferCreateWithIOSurface(
                                          CFAllocatorRef allocator,
                                          CFTypeRef surface,
                                          CFDictionaryRef pixelBufferAttributes,
                                          CVPixelBufferRef *pixelBufferOut);
@interface UIWindow (ScreenRecorder)
+ (CFTypeRef)createScreenIOSurface;
@end

@interface UIScreen (ScreenRecorder)
- (CGRect)_boundsInPixels;
@end
#endif

@interface SRScreenRecorder ()

@property (strong, nonatomic) AVAssetWriter *writer;
@property (strong, nonatomic) AVAssetWriterInput *writerInput;
@property (strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *writerInputPixelBufferAdaptor;
@property (strong, nonatomic) CADisplayLink *displayLink;

@end

@implementation SRScreenRecorder {
	CFAbsoluteTime firstFrameTime;
    CFTimeInterval startTimestamp;
    BOOL shouldRestart;
    
    dispatch_queue_t queue;
    UIBackgroundTaskIdentifier backgroundTask;
}

+ (SRScreenRecorder *)sharedInstance
{
    static SRScreenRecorder *sharedInstance = nil;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        sharedInstance = [[SRScreenRecorder alloc] init];
    });
    return sharedInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        _frameInterval = DEFAULT_FRAME_INTERVAL;
        _autosaveDuration = DEFAULT_AUTOSAVE_DURATION;
        _showsTouchPointer = YES;
        
        counter++;
        NSString *label = [NSString stringWithFormat:@"com.kishikawakatsumi.screen_recorder-%d", counter];
        queue = dispatch_queue_create([label cStringUsingEncoding:NSUTF8StringEncoding], NULL);
        
        [self setupNotifications];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopRecordingWithCompletionHandler:^(NSURL *url) {
        ;
    }];
}

#pragma mark Setup

- (void)setupAssetWriterWithURL:(NSURL *)outputURL
{
    NSError *error = nil;
    
    self.writer = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeQuickTimeMovie error:&error];
    NSParameterAssert(self.writer);
    if (error) {
        NSLog(@"Error: %@", [error localizedDescription]);
    }
    
    UIScreen *mainScreen = [UIScreen mainScreen];
#if APPSTORE_SAFE
    CGSize size = mainScreen.bounds.size;
#else
    CGRect boundsInPixels = [mainScreen _boundsInPixels];
    CGSize size = boundsInPixels.size;
#endif
    
    NSDictionary *outputSettings = @{AVVideoCodecKey : AVVideoCodecH264, AVVideoWidthKey : @(size.width), AVVideoHeightKey : @(size.height)};
    self.writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:outputSettings];
	self.writerInput.expectsMediaDataInRealTime = YES;
    
    NSDictionary *sourcePixelBufferAttributes = @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32ARGB)};
    self.writerInputPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.writerInput
                                                                                                          sourcePixelBufferAttributes:sourcePixelBufferAttributes];
    NSParameterAssert(self.writerInput);
    NSParameterAssert([self.writer canAddInput:self.writerInput]);
    
    [self.writer addInput:self.writerInput];
    
	firstFrameTime = CFAbsoluteTimeGetCurrent();
    
    [self.writer startWriting];
    [self.writer startSessionAtSourceTime:kCMTimeZero];
}

- (void)setupTouchPointer
{
    if (self.showsTouchPointer) {
        KTouchPointerWindowInstall();
    } else {
        KTouchPointerWindowUninstall();
    }
}

- (void)setupNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (void)setupTimer
{
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(captureFrame:)];
    self.displayLink.frameInterval = self.frameInterval;
    [self.displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
}

#pragma mark Recording

- (void)startRecording
{
    [self setupAssetWriterWithURL:[self outputFileURL]];
    
    [self setupTouchPointer];
    
    [self setupTimer];
}

- (NSURL *)stopRecording
{
    __block NSURL *url = nil;
    __block BOOL finished = NO;
    
    [self stopRecordingWithCompletionHandler:^(NSURL *saveUrl) {
        url = saveUrl;
        finished = YES;
    }];
    
    while (!finished) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    }
    
    return url;
}

- (void)stopRecordingWithCompletionHandler:(void (^)(NSURL *saveUrl))completionHandler
{
    [self.displayLink invalidate];
    startTimestamp = 0.0;
    
    dispatch_async(queue, ^
                   {
                       NSURL *url = self.writer.outputURL;
                       if (self.writer.status != AVAssetWriterStatusCompleted && self.writer.status != AVAssetWriterStatusUnknown) {
                           [self.writerInput markAsFinished];
                       }
                       if ([self.writer respondsToSelector:@selector(finishWritingWithCompletionHandler:)]) {
                           [self.writer finishWritingWithCompletionHandler:^
                            {
                                [self finishBackgroundTask];
                                [self restartRecordingIfNeeded];
                                completionHandler(url);
                            }];
                       } else {
                           [self.writer finishWriting];
                           
                           [self finishBackgroundTask];
                           [self restartRecordingIfNeeded];
                           completionHandler(url);
                       }
                   });
    
    [self limitNumberOfFiles];
}

- (void)restartRecordingIfNeeded
{
    if (shouldRestart) {
        shouldRestart = NO;
        dispatch_async(queue, ^
                       {
                           dispatch_async(dispatch_get_main_queue(), ^
                                          {
                                              [self startRecording];
                                          });
                       });
    }
}

- (void)rotateFile
{
    shouldRestart = YES;
    dispatch_async(queue, ^
                   {
                       [self stopRecordingWithCompletionHandler:^(NSURL *url) {
                           ;
                       }];
                   });
}

- (void)captureFrame:(CADisplayLink *)displayLink
{
    dispatch_async(queue, ^
                   {
                       if (self.writerInput.readyForMoreMediaData) {
                           CVReturn status = kCVReturnSuccess;
                           CVPixelBufferRef buffer = NULL;
                           CFTypeRef backingData;
#if APPSTORE_SAFE || TARGET_IPHONE_SIMULATOR
                           __block UIImage *screenshot = nil;
                           dispatch_sync(dispatch_get_main_queue(), ^{
                               screenshot = [self screenshot];
                           });
                           CGImageRef image = screenshot.CGImage;
                           
                           CGDataProviderRef dataProvider = CGImageGetDataProvider(image);
                           CFDataRef data = CGDataProviderCopyData(dataProvider);
                           backingData = CFDataCreateMutableCopy(kCFAllocatorDefault, CFDataGetLength(data), data);
                           CFRelease(data);
                           
                           const UInt8 *bytePtr = CFDataGetBytePtr(backingData);
                           
                           status = CVPixelBufferCreateWithBytes(kCFAllocatorDefault,
                                                                 CGImageGetWidth(image),
                                                                 CGImageGetHeight(image),
                                                                 kCVPixelFormatType_32BGRA,
                                                                 (void *)bytePtr,
                                                                 CGImageGetBytesPerRow(image),
                                                                 NULL,
                                                                 NULL,
                                                                 NULL,
                                                                 &buffer);
                           NSParameterAssert(status == kCVReturnSuccess && buffer);
#else
                           CFTypeRef surface = [UIWindow createScreenIOSurface];
                           backingData = surface;
                           
                           NSDictionary *pixelBufferAttributes = @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
                           status = CVPixelBufferCreateWithIOSurface(NULL, surface, (__bridge CFDictionaryRef)(pixelBufferAttributes), &buffer);
                           NSParameterAssert(status == kCVReturnSuccess && buffer);
#endif
                           if (buffer) {
                               CFAbsoluteTime currentTime = CFAbsoluteTimeGetCurrent();
                               CFTimeInterval elapsedTime = currentTime - firstFrameTime;
                               
                               CMTime presentTime =  CMTimeMake(elapsedTime * TIME_SCALE, TIME_SCALE);
                               
                               if(![self.writerInputPixelBufferAdaptor appendPixelBuffer:buffer withPresentationTime:presentTime]) {
                                   [self stopRecordingWithCompletionHandler:^(NSURL *url) {
                                       ;
                                   }];
                               }
                               
                               CVPixelBufferRelease(buffer);
                           }
                           
                           CFRelease(backingData);
                       }
                   });
    
    if (startTimestamp == 0.0) {
        startTimestamp = displayLink.timestamp;
    }
    
    NSTimeInterval dalta = displayLink.timestamp - startTimestamp;
    
    if (self.autosaveDuration > 0 && dalta > self.autosaveDuration) {
        startTimestamp = 0.0;
        [self rotateFile];
    }
}

- (UIImage *)screenshot
{
    UIScreen *mainScreen = [UIScreen mainScreen];
    CGSize imageSize = mainScreen.bounds.size;
    if (UIGraphicsBeginImageContextWithOptions != NULL) {
        UIGraphicsBeginImageContextWithOptions(imageSize, NO, 0);
    } else {
        UIGraphicsBeginImageContext(imageSize);
    }
    
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    NSArray *windows = [[UIApplication sharedApplication] windows];
    for (UIWindow *window in windows) {
        if (![window respondsToSelector:@selector(screen)] || window.screen == mainScreen) {
            CGContextSaveGState(context);
            
            CGContextTranslateCTM(context, window.center.x, window.center.y);
            CGContextConcatCTM(context, [window transform]);
            CGContextTranslateCTM(context,
                                  -window.bounds.size.width * window.layer.anchorPoint.x,
                                  -window.bounds.size.height * window.layer.anchorPoint.y);
            
            [window.layer.presentationLayer renderInContext:context];
            
            CGContextRestoreGState(context);
        }
    }
    
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    
    UIGraphicsEndImageContext();
    
    return image;
}

#pragma mark Background tasks

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    UIApplication *application = [UIApplication sharedApplication];
    
    UIDevice *device = [UIDevice currentDevice];
    BOOL backgroundSupported = NO;
    if ([device respondsToSelector:@selector(isMultitaskingSupported)]) {
        backgroundSupported = device.multitaskingSupported;
    }
    
    if (backgroundSupported) {
        backgroundTask = [application beginBackgroundTaskWithExpirationHandler:^{
            [self finishBackgroundTask];
        }];
    }
    
    [self stopRecordingWithCompletionHandler:^(NSURL *url) {
        ;
    }];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    [self finishBackgroundTask];
    [self startRecording];
}

- (void)finishBackgroundTask
{
    if (backgroundTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:backgroundTask];
        backgroundTask = UIBackgroundTaskInvalid;
    }
}

#pragma mark Utility methods

- (NSString *)documentDirectory
{
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *documentsDirectory = [paths objectAtIndex:0];
	return documentsDirectory;
}

- (NSString *)defaultFilename
{
    time_t timer;
    time(&timer);
    NSString *timestamp = [NSString stringWithFormat:@"%ld", timer];
    return timestamp;
}

- (BOOL)existsFile:(NSString *)filename
{
    NSString *path = [[self directoryPathForSave] stringByAppendingPathComponent:filename];
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    BOOL isDirectory;
    return [fileManager fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory;
}

- (NSString *)nextFilename:(NSString *)filename
{
    static NSInteger fileCounter;
    
    fileCounter++;
    NSString *pathExtension = [filename pathExtension];
    filename = [[[filename stringByDeletingPathExtension] stringByAppendingString:[NSString stringWithFormat:@"-%d", fileCounter]] stringByAppendingPathExtension:pathExtension];
    
    if ([self existsFile:filename]) {
        return [self nextFilename:filename];
    }
    
    return filename;
}

- (NSURL *)outputFileURL
{    
    if (!self.filenameBlock) {
        __block SRScreenRecorder *wself = self;
        self.filenameBlock = ^(void) {
            return [wself defaultFilename];
        };
    }
    
    NSString *filename = self.filenameBlock();
    filename = [filename stringByAppendingPathExtension:@"mov"];
    if ([self existsFile:filename]) {
        filename = [self nextFilename:filename];
    }
    
    NSString *path = [[self directoryPathForSave] stringByAppendingPathComponent:filename];
    return [NSURL fileURLWithPath:path];
}

- (NSString *)directoryPathForSave
{
    NSString *path = nil;
    if (self.directoryPath.length > 0) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:self.directoryPath]) {
            BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:self.directoryPath
                                                     withIntermediateDirectories:YES
                                                                      attributes:nil
                                                                           error:nil];
            if (success) {
                [self addSkipBackupAttributeAtPath:self.directoryPath];
                path = self.directoryPath;
            }
        } else {
            path = self.directoryPath;
        }
    }
    if (!path) {
        path = self.documentDirectory;
    }
    return path;
}

- (BOOL)addSkipBackupAttributeAtPath:(NSString *)path
{
    if ([[[UIDevice currentDevice] systemVersion] compare:@"5.0.1" options:NSNumericSearch] != NSOrderedDescending) {
        // iOS <= 5.0.1
        const char *filePath = [path fileSystemRepresentation];
        const char *attrName = "com.apple.MobileBackup";
        u_int8_t attrValue = 1;
        
        int result = setxattr(filePath, attrName, &attrValue, sizeof(attrValue), 0, 0);
        return result == 0;
    } else {
        // iOS >= 5.1
        NSURL *URL = [NSURL fileURLWithPath:path];
        BOOL result = [URL setResourceValue:[NSNumber numberWithBool:YES]
                                     forKey:@"NSURLIsExcludedFromBackupKey"
                                      error:nil];
        return result;
    }
}

- (void)limitNumberOfFiles
{
    if (self.maxNumberOfFiles == 0) {
        return;
    }
    
    NSString *dirPath = [self directoryPathForSave];
    NSError *error = nil;
    NSArray *list = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self directoryPathForSave] error:&error];
    if (!error) {
        NSMutableArray *attributes = [NSMutableArray array];
        for (NSString *file in list) {
            NSMutableDictionary *dic = [NSMutableDictionary dictionary];
            NSString *filePath = [dirPath stringByAppendingPathComponent:file];
            NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
            if ([[filePath pathExtension] isEqualToString:@"mov"] && [attr objectForKey:NSFileType] == NSFileTypeRegular) {
                [dic setDictionary:attr];
                [dic setObject:filePath forKey:@"FilePath"];
                [attributes addObject:dic];
            }
        }
        
        NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:NSFileCreationDate ascending:YES];
        NSArray *descArray = [NSArray arrayWithObject:sortDescriptor];
        NSArray *sortedArray = [attributes sortedArrayUsingDescriptors:descArray];
        
        if (sortedArray.count > self.maxNumberOfFiles) {
            for (int i = 0; i < sortedArray.count - self.maxNumberOfFiles; i++) {
                [[NSFileManager defaultManager] removeItemAtPath:attributes[i][@"FilePath"] error:nil];
            }
        }
    }
}

@end
