#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "DownloadCoordinator.h"
#import "DownloadLog.h"
#import "SABRDownloader.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTKACEPlaylistDownloadKey =
    @"YTKACE.Preference.Downloads.PlaylistEnabled";
static NSInteger const YTKACEPlaylistButtonTag = 0x59544B50;

static IMP OriginalPlaylistContents;
static IMP OriginalPlaylistHeaderModel;

static NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *YTKACEPlaylistItems;
static NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *YTKACEPlaylistSeen;
static NSString *YTKACECurrentPlaylistID;
static __weak UIViewController *YTKACEPlaylistBrowseController;
static NSString *YTKACECurrentPlaylistTitle;

static NSArray<NSDictionary *> *YTKACECurrentPlaylistItems(void);

static BOOL YTKACEPlaylistDownloadEnabled(void) {
    return YTKACEDownloadsEnabled() &&
        YTKACEFeatureEnabled(YTKACEPlaylistDownloadKey);
}

static id YTKACEPlaylistValue(id object, NSString *name) {
    if (object == nil) return nil;
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *YTKACEPlaylistText(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    for (NSString *name in @[@"text", @"simpleText", @"string"]) {
        id nested = YTKACEPlaylistValue(value, name);
        if ([nested isKindOfClass:NSString.class]) return nested;
    }
    return nil;
}

static id YTKACEPlaylistVideoRenderer(id entry) {
    id direct = YTKACEPlaylistValue(entry, @"playlistVideoRenderer");
    if (direct != nil) return direct;
    if (YTKACEPlaylistValue(entry, @"videoId") != nil) return entry;
    for (NSString *name in @[@"playlistPanelVideoRenderer", @"videoRenderer",
                             @"compactVideoRenderer", @"gridVideoRenderer"]) {
        id nested = YTKACEPlaylistValue(entry, name);
        if (nested != nil) return nested;
    }
    return nil;
}

static void YTKACERecordPlaylistItem(NSString *playlistID, id renderer) {
    NSString *videoID = YTKACEPlaylistText(YTKACEPlaylistValue(renderer, @"videoId"));
    if (videoID.length == 0) return;
    NSMutableSet<NSString *> *seen = YTKACEPlaylistSeen[playlistID];
    if (seen == nil) {
        seen = [NSMutableSet set];
        YTKACEPlaylistSeen[playlistID] = seen;
        YTKACEPlaylistItems[playlistID] = [NSMutableArray array];
    }
    if ([seen containsObject:videoID]) return;
    [seen addObject:videoID];
    NSString *title = YTKACEPlaylistText(YTKACEPlaylistValue(renderer, @"title"));
    NSString *author = YTKACEPlaylistText(
        YTKACEPlaylistValue(renderer, @"shortBylineText")) ?:
        YTKACEPlaylistText(YTKACEPlaylistValue(renderer, @"longBylineText"));
    [YTKACEPlaylistItems[playlistID] addObject:@{
        @"videoId": videoID,
        @"title": title ?: videoID,
        @"author": author ?: @""
    }];
}

static NSArray *YTKACEPlaylistContents(id receiver, SEL selector) {
    NSArray *items = OriginalPlaylistContents == NULL ? nil :
        ((id (*)(id, SEL))OriginalPlaylistContents)(receiver, selector);
    if (![items isKindOfClass:NSArray.class] || items.count == 0) return items;
    NSString *playlistID = YTKACEPlaylistText(
        YTKACEPlaylistValue(receiver, @"playlistId"));
    if (playlistID.length == 0) playlistID = YTKACECurrentPlaylistID;
    if (playlistID.length == 0) return items;
    NSUInteger before = YTKACEPlaylistItems[playlistID].count;
    for (id entry in items) {
        id renderer = YTKACEPlaylistVideoRenderer(entry);
        if (renderer != nil) YTKACERecordPlaylistItem(playlistID, renderer);
    }
    NSUInteger after = YTKACEPlaylistItems[playlistID].count;
    if (after != before) {
        YTKACECurrentPlaylistID = playlistID;
    }
    return items;
}

static void YTKACEPlaylistHeaderModel(id receiver, SEL selector, id model) {
    if (OriginalPlaylistHeaderModel != NULL) {
        ((void (*)(id, SEL, id))OriginalPlaylistHeaderModel)(receiver, selector, model);
    }
    id renderer = YTKACEPlaylistValue(model, @"playlistHeaderRenderer") ?: model;
    NSString *playlistID = YTKACEPlaylistText(
        YTKACEPlaylistValue(renderer, @"playlistId"));
    if (playlistID.length == 0) return;
    YTKACECurrentPlaylistID = playlistID;
    YTKACECurrentPlaylistTitle =
        YTKACEPlaylistText(YTKACEPlaylistValue(renderer, @"title")) ?: @"";
}

static NSMutableDictionary<NSString *, UIImage *> *YTKACEPlaylistThumbnails;

static UIImage *YTKACEPlaylistPlaceholderImage(void) {
    static UIImage *placeholder;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGSize size = CGSizeMake(80.0, 45.0);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
        [[UIColor colorWithWhite:0.25 alpha:1.0] setFill];
        UIRectFill(CGRectMake(0.0, 0.0, size.width, size.height));
        placeholder = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return placeholder;
}

@interface YTKACEPlaylistPickerController : UITableViewController
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@property(nonatomic, strong) NSMutableSet<NSString *> *selection;
@property(nonatomic, copy) void (^onDone)(NSSet<NSString *> *selection);
@end

@implementation YTKACEPlaylistPickerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = YTKACELocalized(@"Select videos");
    self.tableView.allowsMultipleSelection = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:YTKACELocalized(@"Done")
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(finish)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:YTKACELocalized(@"Select all")
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(toggleAll)];
}

