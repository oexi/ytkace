#import "YTKACEDownloadPlayerController.h"
#import "../../YTKACE.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "MediaArtwork.h"
#import "../../Settings/YTKACESettingsPages.h"

#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <math.h>

NSNotificationName const YTKACEDownloadPlaybackDidChangeNotification =
    @"YTKACEDownloadPlaybackDidChangeNotification";
NSNotificationName const YTKACEDownloadPlaybackDidStopNotification =
    @"YTKACEDownloadPlaybackDidStopNotification";

static NSString *YTKACEPlayerTimeText(NSTimeInterval duration) {
    if (!isfinite(duration) || duration < 0.0) {
        return @"0:00";
    }
    NSInteger seconds = (NSInteger)floor(duration);
    NSInteger hours = seconds / 3600;
    NSInteger minutes = (seconds % 3600) / 60;
    NSInteger remainder = seconds % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld",
            (long)hours, (long)minutes, (long)remainder];
    }
    return [NSString stringWithFormat:@"%ld:%02ld",
        (long)minutes, (long)remainder];
}

@interface YTKACESubtitleCue : NSObject
@property(nonatomic, assign) NSTimeInterval start;
@property(nonatomic, assign) NSTimeInterval end;
@property(nonatomic, copy) NSString *text;
@end

@implementation YTKACESubtitleCue
@end

static NSTimeInterval YTKACESubtitleTime(NSString *value) {
    NSString *clean = [[value stringByReplacingOccurrencesOfString:@"," withString:@"."]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSArray<NSString *> *parts = [clean componentsSeparatedByString:@":"];
    if (parts.count == 3) {
        return parts[0].doubleValue * 3600.0 + parts[1].doubleValue * 60.0 +
            parts[2].doubleValue;
    }
    if (parts.count == 2) return parts[0].doubleValue * 60.0 + parts[1].doubleValue;
    return clean.doubleValue;
}

static NSArray<YTKACESubtitleCue *> *YTKACEReadSubtitles(NSURL *mediaURL) {
    NSURL *base = mediaURL.URLByDeletingPathExtension;
    NSURL *subtitleURL = nil;
    for (NSString *extension in @[@"srt", @"vtt"]) {
        NSURL *candidate = [base URLByAppendingPathExtension:extension];
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate.path]) {
            subtitleURL = candidate;
            break;
        }
    }
    if (subtitleURL == nil) return @[];
    NSString *contents = [NSString stringWithContentsOfURL:subtitleURL
                                                   encoding:NSUTF8StringEncoding error:nil];
    if (contents.length == 0) return @[];
    contents = [[contents stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSRegularExpression *blankLines = [NSRegularExpression
        regularExpressionWithPattern:@"\\n[ \\t]*\\n" options:0 error:nil];
    contents = [blankLines stringByReplacingMatchesInString:contents options:0
        range:NSMakeRange(0, contents.length) withTemplate:@"\n\n"];
    NSMutableArray<YTKACESubtitleCue *> *cues = [NSMutableArray array];
    for (NSString *block in [contents componentsSeparatedByString:@"\n\n"]) {
        NSArray<NSString *> *lines = [block componentsSeparatedByString:@"\n"];
        NSUInteger timingIndex = NSNotFound;
        for (NSUInteger index = 0; index < lines.count; index++) {
            if ([lines[index] containsString:@"-->"]) {
                timingIndex = index;
                break;
            }
        }
        if (timingIndex == NSNotFound) continue;
        NSArray<NSString *> *times = [lines[timingIndex] componentsSeparatedByString:@"-->"];
        if (times.count != 2) continue;
        NSArray<NSString *> *endParts = [times[1]
            componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *endValue = nil;
        for (NSString *part in endParts) {
            if (part.length != 0) {
                endValue = part;
                break;
            }
        }
        NSMutableArray<NSString *> *textLines = [NSMutableArray array];
        for (NSUInteger index = timingIndex + 1; index < lines.count; index++) {
            NSString *line = [lines[index] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (line.length != 0) [textLines addObject:line];
        }
        if (endValue.length == 0 || textLines.count == 0) continue;
        YTKACESubtitleCue *cue = [YTKACESubtitleCue new];
        cue.start = YTKACESubtitleTime(times[0]);
        cue.end = YTKACESubtitleTime(endValue);
        cue.text = [textLines componentsJoinedByString:@"\n"];
        if (cue.end > cue.start) [cues addObject:cue];
    }
    return cues;
}

static NSArray<YTKACESubtitleCue *> *YTKACEReadEmbeddedSubtitles(NSURL *mediaURL) {
    if (mediaURL == nil) return @[];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:mediaURL options:nil];
    NSArray<AVAssetTrack *> *tracks =
        [asset tracksWithMediaType:AVMediaTypeSubtitle];
    if (tracks.count == 0) tracks = [asset tracksWithMediaType:AVMediaTypeText];
    if (tracks.count == 0) return @[];
    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                           error:&error];
    if (reader == nil) return @[];
    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks.firstObject
                                         outputSettings:nil];
    if (![reader canAddOutput:output]) return @[];
    [reader addOutput:output];
    if (![reader startReading]) return @[];

    NSMutableArray<YTKACESubtitleCue *> *cues = [NSMutableArray array];
    CMSampleBufferRef sample = NULL;
    while ((sample = [output copyNextSampleBuffer]) != NULL) {
        const CMTime start = CMSampleBufferGetPresentationTimeStamp(sample);
        const CMTime duration = CMSampleBufferGetDuration(sample);
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        const size_t length = block != NULL
            ? CMBlockBufferGetDataLength(block) : 0;
        if (block != NULL && length > 2) {
            uint8_t *bytes = (uint8_t *)malloc(length);
            if (bytes != NULL) {
                if (CMBlockBufferCopyDataBytes(block, 0, length, bytes) ==
                        kCMBlockBufferNoErr) {
                    const NSUInteger textLength =
                        (NSUInteger)((bytes[0] << 8) | bytes[1]);
                    if (textLength > 0 && textLength + 2 <= length) {
                        NSString *text = [[NSString alloc]
                            initWithBytes:bytes + 2
                                   length:textLength
                                 encoding:NSUTF8StringEncoding];
                        if (text.length != 0) {
                            YTKACESubtitleCue *cue = [YTKACESubtitleCue new];
                            cue.start = CMTimeGetSeconds(start);
                            cue.end = cue.start + CMTimeGetSeconds(duration);
                            cue.text = text;
                            if (cue.end > cue.start) [cues addObject:cue];
                        }
                    }
                }
                free(bytes);
            }
        }
        CFRelease(sample);
    }
    return cues;
}

