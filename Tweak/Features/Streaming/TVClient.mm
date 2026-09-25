#import "../../YTKACE.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>

static NSString *const YTKACETVName = @"TVHTML5";
static NSString *const YTKACETVVersion = @"7.20260707.07.00";
static NSString *const YTKACETVNumber = @"7";
static NSString *const YTKACETVDeviceMake = @"Sony";
static NSString *const YTKACETVDeviceModel = @"PS4";
static NSString *const YTKACETVOSName = @"PlayStation 4";
static NSString *const YTKACETVPlatform = @"GAME_CONSOLE";
static NSString *const YTKACETVUserAgent =
    @"Mozilla/5.0 (PS4; Leanback Shell) Gecko/20100101 Firefox/65.0 "
     "LeanbackShell/01.00.01.75 Sony PS4/ (PS4, , no, CH)";
static NSString *const YTKACETVVisitorKey = @"YTKACE.Cache.TVVisitor";
static NSString *const YTKACETVTimestampKey = @"YTKACE.Cache.TVSignatureTimestamps";
static const NSTimeInterval YTKACETVVisitorLifetime = 30.0 * 24.0 * 60.0 * 60.0;

static NSDictionary *YTKACETVContext(NSString *visitor) {
    NSMutableDictionary *client = [@{
        @"clientName": YTKACETVName, @"clientVersion": YTKACETVVersion,
        @"platform": YTKACETVPlatform, @"deviceMake": YTKACETVDeviceMake,
        @"deviceModel": YTKACETVDeviceModel, @"osName": YTKACETVOSName, @"osVersion": @"",
        @"hl": @"en-GB", @"gl": @"GB", @"utcOffsetMinutes": @0} mutableCopy];
    if (visitor.length != 0) client[@"visitorData"] = visitor;
    return @{@"client": client, @"request": @{@"useSsl": @YES},
             @"user": @{@"lockedSafetyMode": @NO}};
}

NSDictionary<NSString *, NSString *> *YTKACETVHeaders(NSString *visitor) {
    NSMutableDictionary *headers = [@{
        @"User-Agent": YTKACETVUserAgent, @"X-YouTube-Client-Name": YTKACETVNumber,
        @"X-YouTube-Client-Version": YTKACETVVersion, @"Origin": @"https://www.youtube.com"} mutableCopy];
    if (visitor.length != 0) headers[@"X-Goog-Visitor-Id"] = visitor;
    return headers;
}

static void YTKACETVAppendField(NSMutableData *data, uint64_t key, NSData *value) {
    while (key >= 0x80) { uint8_t byte = (uint8_t)(key | 0x80); [data appendBytes:&byte length:1]; key >>= 7; }
    uint8_t last = (uint8_t)key;
    [data appendBytes:&last length:1];
    if (value == nil) return;
    uint64_t length = value.length;
    while (length >= 0x80) { uint8_t byte = (uint8_t)(length | 0x80); [data appendBytes:&byte length:1]; length >>= 7; }
    uint8_t tail = (uint8_t)length;
    [data appendBytes:&tail length:1];
    [data appendData:value];
}

NSData *YTKACETVClientInfo(void) {
    NSMutableData *data = [NSMutableData data];
    NSData *(^text)(NSString *) = ^NSData *(NSString *value) {
        return [value dataUsingEncoding:NSUTF8StringEncoding];
    };
    YTKACETVAppendField(data, (12 << 3) | 2, text(YTKACETVDeviceMake));
    YTKACETVAppendField(data, (13 << 3) | 2, text(YTKACETVDeviceModel));
    YTKACETVAppendField(data, (16 << 3) | 0, nil);
    uint8_t name = 7;
    [data appendBytes:&name length:1];
    YTKACETVAppendField(data, (17 << 3) | 2, text(YTKACETVVersion));
    YTKACETVAppendField(data, (18 << 3) | 2, text(YTKACETVOSName));
    YTKACETVAppendField(data, (21 << 3) | 2, text(@"en"));
    YTKACETVAppendField(data, (22 << 3) | 2, text(@"GB"));
    return data;
}

