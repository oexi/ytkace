#import "YTKACEAudioPlayerController.h"
#import "YTKACEDownloadPlayerController.h"
#import "MediaArtwork.h"
#import "DownloadSponsor.h"
#import "../../Settings/YTKACESettingsPages.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"

#import <AVFoundation/AVFoundation.h>

static NSString *YTKACEAudioTime(NSTimeInterval value) {
    if (!isfinite(value) || value < 0.0) return @"0:00";
    NSInteger seconds = (NSInteger)floor(value);
    return [NSString stringWithFormat:@"%ld:%02ld",
        (long)(seconds / 60), (long)(seconds % 60)];
}

@interface YTKACEAudioPlayerController ()
    <UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, strong) YTKACEDownloadPlaybackSession *session;
@property(nonatomic, strong) UIImageView *artworkView;
@property(nonatomic, strong) UILabel *positionLabel;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *channelLabel;
@property(nonatomic, strong) UILabel *elapsedLabel;
@property(nonatomic, strong) UILabel *durationLabel;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, strong) UIButton *playButton;
@property(nonatomic, strong) UIButton *repeatButton;
@property(nonatomic, strong) UIView *queuePanel;
@property(nonatomic, strong) UITableView *queueTable;
@property(nonatomic, strong) NSLayoutConstraint *queueHeight;
@property(nonatomic, strong) UIView *optionsView;
@property(nonatomic, strong) UIView *optionsCard;
@property(nonatomic, strong) UILabel *speedDetail;
@property(nonatomic, strong) UILabel *sleepDetail;
@property(nonatomic, strong) UILabel *autoplayDetail;
@property(nonatomic, strong) NSTimer *sleepTimer;
@property(nonatomic, strong) id timeObserver;
@property(nonatomic, assign) BOOL queueOpen;
@property(nonatomic, assign) BOOL scrubbing;
@property(nonatomic, assign) NSInteger sleepMinutes;
@end

@implementation YTKACEAudioPlayerController

- (void)applyTheme {
    self.view.backgroundColor =
        YTKACEInterfaceBackgroundColor(self.traitCollection);
    self.queuePanel.backgroundColor =
        YTKACEInterfaceBackgroundColor(self.traitCollection);
    self.optionsCard.backgroundColor =
        YTKACEInterfaceSurfaceColor(self.traitCollection);
    self.artworkView.backgroundColor =
        YTKACEInterfaceSurfaceColor(self.traitCollection);
    self.titleLabel.textColor = UIColor.labelColor;
    self.channelLabel.textColor = UIColor.secondaryLabelColor;
    self.positionLabel.textColor = UIColor.secondaryLabelColor;
    self.elapsedLabel.textColor = UIColor.secondaryLabelColor;
    self.durationLabel.textColor = UIColor.secondaryLabelColor;
    self.slider.minimumTrackTintColor = UIColor.labelColor;
    self.slider.maximumTrackTintColor = UIColor.tertiaryLabelColor;
    self.playButton.tintColor = UIColor.labelColor;
    [self.queueTable reloadData];
}

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
    [self buildPlayer];
    [self buildQueue];
    [self buildOptions];
    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(playbackChanged:)
        name:YTKACEDownloadPlaybackDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(playbackChanged:)
        name:YTKACEDownloadInfoDidChangeNotification object:nil];
    __weak YTKACEAudioPlayerController *weakSelf = self;
    self.timeObserver = [self.session.player addPeriodicTimeObserverForInterval:
        CMTimeMakeWithSeconds(0.5, 600) queue:dispatch_get_main_queue()
        usingBlock:^(__unused CMTime time) { [weakSelf refreshTime]; }];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyTheme];
    [self.session play];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection == nil ||
        [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self applyTheme];
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.sleepTimer invalidate];
    if (self.timeObserver != nil) {
        [self.session.player removeTimeObserver:self.timeObserver];
    }
}

- (BOOL)prefersStatusBarHidden { return NO; }

