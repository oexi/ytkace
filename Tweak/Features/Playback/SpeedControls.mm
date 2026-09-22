#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Assets.h"
#import "../../UI/OverlayButtonHost.h"

#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

static NSMutableDictionary<NSString *, NSNumber *> *YTKACEMaximumRateOriginals;

static NSString * const YTKACELastRateKey = @"YTKACE.Preference.Player.SavedRate";
static NSString * const YTKACEStartRateKey = @"YTKACE.Preference.Player.StartRate";
static NSString * const YTKACELegacyRateKey = @"YTKACE.Preference.Player.DefaultRate";
static NSString * const YTKACELegacyModeKey =
    @"YTKACE.Preference.Player.DefaultRateMode";

static NSString * const YTKACECustomRateKey = @"YTKACE.Preference.Player.CustomRate";

static const double YTKACERateFollowApp = 0.0;
static const double YTKACERateReuseLast = -1.0;
static const double YTKACERateUseCustom = -2.0;
static const double YTKACERateFloor = 0.25;
static const double YTKACERateCeiling = 5.0;

static BOOL YTKACERateIsUsable(double rate) {
    return isfinite(rate) && rate >= YTKACERateFloor && rate <= YTKACERateCeiling;
}

static double YTKACELastPlayedRate(void) {
    double rate = [NSUserDefaults.standardUserDefaults doubleForKey:YTKACELastRateKey];
    return YTKACERateIsUsable(rate) ? rate : 0.0;
}

static NSString * const YTKACERateMigratedKey =
    @"YTKACE.Preference.Player.StartRateMigrated";

static double YTKACEConfiguredStartRate(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:YTKACERateMigratedKey]) {
        return [defaults doubleForKey:YTKACEStartRateKey];
    }
    [defaults setBool:YES forKey:YTKACERateMigratedKey];
    double migrated = YTKACERateFollowApp;
    switch ([defaults integerForKey:YTKACELegacyModeKey]) {
        case 1:
            migrated = YTKACERateReuseLast;
            break;
        case 2: {
            double legacy = [defaults doubleForKey:YTKACELegacyRateKey];
            if (YTKACERateIsUsable(legacy)) {
                [defaults setDouble:legacy forKey:YTKACECustomRateKey];
                migrated = YTKACERateUseCustom;
            }
            break;
        }
        default:
            break;
    }
    [defaults setDouble:migrated forKey:YTKACEStartRateKey];
    return migrated;
}

double YTKACEStartPlaybackRate(void) {
    const double configured = YTKACEConfiguredStartRate();
    if (configured == YTKACERateReuseLast) {
        const double last = YTKACELastPlayedRate();
        return last > 0.0 ? last : 1.0;
    }
    if (configured == YTKACERateUseCustom) {
        const double custom =
            [NSUserDefaults.standardUserDefaults doubleForKey:YTKACECustomRateKey];
        return YTKACERateIsUsable(custom) ? custom : 1.0;
    }
    return YTKACERateIsUsable(configured) ? configured : 1.0;
}

static BOOL YTKACERateCeilingRaised(void) {
    return YTKACEFeatureEnabled(YTKACESpeedKey) || YTKACEStartPlaybackRate() > 2.0;
}

