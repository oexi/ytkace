#import "SponsorPreferences.h"
#import "../Downloads/DownloadLog.h"
#import "../Interface/AiSList.h"
#import "../../YTKACE.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../UI/OverlayButtonHost.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

extern id YTKACESponsorActiveController(void);
extern NSString *YTKACESponsorActiveVideoID(void);
extern NSArray *YTKACESponsorActiveSegments(void);
extern double YTKACESponsorActiveTime(void);
extern double YTKACESponsorActiveDuration(void);
extern void YTKACESponsorSeekActive(double time);
extern NSString *YTKACESponsorActiveHandle(void);
extern void YTKACESponsorSetActiveHandle(NSString *handle);

static NSString * const YTKACESponsorButtonKey = @"YTKACE.Preference.SponsorBlock.OverlayButton";
static NSString * const YTKACESponsorWhitelistKey = @"YTKACE.Preference.SponsorBlock.Whitelist";
static NSString * const YTKACESponsorUserIDKey = @"YTKACE.SponsorBlock.UserID";

static NSString *YTKACESponsorUserID(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *stored = [defaults stringForKey:YTKACESponsorUserIDKey];
    if (stored.length >= 30) return stored;
    NSString *generated = [[NSString stringWithFormat:@"%@%@", NSUUID.UUID.UUIDString, NSUUID.UUID.UUIDString]
        stringByReplacingOccurrencesOfString:@"-" withString:@""];
    [defaults setObject:generated forKey:YTKACESponsorUserIDKey];
    return generated;
}

static NSString *YTKACESponsorTimeText(double seconds) {
    NSInteger total = (NSInteger)floor(MAX(seconds, 0.0));
    NSInteger hours = total / 3600;
    NSInteger minutes = (total / 60) % 60;
    NSInteger secs = total % 60;
    if (hours > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)secs];
}

static NSString *YTKACESponsorTitleForCategory(NSString *category) {
    for (NSDictionary *definition in YTKACESponsorCategoryDefinitions()) {
        if ([definition[@"id"] isEqualToString:category]) return definition[@"title"];
    }
    return category;
}

static UIImage *YTKACESponsorIcon(NSString *symbol) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:19.0 weight:UIImageSymbolWeightRegular];
    UIImage *glyph = [UIImage systemImageNamed:symbol withConfiguration:configuration];
    if (glyph == nil) return [UIImage new];
    CGSize canvas = CGSizeMake(24.0, 24.0);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:canvas format:format]
        imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        CGSize size = glyph.size;
        [glyph drawInRect:CGRectMake((canvas.width - size.width) / 2.0, (canvas.height - size.height) / 2.0,
                                     size.width, size.height)];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static NSDictionary *YTKACESponsorAction(NSString *title, NSString *symbol, BOOL checked, dispatch_block_t handler) {
    return @{@"title": title, @"icon": YTKACESponsorIcon(symbol), @"check": @(checked), @"handler": [handler copy]};
}

static NSDictionary *YTKACESponsorValueAction(NSString *title, NSString *value, NSString *symbol,
                                              dispatch_block_t handler) {
    return @{@"title": title, @"value": value ?: @"", @"icon": YTKACESponsorIcon(symbol), @"handler": [handler copy]};
}

static NSDictionary *YTKACESponsorSubtitledAction(NSString *title, NSString *subtitle, NSString *symbol,
                                                  dispatch_block_t handler) {
    return @{@"title": title, @"subtitle": subtitle ?: @"", @"icon": YTKACESponsorIcon(symbol),
             @"handler": [handler copy]};
}

static void YTKACESponsorLater(dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static void YTKACESponsorPost(NSString *path, NSDictionary *body, NSString *what,
                              void (^completion)(NSInteger status)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[@"https://sponsor.ajay.app" stringByAppendingString:path]]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *text = data.length != 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        YTKACEDownloadLog(@"sponsor", @"%@ status=%ld", what, (long)status);
        YTKACEDebugLog(@"sponsor", @"%@ response=%@ error=%@", what,
                       text.length > 300 ? [text substringToIndex:300] : (text ?: @"-"),
                       error.localizedDescription ?: @"-");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(status); });
    }] resume];
}

