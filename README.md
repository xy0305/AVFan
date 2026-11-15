# AVFan

Personal iOS client for browsing public catalog pages on avfan.com, with optional 115 push-to-play. This is a private, personal sideload app (TrollStore / AltStore / Sideloadly). It is not an official AVFan product, is not licensed for public distribution, and is used at the owner's own risk.

## 1.0 scope

- Native SwiftUI screens: home, search, rankings, local bookmarks, movie detail (including magnet lists), settings
- On-demand fetching of public HTML only, with a local cache and serial rate limiting
- WKWebView fallback when URLSession is blocked (403/429) or a list page is JS-rendered without items
- Optional site login stays inside WKWebView; 115 credentials are stored only in this app (Keychain)
- Unsigned IPA via GitHub Actions (private repo artifact, no public Release page)

## Build

CI on `main` produces `AVFan-unsigned-1.0-1.ipa`. Download the Actions artifact while signed in as the repository owner.
