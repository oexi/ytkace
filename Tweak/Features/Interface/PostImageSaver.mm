#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Notice.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTKACEPostImageSaveKey = @"YTKACE.Preference.Posts.SaveImage";

static IMP OriginalZoomNodeVisible;
static __weak id YTKACECurrentZoomNode;
static const void *YTKACEPostSaveButtonKey = &YTKACEPostSaveButtonKey;

static void YTKACEWriteImageDataToPhotos(NSData *data) {
    void (^save)(void) = ^{
        [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
            PHAssetCreationRequest *request =
                [PHAssetCreationRequest creationRequestForAsset];
            [request addResourceWithType:PHAssetResourceTypePhoto data:data
                                 options:nil];
        } completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    YTKACEShowNotice(YTKACELocalized(@"Saved to Photos"));
                } else {
                    YTKACEShowNotice(error.localizedDescription ?:
                        YTKACELocalized(@"The image could not be saved."));
                }
            });
        }];
    };

    void (^afterAuthorization)(PHAuthorizationStatus) = ^(PHAuthorizationStatus status) {
        if (status == PHAuthorizationStatusAuthorized ||
            status == PHAuthorizationStatusLimited) {
            save();
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACEShowNotice(
                YTKACELocalized(@"YouTube needs permission to add to Photos."));
        });
    };

    if (@available(iOS 14.0, *)) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                                   handler:afterAuthorization];
    } else {
        [PHPhotoLibrary requestAuthorization:afterAuthorization];
    }
}

static NSURL *YTKACEOriginalImageURL(NSURL *url) {
    NSString *text = url.absoluteString;
    const NSRange crop = [text rangeOfString:@"c-fcrop"];
    if (crop.location != NSNotFound) {
        NSString *upgraded = [[text substringToIndex:crop.location]
            stringByAppendingString:@"nd-v1"];
        return [NSURL URLWithString:upgraded] ?: url;
    }
    const NSRange slash = [text rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound) return url;
    NSRange options = [text rangeOfString:@"=" options:NSBackwardsSearch
                                    range:NSMakeRange(slash.location,
                                          text.length - slash.location)];
    if (options.location == NSNotFound) return url;
    NSString *upgraded = [[text substringToIndex:options.location]
        stringByAppendingString:@"=s0"];
    return [NSURL URLWithString:upgraded] ?: url;
}

@interface YTKACEPostImageSaveTarget : NSObject
+ (instancetype)sharedTarget;
- (void)saveTapped:(UIButton *)sender;
@end

@implementation YTKACEPostImageSaveTarget

+ (instancetype)sharedTarget {
    static YTKACEPostImageSaveTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTKACEPostImageSaveTarget new]; });
    return target;
}

- (void)saveTapped:(UIButton *)sender {
    id node = YTKACECurrentZoomNode;
    if (node == nil) {
        YTKACEShowNotice(YTKACELocalized(@"The image could not be saved."));
        return;
    }

    SEL urlGetter = NSSelectorFromString(@"URL");
    NSURL *url = [node respondsToSelector:urlGetter]
        ? ((id (*)(id, SEL))objc_msgSend)(node, urlGetter)
        : nil;
    if (url == nil) {
        YTKACEShowNotice(YTKACELocalized(@"The image is still loading."));
        return;
    }

    NSURL *original = YTKACEOriginalImageURL(url);
    sender.enabled = NO;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:original
      completionHandler:^(NSData *data, NSURLResponse *response,
                          __unused NSError *error) {
        (void)response;
        dispatch_async(dispatch_get_main_queue(), ^{ sender.enabled = YES; });
        if (data.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                YTKACEShowNotice(YTKACELocalized(@"The image could not be saved."));
            });
            return;
        }
        YTKACEWriteImageDataToPhotos(data);
    }];
    [task resume];
}

@end

static UIImage *YTKACEPostSaveIcon(void) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:18.0
                                                           weight:UIImageSymbolWeightSemibold];
        return [UIImage systemImageNamed:@"square.and.arrow.down"
                       withConfiguration:configuration];
    }
    return nil;
}

static void YTKACEAttachSaveButton(UIView *container) {
    UIButton *existing = objc_getAssociatedObject(container, YTKACEPostSaveButtonKey);
    if (existing != nil && existing.superview == container) {
        existing.hidden = NO;
        [container bringSubviewToFront:existing];
        return;
    }
    [existing removeFromSuperview];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:YTKACEPostSaveIcon() forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = YTKACELocalized(@"Save to Photos");
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.5f;
    button.layer.shadowRadius = 3.0f;
    button.layer.shadowOffset = CGSizeZero;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:[YTKACEPostImageSaveTarget sharedTarget]
               action:@selector(saveTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(container, YTKACEPostSaveButtonKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [container addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                            constant:12.0],
        [button.topAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.topAnchor
                                        constant:8.0],
        [button.widthAnchor constraintEqualToConstant:44.0],
        [button.heightAnchor constraintEqualToConstant:44.0]
    ]];
}

static UIViewController *YTKACEOwningController(UIView *view) {
    UIResponder *responder = view;
    while (responder != nil) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static void YTKACEZoomNodeDidEnterVisibleState(id receiver, SEL selector) {
    if (OriginalZoomNodeVisible != NULL) {
        ((void (*)(id, SEL))OriginalZoomNodeVisible)(receiver, selector);
    }
    if (!YTKACEFeatureEnabled(YTKACEPostImageSaveKey)) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        SEL viewGetter = NSSelectorFromString(@"view");
        if (![receiver respondsToSelector:viewGetter]) return;
        UIView *view = ((id (*)(id, SEL))objc_msgSend)(receiver, viewGetter);
        if (view.window == nil) return;
        UIViewController *owner = YTKACEOwningController(view);
        if (owner.view == nil) return;

        Class viewerClass =
            NSClassFromString(@"YTInterstitialElementsViewControllerImpl");
        if (viewerClass == Nil || ![owner isKindOfClass:viewerClass]) return;
        YTKACECurrentZoomNode = receiver;
        YTKACEAttachSaveButton(owner.view);
    });
}

void YTKACEInstallPostImageSaverHooks(void) {
    YTKACEInstallInstanceHook(
        @"YTImageZoomNode", @"didEnterVisibleState",
        (IMP)YTKACEZoomNodeDidEnterVisibleState, &OriginalZoomNodeVisible);
}
