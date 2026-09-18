# Native auto-translation for non-English captions

The **Playback → Auto-Translate All Caption Languages** preference is enabled by
default. Reopen the video after changing it. The separate Chinese Auto-Translate
Fix preference continues to control Simplified/Traditional Chinese behavior.

This extends the iOS player's existing translation pipeline. It does not embed
the website, transcribe audio, or contact a third-party translation service.
An existing YouTube timed-text subtitle track is required. Server refusal,
expired subtitle URLs, or videos without captions cannot be fixed by displaying
a translation menu.

## Implementation

- Enable the native iOS captions auto-translation config flag.
- Return copied caption entries marked translatable for HTTPS YouTube timed-text
  URLs. Keep the stored response and all original URL parameters unchanged.
- Extend default translation-source indices with usable captions regardless of
  their language. Preserve original source priority. The native
  `sourceCaptionTrackForIndices:audioTrackData:` method still intersects these
  indices with the selected audio track.
- Preserve a supplied translation-target list. Only when that list is absent or
  empty, construct native `YTITranslationTarget` objects from a bundled fallback
  list. The fallback is not a live mirror of every language on the website.
- Keep protobuf count getters consistent with the arrays exposed to the player.
- Keep existing Traditional Chinese timing/proxy handling in the original
  translation-track hook. No source-language code is changed to English.

Hooks check the native return type and argument count and skip missing methods.
Fallback targets are cached per renderer, not shared across videos. Turning the
feature off exposes the original source indices and caption entries again.

## Validation and device acceptance

The implementation was built for arm64 with the iPhoneOS 16.5 SDK. Runtime
metadata was checked in the locally available YouTube 21.33.6 and 21.36.6
binaries, including their different config accessors. Native source selection
was inspected in 21.36.6. These checks do not establish successful playback on iOS.

Before releasing an IPA, test on-device with both supported YouTube versions:

1. A Hebrew/Japanese/Arabic video with only automatically generated source
   captions: open Captions, choose Auto-translate, then Simplified Chinese and
   another target. Confirm translated text actually loads.
2. Existing English translation: confirm the existing menu and playback still
   work, including Simplified and Traditional Chinese.
3. Seek forward/backward and change videos: check timing and absence of stale
   captions. With Chinese Fix enabled, verify Traditional Chinese characters.
4. A video without captions: no synthetic subtitle track or empty translation
   menu should appear.
5. Multi-audio video: change audio tracks and confirm the source belongs to the
   selected audio track. Keep target-specific audio exclusions intact.
6. Disable All Caption Languages, reopen the video, and confirm native behavior.

Actual subtitle requests and menu behavior remain subject to device validation;
the tweak cannot guarantee translation for every video or target language.
