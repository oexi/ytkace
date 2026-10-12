#import "AiSList.h"
#import "../Downloads/DownloadLog.h"

#import <os/lock.h>

static NSString * const YTKACEAiSListBlockURL =
    @"https://raw.githubusercontent.com/Override92/AiSList/main/AiSList/aislist_blocklist.txt";
static NSString * const YTKACEAiSListWarnURL =
    @"https://raw.githubusercontent.com/Override92/AiSList/main/AiSList/aislist_warnlist.txt";
static NSString * const YTKACEAiSListFetchedKey = @"YTKACE.AiSList.LastFetch";
static const NSTimeInterval YTKACEAiSListMaxAge = 4 * 60 * 60;

static os_unfair_lock YTKACEAiSListLock = OS_UNFAIR_LOCK_INIT;
static NSSet<NSString *> *YTKACEAiSListBlock;
static NSSet<NSString *> *YTKACEAiSListWarn;
static BOOL YTKACEAiSListLoading;

static NSURL *YTKACEAiSListFile(NSString *name) {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                       inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [base URLByAppendingPathComponent:@"YTKACE" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
                                            attributes:nil error:nil];
    return [directory URLByAppendingPathComponent:name];
}

static NSSet<NSString *> *YTKACEAiSListParse(NSString *text) {
    NSMutableSet<NSString *> *entries = [NSMutableSet set];
    [text enumerateLinesUsingBlock:^(NSString *line, __unused BOOL *stop) {
        NSString *entry = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (entry.length < 3 || [entry hasPrefix:@"!"]) return;
        if ([entry hasPrefix:@"@"]) [entries addObject:entry.lowercaseString];
        else if ([entry hasPrefix:@"UC"] && entry.length == 24) [entries addObject:entry];
    }];
    return entries;
}

static void YTKACEAiSListLoadCached(void) {
    NSString *block = [NSString stringWithContentsOfURL:YTKACEAiSListFile(@"aislist_blocklist.txt")
                                               encoding:NSUTF8StringEncoding error:nil];
    NSString *warn = [NSString stringWithContentsOfURL:YTKACEAiSListFile(@"aislist_warnlist.txt")
                                              encoding:NSUTF8StringEncoding error:nil];
    NSSet *blockSet = block.length != 0 ? YTKACEAiSListParse(block) : nil;
    NSSet *warnSet = warn.length != 0 ? YTKACEAiSListParse(warn) : nil;
    os_unfair_lock_lock(&YTKACEAiSListLock);
    if (blockSet != nil) YTKACEAiSListBlock = blockSet;
    if (warnSet != nil) YTKACEAiSListWarn = warnSet;
    os_unfair_lock_unlock(&YTKACEAiSListLock);
    YTKACEDownloadLog(@"aislist", @"loaded block=%lu warn=%lu", (unsigned long)blockSet.count,
                      (unsigned long)warnSet.count);
}

static NSData *YTKACEAiSListDownload(NSString *url) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.timeoutInterval = 30.0;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *body = nil;
    __block NSInteger status = 0;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, __unused NSError *error) {
        if ([response isKindOfClass:NSHTTPURLResponse.class]) status = ((NSHTTPURLResponse *)response).statusCode;
        if (status == 200 && data.length != 0 && data.length < 8 * 1024 * 1024) body = data;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_SEC)));
    YTKACEDownloadLog(@"aislist", @"fetch %@ status=%ld bytes=%lu", url.lastPathComponent, (long)status,
                      (unsigned long)body.length);
    return body;
}