- (void)finish {
    if (self.onDone != nil) self.onDone(self.selection);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)toggleAll {
    if (self.selection.count == self.items.count) {
        [self.selection removeAllObjects];
    } else {
        for (NSDictionary *item in self.items) {
            [self.selection addObject:item[@"videoId"]];
        }
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.items.count;
}

- (CGFloat)tableView:(UITableView *)tableView
heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 64.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ytkace"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"ytkace"];
    }
    NSDictionary *item = self.items[(NSUInteger)indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.text = item[@"author"];
    cell.accessoryType = [self.selection containsObject:item[@"videoId"]]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.imageView.image = YTKACEPlaylistPlaceholderImage();
    NSString *thumbnail = item[@"thumbnail"];
    NSString *videoID = item[@"videoId"];
    if (thumbnail.length != 0) {
        UIImage *cached = YTKACEPlaylistThumbnails[videoID];
        if (cached != nil) {
            cell.imageView.image = cached;
        } else {
            __weak UITableView *weakTable = tableView;
            dispatch_async(dispatch_get_global_queue(
                DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                NSData *data = [NSData dataWithContentsOfURL:
                    [NSURL URLWithString:thumbnail]];
                UIImage *image = data != nil ? [UIImage imageWithData:data] : nil;
                if (image == nil) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    YTKACEPlaylistThumbnails[videoID] = image;
                    [weakTable reloadRowsAtIndexPaths:@[indexPath]
                                     withRowAnimation:UITableViewRowAnimationNone];
                });
            });
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.items[(NSUInteger)indexPath.row];
    NSString *videoID = item[@"videoId"];
    if ([self.selection containsObject:videoID]) {
        [self.selection removeObject:videoID];
    } else {
        [self.selection addObject:videoID];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    [tableView reloadRowsAtIndexPaths:@[indexPath]
                     withRowAnimation:UITableViewRowAnimationNone];
}

@end

static UIViewController *YTKACEPlaylistTopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static UIViewController *YTKACEOwningController(UIView *view) {
    UIResponder *responder = view;
    for (NSUInteger depth = 0; responder != nil && depth < 24; depth++) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static UIView *YTKACESheetAnchorForView(UIView *source) {
    if (source == nil || source.window == nil) return source;
    UIViewController *owner = YTKACEOwningController(source);
    UIViewController *browse = YTKACEPlaylistBrowseController;
    UIView *host = browse.viewIfLoaded ?: owner.viewIfLoaded;
    if (host == nil || host.window == nil) {
        host = YTKACEPlaylistTopController().viewIfLoaded;
    }
    if (host == nil) return source;
    if ([source isDescendantOfView:host]) return source;
    static UIView *anchor;
    if (anchor == nil) {
        anchor = [[UIView alloc] initWithFrame:CGRectZero];
        anchor.userInteractionEnabled = NO;
        anchor.backgroundColor = UIColor.clearColor;
        anchor.accessibilityIdentifier = @"YTKACE Sheet Anchor";
    }
    if (anchor.superview != host) {
        [anchor removeFromSuperview];
        [host addSubview:anchor];
    }
    anchor.frame = [source convertRect:source.bounds toView:host];
    [host sendSubviewToBack:anchor];
    return anchor;
}

static void YTKACEWaitForIdleDownloads(NSUInteger attempt,
                                       dispatch_block_t next) {
    NSUInteger active = [YTKACEDownloadCoordinator.sharedCoordinator activeJobCount];
    if (active == 0 || attempt > 1200) {
        if (attempt > 1200) {
            YTKACEDownloadLog(@"playlist", @"idle wait timed out active=%lu",
                (unsigned long)active);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTKACEWaitForIdleDownloads(attempt + 1, next);
        });
}

static void YTKACERunPlaylistQueue(NSArray<NSDictionary *> *queue,
                                   NSUInteger index,
                                   NSInteger quality,
                                   BOOL audioOnly,
                                   BOOL savesToPhotos,
                                   BOOL sharesFile,
                                   NSUInteger started,
                                   NSUInteger failed) {
    if (index >= queue.count) {
        YTKACEDownloadLog(@"playlist", @"queue finished started=%lu failed=%lu",
            (unsigned long)started, (unsigned long)failed);
        NSString *message = failed == 0
            ? [NSString stringWithFormat:
                YTKACELocalized(@"Downloaded %lu videos"), (unsigned long)started]
            : [NSString stringWithFormat:
                YTKACELocalized(@"Downloaded %lu videos, %lu unavailable"),
                (unsigned long)started, (unsigned long)failed];
        if (started == 0 && failed != 0) {
            YTKACEDiscardRestoredRequest();
            message = YTKACELocalized(
                @"Play any video once to refresh downloads, then try again.");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACEShowNotice(message);
            [YTKACEDownloadCoordinator.sharedCoordinator
                flushBatchSharingFromView:nil];
        });
        return;
    }
    NSDictionary *item = queue[index];
    NSString *videoID = item[@"videoId"];
    YTKACEResolvePlayerResponse(videoID, ^(id playerResponse, NSError *error) {
        BOOL queued = NO;
        if (playerResponse != nil) {
            queued = [YTKACEDownloadCoordinator.sharedCoordinator
                enqueueDownloadForResponse:playerResponse
                                   quality:quality
                                 audioOnly:audioOnly
                             savesToPhotos:savesToPhotos
                                sharesFile:sharesFile];
        }
        YTKACEDownloadLog(@"playlist", @"item %lu/%lu video=%@ queued=%d error=%@",
            (unsigned long)(index + 1), (unsigned long)queue.count, videoID,
            queued, error.localizedDescription ?: @"none");
        YTKACEWaitForIdleDownloads(0, ^{
            YTKACERunPlaylistQueue(queue, index + 1, quality, audioOnly,
                savesToPhotos, sharesFile, started + (queued ? 1 : 0),
                failed + (queued ? 0 : 1));
        });
    });
}

static void YTKACEStartPlaylistDownload(NSArray<NSDictionary *> *items,
                                        NSSet<NSString *> *selection,
                                        NSInteger quality,
                                        BOOL audioOnly,
                                        UIView *source) {
    NSMutableArray<NSDictionary *> *queue = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (selection == nil || [selection containsObject:item[@"videoId"]]) {
            [queue addObject:item];
        }
    }
    if (queue.count == 0) {
        YTKACEShowNotice(YTKACELocalized(@"No videos selected"));
        return;
    }
    if (!YTKACEPlaybackTemplateReady()) {
        YTKACEShowNotice(YTKACELocalized(
            @"Play any video once so YTKACE can prepare downloads, then try again."));
        return;
    }
    YTKACEDownloadLog(@"playlist", @"start count=%lu quality=%ld audioOnly=%d",
        (unsigned long)queue.count, (long)quality, audioOnly);
    [YTKACEDownloadCoordinator.sharedCoordinator
        resolvePlaylistDestinationFromView:source
                                 audioOnly:audioOnly
                                      then:^(BOOL savesToPhotos,
                                             BOOL sharesFile) {
            YTKACEShowNotice([NSString stringWithFormat:
                YTKACELocalized(@"Preparing %lu videos"),
                (unsigned long)queue.count]);
            if (sharesFile) {
                [YTKACEDownloadCoordinator.sharedCoordinator beginBatchSharing];
            }
            YTKACEWaitForIdleDownloads(0, ^{
                YTKACERunPlaylistQueue(queue, 0, quality, audioOnly,
                                       savesToPhotos, sharesFile, 0, 0);
            });
        }];
}