static NSData *YTKACETVFetch(NSURLRequest *request, NSInteger *status) {
    __block NSData *result = nil;
    __block NSInteger code = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, __unused NSError *error) {
        result = data;
        code = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    if (status != NULL) *status = code;
    return result;
}

static NSMutableURLRequest *YTKACETVRequest(NSString *path, NSDictionary *body, NSString *visitor) {
    NSURL *URL = [NSURL URLWithString:[@"https://youtubei.googleapis.com/youtubei/v1/" stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *headers = YTKACETVHeaders(visitor);
    for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];
    return request;
}

static NSString *YTKACETVVisitor(BOOL refresh) {
    NSDictionary *cached = YTKACEPreferenceObject(YTKACETVVisitorKey);
    if (!refresh && [cached isKindOfClass:NSDictionary.class]) {
        NSString *value = cached[@"id"];
        NSNumber *time = cached[@"time"];
        if ([value isKindOfClass:NSString.class] && value.length != 0 &&
            NSDate.date.timeIntervalSince1970 - time.doubleValue < YTKACETVVisitorLifetime) {
            return value;
        }
    }
    NSInteger status = 0;
    NSData *data = YTKACETVFetch(YTKACETVRequest(
        @"guide?prettyPrint=false&fields=responseContext.visitorData",
        @{@"context": YTKACETVContext(nil)}, nil), &status);
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *visitor = [json isKindOfClass:NSDictionary.class] ? json[@"responseContext"][@"visitorData"] : nil;
    if ([visitor isKindOfClass:NSString.class] && visitor.length != 0) {
        YTKACESetPreferenceObject(YTKACETVVisitorKey,
            @{@"id": visitor, @"time": @(NSDate.date.timeIntervalSince1970)});
        return visitor;
    }
    YTKACEDownloadLog(@"tv", @"visitor failed http=%ld", (long)status);
    return nil;
}

static NSString *YTKACETVFirstMatch(NSString *text, NSString *pattern) {
    if (text.length == 0) return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match ? [text substringWithRange:[match rangeAtIndex:1]] : nil;
}

static BOOL YTKACETVPlayer(NSString **playerID, NSString **playerJS, NSInteger *timestamp) {
    static NSString *cachedIdentifier;
    static CFAbsoluteTime cachedAt;
    NSString *identifier = nil;
    @synchronized (YTKACETVTimestampKey) {
        if (cachedIdentifier.length != 0 && CFAbsoluteTimeGetCurrent() - cachedAt < 6.0 * 60.0 * 60.0) {
            identifier = cachedIdentifier;
        }
    }
    if (identifier.length == 0) {
        NSData *api = YTKACETVFetch([NSURLRequest requestWithURL:
            [NSURL URLWithString:@"https://www.youtube.com/iframe_api"]], NULL);
        identifier = YTKACETVFirstMatch(
            api ? [[NSString alloc] initWithData:api encoding:NSUTF8StringEncoding] : nil,
            @"player\\\\?/([0-9a-f]{8})\\\\?/");
        if (identifier.length == 0) return NO;
        @synchronized (YTKACETVTimestampKey) {
            cachedIdentifier = identifier;
            cachedAt = CFAbsoluteTimeGetCurrent();
        }
    }
    *playerID = identifier;
    NSDictionary *known = YTKACEPreferenceObject(YTKACETVTimestampKey);
    NSNumber *stored = [known isKindOfClass:NSDictionary.class] ? known[identifier] : nil;
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    NSString *prepared = [caches URLByAppendingPathComponent:
        [NSString stringWithFormat:@"YTKACE-player-%@.js", identifier]].path;
    if (stored != nil && [NSFileManager.defaultManager fileExistsAtPath:prepared]) {
        *timestamp = stored.integerValue;
        return YES;
    }
    NSString *address = [NSString stringWithFormat:
        @"https://www.youtube.com/s/player/%@/player_ias.vflset/en_US/base.js", identifier];
    NSData *js = YTKACETVFetch([NSURLRequest requestWithURL:[NSURL URLWithString:address]], NULL);
    NSString *source = js ? [[NSString alloc] initWithData:js encoding:NSUTF8StringEncoding] : nil;
    NSString *value = YTKACETVFirstMatch(source, @"(?:signatureTimestamp|sts)\\s*:\\s*(\\d{5})");
    if (source.length == 0) return NO;
    *playerJS = source;
    *timestamp = value.integerValue;
    NSMutableDictionary *updated = [known isKindOfClass:NSDictionary.class] ? [known mutableCopy] : [NSMutableDictionary dictionary];
    if (updated.count > 8) [updated removeAllObjects];
    updated[identifier] = @(value.integerValue);
    YTKACESetPreferenceObject(YTKACETVTimestampKey, updated);
    return YES;
}

void YTKACETVFetchPlayerResponse(NSString *videoID, void (^completion)(id _Nullable response,
                                                                      NSString * _Nullable visitor,
                                                                      NSError * _Nullable error)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *(^failure)(NSString *) = ^NSError *(NSString *message) {
            YTKACEDownloadLog(@"tv", @"video=%@ %@", videoID, message);
            return [NSError errorWithDomain:@"YTKACETVClient" code:1
                                   userInfo:@{NSLocalizedDescriptionKey: message}];
        };
        NSString *playerID = nil, *playerJS = nil;
        NSInteger timestamp = 0;
        if (!YTKACETVPlayer(&playerID, &playerJS, &timestamp)) {
            completion(nil, nil, failure(@"player script unavailable"));
            return;
        }
        id response = nil;
        NSString *visitor = nil;
        NSString *reason = nil;
        for (NSInteger attempt = 0; attempt < 2 && response == nil; attempt++) {
            visitor = YTKACETVVisitor(attempt > 0);
            NSMutableDictionary *body = [@{
                @"context": YTKACETVContext(visitor), @"videoId": videoID,
                @"contentCheckOk": @YES, @"racyCheckOk": @YES} mutableCopy];
            if (timestamp != 0) {
                body[@"playbackContext"] = @{@"contentPlaybackContext": @{
                    @"html5Preference": @"HTML5_PREF_WANTS", @"signatureTimestamp": @(timestamp)}};
            }
            NSInteger status = 0;
            NSData *proto = YTKACETVFetch(YTKACETVRequest(@"player?alt=proto", body, visitor), &status);
            Class responseClass = NSClassFromString(@"YTIPlayerResponse");
            id parsed = responseClass && proto.length
                ? ((id (*)(id, SEL, id, NSError **))objc_msgSend)([responseClass alloc],
                    NSSelectorFromString(@"initWithData:error:"), proto, NULL) : nil;
            id streaming = [parsed valueForKey:@"streamingData"];
            NSString *serverURL = [streaming valueForKey:@"serverAbrStreamingURL"];
            if ([serverURL isKindOfClass:NSString.class] && serverURL.length != 0) {
                response = parsed;
            } else {
                id playability = [parsed valueForKey:@"playabilityStatus"];
                reason = [NSString stringWithFormat:@"no stream http=%ld reason=%@", (long)status,
                          [playability valueForKey:@"reason"] ?: @"none"];
            }
        }
        if (response == nil) {
            completion(nil, nil, failure(reason ?: @"no response"));
            return;
        }
        id streaming = [response valueForKey:@"streamingData"];
        NSString *serverURL = [streaming valueForKey:@"serverAbrStreamingURL"];
        NSString *solved = YTKACESolveURLParameterN(playerID, playerJS, serverURL);
        if ([solved isEqualToString:serverURL] && [serverURL containsString:@"&n="]) {
            completion(nil, nil, failure(@"n challenge unsolved"));
            return;
        }
        [streaming setValue:solved forKey:@"serverAbrStreamingURL"];
        YTKACEDownloadLog(@"tv", @"video=%@ ready player=%@", videoID, playerID);
        completion(response, visitor, nil);
    });
}
