#import "AiSList.h"
#import "../Downloads/DownloadLog.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../UI/OverlayButtonHost.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSString * const YTKACEAiSListReportKey = @"YTKACE.Preference.Feed.AIChannelReporting";
static NSString * const YTKACEAiSListNameKey = @"YTKACE.Preference.Feed.AIReportName";

BOOL YTKACEAiSListReportingEnabled(void) {
    return YTKACEFeatureEnabled(YTKACEAiSListReportKey);
}

static NSString *YTKACEAiSListHandleFromURL(NSString *url) {
    if (![url isKindOfClass:NSString.class]) return nil;
    NSRange at = [url rangeOfString:@"/@"];
    if (at.location == NSNotFound) return nil;
    NSString *handle = [url substringFromIndex:at.location + 1];
    NSRange end = [handle rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#"]];
    if (end.location != NSNotFound) handle = [handle substringToIndex:end.location];
    handle = handle.stringByRemovingPercentEncoding ?: handle;
    return handle.length >= 3 && handle.length <= 31 ? handle : nil;
}

void YTKACELookupChannelHandle(NSString *videoID, void (^completion)(NSString *handle, NSString *channel,
                                                                     NSString *title)) {
    static NSCache<NSString *, NSDictionary *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSCache new]; });
    NSDictionary *cached = videoID.length != 0 ? [cache objectForKey:videoID] : nil;
    if (cached != nil) {
        completion(cached[@"handle"], cached[@"channel"], cached[@"title"]);
        return;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.youtube.com/oembed"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"url"
                                    value:[@"https://www.youtube.com/watch?v=" stringByAppendingString:videoID]],
        [NSURLQueryItem queryItemWithName:@"format" value:@"json"]
    ];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    request.timeoutInterval = 15.0;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        id json = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *info = [json isKindOfClass:NSDictionary.class] ? json : nil;
        NSString *author = info[@"author_url"];
        NSString *name = [info[@"author_name"] isKindOfClass:NSString.class] ? info[@"author_name"] : nil;
        NSString *title = [info[@"title"] isKindOfClass:NSString.class] ? info[@"title"] : nil;
        NSString *handle = YTKACEAiSListHandleFromURL(author);
        YTKACEDebugLog(@"aislist", @"lookup video=%@ status=%ld author=%@ handle=%@ error=%@", videoID,
                       (long)status, author ?: @"-", handle ?: @"-", error.localizedDescription ?: @"-");
        if (handle.length != 0) {
            NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject:handle forKey:@"handle"];
            if (name != nil) entry[@"channel"] = name;
            if (title != nil) entry[@"title"] = title;
            [cache setObject:entry forKey:videoID];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(handle, name, title); });
    }] resume];
}

static NSString *YTKACEAiSListResultMessage(NSInteger status) {
    switch (status) {
        case 200: return YTKACELocalized(@"Reported to AiSList");
        case 409: return YTKACELocalized(@"This channel was already reported");
        case 429: return YTKACELocalized(@"Too many reports. Try again later.");
        case 400: return YTKACELocalized(@"AiSList could not accept this report");
        default: return YTKACELocalized(@"Could not reach AiSList");
    }
}

static void YTKACEAiSListSubmit(NSString *handle, NSString *videoID, NSString *name) {
    NSDictionary *body = @{
        @"channel_handle": handle,
        @"video_url": [@"https://youtu.be/" stringByAppendingString:videoID],
        @"username": name
    };
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.aisloplist.com"]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"YTKACE" forHTTPHeaderField:@"User-Agent"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *text = data.length != 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        YTKACEDownloadLog(@"aislist", @"report %@ video=%@ status=%ld", handle, videoID, (long)status);
        YTKACEDebugLog(@"aislist", @"report response=%@ error=%@",
                       text.length > 300 ? [text substringToIndex:300] : (text ?: @"-"),
                       error.localizedDescription ?: @"-");
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACEShowNotice(YTKACEAiSListResultMessage(status));
        });
    }] resume];
}

static void YTKACEAiSListConfirm(NSString *handle, NSString *channel, NSString *videoID) {
    NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:YTKACEAiSListNameKey];
    if (name.length == 0) name = @"YTKACE";
    UIImage *icon = [[UIImage systemImageNamed:@"flag"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    YTKACEPresentNativeSheet(channel.length != 0 ? channel : handle, channel.length != 0 ? handle : nil, nil, @[
        @{@"title": YTKACELocalized(@"Report as AI channel"),
          @"icon": icon ?: [UIImage new],
          @"handler": [^{ YTKACEAiSListSubmit(handle, videoID, name); } copy]}
    ]);
}

void YTKACEAiSListReportVideo(NSString *videoID) {
    if (videoID.length != 11) return;
    YTKACEShowNotice(YTKACELocalized(@"Finding channel…"));
    YTKACELookupChannelHandle(videoID, ^(NSString *handle, NSString *channel, __unused NSString *title) {
        if (handle.length == 0) {
            YTKACEShowNotice(YTKACELocalized(@"Could not find this channel's handle"));
            return;
        }
        YTKACEAiSListConfirm(handle, channel, videoID);
    });
}

static NSString *YTKACEAiSListMenuVideoID(id renderers) {
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:@"video_?[Ii]d:\\s*\"([A-Za-z0-9_-]{11})\""
                                                               options:0 error:NULL];
    });
    NSArray *items = [renderers isKindOfClass:NSArray.class] ? renderers : (renderers != nil ? @[renderers] : @[]);
    NSString *found = nil;
    for (id item in items) {
        NSString *dump = nil;
        @try {
            dump = [item description];
        } @catch (__unused NSException *exception) {
            continue;
        }
        if (dump.length == 0) continue;
        for (NSTextCheckingResult *match in [expression matchesInString:dump options:0
                                                                   range:NSMakeRange(0, dump.length)]) {
            NSString *videoID = [dump substringWithRange:[match rangeAtIndex:1]];
            if (found == nil) found = videoID;
            else if (![found isEqualToString:videoID]) return nil;
        }
    }
    return found;
}

id YTKACEAiSListAppendMenuAction(id renderers, id actions) {
    if (!YTKACEAiSListReportingEnabled()) return actions;
    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    NSString *videoID = YTKACEAiSListMenuVideoID(renderers);
    YTKACEDebugLog(@"aislist", @"menu actions=%@ count=%lu first=%@ renderers=%@ video=%@",
                      NSStringFromClass([actions class]),
                      (unsigned long)([actions isKindOfClass:NSArray.class] ? [actions count] : 0),
                      [actions isKindOfClass:NSArray.class] ? NSStringFromClass([[actions firstObject] class]) : @"-",
                      NSStringFromClass([renderers class]), videoID ?: @"-");
    if (![actions isKindOfClass:NSArray.class] || [actions count] == 0) return actions;
    if (actionClass == Nil || ![[actions firstObject] isKindOfClass:actionClass]) return actions;
    if (videoID.length == 0) return actions;
    SEL make = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    if (![actionClass respondsToSelector:make]) return actions;
    UIImage *icon = [[UIImage systemImageNamed:@"flag"]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    void (^handler)(void) = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTKACEAiSListReportVideo(videoID);
        });
    };
    id action = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
        actionClass, make, YTKACELocalized(@"Report AI Channel"), icon, 0, handler);
    if (action == nil) return actions;
    YTKACEDebugLog(@"aislist", @"menu action added video=%@ count=%lu", videoID, (unsigned long)[actions count]);
    return [(NSArray *)actions arrayByAddingObject:action];
}
