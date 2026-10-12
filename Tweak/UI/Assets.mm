#import "Assets.h"

#import <dlfcn.h>

static NSString *YTKACELoadedImagePath(void) {
    Dl_info image;
    memset(&image, 0, sizeof(image));
    if (dladdr((const void *)&YTKACEAssetsBundle, &image) == 0) return nil;
    if (image.dli_fname == NULL) return nil;
    return [NSString stringWithUTF8String:image.dli_fname];
}

static NSArray<NSString *> *YTKACECandidateBundlePaths(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *loaded = YTKACELoadedImagePath();
    if (loaded.length != 0) {
        for (NSString *marker in @[@"/Library/MobileSubstrate/DynamicLibraries/", @"/usr/lib/TweakInject/"]) {
            NSRange range = [loaded rangeOfString:marker];
            if (range.location == NSNotFound) continue;
            NSString *root = [loaded substringToIndex:range.location];
            [candidates addObject:[root stringByAppendingPathComponent:
                @"Library/Application Support/YTKACE.bundle"]];
        }
        NSString *directory = loaded.stringByDeletingLastPathComponent;
        for (NSUInteger level = 0; level < 2 && directory.length > 1; level++) {
            [candidates addObject:
                [directory stringByAppendingPathComponent:@"YTKACE.bundle"]];
            directory = directory.stringByDeletingLastPathComponent;
        }
    }
    NSString *packaged = [NSBundle.mainBundle pathForResource:@"YTKACE"
                                                       ofType:@"bundle"];
    if (packaged.length != 0) [candidates addObject:packaged];
    [candidates addObject:@"/var/jb/Library/Application Support/YTKACE.bundle"];
    [candidates addObject:@"/Library/Application Support/YTKACE.bundle"];
    [candidates addObject:@"/var/jb/Library/MobileSubstrate/DynamicLibraries/YTKACE.bundle"];
    return candidates;
}

NSBundle *YTKACEAssetsBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        for (NSString *path in YTKACECandidateBundlePaths()) {
            BOOL directory = NO;
            if (![manager fileExistsAtPath:path isDirectory:&directory]) continue;
            if (!directory) continue;
            bundle = [NSBundle bundleWithPath:path];
            if (bundle != nil) break;
        }
    });
    return bundle;
}

UIImage *YTKACEAssetImage(NSString *name, NSString *fallbackSymbol) {
    UIImage *image = nil;
    NSBundle *bundle = YTKACEAssetsBundle();
    if (bundle != nil && name.length != 0) {
        image = [UIImage imageNamed:name
                           inBundle:bundle
      compatibleWithTraitCollection:nil];
    }
    if (image == nil && fallbackSymbol.length != 0) {
        if (@available(iOS 13.0, *)) {
            image = [UIImage systemImageNamed:fallbackSymbol];
        }
    }
    return image;
}

UIImage *YTKACEYouTubeImage(NSArray<NSString *> *names, NSString *fallbackSymbol) {
    for (NSString *name in names) {
        UIImage *image = [UIImage imageNamed:name];
        if (image != nil) return image;
    }
    return fallbackSymbol.length == 0 ? nil : [UIImage systemImageNamed:fallbackSymbol];
}

UIImage *YTKACEGearImage(void) {
    return YTKACEYouTubeImage(@[
        @"yt_outline_gear_24pt",
        @"yt_outline_gear_vd_theme_24",
        @"yt_outline_experimental_gear_vd_theme_24"
    ], @"gearshape");
}

UIImage *YTKACEShortsImage(BOOL selected) {
    return selected
        ? YTKACEYouTubeImage(@[
            @"yt_fill_youtube_shorts_24pt",
            @"yt_fill_youtube_shorts_vd_theme_24"
        ], @"play.rectangle.fill")
        : YTKACEYouTubeImage(@[
            @"yt_outline_youtube_shorts_24pt",
            @"yt_outline_youtube_shorts_vd_theme_24"
        ], @"play.rectangle");
}

UIImage *YTKACEDownloadTabImage(BOOL selected) {
    return [UIImage systemImageNamed:selected
        ? @"arrow.down.square.fill" : @"arrow.down.square"];
}

UIColor *YTKACEAccentColor(void) {
    return [UIColor colorWithRed:0.749 green:0.0 blue:0.075 alpha:1.0];
}