@interface YTKACEDownloadPlaybackSession ()
@property(nonatomic, strong, readwrite) AVPlayer *player;
@property(nonatomic, strong) id resumeObserver;
@property(nonatomic, copy, readwrite, nullable) NSURL *currentURL;
@property(nonatomic, copy, readwrite) NSArray<NSURL *> *playlist;
@property(nonatomic, assign, readwrite) NSInteger currentIndex;
@property(nonatomic, assign) BOOL continueInBackground;
@end

@implementation YTKACEDownloadPlaybackSession

+ (instancetype)sharedSession {
    static YTKACEDownloadPlaybackSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        session = [YTKACEDownloadPlaybackSession new];
    });
    return session;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    self.player = [AVPlayer new];
    self.playlist = @[];
    self.currentIndex = NSNotFound;
    self.autoplayEnabled = YES;
    self.gesturesEnabled = NO;
    self.repeatEnabled = NO;
    double defaultRate = YTKACEStartPlaybackRate();
    self.playbackRate = defaultRate >= 0.25 ? (float)defaultRate : 1.0f;
    self.player.allowsExternalPlayback = YES;
    if (@available(iOS 15.0, *)) {
        self.player.audiovisualBackgroundPlaybackPolicy =
            AVPlayerAudiovisualBackgroundPlaybackPolicyContinuesIfPossible;
    }
    [self configureAudioSession];
    [self configureRemoteCommands];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(itemDidEnd:)
        name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(applicationWillResignActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(applicationDidEnterBackground:)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    return self;
}

static NSString * const YTKACEResumeKey = @"YTKACE.Preference.Downloads.ResumePositions";

static NSString *YTKACEResumeIdentifier(NSURL *URL) {
    if (URL == nil) return @"";
    NSString *path = URL.URLByStandardizingPath.path;
    NSString *root = YTKACEApplicationSupportDirectory()
        .URLByStandardizingPath.path;
    NSString *prefix = [root stringByAppendingString:@"/"];
    if (path.length != 0 && [path hasPrefix:prefix]) {
        return [@"v2|" stringByAppendingString:
            [path substringFromIndex:prefix.length]];
    }
    NSString *identity = path.length != 0 ? path : URL.absoluteString;
    return [@"v2|external|" stringByAppendingString:identity ?: @""];
}

static NSString *YTKACELegacyResumeIdentifier(NSURL *URL) {
    NSString *name = URL.lastPathComponent;
    return name.length != 0 ? name : URL.absoluteString;
}

static void YTKACEWriteResumeTable(NSUserDefaults *defaults,
                                   NSDictionary *table) {
    [defaults setObject:table forKey:YTKACEResumeKey];
}

static NSDictionary *YTKACEValidatedResumeRecord(NSURL *URL,
                                                  double *legacyPosition) {
    if (legacyPosition != NULL) *legacyPosition = 0.0;
    if (URL == nil) return nil;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *table =
        [[defaults dictionaryForKey:YTKACEResumeKey] mutableCopy];
    if (table == nil) return nil;
    NSString *identifier = YTKACEResumeIdentifier(URL);
    NSString *legacyIdentifier = YTKACELegacyResumeIdentifier(URL);
    NSString *sourceIdentifier = identifier;
    id value = table[identifier];
    if (value == nil && legacyIdentifier.length != 0) {
        sourceIdentifier = legacyIdentifier;
        value = table[legacyIdentifier];
    }
    if (value == nil) return nil;

    if (![value isKindOfClass:NSDictionary.class]) {
        double position = [value respondsToSelector:@selector(doubleValue)]
            ? [value doubleValue] : NAN;
        if (!isfinite(position) || position <= 0.0) {
            [table removeObjectForKey:sourceIdentifier];
            YTKACEWriteResumeTable(defaults, table);
            return nil;
        }
        if (legacyPosition != NULL) *legacyPosition = position;
        return nil;
    }

    NSDictionary *record = (NSDictionary *)value;
    id positionValue = record[@"t"];
    id durationValue = record[@"d"];
    if (![positionValue respondsToSelector:@selector(doubleValue)] ||
        ![durationValue respondsToSelector:@selector(doubleValue)]) {
        [table removeObjectForKey:sourceIdentifier];
        YTKACEWriteResumeTable(defaults, table);
        return nil;
    }
    double position = [positionValue doubleValue];
    double duration = [durationValue doubleValue];
    BOOL completed = [record[@"c"] respondsToSelector:@selector(boolValue)] &&
        [record[@"c"] boolValue];
    BOOL valid = isfinite(position) && isfinite(duration) &&
        duration > 0.0 && position >= 0.0 && position <= duration &&
        (completed || position > 0.0);
    if (!valid) {
        [table removeObjectForKey:sourceIdentifier];
        YTKACEWriteResumeTable(defaults, table);
        return nil;
    }

    NSDictionary *normalized = @{
        @"t": @(completed ? 0.0 : position),
        @"d": @(duration),
        @"c": @(completed),
        @"v": @2
    };
    if (![sourceIdentifier isEqualToString:identifier] ||
        ![normalized isEqualToDictionary:record]) {
        [table removeObjectForKey:sourceIdentifier];
        if (legacyIdentifier.length != 0 &&
            ![legacyIdentifier isEqualToString:identifier]) {
            [table removeObjectForKey:legacyIdentifier];
        }
        table[identifier] = normalized;
        YTKACEWriteResumeTable(defaults, table);
    }
    return normalized;
}

static NSTimeInterval YTKACEStoredResume(NSURL *URL) {
    double legacyPosition = 0.0;
    NSDictionary *record =
        YTKACEValidatedResumeRecord(URL, &legacyPosition);
    if (record == nil) return legacyPosition;
    if ([record[@"c"] boolValue]) return 0.0;
    double position = [record[@"t"] doubleValue];
    return isfinite(position) && position > 0.0 ? position : 0.0;
}

