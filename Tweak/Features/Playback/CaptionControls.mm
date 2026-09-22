#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalSetActiveCaptionTrack;

static __weak id YTKACERememberedTrack;
static NSString *YTKACERememberedVSSID;
static NSString *YTKACERememberedLanguage;
static long long YTKACERememberedSource;
static BOOL YTKACEHasRememberedTrack;

static NSString *YTKACECaptionString(id track, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (track == nil || ![track respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(track, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id YTKACECaptionValueForKey(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static void YTKACERememberTrack(id track, long long source) {
    YTKACERememberedTrack = track;
    YTKACERememberedVSSID = [YTKACECaptionString(track, @"VSSID") copy];
    YTKACERememberedLanguage = [YTKACECaptionString(track, @"languageCode") copy];
    YTKACERememberedSource = source;
    YTKACEHasRememberedTrack = YES;
}

static void YTKACESetActiveCaptionTrack(id receiver,
                                        SEL selector,
                                        id track,
                                        long long source) {
    if (track != nil) {
        YTKACERememberTrack(track, source);
    } else {
        YTKACEHasRememberedTrack = NO;
        YTKACERememberedTrack = nil;
        YTKACERememberedVSSID = nil;
        YTKACERememberedLanguage = nil;
    }
    if (OriginalSetActiveCaptionTrack != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalSetActiveCaptionTrack)(
            receiver, selector, track, source);
    }
}

static id YTKACEMatchingTrack(id player) {
    id video = YTKACECaptionValueForKey(player, @"activeVideo");
    id available = YTKACECaptionValueForKey(video, @"availableCaptionTracks")
        ?: YTKACECaptionValueForKey(player, @"availableCaptionTracks");
    if (![available isKindOfClass:NSArray.class]) return YTKACERememberedTrack;
    for (id track in (NSArray *)available) {
        NSString *vssID = YTKACECaptionString(track, @"VSSID");
        if (YTKACERememberedVSSID.length != 0 &&
            [vssID isEqualToString:YTKACERememberedVSSID]) {
            return track;
        }
    }
    for (id track in (NSArray *)available) {
        NSString *language = YTKACECaptionString(track, @"languageCode");
        if (YTKACERememberedLanguage.length != 0 &&
            [language isEqualToString:YTKACERememberedLanguage]) {
            return track;
        }
    }
    return YTKACERememberedTrack;
}


static NSString *const YTKACEPreferredLanguageKey =
    @"YTKACE.Preference.Playback.CaptionLanguage";

static NSString *YTKACETrackLanguage(id track) {
    id value = YTKACECaptionValueForKey(track, @"languageCode");
    return [value isKindOfClass:NSString.class] ? value : nil;
}

void YTKACEApplyPreferredCaptionLanguage(id player) {
    NSString *preferred = [NSUserDefaults.standardUserDefaults
        stringForKey:YTKACEPreferredLanguageKey];
    if (preferred.length == 0) return;

    id video = YTKACECaptionValueForKey(player, @"activeVideo");
    id available = YTKACECaptionValueForKey(video, @"availableCaptionTracks")
        ?: YTKACECaptionValueForKey(player, @"availableCaptionTracks");
    if (![available isKindOfClass:NSArray.class] || [available count] == 0) {
        return;
    }
    id active = YTKACECaptionValueForKey(video, @"activeCaptionTrack");
    if (active != nil &&
        [YTKACETrackLanguage(active) hasPrefix:preferred]) {
        return;
    }

    id exact = nil;
    id prefix = nil;
    for (id track in (NSArray *)available) {
        NSString *code = YTKACETrackLanguage(track);
        if (code.length == 0) continue;
        if ([code caseInsensitiveCompare:preferred] == NSOrderedSame) {
            exact = track;
            break;
        }
        if (prefix == nil && [code.lowercaseString
                hasPrefix:preferred.lowercaseString]) {
            prefix = track;
        }
    }
    id chosen = exact ?: prefix;
    if (chosen == nil) {
        YTKACEDownloadLog(@"caption", @"no track for %@", preferred);
        return;
    }
    SEL setter = NSSelectorFromString(@"setActiveCaptionTrack:source:");
    if (![player respondsToSelector:setter]) return;
    ((void (*)(id, SEL, id, long long))objc_msgSend)(
        player, setter, chosen, YTKACERememberedSource);
    YTKACEDownloadLog(@"caption", @"applied preferred %@", preferred);
}

void YTKACECaptionsSnapshot(id player) {
    id video = YTKACECaptionValueForKey(player, @"activeVideo");
    id active = YTKACECaptionValueForKey(video, @"activeCaptionTrack");
    if (active != nil) {
        YTKACERememberTrack(active, YTKACERememberedSource);
    }
}

void YTKACECaptionsRestore(id player) {
    if (!YTKACEHasRememberedTrack) return;
    id video = YTKACECaptionValueForKey(player, @"activeVideo");
    if (YTKACECaptionValueForKey(video, @"activeCaptionTrack") != nil) return;

    id track = YTKACEMatchingTrack(player);
    if (track == nil) return;
    SEL setter = NSSelectorFromString(@"setActiveCaptionTrack:source:");
    if (![player respondsToSelector:setter]) return;
    ((void (*)(id, SEL, id, long long))objc_msgSend)(
        player, setter, track, YTKACERememberedSource);
    YTKACEDownloadLog(@"fix", @"captions restored %@",
                      YTKACECaptionString(track, @"languageCode") ?: @"?");
}

void YTKACEInstallCaptionHooks(void) {
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"setActiveCaptionTrack:source:",
                              (IMP)YTKACESetActiveCaptionTrack,
                              &OriginalSetActiveCaptionTrack);
}