static BOOL YTKACEDeliverRate(id target, NSString *name, double rate) {
    SEL selector = NSSelectorFromString(name);
    if (![target respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 3) return NO;

    NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
    call.target = target;
    call.selector = selector;

    const long long scaled = llround(rate * 100.0);
    switch ([signature getArgumentTypeAtIndex:2][0]) {
        case 'd': {
            double value = rate;
            [call setArgument:&value atIndex:2];
            break;
        }
        case 'f': {
            float value = (float)rate;
            [call setArgument:&value atIndex:2];
            break;
        }
        case '@': {
            id value = @(rate);
            [call setArgument:&value atIndex:2];
            break;
        }
        case 'c': case 'C': {
            char value = (char)scaled;
            [call setArgument:&value atIndex:2];
            break;
        }
        case 's': case 'S': {
            short value = (short)scaled;
            [call setArgument:&value atIndex:2];
            break;
        }
        case 'i': case 'I': {
            int value = (int)scaled;
            [call setArgument:&value atIndex:2];
            break;
        }
        case 'l': case 'L': case 'q': case 'Q': {
            long long value = scaled;
            [call setArgument:&value atIndex:2];
            break;
        }
        default:
            return NO;
    }
    [call invoke];
    return YES;
}

static NSString *YTKACESpeedText(double rate) {
    if (fabs(rate - round(rate)) < 0.001) {
        return [NSString stringWithFormat:@"%.0fx", rate];
    }
    if (fabs(rate * 2.0 - round(rate * 2.0)) < 0.001) {
        return [NSString stringWithFormat:@"%.1fx", rate];
    }
    return [NSString stringWithFormat:@"%.2fx", rate];
}

static UIImage *YTKACESpeedButtonImage(BOOL plus) {
    CGSize size = CGSizeMake(22.0, 22.0);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(context, UIColor.whiteColor.CGColor);
    CGContextSetLineWidth(context, 2.0);
    CGContextAddEllipseInRect(context, CGRectInset((CGRect){CGPointZero, size}, 1.5, 1.5));
    CGContextMoveToPoint(context, 6.5, 11.0);
    CGContextAddLineToPoint(context, 15.5, 11.0);
    if (plus) {
        CGContextMoveToPoint(context, 11.0, 6.5);
        CGContextAddLineToPoint(context, 11.0, 15.5);
    }
    CGContextStrokePath(context);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

@interface YTKACESpeedCoordinator : NSObject
+ (instancetype)sharedCoordinator;
@property(nonatomic, weak) UIView *overlay;
@property(nonatomic, weak) UIButton *valueButton;
@property(nonatomic, weak) id rateSource;
@property(nonatomic, copy) NSString *primedVideo;
@property(nonatomic, assign) double observedRate;
@property(nonatomic, readonly) double currentRate;
- (void)decrease;
- (void)increase;
- (void)reset;
@end

@implementation YTKACESpeedCoordinator

+ (instancetype)sharedCoordinator {
    static YTKACESpeedCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [YTKACESpeedCoordinator new];
    });
    return coordinator;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _observedRate = 0.0;
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(playbackTimeChanged:)
                   name:@"YTKACEPlaybackTimeDidChange"
                 object:nil];
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(preferencesChanged:)
                   name:YTKACEPreferencesDidChangeNotification
                 object:nil];
    }
    return self;
}

- (double)rateFromObject:(id)object depth:(NSUInteger)depth {
    if (object == nil || depth > 2) {
        return 0.0;
    }
    for (NSString *name in @[@"playbackRate", @"currentPlaybackRate", @"rate"]) {
        SEL selector = NSSelectorFromString(name);
        NSMethodSignature *signature = [object methodSignatureForSelector:selector];
        if (![object respondsToSelector:selector] || signature == nil) {
            continue;
        }
        const char *type = signature.methodReturnType;
        double rate = 0.0;
        if (type[0] == 'd') {
            rate = ((double (*)(id, SEL))objc_msgSend)(object, selector);
        } else if (type[0] == 'f') {
            rate = ((float (*)(id, SEL))objc_msgSend)(object, selector);
        } else if (strchr("cislqCISLQ", type[0]) != NULL) {
            rate = ((NSInteger (*)(id, SEL))objc_msgSend)(object, selector);
        } else if (type[0] == '@') {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if ([value respondsToSelector:@selector(doubleValue)]) {
                rate = [value doubleValue];
            }
        }
        if (isfinite(rate) && rate >= 0.25 && rate <= 5.0) {
            return rate;
        }
    }
    for (NSString *name in @[@"eventsDelegate", @"playbackController",
                              @"playerController", @"player"]) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) {
            continue;
        }
        id child = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if (child == object) {
            continue;
        }
        double rate = [self rateFromObject:child depth:depth + 1];
        if (rate >= 0.25) {
            return rate;
        }
    }
    return 0.0;
}