CGFloat YTKACEDownloadProgressRatio(NSURL *URL) {
    NSDictionary *record = YTKACEValidatedResumeRecord(URL, NULL);
    if (record == nil) return 0.0;
    if ([record[@"c"] boolValue]) return 1.0;
    double position = [record[@"t"] doubleValue];
    double duration = [record[@"d"] doubleValue];
    if (!isfinite(position) || !isfinite(duration) || duration <= 0.0 ||
        position < 0.0 || position > duration) return 0.0;
    double ratio = position / duration;
    if (!isfinite(ratio)) return 0.0;
    return (CGFloat)MAX(0.0, MIN(1.0, ratio));
}

static void YTKACEStoreResume(NSURL *URL, NSTimeInterval seconds,
                              NSTimeInterval duration, BOOL completed) {
    if (URL == nil) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *table =
        [[defaults dictionaryForKey:YTKACEResumeKey] mutableCopy]
            ?: [NSMutableDictionary dictionary];
    NSString *identifier = YTKACEResumeIdentifier(URL);
    NSString *legacyIdentifier = YTKACELegacyResumeIdentifier(URL);
    if (legacyIdentifier.length != 0 &&
        ![legacyIdentifier isEqualToString:identifier]) {
        [table removeObjectForKey:legacyIdentifier];
    }
    BOOL validDuration = isfinite(duration) && duration > 0.0;
    BOOL validPosition = isfinite(seconds) && seconds >= 0.0 &&
        validDuration && seconds <= duration;
    if (!validDuration || (!completed && (!validPosition || seconds <= 0.0))) {
        [table removeObjectForKey:identifier];
    } else {
        table[identifier] = @{
            @"t": @(completed ? 0.0 : seconds),
            @"d": @(duration),
            @"c": @(completed),
            @"v": @2
        };
        if (table.count > 300) {
            NSArray *keys = table.allKeys;
            for (NSUInteger i = 0; i + 200 < keys.count; i++) {
                [table removeObjectForKey:keys[i]];
            }
        }
    }
    YTKACEWriteResumeTable(defaults, table);
}

static void YTKACERemoveResume(NSURL *URL) {
    if (URL == nil) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *table =
        [[defaults dictionaryForKey:YTKACEResumeKey] mutableCopy];
    if (table == nil) return;
    [table removeObjectForKey:YTKACEResumeIdentifier(URL)];
    [table removeObjectForKey:YTKACELegacyResumeIdentifier(URL)];
    YTKACEWriteResumeTable(defaults, table);
}

static BOOL YTKACEStoredResumeIsCompleted(NSURL *URL) {
    NSDictionary *record = YTKACEValidatedResumeRecord(URL, NULL);
    return [record[@"c"] boolValue];
}

static void YTKACEStoreCompleted(NSURL *URL, NSTimeInterval duration,
                                 NSTimeInterval fallbackDuration) {
    NSTimeInterval total = duration;
    if (!isfinite(total) || total <= 0.0) total = fallbackDuration;
    if (!isfinite(total) || total <= 0.0) {
        NSDictionary *record = YTKACEValidatedResumeRecord(URL, NULL);
        total = [record[@"d"] doubleValue];
    }
    if (isfinite(total) && total > 0.0) {
        YTKACEStoreResume(URL, 0.0, total, YES);
    }
}

- (void)rememberPosition {
    AVPlayerItem *item = self.player.currentItem;
    if (self.currentURL == nil || item == nil) return;
    NSTimeInterval position = CMTimeGetSeconds(item.currentTime);
    NSTimeInterval duration = CMTimeGetSeconds(item.duration);
    if (!isfinite(position) || position < 0.0) return;
    if (!isfinite(duration) || duration <= 0.0 || position > duration) {
        return;
    }
    if (position < 5.0) {
        if (!YTKACEStoredResumeIsCompleted(self.currentURL)) {
            YTKACERemoveResume(self.currentURL);
        }
        return;
    }
    if (position >= MAX(0.0, duration - 10.0)) {
        YTKACEStoreCompleted(self.currentURL, duration, position);
        return;
    }
    YTKACEStoreResume(self.currentURL, position, duration, NO);
}

- (void)configureAudioSession {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeMoviePlayback
                 options:0 error:nil];
    [session setActive:YES error:nil];
}