static void YTKACEPresentCustomQualityMenu(UIView *source,
                                           NSArray<NSDictionary *> *items,
                                           NSSet<NSString *> *selection) {
    YTKACEDownloadCoordinator *coordinator =
        YTKACEDownloadCoordinator.sharedCoordinator;
    NSArray<NSArray *> *heights = @[
        @[YTKACELocalized(@"Up to 1080p"), @1080],
        @[YTKACELocalized(@"Up to 720p"), @720],
        @[YTKACELocalized(@"Up to 480p"), @480],
        @[YTKACELocalized(@"Up to 360p"), @360]
    ];
    NSMutableArray *actions = [NSMutableArray array];
    for (NSArray *choice in heights) {
        NSInteger cap = [choice[1] integerValue];
        [actions addObject:[coordinator nativeSheetAction:choice[0]
            icon:@"play" handler:^{
                YTKACEStartPlaylistDownload(items, selection, cap, NO, source);
            }]];
    }
    [coordinator presentPlaylistSheetWithTitle:YTKACELocalized(@"Maximum quality")
                                      subtitle:nil
                                    sourceView:YTKACESheetAnchorForView(source)
                                       actions:actions];
}

static void YTKACEPresentQualityMenu(UIView *source,
                                     NSArray<NSDictionary *> *items,
                                     NSSet<NSString *> *selection) {
    YTKACEDownloadCoordinator *coordinator =
        YTKACEDownloadCoordinator.sharedCoordinator;
    NSMutableArray *actions = [NSMutableArray array];
    [actions addObject:[coordinator nativeSheetAction:
        YTKACELocalized(@"Best available") icon:@"play" handler:^{
            YTKACEStartPlaylistDownload(items, selection, 0, NO, source);
        }]];
    [actions addObject:[coordinator nativeSheetAction:
        YTKACELocalized(@"Custom quality") icon:@"chevron.right" handler:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    YTKACEPresentCustomQualityMenu(source, items, selection);
                });
        }]];
    [actions addObject:[coordinator nativeSheetAction:
        YTKACELocalized(@"Audio only") icon:@"music.note" handler:^{
            YTKACEStartPlaylistDownload(items, selection, 0, YES, source);
        }]];
    [coordinator presentPlaylistSheetWithTitle:YTKACELocalized(@"Download quality")
                                      subtitle:nil
                                    sourceView:YTKACESheetAnchorForView(source)
                                       actions:actions];
}