- (NSString *)identifierForSource:(id)source {
    NSString *resolved = nil;
    for (NSString *probe in @[@"currentVideoID", @"videoID", @"videoId"]) {
        SEL selector = NSSelectorFromString(probe);
        if (![source respondsToSelector:selector]) continue;
        id candidate = ((id (*)(id, SEL))objc_msgSend)(source, selector);
        if (![candidate isKindOfClass:NSString.class]) continue;
        if ([candidate length] == 0) continue;
        resolved = candidate;
        break;
    }
    return resolved.length != 0 ? resolved : YTKACELastVideoID();
}

- (BOOL)primeStartRateForSource:(id)source {
    NSString *identifier = [self identifierForSource:source];
    if (identifier.length == 0) return NO;
    if ([self.primedVideo isEqualToString:identifier]) return NO;
    self.primedVideo = identifier;

    const double target = YTKACEStartPlaybackRate();
    if (!YTKACERateIsUsable(target)) return NO;
    const double playing = [self rateFromObject:source depth:0];
    if (fabs(playing - target) < 0.01) return NO;

    [self setRate:target];
    return YES;
}

- (void)preferencesChanged:(NSNotification *)notification {
    NSString *key = notification.userInfo[@"key"];
    if (![key isEqualToString:YTKACEStartRateKey] &&
        ![key isEqualToString:YTKACELegacyRateKey] &&
        ![key isEqualToString:YTKACELegacyModeKey]) {
        return;
    }
    self.primedVideo = nil;
    id source = self.rateSource;
    if ([self rateFromObject:source depth:0] >= 0.25) {
        [self primeStartRateForSource:source];
    }
}

- (void)playbackTimeChanged:(NSNotification *)notification {
    self.rateSource = notification.object;
    if ([self primeStartRateForSource:notification.object]) {
        return;
    }
    double rate = [self rateFromObject:notification.object depth:0];
    if (rate < 0.25) {
        AVPlayer *player = self.activePlayer;
        if (player.rate >= 0.25f) {
            rate = player.rate;
        }
    }
    if (rate < 0.25 || rate > 5.0) {
        return;
    }
    self.observedRate = rate;
    [NSUserDefaults.standardUserDefaults setFloat:(float)rate
                                           forKey:YTKACELastRateKey];
    [self.valueButton setTitle:YTKACESpeedText(rate)
                      forState:UIControlStateNormal];
}

- (id)eventsDelegate {
    SEL selector = NSSelectorFromString(@"eventsDelegate");
    if ([self.overlay respondsToSelector:selector]) {
        return ((id (*)(id, SEL))objc_msgSend)(self.overlay, selector);
    }
    return nil;
}

- (double)currentRate {
    if (isfinite(self.observedRate) && self.observedRate >= 0.25 &&
        self.observedRate <= 5.0) {
        return self.observedRate;
    }
    double saved = YTKACELastPlayedRate();
    return saved >= 0.25 ? saved : 1.0;
}

- (AVPlayer *)activePlayerInLayer:(CALayer *)layer {
    if ([layer isKindOfClass:AVPlayerLayer.class]) {
        AVPlayer *player = ((AVPlayerLayer *)layer).player;
        if (player != nil) {
            return player;
        }
    }
    for (CALayer *child in layer.sublayers) {
        AVPlayer *player = [self activePlayerInLayer:child];
        if (player != nil) {
            return player;
        }
    }
    return nil;
}

- (AVPlayer *)activePlayer {
    UIView *root = self.overlay;
    while (root.superview != nil) {
        root = root.superview;
    }
    return [self activePlayerInLayer:root.layer];
}

- (BOOL)applyRate:(double)rate toObject:(id)object depth:(NSUInteger)depth {
    if (object == nil || depth > 2) {
        return NO;
    }
    if (YTKACEDeliverRate(object, @"setPlaybackRate:", rate)) {
        return YES;
    }
    if (depth == 0 && YTKACEDeliverRate(object, @"setRate:", rate)) {
        return YES;
    }
    for (NSString *name in @[@"eventsDelegate", @"playbackController",
                              @"playerController"]) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) {
            continue;
        }
        id child = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if (child == object) {
            continue;
        }
        if ([self applyRate:rate toObject:child depth:depth + 1]) {
            return YES;
        }
    }
    return NO;
}