- (void)configureRemoteCommands {
    [UIApplication.sharedApplication beginReceivingRemoteControlEvents];
    MPRemoteCommandCenter *commands = MPRemoteCommandCenter.sharedCommandCenter;
    __weak YTKACEDownloadPlaybackSession *weakSelf = self;
    [commands.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        (void)event;
        [weakSelf play];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [commands.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        (void)event;
        [weakSelf pause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [commands.togglePlayPauseCommand addTargetWithHandler:
        ^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            (void)event;
            [weakSelf togglePlayback];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
    [commands.nextTrackCommand addTargetWithHandler:
        ^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            (void)event;
            [weakSelf playNext];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
    [commands.previousTrackCommand addTargetWithHandler:
        ^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            (void)event;
            [weakSelf playPrevious];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    self.continueInBackground = self.player.rate != 0.0f;
    [self rememberPosition];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    if (!self.continueInBackground || self.currentURL == nil) return;
    [self configureAudioSession];
    [self.player play];
    self.player.rate = self.playbackRate;
    [self updateNowPlayingInfo];
}

- (void)dealloc {
    [self rememberPosition];
    if (self.resumeObserver != nil) {
        [self.player removeTimeObserver:self.resumeObserver];
        self.resumeObserver = nil;
    }
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)loadURL:(NSURL *)URL
       playlist:(NSArray<NSURL *> *)playlist
          index:(NSInteger)index {
    self.playlist = playlist ?: @[];
    self.currentIndex = index;
    if (URL == nil) {
        return;
    }
    if (![self.currentURL isEqual:URL]) {
        [self rememberPosition];
        self.currentURL = URL;
        [self.player replaceCurrentItemWithPlayerItem:
            [AVPlayerItem playerItemWithURL:URL]];
        NSTimeInterval resume = YTKACEStoredResume(URL);
        if (resume > 0.0) {
            [self.player seekToTime:CMTimeMakeWithSeconds(resume, 600)
                    toleranceBefore:kCMTimeZero
                     toleranceAfter:kCMTimeZero];
        }
    }
    [self play];
    [self notifyChange];
}

- (void)updatePlaylist:(NSArray<NSURL *> *)playlist {
    self.playlist = playlist ?: @[];
    NSUInteger index = self.currentURL == nil
        ? NSNotFound : [self.playlist indexOfObject:self.currentURL];
    self.currentIndex = index == NSNotFound ? NSNotFound : (NSInteger)index;
    [self notifyChange];
}

- (void)beginTrackingPosition {
    if (self.resumeObserver != nil) return;
    __weak YTKACEDownloadPlaybackSession *weakSelf = self;
    self.resumeObserver = [self.player
        addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(5.0, 600)
                                     queue:dispatch_get_main_queue()
                                usingBlock:^(__unused CMTime time) {
        YTKACEDownloadPlaybackSession *strongSelf = weakSelf;
        if (strongSelf.player.rate != 0.0f) [strongSelf rememberPosition];
    }];
}

- (void)play {
    [self configureAudioSession];
    [self beginTrackingPosition];
    [self.player play];
    self.player.rate = MAX(0.25f, MIN(self.playbackRate, 5.0f));
    [self notifyChange];
}

- (void)pause {
    [self rememberPosition];
    [self.player pause];
    [self notifyChange];
}

- (void)togglePlayback {
    self.player.rate == 0.0f ? [self play] : [self pause];
}

- (void)setPlaybackRate:(float)playbackRate {
    _playbackRate = MAX(0.25f, MIN(playbackRate, 5.0f));
    if (self.player.rate != 0.0f) {
        self.player.rate = _playbackRate;
    }
    [self notifyChange];
}

- (void)seekBy:(NSTimeInterval)seconds {
    NSTimeInterval current = CMTimeGetSeconds(self.player.currentTime);
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    if (!isfinite(current)) {
        current = 0.0;
    }
    NSTimeInterval target = MAX(0.0, current + seconds);
    if (isfinite(duration) && duration > 0.0) {
        target = MIN(target, duration);
    }
    [self.player seekToTime:CMTimeMakeWithSeconds(target, 600)
            toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (void)playNext {
    if (self.playlist.count == 0 || self.currentIndex == NSNotFound) {
        return;
    }
    NSInteger next = self.currentIndex + 1;
    if (next >= (NSInteger)self.playlist.count) {
        next = self.autoplayEnabled ? 0 : NSNotFound;
    }
    if (next != NSNotFound) {
        [self loadURL:self.playlist[(NSUInteger)next]
             playlist:self.playlist index:next];
    }
}

- (void)playPrevious {
    NSTimeInterval current = CMTimeGetSeconds(self.player.currentTime);
    if (isfinite(current) && current > 5.0) {
        [self.player seekToTime:kCMTimeZero];
        return;
    }
    if (self.playlist.count == 0 || self.currentIndex == NSNotFound) {
        return;
    }
    NSInteger previous = self.currentIndex - 1;
    if (previous < 0) {
        previous = self.autoplayEnabled ? (NSInteger)self.playlist.count - 1 : NSNotFound;
    }
    if (previous != NSNotFound) {
        [self loadURL:self.playlist[(NSUInteger)previous]
             playlist:self.playlist index:previous];
    }
}

- (void)stop {
    [self.player pause];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    self.currentURL = nil;
    self.playlist = @[];
    self.currentIndex = NSNotFound;
    [NSNotificationCenter.defaultCenter
        postNotificationName:YTKACEDownloadPlaybackDidStopNotification object:self];
}

- (void)itemDidEnd:(NSNotification *)notification {
    if (notification.object != self.player.currentItem) {
        return;
    }
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    NSTimeInterval position = CMTimeGetSeconds(self.player.currentTime);
    YTKACEStoreCompleted(self.currentURL, duration, position);
    if (self.pauseAtEnd) {
        self.pauseAtEnd = NO;
        [self pause];
    } else if (self.repeatEnabled) {
        [self.player seekToTime:kCMTimeZero completionHandler:^(__unused BOOL finished) {
            [self play];
        }];
    } else if (self.autoplayEnabled) {
        [self playNext];
    } else {
        [self pause];
    }
}

- (void)notifyChange {
    [self updateNowPlayingInfo];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:YTKACEDownloadPlaybackDidChangeNotification object:self];
    });
}

- (void)updateNowPlayingInfo {
    if (self.currentURL == nil) {
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
        return;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] =
        self.currentURL.lastPathComponent.stringByDeletingPathExtension ?: @"YTKACE";
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    NSTimeInterval elapsed = CMTimeGetSeconds(self.player.currentTime);
    if (isfinite(duration) && duration > 0.0) info[MPMediaItemPropertyPlaybackDuration] = @(duration);
    if (isfinite(elapsed) && elapsed >= 0.0) info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.player.rate);
    UIImage *image = YTKACEMediaArtworkImage(self.currentURL);
    if (image != nil) {
        MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc]
            initWithBoundsSize:image.size requestHandler:^UIImage *(CGSize size) {
                (void)size;
                return image;
            }];
        info[MPMediaItemPropertyArtwork] = artwork;
    }
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
}

@end

@interface YTKACEPlayerSurface : UIView
@property(nonatomic, strong) AVPlayer *player;
@end

@implementation YTKACEPlayerSurface
+ (Class)layerClass { return AVPlayerLayer.class; }
- (AVPlayerLayer *)playerLayer { return (AVPlayerLayer *)self.layer; }
- (void)setPlayer:(AVPlayer *)player {
    _player = player;
    self.playerLayer.player = player;
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
}
@end

@interface YTKACEDownloadPlayerController () <UIGestureRecognizerDelegate>
@property(nonatomic, strong) YTKACEDownloadPlaybackSession *session;
@property(nonatomic, strong) YTKACEPlayerSurface *playerSurface;
@property(nonatomic, strong) UIView *controlsView;
@property(nonatomic, strong) UIButton *playButton;
@property(nonatomic, strong) UIButton *repeatButton;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *elapsedLabel;
@property(nonatomic, strong) UILabel *durationLabel;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, strong) UIView *optionsView;
@property(nonatomic, strong) UIView *optionsCard;
@property(nonatomic, strong) UILabel *speedDetail;
@property(nonatomic, strong) UILabel *sleepDetail;
@property(nonatomic, strong) UILabel *gesturesDetail;
@property(nonatomic, strong) UILabel *autoplayDetail;
@property(nonatomic, strong) NSTimer *hideTimer;
@property(nonatomic, strong) NSTimer *sleepTimer;
@property(nonatomic, assign) NSInteger sleepMinutes;
@property(nonatomic, strong) id timeObserver;
@property(nonatomic, strong) UILabel *subtitleLabel;
@property(nonatomic, copy) NSArray<YTKACESubtitleCue *> *subtitleCues;
@property(nonatomic, copy) NSString *subtitleMediaPath;
@property(nonatomic, strong) UIButton *captionButton;
@property(nonatomic, assign) BOOL subtitlesEnabled;
@property(nonatomic, assign) BOOL scrubbing;
@property(nonatomic, assign) BOOL aspectFill;
@property(nonatomic, assign) CGPoint panStart;
@end

@implementation YTKACEDownloadPlayerController

- (instancetype)initWithSession:(YTKACEDownloadPlaybackSession *)session {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        self.session = session;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    [self buildPlayer];
    [self buildOptions];
    [self observePlayback];
    [self refreshControls];
    [self scheduleControlsHide];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.session play];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.hideTimer invalidate];
}

