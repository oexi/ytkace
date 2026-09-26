#import "DownloadProgressView.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"

#import <UIKit/UIKit.h>
#import <math.h>

@interface YTKACEDownloadProgressItem : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *stage;
@property(nonatomic, strong, nullable) NSURL *thumbnailURL;
@property(nonatomic, strong, nullable) UIImage *thumbnail;
@property(nonatomic, assign) double progress;
@property(nonatomic, assign) int64_t downloadedBytes;
@property(nonatomic, assign) int64_t totalBytes;
@end

@implementation YTKACEDownloadProgressItem
@end

@interface YTKACEDownloadProgressView () <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIImageView *thumbnailView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *percentLabel;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, strong) UIButton *cancelButton;
@property(nonatomic, strong) NSMutableDictionary<NSString *, YTKACEDownloadProgressItem *> *items;
@property(nonatomic, strong) NSMutableArray<NSString *> *activeIdentifiers;
@property(nonatomic, copy, nullable) NSString *visibleIdentifier;
@property(nonatomic, copy, nullable) NSString *renderedIdentifier;
@property(nonatomic, strong) NSTimer *positionTimer;
@end

@implementation YTKACEDownloadProgressView

- (void)applyTheme {
    UITraitCollection *traits = self.keyWindow.traitCollection ?:
        UIScreen.mainScreen.traitCollection;
    BOOL oled = YTKACEOLEDActive(traits);
    BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    self.card.backgroundColor = oled ? UIColor.blackColor :
        (dark ? YTKACEInterfaceSurfaceColor(traits) : UIColor.systemBackgroundColor);
    self.thumbnailView.backgroundColor = YTKACEInterfaceSurfaceColor(traits);
    self.titleLabel.textColor = UIColor.labelColor;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.percentLabel.textColor = UIColor.labelColor;
    self.cancelButton.tintColor = UIColor.tertiaryLabelColor;
    self.progressView.trackTintColor = oled
        ? [UIColor colorWithWhite:0.18 alpha:1.0]
        : UIColor.systemGray4Color;
    self.card.layer.borderWidth = dark ? 0.0 : 0.5;
    self.card.layer.borderColor = UIColor.separatorColor.CGColor;
}

+ (instancetype)sharedView {
    static YTKACEDownloadProgressView *view;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ view = [YTKACEDownloadProgressView new]; });
    return view;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _items = [NSMutableDictionary dictionary];
        _activeIdentifiers = [NSMutableArray array];
        [self makeUI];
    }
    return self;
}

- (void)makeUI {
    self.card = [[UIView alloc] initWithFrame:CGRectMake(12.0, 0.0, 360.0, 72.0)];
    self.card.layer.cornerRadius = 12.0;
    self.card.layer.shadowColor = UIColor.blackColor.CGColor;
    self.card.layer.shadowOpacity = 0.24;
    self.card.layer.shadowRadius = 12.0;
    self.card.layer.shadowOffset = CGSizeMake(0.0, 4.0);
    self.card.alpha = 0.0;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(cycleTapped)];
    tap.cancelsTouchesInView = NO;
    tap.delegate = self;
    [self.card addGestureRecognizer:tap];

    self.thumbnailView = [UIImageView new];
    self.thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
    self.thumbnailView.clipsToBounds = YES;
    self.thumbnailView.layer.cornerRadius = 8.0;
    [self.card addSubview:self.thumbnailView];

    self.titleLabel = [UILabel new];
    self.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.card addSubview:self.titleLabel];

    self.statusLabel = [UILabel new];
    self.statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    [self.card addSubview:self.statusLabel];

    self.percentLabel = [UILabel new];
    self.percentLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightBold];
    self.percentLabel.textAlignment = NSTextAlignmentRight;
    [self.card addSubview:self.percentLabel];

    self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *close = [UIImage systemImageNamed:@"xmark.circle.fill"];
    [self.cancelButton setImage:close forState:UIControlStateNormal];
    [self.cancelButton addTarget:self action:@selector(cancelTapped)
                forControlEvents:UIControlEventTouchUpInside];
    [self.card addSubview:self.cancelButton];

    self.progressView = [[UIProgressView alloc]
        initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.progressTintColor = UIColor.systemBlueColor;
    self.progressView.transform = CGAffineTransformMakeScale(1.0, 2.4);
    [self.card addSubview:self.progressView];
    [self applyTheme];
}

- (UIWindow *)keyWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

- (void)layoutCard {
    UIWindow *window = [self keyWindow];
    if (window == nil || self.card.superview == nil) return;
    CGFloat width = MIN(CGRectGetWidth(window.bounds) - 24.0, 430.0);
    CGFloat bottom = window.safeAreaInsets.bottom + 52.0;
    CGFloat x = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
        ? 12.0 : (CGRectGetWidth(window.bounds) - width) * 0.5;
    self.card.frame = CGRectMake(x, CGRectGetHeight(window.bounds) - bottom - 80.0,
                                 width, 72.0);
    self.thumbnailView.frame = CGRectMake(8.0, 6.0, 100.0, 60.0);
    self.cancelButton.frame = CGRectMake(width - 30.0, 24.0, 24.0, 24.0);
    self.percentLabel.frame = CGRectMake(width - 88.0, 12.0, 52.0, 20.0);
    CGFloat textWidth = MAX(width - 206.0, 80.0);
    self.titleLabel.frame = CGRectMake(118.0, 11.0, textWidth, 20.0);
    self.statusLabel.frame = CGRectMake(118.0, 35.0, width - 158.0, 18.0);
    self.progressView.frame = CGRectMake(0.0, 69.5, width, 2.0);
}

