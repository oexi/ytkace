#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTKACEPreventShortsOpenKey =
    @"YTKACE.Preference.Shorts.PreventAutoOpen";

static IMP OriginalEligibilityModern;
static IMP OriginalEligibilityLegacy;
static IMP OriginalExecuteModern;
static IMP OriginalExecuteLegacy;
static IMP OriginalResumeToShorts;
static IMP OriginalShortsTargeted;
static IMP OriginalLaunchToShorts;

static BOOL YTKACEPreventShortsOpen(void) {
    return YTKACEFeatureEnabled(YTKACEPreventShortsOpenKey);
}

static BOOL YTKACEEligibilityModern(id receiver,
                                    SEL selector,
                                    id launchOptions,
                                    id sceneOptions) {
    if (YTKACEPreventShortsOpen()) {
        YTKACEDownloadLog(@"shorts", @"eligibility suppressed");
        return NO;
    }
    return OriginalEligibilityModern == NULL ? NO
        : ((BOOL (*)(id, SEL, id, id))OriginalEligibilityModern)(
            receiver, selector, launchOptions, sceneOptions);
}

static BOOL YTKACEEligibilityLegacy(id receiver,
                                    SEL selector,
                                    long long applicationState,
                                    id launchOptions) {
    if (YTKACEPreventShortsOpen()) {
        YTKACEDownloadLog(@"shorts", @"eligibility suppressed");
        return NO;
    }
    return OriginalEligibilityLegacy == NULL ? NO
        : ((BOOL (*)(id, SEL, long long, id))OriginalEligibilityLegacy)(
            receiver, selector, applicationState, launchOptions);
}

static BOOL YTKACEExecuteModern(id receiver,
                                SEL selector,
                                id responder,
                                id launchOptions,
                                id sceneOptions) {
    if (YTKACEPreventShortsOpen()) {
        YTKACEDownloadLog(@"shorts", @"execution suppressed");
        return NO;
    }
    return OriginalExecuteModern == NULL ? NO
        : ((BOOL (*)(id, SEL, id, id, id))OriginalExecuteModern)(
            receiver, selector, responder, launchOptions, sceneOptions);
}

static BOOL YTKACEExecuteLegacy(id receiver,
                                SEL selector,
                                id responder,
                                long long applicationState,
                                id launchOptions) {
    if (YTKACEPreventShortsOpen()) {
        YTKACEDownloadLog(@"shorts", @"execution suppressed");
        return NO;
    }
    return OriginalExecuteLegacy == NULL ? NO
        : ((BOOL (*)(id, SEL, id, long long, id))OriginalExecuteLegacy)(
            receiver, selector, responder, applicationState, launchOptions);
}

static id YTKACEResumeToShorts(id receiver, SEL selector) {
    if (YTKACEPreventShortsOpen()) return nil;
    return OriginalResumeToShorts == NULL ? nil
        : ((id (*)(id, SEL))OriginalResumeToShorts)(receiver, selector);
}

static id YTKACEShortsTargeted(id receiver, SEL selector) {
    if (YTKACEPreventShortsOpen()) return nil;
    return OriginalShortsTargeted == NULL ? nil
        : ((id (*)(id, SEL))OriginalShortsTargeted)(receiver, selector);
}

static id YTKACELaunchToShorts(id receiver, SEL selector) {
    if (YTKACEPreventShortsOpen()) return nil;
    return OriginalLaunchToShorts == NULL ? nil
        : ((id (*)(id, SEL))OriginalLaunchToShorts)(receiver, selector);
}

void YTKACEInstallShortsStartupHooks(void) {
    NSString *coordinator = nil;
    for (NSString *name in @[@"YTShortsStartupCoordinatorImpl",
                             @"YTShortsStartupCoordinator"]) {
        if (NSClassFromString(name) != Nil) {
            coordinator = name;
            break;
        }
    }
    if (coordinator == nil) {
        YTKACEDownloadLog(@"shorts", @"startup coordinator not found");
        return;
    }

    const BOOL eligibilityModern = YTKACEInstallInstanceHook(
        coordinator,
        @"evaluateShortsStartupEligibilityWithLaunchOptions:sceneConnectionOptions:",
        (IMP)YTKACEEligibilityModern, &OriginalEligibilityModern);
    const BOOL eligibilityLegacy = YTKACEInstallInstanceHook(
        coordinator,
        @"evaluateShortsStartupEligibilityWithApplicationState:launchOptions:",
        (IMP)YTKACEEligibilityLegacy, &OriginalEligibilityLegacy);
    const BOOL executeModern = YTKACEInstallInstanceHook(
        coordinator,
        @"executeStartupWithResponder:launchOptions:sceneConnectionOptions:",
        (IMP)YTKACEExecuteModern, &OriginalExecuteModern);
    const BOOL executeLegacy = YTKACEInstallInstanceHook(
        coordinator,
        @"executeStartupWithResponder:applicationState:launchOptions:",
        (IMP)YTKACEExecuteLegacy, &OriginalExecuteLegacy);
    const BOOL resume = YTKACEInstallInstanceHook(
        coordinator, @"evaluateResumeToShorts",
        (IMP)YTKACEResumeToShorts, &OriginalResumeToShorts);
    const BOOL targeted = YTKACEInstallInstanceHook(
        coordinator, @"evaluateShortsTargeted",
        (IMP)YTKACEShortsTargeted, &OriginalShortsTargeted);
    const BOOL launch = YTKACEInstallInstanceHook(
        coordinator, @"launchToShorts",
        (IMP)YTKACELaunchToShorts, &OriginalLaunchToShorts);

    YTKACEDownloadLog(@"shorts",
                      @"startup hooks on %@ em=%d el=%d xm=%d xl=%d r=%d t=%d l=%d enabled=%d",
                      coordinator, eligibilityModern, eligibilityLegacy,
                      executeModern, executeLegacy, resume, targeted, launch,
                      YTKACEPreventShortsOpen());
}