- (void)dealloc {
    [self.hideTimer invalidate];
    [self.sleepTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (self.timeObserver != nil) {
        [self.session.player removeTimeObserver:self.timeObserver];
    }
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }

- (UIButton *)buttonWithSymbol:(NSString *)symbol
                          size:(CGFloat)size
                        action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:size
                                                        weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
             forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildPlayer {
    self.playerSurface = [YTKACEPlayerSurface new];
    self.playerSurface.player = self.session.player;
    self.playerSurface.userInteractionEnabled = YES;
    self.playerSurface.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.playerSurface];
    UITapGestureRecognizer *surfaceTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(toggleControls)];
    [self.playerSurface addGestureRecognizer:surfaceTap];

    self.controlsView = [UIView new];
    self.controlsView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
    self.controlsView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.controlsView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(toggleControls)];
    [self.controlsView addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePan:)];
    [self.controlsView addGestureRecognizer:pan];

    UIButton *minimize = [self buttonWithSymbol:@"chevron.down" size:21.0
                                          action:@selector(minimizePlayer)];
    UIButton *more = [self buttonWithSymbol:@"ellipsis" size:24.0
                                      action:@selector(showOptions)];
    self.titleLabel = [UILabel new];
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[
        minimize, self.titleLabel, more
    ]];
    top.axis = UILayoutConstraintAxisHorizontal;
    top.alignment = UIStackViewAlignmentCenter;
    top.spacing = 14.0;
    top.translatesAutoresizingMaskIntoConstraints = NO;
    [minimize.widthAnchor constraintEqualToConstant:44.0].active = YES;
    [minimize.heightAnchor constraintEqualToConstant:44.0].active = YES;
    [more.widthAnchor constraintEqualToConstant:44.0].active = YES;
    [more.heightAnchor constraintEqualToConstant:44.0].active = YES;
    [self.controlsView addSubview:top];

    UIButton *back = [self buttonWithSymbol:@"gobackward.10" size:22.0
                                      action:@selector(skipBack)];
    UIButton *previous = [self buttonWithSymbol:@"backward.end.fill" size:22.0
                                          action:@selector(previousItem)];
    self.playButton = [self buttonWithSymbol:@"pause.fill" size:48.0
                                      action:@selector(togglePlayback)];
    UIButton *next = [self buttonWithSymbol:@"forward.end.fill" size:22.0
                                      action:@selector(nextItem)];
    UIButton *forward = [self buttonWithSymbol:@"goforward.10" size:22.0
                                         action:@selector(skipForward)];
    UIStackView *center = [[UIStackView alloc] initWithArrangedSubviews:@[
        back, previous, self.playButton, next, forward
    ]];
    center.axis = UILayoutConstraintAxisHorizontal;
    center.alignment = UIStackViewAlignmentCenter;
    center.distribution = UIStackViewDistributionEqualSpacing;
    center.translatesAutoresizingMaskIntoConstraints = NO;
    for (UIButton *button in @[back, previous, next, forward]) {
        [button.widthAnchor constraintEqualToConstant:46.0].active = YES;
        [button.heightAnchor constraintEqualToConstant:46.0].active = YES;
    }
    [self.playButton.widthAnchor constraintEqualToConstant:78.0].active = YES;
    [self.playButton.heightAnchor constraintEqualToConstant:78.0].active = YES;
    [self.controlsView addSubview:center];

    self.elapsedLabel = [self timeLabel];
    self.durationLabel = [self timeLabel];
    self.durationLabel.textAlignment = NSTextAlignmentRight;
    self.slider = [UISlider new];
    self.slider.minimumTrackTintColor = UIColor.whiteColor;
    self.slider.maximumTrackTintColor = [UIColor colorWithWhite:0.7 alpha:0.75];
    self.slider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.slider addTarget:self action:@selector(sliderStarted)
          forControlEvents:UIControlEventTouchDown];
    [self.slider addTarget:self action:@selector(sliderChanged)
          forControlEvents:UIControlEventValueChanged];
    [self.slider addTarget:self action:@selector(sliderEnded)
          forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                           UIControlEventTouchCancel];
    UIButton *aspect = [self buttonWithSymbol:@"arrow.up.left.and.arrow.down.right" size:22.0
                                        action:@selector(toggleAspect)];
    self.repeatButton = [self buttonWithSymbol:@"repeat" size:24.0
                                        action:@selector(toggleRepeat)];
    [aspect.widthAnchor constraintEqualToConstant:44.0].active = YES;
    [aspect.heightAnchor constraintEqualToConstant:44.0].active = YES;
    [self.repeatButton.widthAnchor constraintEqualToConstant:44.0].active = YES;
    [self.repeatButton.heightAnchor constraintEqualToConstant:44.0].active = YES;
    self.subtitlesEnabled = ![NSUserDefaults.standardUserDefaults
        boolForKey:@"YTKACE.Preference.Downloads.SubtitlesHidden"];
    self.captionButton = [self buttonWithSymbol:@"captions.bubble"
                                           size:24.0
                                         action:@selector(toggleSubtitles)];
    [self.captionButton.widthAnchor constraintEqualToConstant:44.0].active = YES;
    [self.captionButton.heightAnchor constraintEqualToConstant:44.0].active = YES;
    UIStackView *bottomButtons = [[UIStackView alloc] initWithArrangedSubviews:@[
        aspect, [UIView new], self.captionButton, self.repeatButton
    ]];
    bottomButtons.axis = UILayoutConstraintAxisHorizontal;
    bottomButtons.translatesAutoresizingMaskIntoConstraints = NO;
    [self.controlsView addSubview:self.slider];
    [self.controlsView addSubview:self.elapsedLabel];
    [self.controlsView addSubview:self.durationLabel];
    [self.controlsView addSubview:bottomButtons];

    self.subtitleLabel = [UILabel new];
    self.subtitleLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.72];
    self.subtitleLabel.textColor = UIColor.whiteColor;
    self.subtitleLabel.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightSemibold];
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    self.subtitleLabel.numberOfLines = 3;
    self.subtitleLabel.layer.cornerRadius = 5.0;
    self.subtitleLabel.layer.masksToBounds = YES;
    self.subtitleLabel.hidden = YES;
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.subtitleLabel];

    UILayoutGuide *safe = self.controlsView.safeAreaLayoutGuide;
    NSLayoutConstraint *centerWidth = [center.widthAnchor
        constraintEqualToAnchor:self.controlsView.widthAnchor multiplier:0.84];
    centerWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [self.playerSurface.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.playerSurface.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.playerSurface.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.playerSurface.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.controlsView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.controlsView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.controlsView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.controlsView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [top.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],
        [top.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:14.0],
        [top.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-14.0],
        [center.centerXAnchor constraintEqualToAnchor:self.controlsView.centerXAnchor],
        [center.centerYAnchor constraintEqualToAnchor:self.controlsView.centerYAnchor],
        [center.widthAnchor constraintLessThanOrEqualToConstant:540.0],
        centerWidth,
        [self.slider.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:28.0],
        [self.slider.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-28.0],
        [self.slider.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-70.0],
        [self.elapsedLabel.leadingAnchor constraintEqualToAnchor:self.slider.leadingAnchor],
        [self.elapsedLabel.bottomAnchor constraintEqualToAnchor:self.slider.topAnchor constant:-4.0],
        [self.durationLabel.trailingAnchor constraintEqualToAnchor:self.slider.trailingAnchor],
        [self.durationLabel.bottomAnchor constraintEqualToAnchor:self.slider.topAnchor constant:-4.0],
        [bottomButtons.leadingAnchor constraintEqualToAnchor:self.slider.leadingAnchor],
        [bottomButtons.trailingAnchor constraintEqualToAnchor:self.slider.trailingAnchor],
        [bottomButtons.topAnchor constraintEqualToAnchor:self.slider.bottomAnchor constant:13.0],
        [bottomButtons.heightAnchor constraintEqualToConstant:38.0],
        [self.subtitleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.subtitleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor
                                                                      constant:30.0],
        [self.subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor
                                                                       constant:-30.0],
        [self.subtitleLabel.bottomAnchor constraintEqualToAnchor:self.slider.topAnchor
                                                         constant:-32.0]
    ]];
}