static void YTKACEPresentPlaylistMenu(UIView *source) {
    NSArray<NSDictionary *> *items = YTKACECurrentPlaylistItems();
    YTKACEDownloadCoordinator *coordinator =
        YTKACEDownloadCoordinator.sharedCoordinator;
    if (items.count == 0) {
        YTKACEShowNotice(YTKACELocalized(
            @"Scroll the playlist once so YTKACE can read it, then try again."));
        return;
    }
    NSMutableArray *actions = [NSMutableArray array];
    NSString *name = YTKACECurrentPlaylistTitle.length != 0
        ? YTKACECurrentPlaylistTitle : YTKACELocalized(@"playlist");
    [actions addObject:[coordinator nativeSheetAction:
        [NSString stringWithFormat:YTKACELocalized(@"Download all of %@ (%lu)"),
            name, (unsigned long)items.count]
        icon:@"play" handler:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    YTKACEPresentQualityMenu(source, items, nil);
                });
        }]];
    [actions addObject:[coordinator nativeSheetAction:
        YTKACELocalized(@"Select videos") icon:@"doc.on.doc" handler:^{
            YTKACEPlaylistPickerController *picker =
                [[YTKACEPlaylistPickerController alloc]
                    initWithStyle:UITableViewStylePlain];
            picker.items = items;
            picker.selection = [NSMutableSet set];
            for (NSDictionary *item in items) {
                [picker.selection addObject:item[@"videoId"]];
            }
            picker.onDone = ^(NSSet<NSString *> *selection) {
                if (selection.count == 0) {
                    YTKACEShowNotice(YTKACELocalized(@"No videos selected"));
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        YTKACEPresentQualityMenu(source, items, selection);
                    });
            };
            UINavigationController *navigation = [[UINavigationController alloc]
                initWithRootViewController:picker];
            [YTKACEPlaylistTopController() presentViewController:navigation
                                                        animated:YES
                                                      completion:nil];
        }]];
    [coordinator presentPlaylistSheetWithTitle:
        YTKACECurrentPlaylistTitle.length != 0 ? YTKACECurrentPlaylistTitle
                                               : YTKACELocalized(@"Playlist")
        subtitle:[NSString stringWithFormat:YTKACELocalized(@"%lu videos"),
            (unsigned long)items.count]
        sourceView:YTKACESheetAnchorForView(source)
        actions:actions];
}