- (UIButton *)symbolButton:(NSString *)symbol size:(CGFloat)size action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:size
            weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
        forState:UIControlStateNormal];
    button.tintColor = UIColor.labelColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UILabel *)timeLabel {
    UILabel *label = [UILabel new];
    label.font = [UIFont monospacedDigitSystemFontOfSize:11.0
        weight:UIFontWeightRegular];
    label.textColor = UIColor.secondaryLabelColor;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)buildPlayer {
    UIButton *minimize = [self symbolButton:@"chevron.down" size:17.0
        action:@selector(minimize)];
    UIButton *more = [self symbolButton:@"ellipsis" size:21.0
        action:@selector(showOptions)];
    self.positionLabel = [UILabel new];
    self.positionLabel.textAlignment = NSTextAlignmentCenter;
    self.positionLabel.textColor = UIColor.secondaryLabelColor;
    self.positionLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[
        minimize, self.positionLabel, more
    ]];
    top.axis = UILayoutConstraintAxisHorizontal;
    top.alignment = UIStackViewAlignmentCenter;
    top.translatesAutoresizingMaskIntoConstraints = NO;
    [minimize.widthAnchor constraintEqualToConstant:44.0].active = YES;
    [minimize.heightAnchor constraintEqualToConstant:44.0].active = YES;
    [more.widthAnchor constraintEqualToConstant:44.0].active = YES;
    [more.heightAnchor constraintEqualToConstant:44.0].active = YES;
    [self.view addSubview:top];

    self.artworkView = [UIImageView new];
    self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkView.clipsToBounds = YES;
    self.artworkView.layer.cornerRadius = 9.0;
    self.artworkView.backgroundColor =
        YTKACEInterfaceSurfaceColor(self.traitCollection);
    self.artworkView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.artworkView];

    self.titleLabel = [UILabel new];
    self.titleLabel.textColor = UIColor.labelColor;
    self.titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.titleLabel];
    self.channelLabel = [UILabel new];
    self.channelLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    self.channelLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.channelLabel];

    self.slider = [UISlider new];
    self.slider.minimumTrackTintColor = UIColor.labelColor;
    self.slider.maximumTrackTintColor = UIColor.tertiaryLabelColor;
    self.slider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.slider addTarget:self action:@selector(sliderStarted)
        forControlEvents:UIControlEventTouchDown];
    [self.slider addTarget:self action:@selector(sliderChanged)
        forControlEvents:UIControlEventValueChanged];
    [self.slider addTarget:self action:@selector(sliderEnded)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
            UIControlEventTouchCancel];
    [self.view addSubview:self.slider];
    self.elapsedLabel = [self timeLabel];
    self.durationLabel = [self timeLabel];
    self.durationLabel.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:self.elapsedLabel];
    [self.view addSubview:self.durationLabel];

    self.repeatButton = [self symbolButton:@"repeat" size:19.0
        action:@selector(toggleRepeat)];
    UIButton *previous = [self symbolButton:@"backward.end.fill" size:19.0
        action:@selector(previous)];
    self.playButton = [self symbolButton:@"pause.fill" size:44.0
        action:@selector(togglePlayback)];
    UIButton *next = [self symbolButton:@"forward.end.fill" size:19.0
        action:@selector(next)];
    UIButton *shuffle = [self symbolButton:@"shuffle" size:19.0
        action:@selector(shuffleQueue)];
    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.repeatButton, previous, self.playButton, next, shuffle
    ]];
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.alignment = UIStackViewAlignmentCenter;
    controls.distribution = UIStackViewDistributionEqualSpacing;
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    for (UIButton *button in @[self.repeatButton, previous, next, shuffle]) {
        [button.widthAnchor constraintEqualToConstant:44.0].active = YES;
        [button.heightAnchor constraintEqualToConstant:44.0].active = YES;
    }
    [self.playButton.widthAnchor constraintEqualToConstant:72.0].active = YES;
    [self.playButton.heightAnchor constraintEqualToConstant:72.0].active = YES;
    [self.view addSubview:controls];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *artworkWidth = [self.artworkView.widthAnchor
        constraintEqualToAnchor:self.view.widthAnchor multiplier:0.78];
    artworkWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [top.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4.0],
        [top.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
        [top.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [top.heightAnchor constraintEqualToConstant:44.0],
        [self.artworkView.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:12.0],
        [self.artworkView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        artworkWidth,
        [self.artworkView.widthAnchor constraintLessThanOrEqualToConstant:410.0],
        [self.artworkView.heightAnchor constraintEqualToAnchor:self.artworkView.widthAnchor],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.artworkView.bottomAnchor constant:16.0],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20.0],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20.0],
        [self.channelLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2.0],
        [self.channelLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.channelLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
        [self.slider.topAnchor constraintEqualToAnchor:self.channelLabel.bottomAnchor constant:10.0],
        [self.slider.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.slider.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
        [self.elapsedLabel.topAnchor constraintEqualToAnchor:self.slider.bottomAnchor constant:-2.0],
        [self.elapsedLabel.leadingAnchor constraintEqualToAnchor:self.slider.leadingAnchor],
        [self.durationLabel.topAnchor constraintEqualToAnchor:self.slider.bottomAnchor constant:-2.0],
        [self.durationLabel.trailingAnchor constraintEqualToAnchor:self.slider.trailingAnchor],
        [controls.topAnchor constraintEqualToAnchor:self.elapsedLabel.bottomAnchor constant:16.0],
        [controls.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:26.0],
        [controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-26.0],
        [controls.heightAnchor constraintEqualToConstant:76.0]
    ]];
}