- (UILabel *)timeLabel {
    UILabel *label = [UILabel new];
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightRegular];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)buildOptions {
    self.optionsView = [UIView new];
    self.optionsView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    self.optionsView.translatesAutoresizingMaskIntoConstraints = NO;
    self.optionsView.hidden = YES;
    [self.view addSubview:self.optionsView];
    UITapGestureRecognizer *dismiss = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(hideOptions)];
    dismiss.delegate = self;
    dismiss.cancelsTouchesInView = NO;
    [self.optionsView addGestureRecognizer:dismiss];

    UIView *card = [UIView new];
    card.backgroundColor = [UIColor colorWithWhite:0.035 alpha:0.98];
    card.layer.cornerRadius = 22.0;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    self.optionsCard = card;
    [self.optionsView addSubview:card];

    UIStackView *rows = [UIStackView new];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.distribution = UIStackViewDistributionFillEqually;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:rows];
    [rows addArrangedSubview:[self optionRow:@"speedometer"
        title:YTKACELocalized(@"Playback Speed") selector:@selector(selectSpeed) detail:&_speedDetail]];
    [rows addArrangedSubview:[self optionRow:@"moon.zzz.fill"
        title:YTKACELocalized(@"Sleep Timer") selector:@selector(selectSleepTimer) detail:&_sleepDetail]];
    [rows addArrangedSubview:[self optionRow:@"hand.draw"
        title:YTKACELocalized(@"Gestures") selector:@selector(toggleGestures) detail:&_gesturesDetail]];
    [rows addArrangedSubview:[self optionRow:@"forward.end.fill"
        title:YTKACELocalized(@"AutoPlay") selector:@selector(toggleAutoplay) detail:&_autoplayDetail]];
    [rows addArrangedSubview:[self optionRow:@"text.line.first.and.arrowtriangle.forward"
        title:YTKACELocalized(@"Play Next") selector:@selector(nextItem) detail:NULL]];
    [rows addArrangedSubview:[self optionRow:@"xmark"
        title:YTKACELocalized(@"Close") selector:@selector(hideOptions) detail:NULL]];
    [NSLayoutConstraint activateConstraints:@[
        [self.optionsView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.optionsView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.optionsView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.optionsView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [card.centerXAnchor constraintEqualToAnchor:self.optionsView.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.optionsView.centerYAnchor],
        [card.widthAnchor constraintLessThanOrEqualToConstant:520.0],
        [card.widthAnchor constraintEqualToAnchor:self.optionsView.widthAnchor multiplier:0.62],
        [card.heightAnchor constraintEqualToConstant:390.0],
        [rows.topAnchor constraintEqualToAnchor:card.topAnchor constant:18.0],
        [rows.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [rows.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
        [rows.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18.0]
    ]];
}

- (UIView *)optionRow:(NSString *)symbol
                title:(NSString *)title
             selector:(SEL)selector
               detail:(UILabel * __strong *)detailOutput {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tintColor = UIColor.whiteColor;
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                        weight:UIImageSymbolWeightRegular];
    UIImage *image = [UIImage systemImageNamed:symbol withConfiguration:configuration];
    UIImageView *icon = [[UIImageView alloc] initWithImage:
        [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    icon.tintColor = UIColor.whiteColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    UILabel *name = [UILabel new];
    name.text = title;
    name.textColor = UIColor.whiteColor;
    name.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightRegular];
    UILabel *detail = [UILabel new];
    detail.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
    detail.font = [UIFont systemFontOfSize:19.0];
    if (detailOutput != NULL) {
        *detailOutput = detail;
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        icon, name, detail, [UIView new]
    ]];
    stack.userInteractionEnabled = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 14.0;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:26.0].active = YES;
    [icon.heightAnchor constraintEqualToConstant:26.0].active = YES;
    [button addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:button.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:8.0],
        [stack.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-8.0],
        [stack.bottomAnchor constraintEqualToAnchor:button.bottomAnchor]
    ]];
    return button;
}

