#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void YTKACEDownloadLog(NSString *identifier,
                                         NSString *format, ...)
    NS_FORMAT_FUNCTION(2, 3);
FOUNDATION_EXPORT BOOL YTKACEDebugLogsEnabled(void);
FOUNDATION_EXPORT void YTKACESetDebugLogsEnabled(BOOL enabled);
FOUNDATION_EXPORT void YTKACEDebugLog(NSString *identifier,
                                      NSString *format, ...)
    NS_FORMAT_FUNCTION(2, 3);
FOUNDATION_EXPORT NSString *YTKACEDownloadLogContents(void);
FOUNDATION_EXPORT void YTKACEClearDownloadLog(void);

NS_ASSUME_NONNULL_END
