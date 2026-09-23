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
void YTKACEInstallQueueHooks(void);
BOOL YTKACEQueueHasItems(void);
BOOL YTKACEQueueOwnsCurrentVideo(void);
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
void YTKACEInstallAutoplayHooks(void);
void YTKACEOpenPausedVideoActivated(id player);
void YTKACEInstallCaptionHooks(void);
void YTKACEInstallTranscriptHooks(void);
NSArray<NSDictionary *> *_Nullable YTKACEParseCaptionCues(NSData *data);
NSArray *_Nullable YTKACECaptionTracksForResponse(id playerResponse);
NSArray<NSDictionary *> *_Nullable YTKACECaptionChoicesForResponse(id playerResponse);
NSString *YTKACECaptionTrackLabel(id track);
NSString *_Nullable YTKACECaptionTrackLanguage(id track);
NSURL *_Nullable YTKACECaptionTrackURL(id track);
void YTKACEFetchCuesForURL(NSURL *_Nullable url,
                           void (^completion)(NSArray<NSDictionary *> *_Nullable cues));
void YTKACEFetchCaptionCues(id playerResponse,
                            void (^completion)(NSArray<NSDictionary *> *_Nullable cues,
                                               NSString *_Nullable language));
void YTKACECaptionsSnapshot(id player);
void YTKACECaptionsRestore(id player);
void YTKACEApplyPreferredCaptionLanguage(id player);
void YTKACEInstallSleepTimerHooks(void);
void YTKACEInstallDoubleTapHooks(void);
void YTKACEConfigureTapToSeek(UIView *view);
void YTKACEInstallShortsLimitHooks(void);
void YTKACEInstallShortsStartupHooks(void);
void YTKACEInstallShortsPinchHooks(void);
void YTKACESetShortsOverlayFullscreen(UIView *overlay, BOOL fullscreen);
BOOL YTKACEShortsLimitReached(void);
BOOL YTKACEPlayerIsShorts(id player);
NSInteger YTKACERealUserInterfaceIdiom(void);
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
void YTKACEInstallPlaylistDownloaderHooks(void);
BOOL YTKACEProductIdentifierMatches(NSString * _Nullable identifier);
BOOL YTKACEViewIsInsidePlayerOverlay(UIView *view);
void YTKACEHideProductSubtree(UIView *view);
BOOL YTKACEProductOverlayMatches(id overlay);
void YTKACEInstallNativeShareHooks(void);
void YTKACEProfileConsiderDisplayView(UIView *view, id node);
void YTKACEScheduleFirstLaunch(void);

NS_ASSUME_NONNULL_END
void YTKACEInstallPlaybackFixHooks(void);
void YTKACEInstallSimplifiedChineseCaptionHooks(void);
void YTKACEPrepareCaptionTrackForSelection(id _Nullable track);
