#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const YTKACEDownloadInfoDidChangeNotification;

FOUNDATION_EXPORT void YTKACEAttachSponsorSegments(NSURL *fileURL, NSString *videoID,
                                                 NSString * _Nullable author);
FOUNDATION_EXPORT NSString * _Nullable YTKACEStoredChannelName(NSURL *fileURL);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *YTKACEStoredSponsorSegments(NSURL *fileURL);
FOUNDATION_EXPORT void YTKACERefreshSponsorSegments(
    NSURL *fileURL, void (^completion)(NSArray<NSDictionary<NSString *, id> *> *segments));

NS_ASSUME_NONNULL_END