- (void)setRate:(double)rate {
    rate = MIN(5.0, MAX(0.25, rate));
    if (![self applyRate:rate toObject:self.eventsDelegate depth:0]) {
        [self applyRate:rate toObject:self.rateSource depth:0];
    }
    [NSUserDefaults.standardUserDefaults setFloat:(float)rate
                                           forKey:YTKACELastRateKey];
    self.observedRate = rate;
    [self.valueButton setTitle:YTKACESpeedText(rate)
                      forState:UIControlStateNormal];
}

- (void)decrease {
    [self setRate:(ceil(self.currentRate * 4.0 - 0.001) - 1.0) / 4.0];
}

- (void)increase {
    [self setRate:(floor(self.currentRate * 4.0 + 0.001) + 1.0) / 4.0];
}

- (void)reset {
    [self setRate:1.0];
}

@end

static IMP YTKACEMaximumOriginal(id receiver, SEL selector) {
    NSString *key = [NSString stringWithFormat:@"%@|%@",
        NSStringFromClass([receiver class]), NSStringFromSelector(selector)];
    return (IMP)(uintptr_t)YTKACEMaximumRateOriginals[key].unsignedLongLongValue;
}

static double YTKACEMaximumPlaybackRateDouble(id receiver, SEL selector) {
    if (YTKACERateCeilingRaised()) {
        return 5.0;
    }
    IMP original = YTKACEMaximumOriginal(receiver, selector);
    return original == NULL
        ? 2.0
        : ((double (*)(id, SEL))original)(receiver, selector);
}

static float YTKACEMaximumPlaybackRateFloat(id receiver, SEL selector) {
    if (YTKACERateCeilingRaised()) {
        return 5.0f;
    }
    IMP original = YTKACEMaximumOriginal(receiver, selector);
    return original == NULL
        ? 2.0f
        : ((float (*)(id, SEL))original)(receiver, selector);
}

static NSInteger YTKACEMaximumPlaybackRateInteger(id receiver, SEL selector) {
    if (YTKACERateCeilingRaised()) {
        return 500;
    }
    IMP original = YTKACEMaximumOriginal(receiver, selector);
    return original == NULL
        ? 2
        : ((NSInteger (*)(id, SEL))original)(receiver, selector);
}

static NSUInteger YTKACEMaximumPlaybackRateUnsigned(id receiver, SEL selector) {
    if (YTKACERateCeilingRaised()) {
        return 500;
    }
    IMP original = YTKACEMaximumOriginal(receiver, selector);
    return original == NULL
        ? 2
        : ((NSUInteger (*)(id, SEL))original)(receiver, selector);
}

static void YTKACEInstallMaximumRateHook(NSString *className,
                                         NSString *selectorName) {
    Class cls = NSClassFromString(className);
    Method method = class_getInstanceMethod(
        cls,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL) {
        return;
    }
    char returnType[16] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    IMP replacement = NULL;
    if (strcmp(returnType, @encode(float)) == 0) {
        replacement = (IMP)YTKACEMaximumPlaybackRateFloat;
    } else if (strcmp(returnType, @encode(double)) == 0) {
        replacement = (IMP)YTKACEMaximumPlaybackRateDouble;
    } else if (strcmp(returnType, @encode(NSInteger)) == 0 ||
               strcmp(returnType, @encode(int)) == 0) {
        replacement = (IMP)YTKACEMaximumPlaybackRateInteger;
    } else if (strcmp(returnType, @encode(NSUInteger)) == 0 ||
               strcmp(returnType, @encode(unsigned int)) == 0) {
        replacement = (IMP)YTKACEMaximumPlaybackRateUnsigned;
    }
    if (replacement != NULL) {
        IMP original = NULL;
        if (YTKACEInstallInstanceHook(className,
                                      selectorName,
                                      replacement,
                                      &original)) {
            NSString *key = [NSString stringWithFormat:@"%@|%@",
                className, selectorName];
            YTKACEMaximumRateOriginals[key] = @((uintptr_t)original);
        }
    }
}