- (void)attach {
    UIWindow *window = [self keyWindow];
    if (window == nil) return;
    if (self.card.superview != window) {
        [self.card removeFromSuperview];
        [window addSubview:self.card];
    }
    [window bringSubviewToFront:self.card];
    [self applyTheme];
    [self layoutCard];
    [self.positionTimer invalidate];
    __weak YTKACEDownloadProgressView *weakSelf = self;
    self.positionTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES
        block:^(NSTimer *timer) {
            (void)timer;
            [weakSelf layoutCard];
        }];
    if (self.card.alpha < 1.0) {
        self.card.transform = CGAffineTransformMakeTranslation(0.0, 18.0);
        [UIView animateWithDuration:0.32 delay:0.0
            usingSpringWithDamping:0.82 initialSpringVelocity:0.2
            options:UIViewAnimationOptionBeginFromCurrentState animations:^{
                self.card.alpha = 1.0;
                self.card.transform = CGAffineTransformIdentity;
            } completion:nil];
    }
}

- (void)renderItem:(YTKACEDownloadProgressItem *)item {
    if (item == nil) return;
    [self attach];
    [self applyTheme];
    self.titleLabel.text = item.title;
    NSString *count = @"";
    if (self.activeIdentifiers.count > 1) {
        NSUInteger index = [self.activeIdentifiers indexOfObject:item.identifier];
        NSUInteger position = index == NSNotFound ? 1 : index + 1;
        count = [NSString stringWithFormat:@"  •  %lu/%lu active",
            (unsigned long)position, (unsigned long)self.activeIdentifiers.count];
    }
    NSString *bytes = @"";
    if (item.downloadedBytes > 0) {
        NSString *done = [NSByteCountFormatter stringFromByteCount:item.downloadedBytes
            countStyle:NSByteCountFormatterCountStyleFile];
        if (item.totalBytes > 0) {
            NSString *total = [NSByteCountFormatter stringFromByteCount:item.totalBytes
                countStyle:NSByteCountFormatterCountStyleFile];
            bytes = [NSString stringWithFormat:@"  •  %@ / %@", done, total];
        } else {
            bytes = [NSString stringWithFormat:@"  •  %@", done];
        }
    }
    self.statusLabel.text = [NSString stringWithFormat:@"%@%@%@",
        item.stage, bytes, count];
    double progress = isfinite(item.progress)
        ? MIN(MAX(item.progress, 0.0), 1.0) : 0.0;
    self.percentLabel.text = [NSString stringWithFormat:@"%.0f%%", progress * 100.0];
    BOOL sameItem = [self.renderedIdentifier isEqualToString:item.identifier];
    if (sameItem && progress > self.progressView.progress) {
        [UIView animateWithDuration:0.35 delay:0.0
                            options:UIViewAnimationOptionCurveLinear |
                                    UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            [self.progressView setProgress:(float)progress animated:NO];
            [self.progressView layoutIfNeeded];
        } completion:nil];
    } else {
        [self.progressView setProgress:(float)progress animated:NO];
    }
    self.renderedIdentifier = [item.identifier copy];
    self.thumbnailView.image = item.thumbnail;
    self.cancelButton.hidden = [item.stage isEqualToString:YTKACELocalized(@"Merging")] ||
        [item.stage isEqualToString:YTKACELocalized(@"Complete")] ||
        [item.stage isEqualToString:YTKACELocalized(@"Failed")] || [item.stage isEqualToString:YTKACELocalized(@"Cancelled")];
    if ([item.stage isEqualToString:YTKACELocalized(@"Downloading audio")]) {
        self.progressView.progressTintColor = UIColor.systemPurpleColor;
    } else if ([item.stage isEqualToString:YTKACELocalized(@"Downloading video")]) {
        self.progressView.progressTintColor = UIColor.systemBlueColor;
    } else if ([item.stage isEqualToString:YTKACELocalized(@"Merging")]) {
        self.progressView.progressTintColor = UIColor.systemOrangeColor;
    } else if ([item.stage isEqualToString:YTKACELocalized(@"Complete")]) {
        self.progressView.progressTintColor = UIColor.systemGreenColor;
    } else if ([item.stage isEqualToString:YTKACELocalized(@"Failed")]) {
        self.progressView.progressTintColor = UIColor.systemRedColor;
    }
}

