#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void YTKACEAiSListRefreshIfStale(void);
FOUNDATION_EXPORT BOOL YTKACEAiSListReady(void);
FOUNDATION_EXPORT BOOL YTKACEAiSListMatches(NSData *bytes, BOOL blocklist, BOOL warnlist,
                                           NSString * _Nullable * _Nullable matched);

NS_ASSUME_NONNULL_END
