#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTKACEShortsPinchKey =
    @"YTKACE.Preference.Shorts.PinchFullscreen";

static IMP OriginalDidPinch;
static IMP OriginalReelWillDisappear;

static BOOL YTKACEShortsImmersive;

static id YTKACEPinchSend(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static id YTKACEAppViewController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *root = window.rootViewController;
            if ([root respondsToSelector:NSSelectorFromString(@"hidePivotBar")]) {
                return root;
            }
        }
    }
    return nil;
}

static const void *YTKACEPinchAlphaKey = &YTKACEPinchAlphaKey;

static void YTKACEFadeOverlaySubviews(UIView *overlay, BOOL hidden) {
    for (UIView *subview in overlay.subviews) {
        if (hidden) {
            if (objc_getAssociatedObject(subview, YTKACEPinchAlphaKey) == nil) {
                objc_setAssociatedObject(subview, YTKACEPinchAlphaKey,
                                         @(subview.alpha),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            subview.alpha = 0.0;
        } else {
            NSNumber *saved = objc_getAssociatedObject(subview,
                                                       YTKACEPinchAlphaKey);
            if (saved != nil) {
                subview.alpha = saved.doubleValue;
                objc_setAssociatedObject(subview, YTKACEPinchAlphaKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}

static void YTKACESettleOverlay(UIView *overlay) {
    if (overlay == nil) return;
    __weak UIView *weakOverlay = overlay;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strong = weakOverlay;
        if (strong == nil) return;
        [strong setNeedsLayout];
        [strong layoutIfNeeded];
        for (UIView *subview in strong.subviews) {
            [subview setNeedsLayout];
            [subview layoutIfNeeded];
        }
    });
}

static UIView *YTKACEReelOverlay(UIViewController *shorts) {
    id content = YTKACEPinchSend(shorts, @"contentView") ?: shorts.view;
    id overlay = YTKACEPinchSend(content, @"playbackOverlay");
    return [overlay isKindOfClass:UIView.class] ? overlay : nil;
}

static void YTKACESetShortsImmersive(BOOL immersive, UIViewController *shorts) {
    if (immersive == YTKACEShortsImmersive) return;
    YTKACEShortsImmersive = immersive;

    id app = YTKACEAppViewController();
    SEL toggle = NSSelectorFromString(immersive ? @"hidePivotBar" : @"showPivotBar");
    if ([app respondsToSelector:toggle]) {
        ((void (*)(id, SEL))objc_msgSend)(app, toggle);
    }
    UIView *overlay = YTKACEReelOverlay(shorts);
    if (overlay == nil) return;
    [UIView animateWithDuration:0.2 animations:^{
        YTKACEFadeOverlaySubviews(overlay, immersive);
    } completion:^(BOOL finished) {
        (void)finished;
        if (!immersive) YTKACESettleOverlay(overlay);
    }];
}

static UIViewController *YTKACEShortsControllerForPlayerView(id playerView) {
    id delegate = YTKACEPinchSend(playerView, @"playerViewDelegate");
    id parent = YTKACEPinchSend(delegate, @"parentViewController");
    if (![parent isKindOfClass:UIViewController.class]) return nil;
    Class shortsClass = NSClassFromString(@"YTShortsPlayerViewController");
    Class reelClass = NSClassFromString(@"YTReelPlayerViewController");
    if ((shortsClass != Nil && [parent isKindOfClass:shortsClass]) ||
        (reelClass != Nil && [parent isKindOfClass:reelClass])) {
        return parent;
    }
    return nil;
}

static void YTKACEDidPinch(id receiver, SEL selector, id recognizer) {
    if (OriginalDidPinch != NULL) {
        ((void (*)(id, SEL, id))OriginalDidPinch)(receiver, selector, recognizer);
    }
    if (!YTKACEFeatureEnabled(YTKACEShortsPinchKey)) return;
    if (![recognizer isKindOfClass:UIPinchGestureRecognizer.class]) return;

    UIPinchGestureRecognizer *pinch = recognizer;
    if (pinch.state != UIGestureRecognizerStateChanged &&
        pinch.state != UIGestureRecognizerStateEnded) {
        return;
    }
    UIViewController *shorts = YTKACEShortsControllerForPlayerView(receiver);
    if (shorts == nil) return;

    if (pinch.scale > 1.05) {
        YTKACESetShortsImmersive(YES, shorts);
    } else if (pinch.scale < 0.95) {
        YTKACESetShortsImmersive(NO, shorts);
    }
}

static void YTKACEReelWillDisappear(id receiver, SEL selector, BOOL animated) {
    if (YTKACEShortsImmersive) {
        YTKACEShortsImmersive = NO;
        id app = YTKACEAppViewController();
        SEL show = NSSelectorFromString(@"showPivotBar");
        if ([app respondsToSelector:show]) {
            ((void (*)(id, SEL))objc_msgSend)(app, show);
        }
        UIView *overlay = YTKACEReelOverlay(receiver);
        if (overlay != nil) {
            YTKACEFadeOverlaySubviews(overlay, NO);
            YTKACESettleOverlay(overlay);
        }
    }
    if (OriginalReelWillDisappear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalReelWillDisappear)(
            receiver, selector, animated);
    }
}

void YTKACEInstallShortsPinchHooks(void) {
    YTKACEInstallInstanceHook(@"YTPlayerView", @"didPinch:",
                              (IMP)YTKACEDidPinch, &OriginalDidPinch);
    YTKACEInstallInstanceHook(@"YTReelPlayerViewController",
                              @"viewWillDisappear:",
                              (IMP)YTKACEReelWillDisappear,
                              &OriginalReelWillDisappear);
}
