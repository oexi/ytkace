#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

static IMP YTKACEZoomOrigBegin;
static IMP YTKACEZoomOrigZoom;
static IMP YTKACEZoomOrigEnd;
static IMP YTKACEZoomOrigMaxState;
static IMP YTKACEZoomOrigLayout;
static BOOL YTKACEZoomReleasing;
static BOOL YTKACEZoomResyncPending;
static const double YTKACEZoomUnlimitedMax = 50.0;

static NSInteger YTKACEZoomMode(void) {
    id stored = YTKACEPreferenceObject(@"YTKACE.Preference.Playback.VideoZoom");
    return [stored respondsToSelector:@selector(integerValue)] ? [stored integerValue] : 0;
}

static double YTKACEZoomDouble(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return NAN;
    return ((double (*)(id, SEL))objc_msgSend)(object, selector);
}

static void YTKACEZoomSetDouble(id object, NSString *name, double value) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, double))objc_msgSend)(object, selector, value);
}

static void YTKACEZoomCall(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL))objc_msgSend)(object, selector);
}

static double YTKACEZoomFillFactor(id controller) {
    static Ivar ivar;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Ivar found = class_getInstanceVariable(object_getClass(controller), "_snappedZoomFactor");
        const char *type = found != NULL ? ivar_getTypeEncoding(found) : NULL;
        if (type != NULL && strcmp(type, "d") == 0) ivar = found;
    });
    if (ivar == NULL) return NAN;
    return *(double *)((uint8_t *)(__bridge void *)controller + ivar_getOffset(ivar));
}

static void YTKACEZoomBegin(id self, SEL _cmd, CGPoint point) {
    if (YTKACEZoomMode() == 2) {
        YTKACEZoomSetDouble(self, @"setMaxFreeZoomFactor:", YTKACEZoomUnlimitedMax);
        YTKACEZoomSetDouble(self, @"setMaxFreeZoomLimit:", YTKACEZoomUnlimitedMax * 1.2);
    }
    ((void (*)(id, SEL, CGPoint))YTKACEZoomOrigBegin)(self, _cmd, point);
}

static void YTKACEZoomDidZoom(id self, SEL _cmd, double zoom, BOOL twoFinger) {
    if (zoom > 1.0 && YTKACEZoomMode() == 1) {
        const double fill = YTKACEZoomFillFactor(self);
        const double current = YTKACEZoomDouble(self, @"videoZoomFactor");
        if (fill >= 1.0 && current > 0.0) {
            if (current >= fill) {
                zoom = 1.0;
            } else if (current * zoom > fill) {
                zoom = fill / current;
            }
        }
    }
    ((void (*)(id, SEL, double, BOOL))YTKACEZoomOrigZoom)(self, _cmd, zoom, twoFinger);
}

static void YTKACEZoomEnd(id self, SEL _cmd) {
    YTKACEZoomReleasing = YES;
    ((void (*)(id, SEL))YTKACEZoomOrigEnd)(self, _cmd);
    YTKACEZoomReleasing = NO;
}

static void YTKACEZoomMaxState(id self, SEL _cmd) {
    if (YTKACEZoomMode() != 2 || !YTKACEZoomReleasing) {
        ((void (*)(id, SEL))YTKACEZoomOrigMaxState)(self, _cmd);
        return;
    }
    const double current = YTKACEZoomDouble(self, @"videoZoomFactor");
    if (current <= YTKACEZoomUnlimitedMax) return;
    YTKACEZoomSetDouble(self, @"setVideoZoomFactor:", YTKACEZoomUnlimitedMax);
    YTKACEZoomSetDouble(self, @"updateRenderingViewFrameWithAnimationDuration:", 0.25);
}

static void YTKACEZoomLayout(id self, SEL _cmd, int layout) {
    ((void (*)(id, SEL, int))YTKACEZoomOrigLayout)(self, _cmd, layout);
    if (YTKACEZoomDouble(self, @"videoZoomFactor") <= 1.001 || YTKACEZoomResyncPending) return;
    YTKACEZoomResyncPending = YES;
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        YTKACEZoomResyncPending = NO;
        id strongSelf = weakSelf;
        if (strongSelf == nil) return;
        YTKACEZoomCall(strongSelf, @"resetVideoFrameToOriginalState");
    });
}

void YTKACEInstallVideoZoomHooks(void) {
    NSString *zoomClass = @"YTVideoFreeZoomOverlayController";
    YTKACEInstallInstanceHook(zoomClass, @"freeZoomViewPinchDidBeginAtPoint:",
                              (IMP)YTKACEZoomBegin, &YTKACEZoomOrigBegin);
    YTKACEInstallInstanceHook(zoomClass, @"freeZoomViewDidZoom:isTwoFingerZoom:",
                              (IMP)YTKACEZoomDidZoom, &YTKACEZoomOrigZoom);
    YTKACEInstallInstanceHook(zoomClass, @"freeZoomViewPinchDidEnd",
                              (IMP)YTKACEZoomEnd, &YTKACEZoomOrigEnd);
    YTKACEInstallInstanceHook(zoomClass, @"resetVideoFrameToMaxFreeState",
                              (IMP)YTKACEZoomMaxState, &YTKACEZoomOrigMaxState);
    YTKACEInstallInstanceHook(zoomClass, @"freeZoomViewDidSetPlayerViewLayout:",
                              (IMP)YTKACEZoomLayout, &YTKACEZoomOrigLayout);
}
