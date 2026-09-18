# Full-coverage native auto-translation

The **Playback → Auto-Translate All Caption Languages** preference is enabled by
default. Reopen the video after changing it. The separate Chinese Auto-Translate
Fix preference continues to control Simplified/Traditional Chinese behavior.

When enabled, this feature takes over the iOS player's auto-translate eligibility,
translation-source indices, and translation-target list for every video that has
a usable YouTube timed-text subtitle track. It does not embed the website,
transcribe audio, or contact a third-party translation service. Server refusal,
expired subtitle URLs, or videos without captions cannot be fixed by displaying
a translation menu.

## Implementation

- Enable the native iOS captions auto-translation config flag.
- Return copied caption entries marked translatable for every usable HTTPS
  YouTube timed-text URL, even when YouTube already marks the entry translatable.
  Keep the stored response and all original URL parameters unchanged.
- Replace the native default translation-source indices with all usable caption
  tracks regardless of source language. The native
  `sourceCaptionTrackForIndices:audioTrackData:` method still intersects these
  indices with the selected audio track.
- Replace the native translation-target list with native
  `YTITranslationTarget` objects built from the full bundled language list on
  every eligible video, instead of only filling an empty native list.
- Keep protobuf count getters consistent with the arrays exposed to the player.
- Keep existing Traditional Chinese timing/proxy handling in the original
  translation-track hook. No source-language code is changed to English.

Hooks check the native return type and argument count and skip missing methods.
Full-coverage targets are cached per renderer, not shared across videos. Turning
the feature off exposes the original source indices, target list, and caption
entries again.

## Validation and device acceptance

The implementation was built for arm64 with the iPhoneOS 16.5 SDK. Runtime
metadata was checked in the locally available YouTube 21.33.6 and 21.36.6
binaries, including their different config accessors. Native source selection
was inspected in 21.36.6. These checks do not establish successful playback on iOS.

Before releasing an IPA, test on-device with both supported YouTube versions:

1. A Hebrew/Japanese/Arabic video with only automatically generated source
   captions: open Captions, choose Auto-translate, then Simplified Chinese and
   another target. Confirm translated text actually loads.
2. Existing English translation: confirm the full-coverage menu replaces the
   native target list and playback still works, including Simplified and
   Traditional Chinese.
3. Seek forward/backward and change videos: check timing and absence of stale
   captions. With Chinese Fix enabled, verify Traditional Chinese characters.
4. A video without captions: no synthetic subtitle track or empty translation
   menu should appear.
5. Multi-audio video: change audio tracks and confirm the source belongs to the
   selected audio track. Keep target-specific audio exclusions intact.
6. Disable All Caption Languages, reopen the video, and confirm native behavior.

Actual subtitle requests and menu behavior remain subject to device validation;
the tweak cannot guarantee translation for every video or target language.