@interface YTKACEPlaylistButtonTarget : NSObject
+ (instancetype)shared;
- (void)tapped:(UIButton *)sender;
@end

@implementation YTKACEPlaylistButtonTarget

+ (instancetype)shared {
    static YTKACEPlaylistButtonTarget *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [self new]; });
    return shared;
}

- (void)tapped:(UIButton *)sender {
    YTKACEPresentPlaylistMenu(sender);
}

@end

static NSData *YTKACEDecodeBlob(NSString *line) {
    NSRange marker = [line rangeOfString:@": \""];
    NSString *escaped = marker.location != NSNotFound
        ? [line substringFromIndex:NSMaxRange(marker)] : line;
    NSUInteger length = escaped.length;
    NSMutableData *bytes = [NSMutableData dataWithCapacity:length];
    NSUInteger index = 0;
    while (index < length) {
        unichar c = [escaped characterAtIndex:index];
        if (c != '\\' || index + 1 >= length) {
            if (c < 128) {
                unsigned char raw = (unsigned char)c;
                [bytes appendBytes:&raw length:1];
            } else {
                NSString *piece = [NSString stringWithCharacters:&c length:1];
                [bytes appendData:[piece dataUsingEncoding:NSUTF8StringEncoding]];
            }
            index++;
            continue;
        }
        unichar next = [escaped characterAtIndex:index + 1];
        unsigned char raw = 0;
        if (next == 'n') { raw = '\n'; index += 2; }
        else if (next == 't') { raw = '\t'; index += 2; }
        else if (next == 'r') { raw = '\r'; index += 2; }
        else if (next == '"') { raw = '"'; index += 2; }
        else if (next == '\\') { raw = '\\'; index += 2; }
        else if (next >= '0' && next <= '7') {
            NSUInteger digits = 0;
            int value = 0;
            while (digits < 3 && index + 1 + digits < length) {
                unichar digit = [escaped characterAtIndex:index + 1 + digits];
                if (digit < '0' || digit > '7') break;
                value = value * 8 + (digit - '0');
                digits++;
            }
            if (digits == 0) { raw = '\\'; index++; }
            else { raw = (unsigned char)(value & 0xFF); index += 1 + digits; }
        } else { raw = '\\'; index++; }
        [bytes appendBytes:&raw length:1];
    }
    return bytes;
}