- (void)observePlayback {
    __weak YTKACEDownloadPlayerController *weakSelf = self;
    self.timeObserver = [self.session.player addPeriodicTimeObserverForInterval:
        CMTimeMakeWithSeconds(0.25, 600) queue:dispatch_get_main_queue()
        usingBlock:^(__unused CMTime time) {
            [weakSelf refreshControls];
        }];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(playbackChanged:)
        name:YTKACEDownloadPlaybackDidChangeNotification object:self.session];
}

- (void)playbackChanged:(NSNotification *)notification {
    (void)notification;
    [self refreshControls];
}

- (void)refreshControls {
    NSURL *currentURL = self.session.currentURL;
    self.titleLabel.text = currentURL.lastPathComponent.stringByDeletingPathExtension;
    if (![self.subtitleMediaPath isEqualToString:currentURL.path]) {
        self.subtitleMediaPath = currentURL.path;
        NSArray<YTKACESubtitleCue *> *loaded =
            currentURL == nil ? @[] : YTKACEReadSubtitles(currentURL);
        if (loaded.count == 0 && currentURL != nil) {
            loaded = YTKACEReadEmbeddedSubtitles(currentURL);
        }
        self.subtitleCues = loaded;
    }
    NSTimeInterval elapsed = CMTimeGetSeconds(self.session.player.currentTime);
    NSTimeInterval duration = CMTimeGetSeconds(self.session.player.currentItem.duration);
    if (!self.scrubbing) {
        self.slider.minimumValue = 0.0f;
        self.slider.maximumValue = isfinite(duration) && duration > 0.0
            ? (float)duration : 1.0f;
        self.slider.value = isfinite(elapsed) ? (float)elapsed : 0.0f;
    }
    self.elapsedLabel.text = YTKACEPlayerTimeText(elapsed);
    self.durationLabel.text = YTKACEPlayerTimeText(duration);
    NSString *playSymbol = self.session.player.rate == 0.0f ? @"play.fill" : @"pause.fill";
    [self.playButton setImage:[UIImage systemImageNamed:playSymbol] forState:UIControlStateNormal];
    self.repeatButton.tintColor = self.session.repeatEnabled
        ? UIColor.systemRedColor : UIColor.whiteColor;
    self.captionButton.hidden = self.subtitleCues.count == 0;
    self.captionButton.tintColor = self.subtitlesEnabled
        ? UIColor.systemRedColor : UIColor.whiteColor;
    self.speedDetail.text = [NSString stringWithFormat:@"· %.2gx", self.session.playbackRate];
    if (self.session.pauseAtEnd) {
        self.sleepDetail.text = YTKACELocalized(@"· End of track");
    } else if (self.sleepTimer.isValid) {
        self.sleepDetail.text = [NSString stringWithFormat:@"· %ldm",
            (long)self.sleepMinutes];
    } else {
        self.sleepDetail.text = YTKACELocalized(@"· Off");
    }
    self.gesturesDetail.text = self.session.gesturesEnabled ? YTKACELocalized(@"· On") : YTKACELocalized(@"· Off");
    self.autoplayDetail.text = self.session.autoplayEnabled ? YTKACELocalized(@"· On") : YTKACELocalized(@"· Off");
    YTKACESubtitleCue *activeCue = nil;
    for (YTKACESubtitleCue *cue in self.subtitleCues) {
        if (elapsed >= cue.start && elapsed <= cue.end) {
            activeCue = cue;
            break;
        }
        if (cue.start > elapsed) break;
    }
    self.subtitleLabel.text = activeCue.text;
    self.subtitleLabel.hidden = activeCue == nil || !self.subtitlesEnabled;
}

- (void)togglePlayback { [self.session togglePlayback]; [self scheduleControlsHide]; }
- (void)skipBack { [self.session seekBy:-10.0]; [self scheduleControlsHide]; }
- (void)skipForward { [self.session seekBy:10.0]; [self scheduleControlsHide]; }
- (void)previousItem { [self.session playPrevious]; [self scheduleControlsHide]; }
- (void)nextItem { [self.session playNext]; [self hideOptions]; [self scheduleControlsHide]; }

- (void)toggleSubtitles {
    self.subtitlesEnabled = !self.subtitlesEnabled;
    [NSUserDefaults.standardUserDefaults
        setBool:!self.subtitlesEnabled
         forKey:@"YTKACE.Preference.Downloads.SubtitlesHidden"];
    self.captionButton.tintColor = self.subtitlesEnabled
        ? UIColor.systemRedColor : UIColor.whiteColor;
    if (!self.subtitlesEnabled) self.subtitleLabel.hidden = YES;
}

- (void)toggleRepeat {
    self.session.repeatEnabled = !self.session.repeatEnabled;
    [self refreshControls];
    [self scheduleControlsHide];
}

- (void)toggleAspect {
    self.aspectFill = !self.aspectFill;
    self.playerSurface.playerLayer.videoGravity = self.aspectFill
        ? AVLayerVideoGravityResizeAspectFill : AVLayerVideoGravityResizeAspect;
    [self scheduleControlsHide];
}

