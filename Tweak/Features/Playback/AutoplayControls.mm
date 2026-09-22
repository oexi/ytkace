#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTKACEOpenPausedKey =
    @"YTKACE.Preference.Playback.OpenPaused";
static NSString *const YTKACEAutoplayOffKey =
    @"YTKACE.Preference.Playback.AutoplayDisabled";

static IMP OriginalPlayAutoplay;
static IMP OriginalTriggerPendingAutoplay;

static NSString *YTKACELastPausedVideo;

static void YTKACEPauseNow(id player) {
    if (player == nil) return;
    SEL pause = NSSelectorFromString(@"pause");
    if (![player respondsToSelector:pause]) return;
    ((void (*)(id, SEL))objc_msgSend)(player, pause);
}

void YTKACEOpenPausedVideoActivated(id player) {
    YTKACEApplyPreferredCaptionLanguage(player);
    if (!YTKACEFeatureEnabled(YTKACEOpenPausedKey)) return;
    NSString *videoID = nil;
    SEL getter = NSSelectorFromString(@"currentVideoID");
    if ([player respondsToSelector:getter]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(player, getter);
        if ([value isKindOfClass:NSString.class]) videoID = value;
    }
    if (videoID.length != 0 &&
        [videoID isEqualToString:YTKACELastPausedVideo]) {
        return;
    }
    YTKACELastPausedVideo = [videoID copy];

    __weak id weakPlayer = player;
    YTKACEPauseNow(player);
    const double delays[] = { 0.0, 0.15, 0.4, 0.8, 1.4 };
    for (size_t index = 0; index < sizeof(delays) / sizeof(delays[0]); index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[index] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YTKACEPauseNow(weakPlayer);
        });
    }
}

static BOOL YTKACEAutoplaySuppressed(void) {
    return YTKACEFeatureEnabled(YTKACEAutoplayOffKey);
}

static void YTKACEPlayAutoplay(id receiver, SEL selector) {
    if (YTKACEAutoplaySuppressed()) return;
    if (OriginalPlayAutoplay != NULL) {
        ((void (*)(id, SEL))OriginalPlayAutoplay)(receiver, selector);
    }
}

static void YTKACETriggerPendingAutoplay(id receiver, SEL selector) {
    if (YTKACEAutoplaySuppressed()) return;
    if (OriginalTriggerPendingAutoplay != NULL) {
        ((void (*)(id, SEL))OriginalTriggerPendingAutoplay)(receiver, selector);
    }
}

void YTKACEInstallAutoplayHooks(void) {
    YTKACEInstallInstanceHook(@"YTWatchFlowController", @"playAutoplay",
                              (IMP)YTKACEPlayAutoplay, &OriginalPlayAutoplay);
    YTKACEInstallInstanceHook(@"YTQueueController", @"triggerPendingAutoplay",
                              (IMP)YTKACETriggerPendingAutoplay,
                              &OriginalTriggerPendingAutoplay);
}
