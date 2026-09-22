#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL YTKACEInstallInstanceHook(
    NSString *className,
    NSString *selectorName,
    IMP replacement,
    IMP _Nullable * _Nullable originalStorage
);

FOUNDATION_EXPORT BOOL YTKACEInstallClassHook(
    NSString *className,
    NSString *selectorName,
    IMP replacement,
    IMP _Nullable * _Nullable originalStorage
);

FOUNDATION_EXPORT BOOL YTKACEAddInstanceMethod(
    NSString *className,
    NSString *selectorName,
    IMP implementation,
    const char *typeEncoding
);

FOUNDATION_EXPORT NSUInteger YTKACEInstalledHookCount(void);

FOUNDATION_EXPORT NSArray<NSString *> *YTKACEAppClassNames(void);

NS_ASSUME_NONNULL_END
