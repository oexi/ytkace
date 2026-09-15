#import <Foundation/Foundation.h>

@class UIView;
@class CALayer;
@class UIImage;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const YTKACEVersion;

void YTKACEInstallAdsHooks(void);
void YTKACEHandleAdDisplayView(UIView *view);
void YTKACECollapseHostCell(UIView *view);
void YTKACEHandleAdCellLayout(UIView *cell);
void YTKACEHandleAdCellReuse(UIView *cell);
NSArray *YTKACEFilterAdSections(NSArray *sections);
void YTKACEInstallPromoHooks(void);
void YTKACEInstallSponsorBlockHooks(void);
void YTKACEInstallDownloadHooks(void);
NSString * _Nullable YTKACELastVideoID(void);
void YTKACEInstallGlobalDownloadMiniPlayer(void);
void YTKACEInstallOLEDHooks(void);
void YTKACEInstallStartupHooks(void);
void YTKACEInstallPremiumLogoHooks(void);
void YTKACEInstallBackgroundPlaybackHooks(void);
void YTKACEInstallPiPHooks(void);
void YTKACEInstallSpeedHooks(void);
double YTKACEStartPlaybackRate(void);
void YTKACEInstallLoopHooks(void);
void YTKACEInstallSleepTimerHooks(void);
void YTKACEInstallDoubleTapHooks(void);
void YTKACEConfigureTapToSeek(UIView *view);
void YTKACEInstallShortsLimitHooks(void);
BOOL YTKACEShortsLimitReached(void);
void YTKACEInstallProgressBarHooks(void);
void YTKACEApplyProgressStyleToBar(UIView *bar);
void YTKACEStyleProgressLayer(CALayer *layer, CGFloat trackWidth);
UIImage *YTKACEProgressFillImage(CGFloat width, CGFloat height);
void YTKACEInstallStreamingHooks(void);
void YTKACEInstallShortsHooks(void);
void YTKACEInstallSideloadCompatibilityHooks(void);
void YTKACEInstallCastCompatibilityHooks(void);
void YTKACEStartCastDiscovery(void);
void YTKACEInstallTabBarHooks(void);
void YTKACERefreshPivotBarBackground(void);
void YTKACEInstallNavigationBehaviorHooks(void);
void YTKACEInstallPlayerGestureHooks(void);
void YTKACEInstallSettingsEntryHooks(void);
void YTKACEInstallNativeSettingsHooks(void);
void YTKACEInstallOverlayVisibilityHooks(void);
void YTKACEInstallContentVisibilityHooks(void);
void YTKACEInstallNavigationVisibilityHooks(void);
void YTKACEInstallMiscellaneousHooks(void);
void YTKACEInstallCopyCommentHooks(void);
void YTKACEInstallProfilePictureHooks(void);
void YTKACEInstallPostImageSaverHooks(void);
void YTKACEInstallNativeShareHooks(void);
void YTKACEProfileConsiderDisplayView(UIView *view, id node);
void YTKACEScheduleFirstLaunch(void);

NS_ASSUME_NONNULL_END
void YTKACEInstallPlaybackFixHooks(void);
void YTKACEInstallSimplifiedChineseCaptionHooks(void);
void YTKACEPrepareCaptionTrackForSelection(id _Nullable track);
