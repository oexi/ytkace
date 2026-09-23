# Third-Party Notices

YTKACE source is licensed under MIT. The following components and services have separate terms.

## FFmpeg

YTKACE statically links FFmpeg 8.1.2 for local media processing. It is built from the official release tarball by `Scripts/build-ffmpeg.sh`, without `--enable-gpl` and without `--enable-nonfree`, so the result is LGPL only. Licence texts ship in the repository at `Vendor/FFmpeg/COPYING.LGPLv2.1` and `COPYING.LGPLv3`. See https://ffmpeg.org/legal.html.

## SponsorBlock and DeArrow

SponsorBlock and DeArrow community data is provided by the SponsorBlock service under CC BY-NC-SA 4.0. See https://sponsor.ajay.app/. The shield image shipped in `YTKACE.bundle` is SponsorBlock's artwork, taken from the same site and used to mark the integration.

## SABR reference

The download path implements YouTube's SABR streaming protocol. It was written for YTKACE, developed against an iPad on iOS 16. Protocol understanding came in part from reading [LuanRT/googlevideo](https://github.com/LuanRT/googlevideo), an MIT-licensed library implementing UMP and SABR. No code from that project is included.

## YTPlaybackFix

The playback error recovery in `Tweak/Features/Playback/PlaybackFixHooks.mm` is adapted from [YTPlaybackFix](https://github.com/Mark02-2012/YTPlaybackFix) by Mark02, used under the MIT licence. It is his `Refresh.xm` method: intercept `handleError:` for playback error codes 14 and 0, send a `YTPlayerTapToRetryResponderEvent`, seek back to the last known position, and re-check after a second. The overall control flow is his. Changes here: the port off Logos to the runtime hooking used elsewhere, the preference gate and the logging; recovery now reloads only the player through `player:reloadWithContext:`, falling back to his retry event when that is unavailable, since the retry event reloads the whole watch page; the re-check waits three seconds instead of one, so a reload still in progress is not retried a second time; and the replay step was dropped because the selector no longer exists. The full licence text is reproduced in the header of that file.

MIT License, Copyright (c) 2026 Mark02.

## Apple frameworks

YTKACE uses UIKit, AVFoundation and SF Symbols supplied by iOS. SF Symbols artwork is requested at runtime and is not included as a redistributed asset pack.
