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
static NSString * const YTKACEAllLanguageAutoTranslateKey =
    @"YTKACE.Preference.Playback.AllLanguageAutoTranslate";
static NSString * const YTKACETraditionalProxyMarkerName = @"origin_tlang";
static NSString * const YTKACETraditionalProxyMarkerValue = @"zh-Hant";

static NSMutableDictionary<NSString *, NSValue *> *YTKACEChineseCaptionOriginals;
static NSMutableSet<NSString *> *YTKACEChineseCaptionInstalledHooks;
static const void *YTKACETraditionalCaptionTrackAssociation =
    &YTKACETraditionalCaptionTrackAssociation;
static std::atomic_bool YTKACETraditionalCaptionProxyActive(false);
static IMP YTKACEOriginalAutoTranslationCaptionTrack;
static const void *YTKACEFallbackTargetsAssociation = &YTKACEFallbackTargetsAssociation;

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
    BOOL changed = NO;

    for (NSString *item in rawItems) {
        NSString *name = YTKACEQueryItemName(item);
        NSString *value = YTKACEQueryItemValue(item);
        if ([name caseInsensitiveCompare:@"tlang"] == NSOrderedSame &&
            YTKACEIsTraditionalChineseCode(value)) {
            [items addObject:@"tlang=zh-Hans"];
            foundTraditional = YES;
            changed = YES;
            continue;
        }
        if ([name caseInsensitiveCompare:YTKACETraditionalProxyMarkerName] == NSOrderedSame) {
            if (markTraditionalProxy) {
                NSString *marker = [NSString stringWithFormat:@"%@=%@",
                    YTKACETraditionalProxyMarkerName, YTKACETraditionalProxyMarkerValue];
                [items addObject:marker];
                markerPresent = YES;
                if (![item isEqualToString:marker]) changed = YES;
            } else {
                changed = YES;
            }
            continue;
        }
        [items addObject:item];
    }

    if (markTraditionalProxy && foundTraditional && !markerPresent) {
        [items addObject:[NSString stringWithFormat:@"%@=%@",
            YTKACETraditionalProxyMarkerName, YTKACETraditionalProxyMarkerValue]];
        markerPresent = YES;
        changed = YES;
    }

    if (matchedTraditional != NULL) {
        *matchedTraditional = foundTraditional || markerPresent;
    }
    if (!changed) return URLString;
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