- (void)sliderStarted { self.scrubbing = YES; [self.hideTimer invalidate]; }
- (void)sliderChanged { self.elapsedLabel.text = YTKACEPlayerTimeText(self.slider.value); }
- (void)sliderEnded {
    self.scrubbing = NO;
    [self.session.player seekToTime:CMTimeMakeWithSeconds(self.slider.value, 600)
        toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    [self scheduleControlsHide];
}

- (void)toggleControls {
    if (!self.optionsView.hidden) {
        return;
    }
    BOOL show = self.controlsView.alpha < 0.5;
    [UIView animateWithDuration:0.18 animations:^{
        self.controlsView.alpha = show ? 1.0 : 0.0;
    }];
    show ? [self scheduleControlsHide] : [self.hideTimer invalidate];
}

- (void)scheduleControlsHide {
    [self.hideTimer invalidate];
    if (self.session.player.rate == 0.0f || !self.optionsView.hidden) {
        return;
    }
    self.hideTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
        target:self selector:@selector(hideControls)
        userInfo:nil repeats:NO];
}

- (void)hideControls {
    [UIView animateWithDuration:0.25 animations:^{
        self.controlsView.alpha = 0.0;
    }];
}

- (void)showOptions {
    [self.hideTimer invalidate];
    [self refreshControls];
    self.optionsView.hidden = NO;
    self.optionsView.alpha = 0.0;
    [UIView animateWithDuration:0.2 animations:^{ self.optionsView.alpha = 1.0; }];
}

- (void)hideOptions {
    [UIView animateWithDuration:0.18 animations:^{ self.optionsView.alpha = 0.0; }
        completion:^(__unused BOOL finished) {
            self.optionsView.hidden = YES;
            [self scheduleControlsHide];
        }];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer.view == self.optionsView &&
        [touch.view isDescendantOfView:self.optionsCard]) {
        return NO;
    }
    return YES;
}

- (void)selectSpeed {
    NSArray<NSNumber *> *speeds = @[@0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @1.75,
                                    @2.0, @2.5, @3.0, @4.0, @5.0];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSUInteger selected = 0;
    for (NSUInteger index = 0; index < speeds.count; index++) {
        NSNumber *speed = speeds[index];
        [titles addObject:[NSString stringWithFormat:@"%.2gx", speed.floatValue]];
        if (fabs(speed.floatValue - self.session.playbackRate) < 0.01) {
            selected = index;
        }
    }
    YTKACEPresentSelectionMenu(self, self.optionsCard, YTKACELocalized(@"Playback Speed"), titles,
        selected, ^(NSUInteger index) {
            self.session.playbackRate = speeds[index].floatValue;
            [self refreshControls];
        });
}

- (void)selectSleepTimer {
    NSArray<NSString *> *titles = @[
        YTKACELocalized(@"Off"), YTKACELocalized(@"End of track"),
        YTKACELocalized(@"15 Minutes"), YTKACELocalized(@"30 Minutes"),
        YTKACELocalized(@"45 Minutes"), YTKACELocalized(@"60 Minutes")
    ];
    NSArray<NSNumber *> *minutes = @[@0, @0, @15, @30, @45, @60];
    NSUInteger selected = self.session.pauseAtEnd ? 1 : 0;
    if (self.sleepTimer.isValid) {
        NSUInteger match = [minutes indexOfObject:@(self.sleepMinutes)];
        if (match != NSNotFound) selected = match;
    }
    YTKACEPresentSelectionMenu(self, self.optionsCard, YTKACELocalized(@"Sleep Timer"), titles,
        selected, ^(NSUInteger index) {
            [self.sleepTimer invalidate];
            self.sleepTimer = nil;
            self.sleepMinutes = 0;
            self.session.pauseAtEnd = index == 1;
            NSInteger minute = minutes[index].integerValue;
            if (minute > 0) {
                self.sleepMinutes = minute;
                self.sleepTimer = [NSTimer scheduledTimerWithTimeInterval:
                    minute * 60.0 target:self selector:@selector(sleepTimerFired)
                    userInfo:nil repeats:NO];
            }
            [self refreshControls];
        });
}

- (void)sleepTimerFired {
    [self.session pause];
    self.sleepTimer = nil;
    self.sleepMinutes = 0;
    [self refreshControls];
}

- (void)toggleGestures {
    self.session.gesturesEnabled = !self.session.gesturesEnabled;
    [self refreshControls];
}

- (void)toggleAutoplay {
    self.session.autoplayEnabled = !self.session.autoplayEnabled;
    [self refreshControls];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (!self.session.gesturesEnabled || !self.optionsView.hidden) {
        return;
    }
    CGPoint translation = [gesture translationInView:self.controlsView];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.panStart = translation;
        [self.hideTimer invalidate];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGFloat dx = translation.x - self.panStart.x;
        CGFloat dy = translation.y - self.panStart.y;
        if (fabs(dx) > fabs(dy) && fabs(dx) > 24.0) {
            [self.session seekBy:dx / 18.0];
            self.panStart = translation;
        } else if (fabs(dy) > 18.0) {
            CGFloat change = -dy / MAX(180.0, CGRectGetHeight(self.view.bounds));
            CGPoint location = [gesture locationInView:self.view];
            if (location.x < CGRectGetMidX(self.view.bounds)) {
                UIScreen.mainScreen.brightness = MAX(0.0,
                    MIN(1.0, UIScreen.mainScreen.brightness + change));
            } else {
                MPVolumeView *volumeView = [MPVolumeView new];
                UISlider *volumeSlider = nil;
                for (UIView *view in volumeView.subviews) {
                    if ([view isKindOfClass:UISlider.class]) {
                        volumeSlider = (UISlider *)view;
                        break;
                    }
                }
                [volumeSlider setValue:MAX(0.0, MIN(1.0, volumeSlider.value + change)) animated:NO];
                [volumeSlider sendActionsForControlEvents:UIControlEventValueChanged];
            }
            self.panStart = translation;
        }
    }
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {
        [self scheduleControlsHide];
    }
}

- (void)minimizePlayer {
    dispatch_block_t handler = self.minimizeHandler;
    self.playerSurface.player = nil;
    [self dismissViewControllerAnimated:YES completion:handler];
}

@end