void YTKACEAiSListRefreshIfStale(void) {
    os_unfair_lock_lock(&YTKACEAiSListLock);
    BOOL busy = YTKACEAiSListLoading;
    BOOL loaded = YTKACEAiSListBlock != nil || YTKACEAiSListWarn != nil;
    if (!busy) YTKACEAiSListLoading = YES;
    os_unfair_lock_unlock(&YTKACEAiSListLock);
    if (busy) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!loaded) YTKACEAiSListLoadCached();
        double last = [NSUserDefaults.standardUserDefaults doubleForKey:YTKACEAiSListFetchedKey];
        BOOL stale = NSDate.date.timeIntervalSince1970 - last > YTKACEAiSListMaxAge;
        os_unfair_lock_lock(&YTKACEAiSListLock);
        BOOL empty = YTKACEAiSListBlock == nil && YTKACEAiSListWarn == nil;
        os_unfair_lock_unlock(&YTKACEAiSListLock);
        if (stale || empty) {
            NSData *block = YTKACEAiSListDownload(YTKACEAiSListBlockURL);
            NSData *warn = YTKACEAiSListDownload(YTKACEAiSListWarnURL);
            if (block != nil) [block writeToURL:YTKACEAiSListFile(@"aislist_blocklist.txt") atomically:YES];
            if (warn != nil) [warn writeToURL:YTKACEAiSListFile(@"aislist_warnlist.txt") atomically:YES];
            if (block != nil || warn != nil) {
                [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970
                                                        forKey:YTKACEAiSListFetchedKey];
                YTKACEAiSListLoadCached();
            }
        }
        os_unfair_lock_lock(&YTKACEAiSListLock);
        YTKACEAiSListLoading = NO;
        os_unfair_lock_unlock(&YTKACEAiSListLock);
    });
}

BOOL YTKACEAiSListReady(void) {
    os_unfair_lock_lock(&YTKACEAiSListLock);
    BOOL ready = YTKACEAiSListBlock.count != 0 || YTKACEAiSListWarn.count != 0;
    os_unfair_lock_unlock(&YTKACEAiSListLock);
    return ready;
}

static BOOL YTKACEAiSListHandleByte(unsigned char byte) {
    return isalnum(byte) || byte == '_' || byte == '-' || byte == '.' || byte >= 0x80;
}

BOOL YTKACEAiSListMatches(NSData *bytes, BOOL blocklist, BOOL warnlist, NSString **matched) {
    if (bytes.length == 0 || (!blocklist && !warnlist)) return NO;
    os_unfair_lock_lock(&YTKACEAiSListLock);
    NSSet<NSString *> *block = blocklist ? YTKACEAiSListBlock : nil;
    NSSet<NSString *> *warn = warnlist ? YTKACEAiSListWarn : nil;
    os_unfair_lock_unlock(&YTKACEAiSListLock);
    if (block.count == 0 && warn.count == 0) return NO;
    const unsigned char *raw = (const unsigned char *)bytes.bytes;
    NSUInteger length = bytes.length;
    NSMutableSet<NSString *> *handles = [NSMutableSet set];
    NSMutableSet<NSString *> *channels = [NSMutableSet set];
    for (NSUInteger i = 2; i < length; i++) {
        if (raw[i] == '@') {
            NSUInteger size = 0;
            if (raw[i - 1] == '/' && i >= 3 && (raw[i - 3] & 0x07) == 2) size = (NSUInteger)raw[i - 2] - 1;
            else if ((raw[i - 2] & 0x07) == 2) size = raw[i - 1];
            if (size < 4 || size > 100 || i + size > length) continue;
            BOOL valid = YES;
            for (NSUInteger k = i + 1; k < i + size && valid; k++) valid = YTKACEAiSListHandleByte(raw[k]);
            if (!valid) continue;
            NSString *handle = [[NSString alloc] initWithBytes:raw + i length:size encoding:NSUTF8StringEncoding];
            if (handle != nil) [handles addObject:handle.lowercaseString];
        } else if (raw[i] == 'U' && i + 24 <= length && raw[i + 1] == 'C' &&
                   (raw[i - 1] == 24 || raw[i - 1] == '/')) {
            BOOL valid = YES;
            for (NSUInteger k = i + 2; k < i + 24 && valid; k++)
                valid = isalnum(raw[k]) || raw[k] == '_' || raw[k] == '-';
            if (!valid) continue;
            NSString *channel = [[NSString alloc] initWithBytes:raw + i length:24 encoding:NSASCIIStringEncoding];
            if (channel != nil) [channels addObject:channel];
        }
    }
    if (channels.count > 1) return NO;
    for (NSSet<NSString *> *candidates in @[handles, channels]) {
        for (NSString *candidate in candidates) {
            if ([block containsObject:candidate] || [warn containsObject:candidate]) {
                if (matched != NULL) *matched = candidate;
                return YES;
            }
        }
    }
    return NO;
}