static NSString *YTKACEURLByEnsuringTraditionalProxyMarker(NSString *URLString) {
    if (URLString.length == 0 || YTKACEURLHasTraditionalProxyMarker(URLString)) {
        return URLString;
    }

    NSRange fragmentRange = [URLString rangeOfString:@"#"];
    NSString *fragment = @"";
    NSString *withoutFragment = URLString;
    if (fragmentRange.location != NSNotFound) {
        fragment = [URLString substringFromIndex:fragmentRange.location];
        withoutFragment = [URLString substringToIndex:fragmentRange.location];
    }

    NSString *separator = [withoutFragment containsString:@"?"] ? @"&" : @"?";
    NSString *marker = [NSString stringWithFormat:@"%@=%@",
        YTKACETraditionalProxyMarkerName, YTKACETraditionalProxyMarkerValue];
    return [NSString stringWithFormat:@"%@%@%@%@",
        withoutFragment, separator, marker, fragment];
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

static void YTKACEMarkTraditionalProxyIdentity(id entry) {
    if (entry == nil) return;

    objc_setAssociatedObject(entry,
                             YTKACETraditionalCaptionTrackAssociation,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (id object in YTKACEURLBearingObjects(entry)) {
        for (NSString *key in @[@"baseUrl", @"baseURL", @"URL", @"url"]) {
            id value = YTKACESafeValue(object, key);
            if ([value isKindOfClass:NSString.class]) {
                NSString *marked = YTKACEURLByEnsuringTraditionalProxyMarker(value);
                if (![marked isEqualToString:value]) {
                    YTKACESafeSetValue(object, key, marked);
                }
            } else if ([value isKindOfClass:NSURL.class]) {
                NSString *absolute = [(NSURL *)value absoluteString];
                NSString *marked = YTKACEURLByEnsuringTraditionalProxyMarker(absolute);
                if (![marked isEqualToString:absolute]) {
                    YTKACESafeSetValue(object, key, [NSURL URLWithString:marked]);
                }
            }
        }
    }
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

// These are native protobuf objects, not dictionaries: YouTube passes each target
// to autoTranslationCaptionTrackForAudioTrackData:translateTarget:.
static NSArray *YTKACEFallbackTranslationLanguages(void) {
    Class targetClass = NSClassFromString(@"YTITranslationTarget");
    Class nameClass = NSClassFromString(@"YTIFormattedString");
    SEL factory = NSSelectorFromString(@"formattedStringWithString:");
    if (targetClass == Nil || ![nameClass respondsToSelector:factory]) return nil;
    // Conservative fallback only when the player supplies no target list. Keep
    // the server's complete list whenever one is available.
    NSString *codes = @"af ak sq am ar hy as ay az bn eu be bho bs bg my ca ceb zh-Hans zh-Hant co hr cs da dv doi nl en eo et ee fil fi fr gl ka de el gn gu ht ha haw iw hi hmn hu is ig id ga it ja jv kn kk km rw ko kri ku ky lo la lv ln lt lg lb mk mg ms ml mt mi mr mn ne no ny or om ps fa pl pt pa qu ro ru sm sa gd sr sn sd si sk sl so st es su sw sv tg ta tt te th ti ts tr tk uk ur ug uz vi cy fy xh yi yo zu";
    NSMutableArray *targets = [NSMutableArray array];
    for (NSString *code in [codes componentsSeparatedByString:@" "]) {
        id target = [targetClass new];
        NSString *name = [NSLocale.currentLocale localizedStringForLanguageCode:code] ?: code;
        id formatted = ((id (*)(id, SEL, id))objc_msgSend)(nameClass, factory, name);
        if (formatted != nil && YTKACESafeSetValue(target, @"languageCode", code) &&
            YTKACESafeSetValue(target, @"languageName", formatted)) {
            [targets addObject:target];
        }
    }
    return targets;
}

static BOOL YTKACEUsableTranslationSource(id entry) {
    id raw = YTKACESafeValue(entry, @"baseURL");
    if (![raw isKindOfClass:NSString.class]) return NO;
    NSURL *URL = [NSURL URLWithString:raw];
    NSString *host = URL.host.lowercaseString;
    return [URL.scheme.lowercaseString isEqualToString:@"https"] &&
        ([host isEqualToString:@"youtube.com"] || [host hasSuffix:@".youtube.com"]) &&
        [URL.path isEqualToString:@"/api/timedtext"] &&
        YTKACELanguageCodeForEntry(entry).length != 0;
}

static id YTKACEAllLanguageCaptionTracks(id receiver, SEL selector) {
    IMP original = YTKACEChineseCaptionOriginal(receiver, selector);
    id result = original ? ((id (*)(id, SEL))original)(receiver, selector) : nil;
    if (!YTKACEFeatureEnabled(YTKACEAllLanguageAutoTranslateKey) ||
        ![result isKindOfClass:NSArray.class]) return result;
    NSMutableArray *tracks = [result mutableCopy];
    for (NSUInteger index = 0; index < tracks.count; index++) {
        id entry = tracks[index];
        if (!YTKACEUsableTranslationSource(entry) ||
            [YTKACESafeValue(entry, @"isTranslatable") boolValue]) continue;
        // Never change the stored protobuf: disabling the feature restores the
        // unmodified server response, and original subtitle URLs stay intact.
        if (![entry respondsToSelector:@selector(copyWithZone:)]) continue;
        id copy = [entry copy];
        if (copy != entry && YTKACESafeSetValue(copy, @"isTranslatable", @YES)) {
            tracks[index] = copy;
        }
    }
    return tracks;
}

static id YTKACETranslationSourceIndices(id receiver, SEL selector) {
    IMP original = YTKACEChineseCaptionOriginal(receiver, selector);
    id result = original ? ((id (*)(id, SEL))original)(receiver, selector) : nil;
    if (!YTKACEFeatureEnabled(YTKACEAllLanguageAutoTranslateKey)) return result;
    id tracks = YTKACESafeValue(receiver, @"captionTracksArray");
    if (![tracks isKindOfClass:NSArray.class]) return result;
    id indices = [result respondsToSelector:@selector(copyWithZone:)] ? [result copy] : nil;
    if (indices == nil) indices = [NSClassFromString(@"GPBInt32Array") new];
    SEL countSEL = @selector(count);
    SEL at = NSSelectorFromString(@"valueAtIndex:");
    SEL add = NSSelectorFromString(@"addValue:");
    if (indices == result || ![indices respondsToSelector:countSEL] ||
        ![indices respondsToSelector:at] || ![indices respondsToSelector:add]) return result;
    NSMutableSet *seen = [NSMutableSet set];
    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(indices, countSEL);
    for (NSUInteger index = 0; index < count; index++) {
        int32_t value = ((int32_t (*)(id, SEL, NSUInteger))objc_msgSend)(indices, at, index);
        [seen addObject:@(value)];
    }
    for (NSUInteger index = 0; index < [tracks count] && index <= INT32_MAX; index++) {
        if (YTKACEUsableTranslationSource(tracks[index]) && ![seen containsObject:@(index)]) {
            ((void (*)(id, SEL, int32_t))objc_msgSend)(indices, add, (int32_t)index);
        }
    }
    // Native sourceCaptionTrackForIndices:audioTrackData: still intersects these
    // indices with the selected audio track; never select another dub's captions.
    return indices;
}

static id YTKACETranslationLanguages(id receiver, SEL selector) {
    IMP original = YTKACEChineseCaptionOriginal(receiver, selector);
    id result = original != NULL
        ? ((id (*)(id, SEL))original)(receiver, selector)
        : nil;
    if (YTKACEFeatureEnabled(YTKACEAllLanguageAutoTranslateKey) &&
        [receiver isKindOfClass:NSClassFromString(@"YTIPlayerCaptionsTrackListRenderer")] &&
        (result == nil || ([result isKindOfClass:NSArray.class] && [result count] == 0))) {
        id tracks = YTKACESafeValue(receiver, @"captionTracksArray");
        if ([tracks isKindOfClass:NSArray.class]) {
            for (id track in tracks) {
                if (YTKACEUsableTranslationSource(track)) {
                    NSArray *fallback = objc_getAssociatedObject(receiver, YTKACEFallbackTargetsAssociation);
                    if (fallback == nil) {
                        fallback = YTKACEFallbackTranslationLanguages();
                        if (fallback.count != 0) {
                            objc_setAssociatedObject(receiver, YTKACEFallbackTargetsAssociation,
                                                     fallback, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        }
                    }
                    result = fallback ?: result;
                    break;
                }
            }
        }
    }
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

static id YTKACECopyTranslationTargetWithLanguageCode(id target,
                                                        NSString *languageCode) {
    if ([target isKindOfClass:NSString.class]) return languageCode;
    if (target == nil || languageCode.length == 0) return target;

    id copy = nil;
    if ([target isKindOfClass:NSDictionary.class]) {
        copy = [target mutableCopy];
    } else {
        @try {
            if ([target respondsToSelector:@selector(copyWithZone:)]) {
                copy = [target copy];
            }
        } @catch (__unused NSException *exception) {
            copy = nil;
        }
    }
    if (copy == nil) return target;

    for (NSString *key in @[@"languageCode", @"language_code",
                             @"targetLanguageCode", @"targetLanguage",
                             @"targetLang", @"language", @"code"]) {
        id current = YTKACESafeValue(copy, key);
        if (current != nil || [key isEqualToString:@"languageCode"]) {
            if (YTKACESafeSetValue(copy, key, languageCode)) return copy;
        }
    }
    return target;
}

static id YTKACEAutoTranslationCaptionTrack(id receiver,
                                             SEL selector,
                                             id audioTrackData,
                                             id translateTarget) {
    BOOL enabled = YTKACEFeatureEnabled(YTKACESimplifiedChineseAutoTranslateKey);
    NSString *requestedLanguageCode = YTKACELanguageCodeForEntry(translateTarget);
    BOOL traditional = enabled &&
        YTKACEIsTraditionalChineseCode(requestedLanguageCode);
    id effectiveTarget = traditional
        ? YTKACECopyTranslationTargetWithLanguageCode(translateTarget, @"zh-Hans")
        : translateTarget;

    id result = YTKACEOriginalAutoTranslationCaptionTrack != NULL
        ? ((id (*)(id, SEL, id, id))YTKACEOriginalAutoTranslationCaptionTrack)(
            receiver, selector, audioTrackData, effectiveTarget)
        : nil;

    if (traditional && result != nil) {
        // Preserve the user's Traditional Chinese choice while using the
        // Simplified Chinese translation path that has correct cue timing.
        YTKACEMarkTraditionalProxyIdentity(result);
    }
    return result;
}

static void YTKACEInstallAutoTranslationCaptionTrackHook(void) {
    if (YTKACEOriginalAutoTranslationCaptionTrack != NULL) return;

    NSString *className = @"YTIPlayerCaptionsTrackListRenderer";
    NSString *selectorName =
        @"autoTranslationCaptionTrackForAudioTrackData:translateTarget:";
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(cls, selector);
    if (method == NULL || method_getNumberOfArguments(method) != 4) return;

    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (returnType[0] != '@') return;

    IMP original = NULL;
    if (YTKACEInstallInstanceHook(className,
                                  selectorName,
                                  (IMP)YTKACEAutoTranslationCaptionTrack,
                                  &original) && original != NULL) {
        YTKACEOriginalAutoTranslationCaptionTrack = original;
    }
}

static id YTKACEPrepareChineseCaptionTrack(id track) {
    if (track == nil || !YTKACEFeatureEnabled(YTKACESimplifiedChineseAutoTranslateKey)) {
        return track;
    }

    // Always rewrite a native Traditional Chinese translation URL before the
    // track is selected. Do not short-circuit this call based on languageCode:
    // YouTube may otherwise keep requesting tlang=zh-Hant and bring back the
    // delayed/misaligned cue timing we are fixing.
    BOOL rewroteTraditionalURL = YTKACEUpdateTranslationEntryURL(track, YES);
    BOOL proxy = rewroteTraditionalURL ||
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

static NSUInteger YTKACETranslationArrayCount(id receiver, SEL selector) {
    NSString *name = NSStringFromSelector(selector);
    NSString *getter = [name substringToIndex:name.length - @"_Count".length];
    id array = YTKACESafeValue(receiver, getter);
    return [array respondsToSelector:@selector(count)] ? [array count] : 0;
}

static BOOL YTKACEAutoTranslationEnabled(id receiver, SEL selector) {
    if (YTKACEFeatureEnabled(YTKACEAllLanguageAutoTranslateKey)) return YES;
    IMP original = YTKACEChineseCaptionOriginal(receiver, selector);
    return original ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

static BOOL YTKACEInstallChineseCaptionHook(Class cls,
                                             SEL selector,
                                             IMP replacement,
                                             char expectedReturn = '@') {
    if (cls == Nil || selector == NULL || replacement == NULL) return NO;
    // Protobuf accessors are resolved lazily rather than listed as baseMethods.
    (void)[cls instancesRespondToSelector:selector];
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL || method_getNumberOfArguments(method) != 2) return NO;

    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (returnType[0] != expectedReturn) return NO;

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
    Class renderer = NSClassFromString(@"YTIPlayerCaptionsTrackListRenderer");
    YTKACEInstallChineseCaptionHook(renderer, NSSelectorFromString(@"captionTracksArray"),
                                    (IMP)YTKACEAllLanguageCaptionTracks);
    YTKACEInstallChineseCaptionHook(renderer,
        NSSelectorFromString(@"defaultTranslationSourceTrackIndicesArray"),
        (IMP)YTKACETranslationSourceIndices);
    for (NSString *name in @[@"translationLanguagesArray_Count",
                             @"defaultTranslationSourceTrackIndicesArray_Count"]) {
        YTKACEInstallChineseCaptionHook(renderer, NSSelectorFromString(name),
                                        (IMP)YTKACETranslationArrayCount, 'Q');
    }
    YTKACEInstallChineseCaptionHook(
        NSClassFromString(@"YTColdConfigIosPlayerClientSharedConfigImpl"),
        NSSelectorFromString(@"enableCaptionsAutoTranslationIosClient"),
        (IMP)YTKACEAutoTranslationEnabled, 'B');
    // 21.33 uses the monolithic config; newer builds also expose the split one.
    YTKACEInstallChineseCaptionHook(NSClassFromString(@"YTColdConfig"),
        NSSelectorFromString(@"iosPlayerClientSharedConfigEnableCaptionsAutoTranslationIosClient"),
        (IMP)YTKACEAutoTranslationEnabled, 'B');
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

        YTKACEInstallAutoTranslationCaptionTrackHook();
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
                        YTKACEInstallAutoTranslationCaptionTrackHook();
                        YTKACEDiscoverChineseCaptionHooks();
                    });
            }
        }];
    });
}
