#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTKACEDownloadCancelHandler)(NSString *identifier);

FOUNDATION_EXPORT NSNotificationName const YTKACEDownloadJobsDidChangeNotification;

@interface YTKACEDownloadProgressView : NSObject
+ (instancetype)sharedView;
@property(nonatomic, copy, nullable) YTKACEDownloadCancelHandler cancelHandler;
@property(nonatomic, copy, nullable) YTKACEDownloadCancelHandler retryHandler;
@property(nonatomic, assign) BOOL suppressed;
- (NSArray<NSDictionary *> *)jobSnapshot;
- (void)cancelOrDismissJob:(NSString *)identifier;
- (void)retryJob:(NSString *)identifier;
- (void)beginJob:(NSString *)identifier
           title:(NSString *)title
    thumbnailURL:(nullable NSURL *)thumbnailURL;
- (void)updateJob:(NSString *)identifier
            stage:(NSString *)stage
         progress:(double)progress
  downloadedBytes:(int64_t)downloadedBytes
       totalBytes:(int64_t)totalBytes;
- (void)finishJob:(NSString *)identifier
          success:(BOOL)success
          message:(NSString *)message;
@end

NS_ASSUME_NONNULL_END