static void YTKACESponsorVote(NSDictionary *segment, BOOL up) {
    NSString *uuid = segment[@"uuid"];
    if (uuid.length == 0) {
        YTKACEShowNotice(YTKACELocalized(@"This segment can't be voted on"));
        return;
    }
    YTKACESponsorPost(@"/api/voteOnSponsorTime",
                      @{@"UUID": uuid, @"userID": YTKACESponsorUserID(), @"type": @(up ? 1 : 0)},
                      up ? @"upvote" : @"downvote", ^(NSInteger status) {
        if (status == 200) YTKACEShowNotice(YTKACELocalized(@"Vote sent"));
        else if (status == 429) YTKACEShowNotice(YTKACELocalized(@"Too many votes. Try again later."));
        else YTKACEShowNotice(YTKACELocalized(@"Could not send vote"));
    });
}

static void YTKACESponsorShowSegment(NSDictionary *segment, UIView *source) {
    double start = [segment[@"start"] doubleValue];
    double end = [segment[@"end"] doubleValue];
    NSString *title = [NSString stringWithFormat:@"%@ · %@ – %@", YTKACESponsorTitleForCategory(segment[@"category"]),
                       YTKACESponsorTimeText(start), YTKACESponsorTimeText(end)];
    YTKACEPresentNativeSheet(title, nil, source, @[
        YTKACESponsorAction(YTKACELocalized(@"Upvote"), @"hand.thumbsup", NO, ^{ YTKACESponsorVote(segment, YES); }),
        YTKACESponsorAction(YTKACELocalized(@"Downvote"), @"hand.thumbsdown", NO, ^{ YTKACESponsorVote(segment, NO); }),
        YTKACESponsorAction(YTKACELocalized(@"Jump to Start"), @"arrow.uturn.backward", NO, ^{
            YTKACESponsorSeekActive(start);
        })
    ]);
}

static void YTKACESponsorShowSegments(UIView *source) {
    NSArray *segments = YTKACESponsorActiveSegments();
    if (segments.count == 0) {
        YTKACEShowNotice(YTKACELocalized(@"No segments for this video"));
        return;
    }
    NSMutableArray *actions = [NSMutableArray array];
    for (NSDictionary *segment in segments) {
        NSString *subtitle = [NSString stringWithFormat:@"%@ – %@", YTKACESponsorTimeText([segment[@"start"] doubleValue]),
                              YTKACESponsorTimeText([segment[@"end"] doubleValue])];
        [actions addObject:YTKACESponsorSubtitledAction(YTKACESponsorTitleForCategory(segment[@"category"]), subtitle,
                                                        @"shield", ^{
            YTKACESponsorLater(^{ YTKACESponsorShowSegment(segment, source); });
        })];
    }
    YTKACEPresentNativeSheet(YTKACELocalized(@"Available segments"), nil, source, actions);
}

static double YTKACESponsorMarkStart = -1.0;
static double YTKACESponsorMarkEnd = -1.0;
static NSString *YTKACESponsorMarkVideo;
static void YTKACESponsorResetMarks(void);

