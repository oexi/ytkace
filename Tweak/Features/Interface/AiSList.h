#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void YTKACEAiSListRefreshIfStale(void);
FOUNDATION_EXPORT BOOL YTKACEAiSListReady(void);
FOUNDATION_EXPORT BOOL YTKACEAiSListReportingEnabled(void);
FOUNDATION_EXPORT void YTKACELookupChannelHandle(NSString *videoID,
                                                 void (^completion)(NSString * _Nullable handle,
                                                                    NSString * _Nullable channel,
                                                                    NSString * _Nullable title));
FOUNDATION_EXPORT void YTKACEAiSListReportVideo(NSString *videoID);
FOUNDATION_EXPORT id _Nullable YTKACEAiSListAppendMenuAction(id _Nullable renderers, id _Nullable actions);
FOUNDATION_EXPORT BOOL YTKACEAiSListMatches(NSData *bytes, BOOL blocklist, BOOL warnlist,
                                           NSString * _Nullable * _Nullable matched);

NS_ASSUME_NONNULL_END