static BOOL YTKACELooksLikeJunk(NSString *run) {
    static NSArray<NSString *> *phrases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        phrases = @[@"SharePlay", @"Save to", @"Remove from", @"queue",
                    @"Play on", @"Action menu", @"Learn more", @"http", @"|",
                    @"%3D", @" views", @" ago", @"Delete", @"Download",
                    @"ytimg", @"googlevideo", @".eml"];
    });
    for (NSString *phrase in phrases) {
        if ([run containsString:phrase]) return YES;
    }
    return NO;
}

static NSString *YTKACETitleFromBlob(NSData *blob) {
    const unsigned char *bytes = (const unsigned char *)blob.bytes;
    NSUInteger length = blob.length;
    NSMutableDictionary<NSString *, NSNumber *> *counts =
        [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index + 1 < length; index++) {
        NSUInteger runLength = bytes[index];
        if (runLength < 6 || runLength > 120) continue;
        if (index + 1 + runLength > length) continue;
        NSString *run = [[NSString alloc]
            initWithBytes:bytes + index + 1
                   length:runLength
                 encoding:NSUTF8StringEncoding];
        if (run == nil) continue;
        if ([run rangeOfString:@" "].location == NSNotFound) continue;
        if ([run rangeOfString:@"_"].location != NSNotFound) continue;
        if (![run isEqualToString:[run stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]]) {
            continue;
        }
        BOOL control = NO;
        for (NSUInteger i = 0; i < run.length; i++) {
            if ([run characterAtIndex:i] < 32) { control = YES; break; }
        }
        if (control || YTKACELooksLikeJunk(run)) continue;
        counts[run] = @(counts[run].integerValue + 1);
    }
    NSString *best = nil;
    for (NSString *run in counts) {
        if (counts[run].integerValue < 2) continue;
        if (run.length > best.length) best = run;
    }
    return best;
}