- (void)buildQueue {
    self.queuePanel = [UIView new];
    self.queuePanel.backgroundColor =
        YTKACEInterfaceBackgroundColor(self.traitCollection);
    self.queuePanel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.queuePanel];

    UIButton *header = [UIButton buttonWithType:UIButtonTypeSystem];
    header.tintColor = UIColor.secondaryLabelColor;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [header addTarget:self action:@selector(toggleQueue)
        forControlEvents:UIControlEventTouchUpInside];
    UILabel *handle = [UILabel new];
    handle.text = YTKACELocalized(@"━");
    handle.textColor = UIColor.tertiaryLabelColor;
    handle.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightBold];
    handle.textAlignment = NSTextAlignmentCenter;
    UILabel *queueTitle = [UILabel new];
    queueTitle.text = YTKACELocalized(@"Your Queue");
    queueTitle.textColor = UIColor.secondaryLabelColor;
    queueTitle.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    queueTitle.textAlignment = NSTextAlignmentCenter;
    UIStackView *headerLabels = [[UIStackView alloc] initWithArrangedSubviews:@[
        handle, queueTitle
    ]];
    headerLabels.axis = UILayoutConstraintAxisVertical;
    headerLabels.spacing = -8.0;
    headerLabels.userInteractionEnabled = NO;
    headerLabels.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:headerLabels];
    [self.queuePanel addSubview:header];

    self.queueTable = [[UITableView alloc] initWithFrame:CGRectZero
        style:UITableViewStylePlain];
    self.queueTable.backgroundColor = UIColor.clearColor;
    self.queueTable.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.queueTable.rowHeight = 58.0;
    self.queueTable.dataSource = self;
    self.queueTable.delegate = self;
    self.queueTable.allowsSelectionDuringEditing = YES;
    self.queueTable.translatesAutoresizingMaskIntoConstraints = NO;
    [self.queueTable setEditing:YES animated:NO];
    [self.queuePanel addSubview:self.queueTable];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    self.queueHeight = [self.queuePanel.heightAnchor constraintEqualToConstant:38.0];
    [NSLayoutConstraint activateConstraints:@[
        [self.queuePanel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.queuePanel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.queuePanel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        self.queueHeight,
        [header.topAnchor constraintEqualToAnchor:self.queuePanel.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:42.0],
        [headerLabels.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [headerLabels.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.queueTable.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [self.queueTable.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.queueTable.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.queueTable.bottomAnchor constraintEqualToAnchor:self.queuePanel.bottomAnchor]
    ]];
}

- (UIView *)optionRow:(NSString *)symbol title:(NSString *)title
                detail:(UILabel **)detail action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tintColor = UIColor.labelColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:19.0
            weight:UIImageSymbolWeightRegular];
    UIImage *image = [UIImage systemImageNamed:symbol
                             withConfiguration:configuration];
    UIImageView *icon = [[UIImageView alloc] initWithImage:image];
    icon.tintColor = UIColor.labelColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    UILabel *name = [UILabel new];
    name.text = title;
    name.textColor = UIColor.labelColor;
    name.font = [UIFont systemFontOfSize:15.0];
    UILabel *value = [UILabel new];
    value.textColor = UIColor.secondaryLabelColor;
    value.font = [UIFont systemFontOfSize:15.0];
    value.textAlignment = NSTextAlignmentRight;
    value.lineBreakMode = NSLineBreakByTruncatingTail;
    if (detail != NULL) *detail = value;
    UIView *spacer = [UIView new];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[
        icon, name, spacer, value
    ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 14.0;
    row.alignment = UIStackViewAlignmentCenter;
    row.userInteractionEnabled = NO;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:26.0].active = YES;
    [icon.heightAnchor constraintEqualToConstant:26.0].active = YES;
    [name setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh
                                          forAxis:UILayoutConstraintAxisHorizontal];
    [value setContentHuggingPriority:UILayoutPriorityRequired
                             forAxis:UILayoutConstraintAxisHorizontal];
    [value setContentCompressionResistancePriority:UILayoutPriorityRequired
                                            forAxis:UILayoutConstraintAxisHorizontal];
    [button addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:15.0],
        [row.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-15.0],
        [row.topAnchor constraintEqualToAnchor:button.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:button.bottomAnchor]
    ]];
    return button;
}