static void YTKACEInstallMaximumRateHooks(void) {
    YTKACEMaximumRateOriginals = [NSMutableDictionary dictionary];
    for (NSString *name in YTKACEAppClassNames()) {
        BOOL candidate = [name containsString:@"GranularVariableSpeedConfig"] ||
            [name containsString:@"PlayerHotConfig"];
        if (!candidate) {
            continue;
        }
        Class cls = NSClassFromString(name);
        if (cls == Nil) {
            continue;
        }
        for (NSString *selector in @[@"maximumPlaybackRate", @"maxPlaybackRate"]) {
            if (class_getInstanceMethod(cls,
                                        NSSelectorFromString(selector)) != NULL) {
                YTKACEInstallMaximumRateHook(name, selector);
            }
        }
    }

}

static NSString *const YTKACEHoldSpeedKey =
    @"YTKACE.Preference.Player.HoldSpeedEnabled";
static NSString *const YTKACEHoldSpeedRateKey =
    @"YTKACE.Preference.Player.HoldSpeedRate";


static IMP OriginalSpeedmasterActivated;
static IMP OriginalSpeedmasterLongPress;

static double YTKACEHoldPreviousRate;
static BOOL YTKACEHoldOverrideActive;

static void YTKACERestoreHoldRate(void);

static void YTKACEApplyHoldRate(NSString *source) {
    const BOOL on = YTKACEFeatureEnabled(YTKACEHoldSpeedKey);
    const double stored =
        [YTKACEPreferenceObject(YTKACEHoldSpeedRateKey) doubleValue];
    (void)source;
    if (!on || stored < 0.25 || stored > 5.0) return;
    if (!YTKACEHoldOverrideActive) {
        const double base = [YTKACESpeedCoordinator sharedCoordinator].currentRate;
        YTKACEHoldPreviousRate =
            (base >= 0.25 && base <= 5.0) ? base : 1.0;
        YTKACEHoldOverrideActive = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[YTKACESpeedCoordinator sharedCoordinator] setRate:stored];
    });
}

static void YTKACERestoreHoldRate(void) {
    if (!YTKACEHoldOverrideActive) return;
    YTKACEHoldOverrideActive = NO;
    const double previous = YTKACEHoldPreviousRate;
    YTKACEHoldPreviousRate = 0.0;
    if (previous < 0.25 || previous > 5.0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[YTKACESpeedCoordinator sharedCoordinator] setRate:previous];
    });
}

static void YTKACESpeedmasterActivated(id receiver, SEL selector, BOOL active) {
    if (OriginalSpeedmasterActivated != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalSpeedmasterActivated)(receiver,
                                                                selector, active);
    }
    if (!active) {
        YTKACERestoreHoldRate();
        return;
    }
    YTKACEApplyHoldRate(@"activated");
}

static void YTKACESpeedmasterLongPress(id receiver, SEL selector,
                                       UILongPressGestureRecognizer *recognizer) {
    if (OriginalSpeedmasterLongPress != NULL) {
        ((void (*)(id, SEL, id))OriginalSpeedmasterLongPress)(receiver, selector,
                                                              recognizer);
    }
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        YTKACEApplyHoldRate(@"longpress");
        return;
    }
    if (recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed) {
        YTKACERestoreHoldRate();
    }
}

static BOOL YTKACELooksLikeSpeedPill(NSString *text) {
    if (text.length < 2 || ![text hasSuffix:@"x"]) return NO;
    NSString *number = [text substringToIndex:text.length - 1];
    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:@"0123456789.,"];
    return [number stringByTrimmingCharactersInSet:allowed].length == 0;
}

static IMP OriginalTextNodeSetAttributedText;

