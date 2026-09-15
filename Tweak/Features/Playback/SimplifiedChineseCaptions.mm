#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <atomic>
#include <stdlib.h>

static NSString * const YTKACESimplifiedChineseAutoTranslateKey =
    @"YTKACE.Preference.Playback.SimplifiedChineseAutoTranslate";
static NSString * const YTKACETraditionalProxyMarkerName = @"origin_tlang";
static NSString * const YTKACETraditionalProxyMarkerValue = @"zh-Hant";

static NSMutableDictionary<NSString *, NSValue *> *YTKACEChineseCaptionOriginals;
static NSMutableSet<NSString *> *YTKACEChineseCaptionInstalledHooks;
static const void *YTKACETraditionalCaptionTrackAssociation =
    &YTKACETraditionalCaptionTrackAssociation;
static std::atomic_bool YTKACETraditionalCaptionProxyActive(false);

static NSString *YTKACEChineseCaptionHookKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls),
                                      NSStringFromSelector(selector)];
}

static IMP YTKACEChineseCaptionOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        IMP original = (IMP)[YTKACEChineseCaptionOriginals[
            YTKACEChineseCaptionHookKey(cls, selector)] pointerValue];
        if (original != NULL) return original;
    }
    return NULL;
}

static id YTKACESafeValue(id object, NSString *key) {
    if (object == nil || key.length == 0) return nil;
    @try {
        if ([object isKindOfClass:NSDictionary.class]) {
            return [(NSDictionary *)object objectForKey:key];
        }
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL YTKACESafeSetValue(id object, NSString *key, id value) {
    if (object == nil || key.length == 0) return NO;
    @try {
        if ([object isKindOfClass:NSMutableDictionary.class]) {
            if (value != nil) {
                [(NSMutableDictionary *)object setObject:value forKey:key];
            } else {
                [(NSMutableDictionary *)object removeObjectForKey:key];
            }
            return YES;
        }
        [object setValue:value forKey:key];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static NSString *YTKACELanguageCodeForEntry(id entry) {
    if ([entry isKindOfClass:NSString.class]) return entry;
    for (NSString *key in @[@"languageCode", @"language_code", @"targetLanguageCode", @"targetLanguage", @"targetLang", @"language", @"code"]) {
        id value = YTKACESafeValue(entry, key);
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length] != 0) {
            return value;
        }
    }
    return nil;
}

static NSString *YTKACENormalizedLanguageCode(NSString *code) {
    return [[code ?: @"" stringByReplacingOccurrencesOfString:@"_" withString:@"-"]
        lowercaseString];
}

static BOOL YTKACEIsSimplifiedChineseCode(NSString *code) {
    NSString *normalized = YTKACENormalizedLanguageCode(code);
    return [normalized isEqualToString:@"zh-hans"] ||
           [normalized isEqualToString:@"zh-cn"] ||
           [normalized isEqualToString:@"zh-sg"] ||
           [normalized hasPrefix:@"zh-hans-"];
}

static BOOL YTKACEIsTraditionalChineseCode(NSString *code) {
    NSString *normalized = YTKACENormalizedLanguageCode(code);
    return [normalized isEqualToString:@"zh-hant"] ||
           [normalized isEqualToString:@"zh-tw"] ||
           [normalized isEqualToString:@"zh-hk"] ||
           [normalized isEqualToString:@"zh-mo"] ||
           [normalized hasPrefix:@"zh-hant-"];
}

static NSString *YTKACESimplifiedChineseDisplayName(void) {
    NSString *name = [NSLocale.currentLocale localizedStringForLanguageCode:@"zh-Hans"];
    return name.length != 0 ? name : @"中文（简体）";
}

static id YTKACEFormattedNameLike(id originalName, NSString *text) {
    if ([originalName isKindOfClass:NSString.class]) return text;
    if (originalName == nil) return nil;

    Class cls = object_getClass(originalName);
    SEL factory = NSSelectorFromString(@"formattedStringWithString:");
    if (cls != Nil && [cls respondsToSelector:factory]) {
        id value = ((id (*)(id, SEL, id))objc_msgSend)(cls, factory, text);
        if (value != nil) return value;
    }

    id copy = nil;
    @try {
        if ([originalName respondsToSelector:@selector(copyWithZone:)]) {
            copy = [originalName copy];
        }
    } @catch (__unused NSException *exception) {
        copy = nil;
    }
    if (copy == nil) return nil;

    if (YTKACESafeSetValue(copy, @"simpleText", text)) {
        id runs = YTKACESafeValue(copy, @"runsArray");
        if ([runs isKindOfClass:NSMutableArray.class]) {
            [(NSMutableArray *)runs removeAllObjects];
        } else if ([runs isKindOfClass:NSArray.class]) {
            YTKACESafeSetValue(copy, @"runsArray", [NSMutableArray array]);
        }
        return copy;
    }
    return nil;
}

static NSString *YTKACEQueryItemName(NSString *item) {
    NSRange equals = [item rangeOfString:@"="];
    NSString *name = equals.location == NSNotFound ? item : [item substringToIndex:equals.location];
    return name.stringByRemovingPercentEncoding ?: name;
}

static NSString *YTKACEQueryItemValue(NSString *item) {
    NSRange equals = [item rangeOfString:@"="];
    if (equals.location == NSNotFound || NSMaxRange(equals) >= item.length) return @"";
    NSString *value = [item substringFromIndex:NSMaxRange(equals)];
    return value.stringByRemovingPercentEncoding ?: value;
}

static NSString *YTKACERewriteTranslationURL(NSString *URLString,
                                              BOOL markTraditionalProxy,
                                              BOOL *matchedTraditional) {
    if (matchedTraditional != NULL) *matchedTraditional = NO;
    if (URLString.length == 0) return URLString;

    NSRange fragmentRange = [URLString rangeOfString:@"#"];
    NSString *fragment = @"";
    NSString *withoutFragment = URLString;
    if (fragmentRange.location != NSNotFound) {
        fragment = [URLString substringFromIndex:fragmentRange.location];
        withoutFragment = [URLString substringToIndex:fragmentRange.location];
    }

    NSRange queryRange = [withoutFragment rangeOfString:@"?"];
    if (queryRange.location == NSNotFound || NSMaxRange(queryRange) >= withoutFragment.length) {
        return URLString;
    }

    NSString *prefix = [withoutFragment substringToIndex:NSMaxRange(queryRange)];
    NSString *query = [withoutFragment substringFromIndex:NSMaxRange(queryRange)];
    NSArray<NSString *> *rawItems = [query componentsSeparatedByString:@"&"];
    NSMutableArray<NSString *> *items = [NSMutableArray arrayWithCapacity:rawItems.count + 1];
    BOOL foundTraditional = NO;
    BOOL markerPresent = NO;

    for (NSString *item in rawItems) {
        NSString *name = YTKACEQueryItemName(item);
        NSString *value = YTKACEQueryItemValue(item);
        if ([name caseInsensitiveCompare:@"tlang"] == NSOrderedSame &&
            YTKACEIsTraditionalChineseCode(value)) {
            [items addObject:@"tlang=zh-Hans"];
            foundTraditional = YES;
            continue;
        }
        if ([name caseInsensitiveCompare:YTKACETraditionalProxyMarkerName] == NSOrderedSame) {
            if (markTraditionalProxy) {
                [items addObject:[NSString stringWithFormat:@"%@=%@",
                    YTKACETraditionalProxyMarkerName, YTKACETraditionalProxyMarkerValue]];
                markerPresent = YES;
            }
            continue;
        }
        [items addObject:item];
    }

    if (!foundTraditional) return URLString;
    if (matchedTraditional != NULL) *matchedTraditional = YES;
    if (markTraditionalProxy && !markerPresent) {
        [items addObject:[NSString stringWithFormat:@"%@=%@",
            YTKACETraditionalProxyMarkerName, YTKACETraditionalProxyMarkerValue]];
    }

    return [NSString stringWithFormat:@"%@%@%@",
        prefix, [items componentsJoinedByString:@"&"], fragment];
}

static BOOL YTKACEURLHasTraditionalProxyMarker(NSString *URLString) {
    if (URLString.length == 0) return NO;
    NSRange queryRange = [URLString rangeOfString:@"?"];
    if (queryRange.location == NSNotFound || NSMaxRange(queryRange) >= URLString.length) {
        return NO;
    }
    NSString *query = [URLString substringFromIndex:NSMaxRange(queryRange)];
    NSRange fragmentRange = [query rangeOfString:@"#"];
    if (fragmentRange.location != NSNotFound) {
        query = [query substringToIndex:fragmentRange.location];
    }
    for (NSString *item in [query componentsSeparatedByString:@"&"]) {
        NSString *name = YTKACEQueryItemName(item);
        NSString *value = YTKACEQueryItemValue(item);
        if ([name caseInsensitiveCompare:YTKACETraditionalProxyMarkerName] == NSOrderedSame &&
            YTKACEIsTraditionalChineseCode(value)) {
            return YES;
        }
    }
    return NO;
}

static NSArray *YTKACEURLBearingObjects(id entry) {
    if (entry == nil) return @[];
    NSMutableArray *objects = [NSMutableArray arrayWithObject:entry];
    for (NSString *key in @[@"captionTrack", @"track", @"translationTrack", @"metadata"]) {
        id nested = YTKACESafeValue(entry, key);
        if (nested != nil && nested != entry && ![objects containsObject:nested]) {
            [objects addObject:nested];
        }
    }
    return objects;
}

static BOOL YTKACEUpdateTranslationEntryURL(id entry, BOOL markTraditionalProxy) {
    BOOL matched = NO;
    for (id object in YTKACEURLBearingObjects(entry)) {
        for (NSString *key in @[@"baseUrl", @"baseURL", @"URL", @"url"]) {
            id value = YTKACESafeValue(object, key);
            if ([value isKindOfClass:NSString.class]) {
                BOOL localMatch = NO;
                NSString *rewritten = YTKACERewriteTranslationURL(
                    value, markTraditionalProxy, &localMatch);
                if (localMatch) {
                    matched = YES;
                    if (![rewritten isEqualToString:value]) {
                        YTKACESafeSetValue(object, key, rewritten);
                    }
                }
            } else if ([value isKindOfClass:NSURL.class]) {
                NSString *absolute = [(NSURL *)value absoluteString];
                BOOL localMatch = NO;
                NSString *rewritten = YTKACERewriteTranslationURL(
                    absolute, markTraditionalProxy, &localMatch);
                if (localMatch) {
                    matched = YES;
                    if (![rewritten isEqualToString:absolute]) {
                        YTKACESafeSetValue(object, key, [NSURL URLWithString:rewritten]);
                    }
                }
            }
        }
    }
    return matched;
}

static BOOL YTKACEObjectHasTraditionalProxyMarker(id entry) {
    NSNumber *associated = objc_getAssociatedObject(
        entry, YTKACETraditionalCaptionTrackAssociation);
    if (associated.boolValue) return YES;

    for (id object in YTKACEURLBearingObjects(entry)) {
        for (NSString *key in @[@"baseUrl", @"baseURL", @"URL", @"url"]) {
            id value = YTKACESafeValue(object, key);
            NSString *URLString = [value isKindOfClass:NSURL.class]
                ? [(NSURL *)value absoluteString]
                : ([value isKindOfClass:NSString.class] ? value : nil);
            if (YTKACEURLHasTraditionalProxyMarker(URLString)) return YES;
        }
    }
    return NO;
}

static id YTKACECopySimplifiedChineseEntry(id traditionalEntry) {
    if ([traditionalEntry isKindOfClass:NSString.class]) return @"zh-Hans";

    id copy = nil;
    if ([traditionalEntry isKindOfClass:NSDictionary.class]) {
        copy = [traditionalEntry mutableCopy];
    } else {
        @try {
            if ([traditionalEntry respondsToSelector:@selector(copyWithZone:)]) {
                copy = [traditionalEntry copy];
            }
        } @catch (__unused NSException *exception) {
            copy = nil;
        }
    }
    if (copy == nil) return nil;

    BOOL codeUpdated = NO;
    for (NSString *key in @[@"languageCode", @"language_code", @"targetLanguageCode", @"targetLanguage", @"targetLang", @"language", @"code"]) {
        id current = YTKACESafeValue(copy, key);
        if (current != nil || [key isEqualToString:@"languageCode"]) {
            if (YTKACESafeSetValue(copy, key, @"zh-Hans")) {
                codeUpdated = YES;
                break;
            }
        }
    }
    if (!codeUpdated) return nil;

    NSString *displayName = YTKACESimplifiedChineseDisplayName();
    for (NSString *key in @[@"languageName", @"name", @"displayName"]) {
        id current = YTKACESafeValue(copy, key);
        if (current == nil) continue;
        id replacement = YTKACEFormattedNameLike(current, displayName);
        if (replacement != nil) {
            YTKACESafeSetValue(copy, key, replacement);
            break;
        }
    }

    YTKACEUpdateTranslationEntryURL(copy, NO);
    return copy;
}

static id YTKACETranslationLanguages(id receiver, SEL selector) {
    IMP original = YTKACEChineseCaptionOriginal(receiver, selector);
    id result = original != NULL
        ? ((id (*)(id, SEL))original)(receiver, selector)
        : nil;
    if (!YTKACEFeatureEnabled(YTKACESimplifiedChineseAutoTranslateKey) ||
        ![result isKindOfClass:NSArray.class]) {
        return result;
    }

    NSArray *languages = result;
    id traditional = nil;
    for (id entry in languages) {
        NSString *code = YTKACELanguageCodeForEntry(entry);
        if (traditional == nil && YTKACEIsTraditionalChineseCode(code)) {
            traditional = entry;
        }
    }
    if (traditional == nil) return result;

    id simplified = nil;
    BOOL alreadyHasSimplified = NO;
    for (id entry in languages) {
        if (YTKACEIsSimplifiedChineseCode(YTKACELanguageCodeForEntry(entry))) {
            alreadyHasSimplified = YES;
            break;
        }
    }
    if (!alreadyHasSimplified) {
        simplified = YTKACECopySimplifiedChineseEntry(traditional);
    }

    // YouTube's zh-Hant auto-translation can return delayed/misaligned cues.
    // Keep the Traditional Chinese menu identity, but make any URL already
    // attached to it request zh-Hans and tag it for on-device Han conversion.
    YTKACEUpdateTranslationEntryURL(traditional, YES);

    if (simplified == nil) return result;
    NSMutableArray *augmented = [languages isKindOfClass:NSMutableArray.class]
        ? (NSMutableArray *)languages
        : [languages mutableCopy];
    NSUInteger index = [languages indexOfObjectIdenticalTo:traditional];
    if (index == NSNotFound || index + 1 >= augmented.count) {
        [augmented addObject:simplified];
    } else {
        [augmented insertObject:simplified atIndex:index + 1];
    }
    return augmented;
}

static id YTKACEPrepareChineseCaptionTrack(id track) {
    if (track == nil || !YTKACEFeatureEnabled(YTKACESimplifiedChineseAutoTranslateKey)) {
        return track;
    }

    BOOL proxy = YTKACEUpdateTranslationEntryURL(track, YES) ||
                 YTKACEObjectHasTraditionalProxyMarker(track);
    objc_setAssociatedObject(track,
                             YTKACETraditionalCaptionTrackAssociation,
                             @(proxy),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return track;
}

static void YTKACEChineseCaptionTrackSelected(id track) {
    if (!YTKACEFeatureEnabled(YTKACESimplifiedChineseAutoTranslateKey)) {
        YTKACETraditionalCaptionProxyActive.store(false, std::memory_order_relaxed);
        return;
    }
    BOOL active = track != nil && YTKACEObjectHasTraditionalProxyMarker(track);
    YTKACETraditionalCaptionProxyActive.store(active, std::memory_order_relaxed);
}

void YTKACEPrepareCaptionTrackForSelection(id track) {
    id prepared = YTKACEPrepareChineseCaptionTrack(track);
    YTKACEChineseCaptionTrackSelected(prepared);
}

static NSString *YTKACETraditionalChineseString(NSString *text) {
    if (text.length == 0) return text;
    NSMutableString *converted = [text mutableCopy];
    Boolean success = CFStringTransform((__bridge CFMutableStringRef)converted,
                                        NULL,
                                        CFSTR("Simplified-Traditional"),
                                        false);
    return success ? converted : text;
}

static id YTKACECaptionSegmentText(id receiver, SEL selector) {
    IMP original = YTKACEChineseCaptionOriginal(receiver, selector);
    id value = original != NULL
        ? ((id (*)(id, SEL))original)(receiver, selector)
        : nil;
    if (!YTKACEFeatureEnabled(YTKACESimplifiedChineseAutoTranslateKey) ||
        !YTKACETraditionalCaptionProxyActive.load(std::memory_order_relaxed)) {
        return value;
    }
    if ([value isKindOfClass:NSString.class]) {
        return YTKACETraditionalChineseString(value);
    }
    return value;
}

static BOOL YTKACEInstallChineseCaptionHook(Class cls,
                                             SEL selector,
                                             IMP replacement) {
    if (cls == Nil || selector == NULL || replacement == NULL) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL || method_getNumberOfArguments(method) != 2) return NO;

    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (returnType[0] != '@') return NO;

    NSString *key = YTKACEChineseCaptionHookKey(cls, selector);
    @synchronized (YTKACEChineseCaptionInstalledHooks) {
        if ([YTKACEChineseCaptionInstalledHooks containsObject:key]) return YES;
    }

    IMP original = NULL;
    if (!YTKACEInstallInstanceHook(NSStringFromClass(cls),
                                   NSStringFromSelector(selector),
                                   replacement,
                                   &original) || original == NULL) {
        return NO;
    }

    @synchronized (YTKACEChineseCaptionInstalledHooks) {
        YTKACEChineseCaptionOriginals[key] =
            [NSValue valueWithPointer:(const void *)original];
        [YTKACEChineseCaptionInstalledHooks addObject:key];
    }
    return YES;
}

static void YTKACEDiscoverChineseCaptionHooks(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (classes == NULL) return;
    count = objc_getClassList(classes, count);

    for (int index = 0; index < count; index++) {
        Class cls = classes[index];
        NSString *className = NSStringFromClass(cls).lowercaseString;
        BOOL captionClass = [className containsString:@"caption"] ||
                            [className containsString:@"subtitle"];
        if (!captionClass) continue;

        for (NSString *selectorName in @[
            @"translationLanguagesArray",
            @"translationLanguages",
            @"availableTranslationLanguages",
            @"autoTranslationLanguages",
            @"autoTranslateLanguages"
        ]) {
            YTKACEInstallChineseCaptionHook(
                cls, NSSelectorFromString(selectorName), (IMP)YTKACETranslationLanguages);
        }

        if ([className containsString:@"captionsegment"] ||
            [className containsString:@"subtitlesegment"]) {
            YTKACEInstallChineseCaptionHook(cls,
                NSSelectorFromString(@"text"), (IMP)YTKACECaptionSegmentText);
        }

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
            SEL selector = method_getName(methods[methodIndex]);
            NSString *name = NSStringFromSelector(selector).lowercaseString;
            if ([name containsString:@"translation"] &&
                [name containsString:@"language"]) {
                YTKACEInstallChineseCaptionHook(cls, selector,
                                                (IMP)YTKACETranslationLanguages);
            }
        }
        free(methods);
    }
    free(classes);
}

void YTKACEInstallSimplifiedChineseCaptionHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTKACEChineseCaptionOriginals = [NSMutableDictionary dictionary];
        YTKACEChineseCaptionInstalledHooks = [NSMutableSet set];

        YTKACEDiscoverChineseCaptionHooks();
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *notification) {
            for (NSNumber *delay in @[@0.25, @2.0, @6.0]) {
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        YTKACEDiscoverChineseCaptionHooks();
                    });
            }
        }];
    });
}