- (void)buildOptions {
    self.optionsView = [UIView new];
    self.optionsView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.58];
    self.optionsView.hidden = YES;
    self.optionsView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.optionsView];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(hideOptions)];
    tap.delegate = self;
    [self.optionsView addGestureRecognizer:tap];

    self.optionsCard = [UIView new];
    self.optionsCard.backgroundColor =
        YTKACEInterfaceSurfaceColor(self.traitCollection);
    self.optionsCard.layer.cornerRadius = 12.0;
    self.optionsCard.translatesAutoresizingMaskIntoConstraints = NO;
    [self.optionsView addSubview:self.optionsCard];
    UILabel *handle = [UILabel new];
    handle.text = YTKACELocalized(@"━");
    handle.textColor = UIColor.tertiaryLabelColor;
    handle.textAlignment = NSTextAlignmentCenter;
    handle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.optionsCard addSubview:handle];
    UIStackView *rows = [UIStackView new];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.distribution = UIStackViewDistributionFillEqually;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *speedDetail = nil;
    UILabel *sleepDetail = nil;
    UILabel *autoplayDetail = nil;
    [rows addArrangedSubview:[self optionRow:@"speedometer"
        title:@"Playback Speed" detail:&speedDetail action:@selector(selectSpeed)]];
    [rows addArrangedSubview:[self optionRow:@"moon.zzz.fill"
        title:@"Sleep Timer" detail:&sleepDetail action:@selector(selectSleep)]];
    [rows addArrangedSubview:[self optionRow:@"forward.end.fill"
        title:@"AutoPlay" detail:&autoplayDetail action:@selector(toggleAutoplay)]];
    self.speedDetail = speedDetail;
    self.sleepDetail = sleepDetail;
    self.autoplayDetail = autoplayDetail;
    [rows addArrangedSubview:[self optionRow:@"list.bullet"
        title:@"Play Next" detail:NULL action:@selector(next)]];
    [rows addArrangedSubview:[self optionRow:@"xmark"
        title:@"Close" detail:NULL action:@selector(hideOptions)]];
    [self.optionsCard addSubview:rows];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.optionsView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.optionsView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.optionsView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.optionsView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.optionsCard.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:7.0],
        [self.optionsCard.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-7.0],
        [self.optionsCard.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-7.0],
        [self.optionsCard.heightAnchor constraintEqualToConstant:286.0],
        [handle.topAnchor constraintEqualToAnchor:self.optionsCard.topAnchor constant:2.0],
        [handle.centerXAnchor constraintEqualToAnchor:self.optionsCard.centerXAnchor],
        [handle.heightAnchor constraintEqualToConstant:20.0],
        [rows.topAnchor constraintEqualToAnchor:handle.bottomAnchor],
        [rows.leadingAnchor constraintEqualToAnchor:self.optionsCard.leadingAnchor],
        [rows.trailingAnchor constraintEqualToAnchor:self.optionsCard.trailingAnchor],
        [rows.bottomAnchor constraintEqualToAnchor:self.optionsCard.bottomAnchor constant:-5.0]
    ]];
}

- (void)playbackChanged:(NSNotification *)notification {
    (void)notification;
    [self refresh];
}