- (void)loadThumbnailForItem:(YTKACEDownloadProgressItem *)item {
    if (item.thumbnailURL == nil) return;
    NSString *identifier = item.identifier;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:item.thumbnailURL completionHandler:^(NSData *data,
            NSURLResponse *response, NSError *error) {
        (void)response;
        if (error != nil || data.length == 0) return;
        UIImage *image = [UIImage imageWithData:data];
        if (image == nil) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACEDownloadProgressItem *current = self.items[identifier];
            current.thumbnail = image;
            if ([self.visibleIdentifier isEqualToString:identifier]) [self renderItem:current];
        });
    }];
    [task resume];
}

- (void)cancelPendingDismiss {
    [self.card.layer removeAllAnimations];
    self.card.alpha = 1.0;
    self.card.transform = CGAffineTransformIdentity;
}

- (void)beginJob:(NSString *)identifier
           title:(NSString *)title
    thumbnailURL:(NSURL *)thumbnailURL {
    dispatch_async(dispatch_get_main_queue(), ^{
        YTKACEDownloadProgressItem *item = [YTKACEDownloadProgressItem new];
        item.identifier = identifier;
        item.title = title.length != 0 ? title : YTKACELocalized(@"YouTube Download");
        item.stage = YTKACELocalized(@"Preparing");
        item.thumbnailURL = thumbnailURL;
        self.items[identifier] = item;
        [self.activeIdentifiers removeObject:identifier];
        [self.activeIdentifiers addObject:identifier];
        self.visibleIdentifier = identifier;
        [self cancelPendingDismiss];
        [self renderItem:item];
        [self layoutCard];
        [self loadThumbnailForItem:item];
    });
}

- (void)updateJob:(NSString *)identifier
            stage:(NSString *)stage
         progress:(double)progress
  downloadedBytes:(int64_t)downloadedBytes
       totalBytes:(int64_t)totalBytes {
    dispatch_async(dispatch_get_main_queue(), ^{
        YTKACEDownloadProgressItem *item = self.items[identifier];
        if (item == nil) return;
        BOOL sameStage = [item.stage isEqualToString:stage];
        item.stage = stage;
        double nextProgress = isfinite(progress)
            ? MIN(MAX(progress, 0.0), 1.0) : 0.0;
        int64_t nextBytes = MAX(downloadedBytes, 0);
        item.progress = sameStage ? MAX(item.progress, nextProgress) : nextProgress;
        item.downloadedBytes = sameStage ? MAX(item.downloadedBytes, nextBytes) : nextBytes;
        item.totalBytes = MAX(totalBytes, 0);
        if ([self.visibleIdentifier isEqualToString:identifier]) [self renderItem:item];
    });
}

- (void)finishJob:(NSString *)identifier
          success:(BOOL)success
          message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        YTKACEDownloadProgressItem *item = self.items[identifier];
        if (item == nil) return;
        item.stage = success ? YTKACELocalized(@"Complete") : (message.length != 0 ? message : YTKACELocalized(@"Failed"));
        if (!success && ![item.stage isEqualToString:YTKACELocalized(@"Cancelled")]) item.stage = YTKACELocalized(@"Failed");
        item.progress = success ? 1.0 : item.progress;
        if ([self.visibleIdentifier isEqualToString:identifier]) [self renderItem:item];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            NSUInteger removedIndex = [self.activeIdentifiers indexOfObject:identifier];
            [self.items removeObjectForKey:identifier];
            [self.activeIdentifiers removeObject:identifier];
            if (self.items.count != 0) {
                if ([self.visibleIdentifier isEqualToString:identifier] ||
                    self.items[self.visibleIdentifier] == nil) {
                    NSUInteger nextIndex = removedIndex == NSNotFound ? 0 :
                        MIN(removedIndex, self.activeIdentifiers.count - 1);
                    self.visibleIdentifier = self.activeIdentifiers[nextIndex];
                }
                [self renderItem:self.items[self.visibleIdentifier]];
                [self layoutCard];
                return;
            }
            self.visibleIdentifier = nil;
            [self.positionTimer invalidate];
            self.positionTimer = nil;
            [UIView animateWithDuration:0.22 animations:^{
                self.card.alpha = 0.0;
                self.card.transform = CGAffineTransformMakeTranslation(0.0, 14.0);
            } completion:^(BOOL finished) {
                (void)finished;
                [self.card removeFromSuperview];
                self.card.transform = CGAffineTransformIdentity;
            }];
        });
    });
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    (void)gestureRecognizer;
    return ![touch.view isDescendantOfView:self.cancelButton];
}

- (void)cycleTapped {
    if (self.activeIdentifiers.count < 2) return;
    NSUInteger index = [self.activeIdentifiers indexOfObject:self.visibleIdentifier];
    NSUInteger nextIndex = index == NSNotFound ? 0 :
        (index + 1) % self.activeIdentifiers.count;
    self.visibleIdentifier = self.activeIdentifiers[nextIndex];
    [self renderItem:self.items[self.visibleIdentifier]];
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
}

- (void)cancelTapped {
    NSString *identifier = self.visibleIdentifier;
    if (identifier.length != 0 && self.cancelHandler != nil) self.cancelHandler(identifier);
}

@end