static void YTKACESponsorSubmit(NSString *category) {
    NSString *videoID = YTKACESponsorActiveVideoID();
    double start = YTKACESponsorMarkStart;
    double end = YTKACESponsorMarkEnd;
    if (videoID.length == 0 || start < 0.0 || end <= start) {
        YTKACEShowNotice(YTKACELocalized(@"Mark a start and end first"));
        return;
    }
    NSDictionary *body = @{
        @"videoID": videoID,
        @"userID": YTKACESponsorUserID(),
        @"userAgent": [NSString stringWithFormat:@"YTKACE/%@", YTKACEVersion],
        @"videoDuration": @(YTKACESponsorActiveDuration()),
        @"segments": @[@{@"segment": @[@(start), @(end)], @"category": category, @"actionType": @"skip"}]
    };
    YTKACESponsorPost(@"/api/skipSegments", body, @"submit", ^(NSInteger status) {
        if (status == 200) {
            YTKACESponsorResetMarks();
            YTKACEShowNotice(YTKACELocalized(@"Segment submitted"));
        } else if (status == 409) {
            YTKACEShowNotice(YTKACELocalized(@"This segment was already submitted"));
        } else if (status == 429) {
            YTKACEShowNotice(YTKACELocalized(@"Too many submissions. Try again later."));
        } else if (status == 400 || status == 403) {
            YTKACEShowNotice(YTKACELocalized(@"SponsorBlock rejected this segment"));
        } else {
            YTKACEShowNotice(YTKACELocalized(@"Could not reach SponsorBlock"));
        }
    });
}

static void YTKACESponsorPickCategory(UIView *source) {
    NSMutableArray *actions = [NSMutableArray array];
    for (NSDictionary *definition in YTKACESponsorCategoryDefinitions()) {
        NSString *category = definition[@"id"];
        if ([category isEqualToString:@"poi_highlight"]) continue;
        [actions addObject:YTKACESponsorAction(definition[@"title"], @"tag", NO, ^{ YTKACESponsorSubmit(category); })];
    }
    NSString *subtitle = [NSString stringWithFormat:@"%@ – %@", YTKACESponsorTimeText(YTKACESponsorMarkStart),
                          YTKACESponsorTimeText(YTKACESponsorMarkEnd)];
    YTKACEPresentNativeSheet(YTKACELocalized(@"Choose a category"), subtitle, source, actions);
}

static __weak UIButton *YTKACESponsorButton;

static void YTKACESponsorRefreshButton(void) {
    UIButton *button = YTKACESponsorButton;
    BOOL marking = YTKACESponsorMarkStart >= 0.0 && [YTKACESponsorMarkVideo isEqualToString:YTKACESponsorActiveVideoID()];
    button.tintColor = marking ? UIColor.systemRedColor : UIColor.whiteColor;
}

static void YTKACESponsorResetMarks(void) {
    YTKACESponsorMarkStart = -1.0;
    YTKACESponsorMarkEnd = -1.0;
    YTKACESponsorRefreshButton();
}

static void YTKACESponsorToggleWhitelist(NSString *handle) {
    NSString *key = handle.lowercaseString;
    NSMutableArray *list = [[NSUserDefaults.standardUserDefaults arrayForKey:YTKACESponsorWhitelistKey] mutableCopy]
        ?: [NSMutableArray array];
    BOOL listed = [list containsObject:key];
    if (listed) [list removeObject:key];
    else [list addObject:key];
    [NSUserDefaults.standardUserDefaults setObject:list forKey:YTKACESponsorWhitelistKey];
    YTKACESponsorSetActiveHandle(handle);
    YTKACEShowNotice(listed ? YTKACELocalized(@"Channel removed from whitelist")
                            : YTKACELocalized(@"SponsorBlock won't skip on this channel"));
}