- (void)refresh {
    NSURL *URL = self.session.currentURL;
    self.titleLabel.text = URL.lastPathComponent.stringByDeletingPathExtension ?: @"Audio";
    self.channelLabel.text = URL == nil ? nil : YTKACEStoredChannelName(URL);
    if (self.queueOpen) self.queueHeight.constant = [self openQueueHeight];
    UIImage *artwork = URL == nil ? nil : YTKACEMediaArtworkImage(URL);
    self.artworkView.image = artwork ?: [UIImage systemImageNamed:@"music.note"];
    self.artworkView.tintColor = UIColor.systemGrayColor;
    NSInteger count = self.session.playlist.count;
    NSInteger index = self.session.currentIndex == NSNotFound
        ? 0 : self.session.currentIndex + 1;
    self.positionLabel.text = [NSString stringWithFormat:@"%ld / %ld",
        (long)index, (long)count];
    NSString *play = self.session.player.rate == 0.0f ? @"play.fill" : @"pause.fill";
    [self.playButton setImage:[UIImage systemImageNamed:play] forState:UIControlStateNormal];
    self.repeatButton.tintColor = self.session.repeatEnabled
        ? UIColor.systemRedColor : UIColor.labelColor;
    self.speedDetail.text = [NSString stringWithFormat:@"· %.2gx",
        self.session.playbackRate];
    if (self.session.pauseAtEnd) {
        self.sleepDetail.text = YTKACELocalized(@"· End of track");
    } else if (self.sleepTimer.isValid) {
        self.sleepDetail.text = [NSString stringWithFormat:@"· %ldm",
            (long)self.sleepMinutes];
    } else {
        self.sleepDetail.text = YTKACELocalized(@"· Off");
    }
    self.autoplayDetail.text = self.session.autoplayEnabled ? @"· On" : @"· Off";
    [self.queueTable reloadData];
    [self refreshTime];
}

- (void)refreshTime {
    NSTimeInterval current = CMTimeGetSeconds(self.session.player.currentTime);
    NSTimeInterval duration = CMTimeGetSeconds(self.session.player.currentItem.duration);
    if (!isfinite(current)) current = 0.0;
    if (!isfinite(duration) || duration < 0.0) duration = 0.0;
    if (!self.scrubbing) {
        self.slider.maximumValue = MAX(duration, 1.0);
        self.slider.value = MIN(current, self.slider.maximumValue);
    }
    self.elapsedLabel.text = YTKACEAudioTime(current);
    self.durationLabel.text = YTKACEAudioTime(duration);
}

- (void)togglePlayback { [self.session togglePlayback]; [self refresh]; }
- (void)previous { [self.session playPrevious]; [self refresh]; }
- (void)next { [self.session playNext]; [self hideOptions]; [self refresh]; }
- (void)toggleRepeat { self.session.repeatEnabled = !self.session.repeatEnabled; [self refresh]; }