static NSArray<NSDictionary *> *YTKACEExtractPlaylistItems(id model) {
    if (model == nil) return @[];
    NSString *dump = nil;
    @try {
        dump = [model description];
    } @catch (__unused NSException *exception) {
        return @[];
    }
    if (dump.length == 0) return @[];
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression
            regularExpressionWithPattern:@"\\\\n\\\\013([A-Za-z0-9_-]{11})"
                                 options:0
                                   error:NULL];
    });
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *line in [dump componentsSeparatedByString:@"\n"]) {
        NSArray<NSTextCheckingResult *> *matches = [expression
            matchesInString:line options:0 range:NSMakeRange(0, line.length)];
        if (matches.count == 0) continue;
        NSString *videoID = nil;
        for (NSTextCheckingResult *candidate in matches) {
            NSString *identifier =
                [line substringWithRange:[candidate rangeAtIndex:1]];
            if ([line containsString:[NSString stringWithFormat:
                    @"i.ytimg.com/vi/%@", identifier]]) {
                videoID = identifier;
                break;
            }
        }
        if (videoID == nil || [seen containsObject:videoID]) continue;
        [seen addObject:videoID];
        NSString *title = YTKACETitleFromBlob(YTKACEDecodeBlob(line));
        [items addObject:@{
            @"videoId": videoID,
            @"title": title.length != 0 ? title : videoID,
            @"thumbnail": [NSString stringWithFormat:
                @"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoID]
        }];
    }
    static NSRegularExpression *titleExpression;
    static dispatch_once_t titleToken;
    dispatch_once(&titleToken, ^{
        titleExpression = [NSRegularExpression
            regularExpressionWithPattern:@"page_title:\\s*\"([^\"]{1,120})\""
                                 options:0
                                   error:NULL];
    });
    NSTextCheckingResult *titleMatch = [titleExpression
        firstMatchInString:dump options:0 range:NSMakeRange(0, dump.length)];
    if (titleMatch != nil) {
        YTKACECurrentPlaylistTitle =
            [dump substringWithRange:[titleMatch rangeAtIndex:1]];
    }
    return items;
}

static NSArray<NSDictionary *> *YTKACECurrentPlaylistItems(void) {
    NSString *playlistID = YTKACECurrentPlaylistID;
    UIViewController *browse = YTKACEPlaylistBrowseController;
    NSArray<NSDictionary *> *found = nil;
    for (NSString *name in @[@"response", @"model", @"browseResponse"]) {
        id model = YTKACEPlaylistValue(browse, name);
        NSArray<NSDictionary *> *items = YTKACEExtractPlaylistItems(model);
        if (items.count != 0) { found = items; break; }
    }
    if (playlistID.length == 0) return found ?: @[];
    NSMutableArray<NSDictionary *> *cached = YTKACEPlaylistItems[playlistID];
    if (cached == nil) {
        cached = [NSMutableArray array];
        YTKACEPlaylistItems[playlistID] = cached;
        YTKACEPlaylistSeen[playlistID] = [NSMutableSet set];
    }
    NSMutableSet<NSString *> *seen = YTKACEPlaylistSeen[playlistID];
    for (NSDictionary *item in found) {
        NSString *videoID = item[@"videoId"];
        if ([seen containsObject:videoID]) continue;
        [seen addObject:videoID];
        [cached addObject:item];
    }
    return [cached copy];
}

static IMP OriginalBrowseAppear;

static void YTKACERefreshHeaderBars(UIView *root);

static IMP OriginalBrowseDisappear;

static void YTKACEBrowseDisappear(UIViewController *receiver, SEL selector,
                                  BOOL animated) {
    if (OriginalBrowseDisappear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalBrowseDisappear)(receiver, selector,
                                                            animated);
    }
    if (YTKACEPlaylistBrowseController != nil &&
        YTKACEPlaylistBrowseController != receiver) {
        return;
    }
    YTKACECurrentPlaylistID = nil;
    YTKACEPlaylistBrowseController = nil;
    YTKACERefreshHeaderBars(receiver.view.window ?: receiver.view);
}

static void YTKACEBrowseAppear(UIViewController *receiver, SEL selector,
                               BOOL animated) {
    if (OriginalBrowseAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalBrowseAppear)(receiver, selector,
                                                        animated);
    }
    id value = YTKACEPlaylistValue(receiver, @"browseIdentifier");
    NSString *browseID = [value isKindOfClass:NSString.class] ? value : nil;
    if (browseID.length == 0) return;
    if ([browseID hasPrefix:@"VL"]) {
        YTKACECurrentPlaylistID = [browseID substringFromIndex:2];
        YTKACEPlaylistBrowseController = receiver;
    } else {
        YTKACECurrentPlaylistID = nil;
        YTKACEPlaylistBrowseController = nil;
    }
    YTKACERefreshHeaderBars(receiver.view.window ?: receiver.view);
}

static IMP OriginalSetRightBarButtonItems;

