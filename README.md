# AVFan

Personal iOS client for browsing public catalog pages on avfan.com, with optional 115 push-to-play. This is a private, personal sideload app (TrollStore / AltStore / Sideloadly). It is not an official AVFan product, is not licensed for public distribution, and is used at the owner's own risk.

## 1.1 scope

- Native SwiftUI screens: home, search, rankings, local bookmarks, movie detail (including magnet lists), settings
- Playback stack ported from AVDB: KSPlayer chrome (resume, speed, PiP, gestures, quality, online file subtitles), plus 115 push / 推送并播放 / file list / offline-task wait
- On-demand fetching of public HTML only, with a local cache and serial rate limiting
- Watch-online play only when a media URL is present in that public HTML (no `/api/` paths)
- WKWebView fallback when URLSession is blocked (403/429) or a list page is JS-rendered without items
- Optional site login stays inside WKWebView; 115 credentials are stored only in this app (Keychain)
- Unsigned IPA via GitHub Actions (Actions artifact, no public Release page)

KSPlayer is licensed under GPL-3.0; see `THIRD_PARTY/KSPlayer-GPL-3.0.txt`. LUT and AVDB's on-device live-ASR subtitle stack are not included.

## Build

CI on `main` produces `AVFan-unsigned-1.1-2.ipa`. Download the Actions artifact while signed in as the repository owner.