- (void)sliderStarted { self.scrubbing = YES; }
- (void)sliderChanged { self.elapsedLabel.text = YTKACEAudioTime(self.slider.value); }
- (void)sliderEnded {
    self.scrubbing = NO;
    [self.session.player seekToTime:CMTimeMakeWithSeconds(self.slider.value, 600)
        toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (CGFloat)openQueueHeight {
    [self.view layoutIfNeeded];
    UIView *anchor = self.channelLabel.text.length != 0 ? self.channelLabel : self.titleLabel;
    CGFloat room = CGRectGetHeight(self.view.bounds) - CGRectGetMaxY(anchor.frame) - 16.0;
    CGFloat height = MIN(330.0, CGRectGetHeight(self.view.bounds) * 0.43);
    return MAX(120.0, MIN(height, room));
}

- (void)toggleQueue {
    self.queueOpen = !self.queueOpen;
    self.queueHeight.constant = self.queueOpen ? [self openQueueHeight] : 38.0;
    [UIView animateWithDuration:0.28 delay:0.0
        usingSpringWithDamping:0.9 initialSpringVelocity:0.0 options:0
        animations:^{ [self.view layoutIfNeeded]; } completion:nil];
}

- (void)shuffleQueue {
    NSMutableArray<NSURL *> *queue = [self.session.playlist mutableCopy];
    for (NSInteger index = (NSInteger)queue.count - 1; index > 0; index--) {
        [queue exchangeObjectAtIndex:(NSUInteger)index
            withObjectAtIndex:(NSUInteger)arc4random_uniform((uint32_t)index + 1)];
    }
    [self.session updatePlaylist:queue];
    [self refresh];
}

- (void)showOptions {
    [self refresh];
    self.optionsView.hidden = NO;
    self.optionsView.alpha = 0.0;
    [UIView animateWithDuration:0.2 animations:^{ self.optionsView.alpha = 1.0; }];
}

- (void)hideOptions {
    if (self.optionsView.hidden) return;
    [UIView animateWithDuration:0.18 animations:^{ self.optionsView.alpha = 0.0; }
        completion:^(__unused BOOL finished) { self.optionsView.hidden = YES; }];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    return gestureRecognizer.view != self.optionsView ||
        ![touch.view isDescendantOfView:self.optionsCard];
}

- (void)selectSpeed {
    NSArray<NSNumber *> *speeds = @[
        @0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @1.75,
        @2.0, @2.5, @3.0, @4.0, @5.0
    ];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSUInteger selected = 0;
    for (NSUInteger index = 0; index < speeds.count; index++) {
        NSNumber *speed = speeds[index];
        [titles addObject:[NSString stringWithFormat:@"%.2gx", speed.floatValue]];
        if (fabs(speed.floatValue - self.session.playbackRate) < 0.01) {
            selected = index;
        }
    }
    YTKACEPresentSelectionMenu(self, self.optionsCard, @"Playback Speed", titles,
        selected, ^(NSUInteger index) {
            self.session.playbackRate = speeds[index].floatValue;
            [self refresh];
        });
}

- (void)selectSleep {
    NSArray<NSString *> *titles = @[
        @"Off", @"End of track", @"15 Minutes", @"30 Minutes",
        @"45 Minutes", @"60 Minutes"
    ];
    NSArray<NSNumber *> *minutes = @[@0, @0, @15, @30, @45, @60];
    NSUInteger selected = self.session.pauseAtEnd ? 1 : 0;
    if (self.sleepTimer.isValid) {
        NSUInteger match = [minutes indexOfObject:@(self.sleepMinutes)];
        if (match != NSNotFound) selected = match;
    }
    YTKACEPresentSelectionMenu(self, self.optionsCard, @"Sleep Timer", titles,
        selected, ^(NSUInteger index) {
            [self.sleepTimer invalidate];
            self.sleepTimer = nil;
            self.sleepMinutes = 0;
            self.session.pauseAtEnd = index == 1;
            NSInteger minute = minutes[index].integerValue;
            if (minute > 0) {
                self.sleepMinutes = minute;
                self.sleepTimer = [NSTimer scheduledTimerWithTimeInterval:
                    minute * 60.0 target:self selector:@selector(sleepFired)
                    userInfo:nil repeats:NO];
            }
            [self refresh];
        });
}

- (void)sleepFired {
    self.sleepMinutes = 0;
    self.sleepTimer = nil;
    [self.session pause];
    [self refresh];
}

- (void)toggleAutoplay {
    self.session.autoplayEnabled = !self.session.autoplayEnabled;
    [self refresh];
}

- (void)minimize {
    dispatch_block_t handler = self.minimizeHandler;
    [self dismissViewControllerAnimated:YES completion:handler];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.session.playlist.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = @"YTKACEAudioQueueCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
            reuseIdentifier:identifier];
        cell.backgroundColor = UIColor.clearColor;
        cell.textLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    }
    NSURL *URL = self.session.playlist[(NSUInteger)indexPath.row];
    cell.textLabel.text = URL.lastPathComponent.stringByDeletingPathExtension;
    cell.textLabel.textColor = [URL isEqual:self.session.currentURL]
        ? UIColor.systemRedColor : UIColor.labelColor;
    NSTimeInterval duration = CMTimeGetSeconds([AVURLAsset URLAssetWithURL:URL
        options:nil].duration);
    NSString *channel = YTKACEStoredChannelName(URL);
    cell.detailTextLabel.text = channel.length != 0
        ? [NSString stringWithFormat:@"%@  ·  %@", channel, YTKACEAudioTime(duration)]
        : YTKACEAudioTime(duration);
    UIImage *artwork = YTKACEMediaArtworkImage(URL);
    cell.imageView.image = artwork ?: [UIImage systemImageNamed:@"music.note"];
    cell.imageView.tintColor = UIColor.systemGrayColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSURL *URL = self.session.playlist[(NSUInteger)indexPath.row];
    [self.session loadURL:URL playlist:self.session.playlist index:indexPath.row];
    [self refresh];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
    editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView
    shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return NO;
}

- (void)tableView:(UITableView *)tableView
    moveRowAtIndexPath:(NSIndexPath *)source
           toIndexPath:(NSIndexPath *)destination {
    (void)tableView;
    NSMutableArray<NSURL *> *queue = [self.session.playlist mutableCopy];
    NSURL *URL = queue[(NSUInteger)source.row];
    [queue removeObjectAtIndex:(NSUInteger)source.row];
    [queue insertObject:URL atIndex:(NSUInteger)destination.row];
    [self.session updatePlaylist:queue];
    [self refresh];
}

@end
