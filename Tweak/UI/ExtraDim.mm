#import "../YTKACE.h"
#import "../Runtime/Preferences.h"

#import <UIKit/UIKit.h>

static NSString *const YTKACEExtraDimKey = @"YTKACE.Preference.Appearance.ExtraDim";
static UIWindow *YTKACEDimWindow;

static UIWindowScene *YTKACEActiveScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    }
    return nil;
}

static void YTKACEUpdateExtraDim(void) {
    double percent = YTKACEMasterEnabled() ? [YTKACEPreferenceObject(YTKACEExtraDimKey) doubleValue] : 0.0;
    CGFloat alpha = (CGFloat)MAX(0.0, MIN(85.0, percent)) / 100.0;
    if (alpha <= 0.001) {
        YTKACEDimWindow.hidden = YES;
        return;
    }
    UIWindowScene *scene = YTKACEActiveScene();
    if (scene == nil) return;
    if (YTKACEDimWindow == nil || YTKACEDimWindow.windowScene != scene) {
        YTKACEDimWindow = [[UIWindow alloc] initWithWindowScene:scene];
        YTKACEDimWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
        YTKACEDimWindow.userInteractionEnabled = NO;
    }
    YTKACEDimWindow.backgroundColor = [UIColor colorWithWhite:0.0 alpha:alpha];
    YTKACEDimWindow.hidden = NO;
}

__attribute__((constructor)) static void YTKACEInstallExtraDim(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification,
                                       YTKACEPreferencesDidChangeNotification]) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
            YTKACEUpdateExtraDim();
        }];
    }
}
