#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTKACERootOptionsController : UIViewController
@end

FOUNDATION_EXPORT UINavigationController *YTKACEMakeSettingsNavigationController(void);
FOUNDATION_EXPORT void YTKACEApplyAppearance(UIViewController *controller);
FOUNDATION_EXPORT UIViewController *YTKACEMakeDownloadLogController(void);
FOUNDATION_EXPORT NSString *YTKACEDeviceInformationText(void);
FOUNDATION_EXPORT BOOL YTKACEOwnsNavigationController(
    UINavigationController *_Nullable navigation);

NS_ASSUME_NONNULL_END