static UIBarButtonItem *YTKACEPlaylistBarItem(void) {
    static UIBarButtonItem *item;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = YTKACEPlaylistButtonTag;
        button.accessibilityIdentifier = @"YTKACE Playlist Download";
        button.accessibilityLabel = YTKACELocalized(@"Download playlist");
        button.tintColor = UIColor.whiteColor;
        button.frame = CGRectMake(0.0, 0.0, 32.0, 32.0);
        [button setImage:YTKACEDownloadGlyphImage() forState:UIControlStateNormal];
        [button addTarget:YTKACEPlaylistButtonTarget.shared
                   action:@selector(tapped:)
         forControlEvents:UIControlEventTouchUpInside];
        item = [[UIBarButtonItem alloc] initWithCustomView:button];
    });
    return item;
}

static void YTKACESetRightBarButtonItems(UIView *receiver, SEL selector,
                                         NSArray *items) {
    NSArray *result = items;
    if (YTKACEPlaylistDownloadEnabled() && YTKACECurrentPlaylistID.length != 0) {
        UIBarButtonItem *ours = YTKACEPlaylistBarItem();
        if (![items containsObject:ours]) {
            NSMutableArray *merged = items != nil
                ? [items mutableCopy] : [NSMutableArray array];
            [merged insertObject:ours atIndex:0];
            result = merged;
        }
    }
    if (OriginalSetRightBarButtonItems != NULL) {
        ((void (*)(id, SEL, id))OriginalSetRightBarButtonItems)(
            receiver, selector, result);
    }
}

static void YTKACERefreshHeaderBars(UIView *root) {
    if (root == nil) return;
    if ([NSStringFromClass(root.class) isEqualToString:@"YTHeaderView"]) {
        SEL getter = NSSelectorFromString(@"rightBarButtonItems");
        SEL setter = NSSelectorFromString(@"setRightBarButtonItems:");
        if ([root respondsToSelector:getter] &&
            [root respondsToSelector:setter]) {
            id current = ((id (*)(id, SEL))objc_msgSend)(root, getter);
            ((void (*)(id, SEL, id))objc_msgSend)(root, setter, current);
        }
        return;
    }
    for (UIView *child in root.subviews) {
        YTKACERefreshHeaderBars(child);
    }
}

void YTKACEInstallPlaylistDownloaderHooks(void) {
    if (YTKACEPlaylistItems == nil) {
        YTKACEPlaylistItems = [NSMutableDictionary dictionary];
        YTKACEPlaylistSeen = [NSMutableDictionary dictionary];
        YTKACEPlaylistThumbnails = [NSMutableDictionary dictionary];
    }
    BOOL contents = YTKACEInstallInstanceHook(@"YTIPlaylistVideoListRenderer",
                                              @"contentsArray",
                                              (IMP)YTKACEPlaylistContents,
                                              &OriginalPlaylistContents);
    BOOL header = YTKACEInstallInstanceHook(@"YTPageHeaderViewController",
                                            @"loadWithModel:",
                                            (IMP)YTKACEPlaylistHeaderModel,
                                            &OriginalPlaylistHeaderModel);
    BOOL layout = YTKACEInstallInstanceHook(@"YTHeaderView",
                                            @"setRightBarButtonItems:",
                                            (IMP)YTKACESetRightBarButtonItems,
                                            &OriginalSetRightBarButtonItems);
    YTKACEDownloadLog(@"playlist",
        @"hooks contents=%d header=%d layout=%d", contents, header, layout);
    YTKACEInstallInstanceHook(@"YTBrowseViewController", @"viewDidAppear:",
                              (IMP)YTKACEBrowseAppear, &OriginalBrowseAppear);
    YTKACEInstallInstanceHook(@"YTBrowseViewController", @"viewWillDisappear:",
                              (IMP)YTKACEBrowseDisappear,
                              &OriginalBrowseDisappear);
}
