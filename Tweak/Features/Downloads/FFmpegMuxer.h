#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTKACEFFmpegCompletion)(NSError * _Nullable error);
typedef void (^YTKACEFFmpegProgress)(double fraction);

FOUNDATION_EXPORT void YTKACEFFmpegCancelConversion(NSString *identifier);

@interface YTKACEFFmpegMuxer : NSObject
+ (void)remuxAudioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
           completion:(YTKACEFFmpegCompletion)completion;
+ (void)remuxVideoURL:(NSURL *)videoURL
             audioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
           completion:(YTKACEFFmpegCompletion)completion;
+ (void)normalizeMediaURL:(NSURL *)mediaURL
                outputURL:(NSURL *)outputURL
               completion:(YTKACEFFmpegCompletion)completion;
+ (void)videoFromAudioURL:(NSURL *)audioURL
             artworkData:(nullable NSData *)artworkData
                outputURL:(NSURL *)outputURL
                 progress:(nullable YTKACEFFmpegProgress)progress
               completion:(YTKACEFFmpegCompletion)completion;
+ (void)muxSubtitlesIntoURL:(NSURL *)mediaURL
                       cues:(NSArray<NSDictionary *> *)cues
                   language:(nullable NSString *)language
                  outputURL:(NSURL *)outputURL
                 completion:(YTKACEFFmpegCompletion)completion;
+ (void)embedArtworkData:(NSData *)artworkData
                 mediaURL:(NSURL *)mediaURL
               completion:(YTKACEFFmpegCompletion)completion;
@end

NS_ASSUME_NONNULL_END