static void YTKACETextNodeSetAttributedText(id receiver, SEL selector,
                                            NSAttributedString *value) {
    NSAttributedString *replacement = value;
    NSString *text = [value isKindOfClass:NSAttributedString.class]
        ? value.string : nil;
    if (text.length != 0 && YTKACEFeatureEnabled(YTKACEHoldSpeedKey) &&
        YTKACELooksLikeSpeedPill(text)) {
        const double stored =
            [YTKACEPreferenceObject(YTKACEHoldSpeedRateKey) doubleValue];
        NSString *wanted = YTKACESpeedText(stored);
        if (stored >= 0.25 && stored <= 5.0 && ![text isEqualToString:wanted]) {
            NSDictionary *attributes = value.length != 0
                ? [value attributesAtIndex:0 effectiveRange:NULL] : @{};
            replacement = [[NSAttributedString alloc] initWithString:wanted
                                                          attributes:attributes];
        }
    }
    if (OriginalTextNodeSetAttributedText != NULL) {
        ((void (*)(id, SEL, id))OriginalTextNodeSetAttributedText)(
            receiver, selector, replacement);
    }
}

static void YTKACEInstallHoldSpeedHooks(void) {
    const BOOL node = YTKACEInstallInstanceHook(
        @"ELMTextNode", @"setAttributedText:",
        (IMP)YTKACETextNodeSetAttributedText, &OriginalTextNodeSetAttributedText);
    const BOOL press = YTKACEInstallInstanceHook(
        @"YTSpeedmasterController", @"speedmasterDidLongPressWithRecognizer:",
        (IMP)YTKACESpeedmasterLongPress, &OriginalSpeedmasterLongPress);
    const BOOL activated = YTKACEInstallInstanceHook(
        @"YTSpeedmasterController", @"setIsSpeedmasterActivated:",
        (IMP)YTKACESpeedmasterActivated, &OriginalSpeedmasterActivated);
    (void)node;
    (void)activated;
    (void)press;
}

void YTKACEInstallSpeedHooks(void) {
    YTKACEInstallHoldSpeedHooks();
    if (YTKACERateCeilingRaised()) {
        YTKACEInstallMaximumRateHooks();
    }
    (void)YTKACESpeedCoordinator.sharedCoordinator;

    YTKACERegisterOverlayConfigurator(@"speed", ^(UIView *overlay, UIStackView *stack) {
        YTKACESpeedCoordinator *coordinator = YTKACESpeedCoordinator.sharedCoordinator;
        coordinator.overlay = overlay;

        UIButton *minus = YTKACEOverlayButton(
            stack,
            @"YTKACE Slower",
            @"minus.circle",
            coordinator,
            @selector(decrease)
        );
        UIButton *value = YTKACEOverlayButton(
            stack,
            @"YTKACE Speed",
            @"speedometer",
            coordinator,
            @selector(reset)
        );
        UIButton *plus = YTKACEOverlayButton(
            stack,
            @"YTKACE Faster",
            @"plus.circle",
            coordinator,
            @selector(increase)
        );
        [minus setImage:YTKACESpeedButtonImage(NO) forState:UIControlStateNormal];
        [plus setImage:YTKACESpeedButtonImage(YES) forState:UIControlStateNormal];
        coordinator.valueButton = value;
        [value setTitle:YTKACESpeedText(coordinator.currentRate)
               forState:UIControlStateNormal];
        [value setImage:nil forState:UIControlStateNormal];
        [value setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        value.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        for (NSLayoutConstraint *constraint in value.constraints) {
            if (constraint.firstAttribute == NSLayoutAttributeWidth) {
                constraint.active = NO;
            }
        }
        [value.widthAnchor constraintGreaterThanOrEqualToConstant:52.0].active = YES;
        value.titleLabel.adjustsFontSizeToFitWidth = NO;
        value.titleLabel.lineBreakMode = NSLineBreakByClipping;
        [value sizeToFit];

        BOOL hidden = !YTKACEFeatureEnabled(YTKACESpeedKey);
        minus.hidden = hidden;
        value.hidden = hidden;
        plus.hidden = hidden;
    });
}