static void YTKACESponsorPresentMenu(UIView *source, NSString *handle, NSString *channel, NSString *title) {
    NSString *videoID = YTKACESponsorActiveVideoID();
    if (![YTKACESponsorMarkVideo isEqualToString:videoID]) {
        YTKACESponsorMarkVideo = videoID;
        YTKACESponsorResetMarks();
    }
    NSArray *whitelist = [NSUserDefaults.standardUserDefaults arrayForKey:YTKACESponsorWhitelistKey];
    BOOL listed = handle.length != 0 && [whitelist containsObject:handle.lowercaseString];
    double now = YTKACESponsorActiveTime();
    NSMutableArray *actions = [NSMutableArray array];
    if (handle.length != 0) {
        [actions addObject:YTKACESponsorAction(listed ? YTKACELocalized(@"Remove from whitelist")
                                                      : YTKACELocalized(@"Whitelist this channel"),
                                               listed ? @"star.fill" : @"star", NO, ^{
            YTKACESponsorToggleWhitelist(handle);
        })];
    }
    NSUInteger count = YTKACESponsorActiveSegments().count;
    [actions addObject:YTKACESponsorValueAction(YTKACELocalized(@"Available segments"),
                                                [NSString stringWithFormat:@"%lu", (unsigned long)count], @"list.bullet", ^{
        YTKACESponsorLater(^{ YTKACESponsorShowSegments(source); });
    })];
    if (YTKACESponsorMarkStart < 0.0) {
        [actions addObject:YTKACESponsorValueAction(YTKACELocalized(@"Start a segment here"), YTKACESponsorTimeText(now),
                                                    @"arrow.right.to.line", ^{
            YTKACESponsorMarkStart = YTKACESponsorActiveTime();
            YTKACESponsorMarkEnd = -1.0;
            YTKACESponsorRefreshButton();
            YTKACEShowNotice(YTKACELocalized(@"Start marked. Tap the shield again where it ends."));
        })];
    } else {
        double start = YTKACESponsorMarkStart;
        [actions addObject:YTKACESponsorValueAction(YTKACELocalized(@"End the segment here"),
            [NSString stringWithFormat:@"%@ – %@", YTKACESponsorTimeText(start), YTKACESponsorTimeText(now)],
            @"arrow.left.to.line", ^{
            double end = YTKACESponsorActiveTime();
            if (end <= YTKACESponsorMarkStart + 0.5) {
                YTKACEShowNotice(YTKACELocalized(@"The end has to be after the start"));
                return;
            }
            YTKACESponsorMarkEnd = end;
            YTKACESponsorLater(^{ YTKACESponsorPickCategory(source); });
        })];
        [actions addObject:YTKACESponsorAction(YTKACELocalized(@"Cancel the segment"), @"xmark", NO, ^{
            YTKACESponsorResetMarks();
        })];
    }
    YTKACEPresentNativeSheet(channel.length != 0 ? channel : @"SponsorBlock", title.length != 0 ? title : handle,
                             source, actions);
}

@interface YTKACESponsorMenuTarget : NSObject
+ (instancetype)shared;
- (void)open:(UIButton *)sender;
@end

@implementation YTKACESponsorMenuTarget
+ (instancetype)shared {
    static YTKACESponsorMenuTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTKACESponsorMenuTarget new]; });
    return target;
}

- (void)open:(UIButton *)sender {
    NSString *videoID = YTKACESponsorActiveVideoID();
    NSString *handle = YTKACESponsorActiveHandle();
    (void)handle;
    if (videoID.length == 0) {
        YTKACESponsorPresentMenu(sender, nil, nil, nil);
        return;
    }
    __weak UIButton *weakSender = sender;
    YTKACELookupChannelHandle(videoID, ^(NSString *found, NSString *channel, NSString *title) {
        if (found.length != 0) YTKACESponsorSetActiveHandle(found);
        YTKACESponsorPresentMenu(weakSender, found, channel, title);
    });
}
@end

void YTKACEInstallSponsorMenu(void) {
    YTKACERegisterOverlayConfigurator(@"sponsorblock", ^(__unused UIView *overlay, UIStackView *stack) {
        UIButton *button = YTKACEOverlayButton(stack, @"YTKACE SponsorBlock", @"shield",
                                               YTKACESponsorMenuTarget.shared, @selector(open:));
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightMedium];
        [button setImage:[[UIImage systemImageNamed:@"shield.lefthalf.filled" withConfiguration:configuration]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
        button.hidden = !YTKACEFeatureEnabled(YTKACESponsorButtonKey);
        YTKACESponsorButton = button;
        YTKACESponsorRefreshButton();
    });
}
