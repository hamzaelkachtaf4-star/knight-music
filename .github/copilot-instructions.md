# PRODUCTION AGENT SPECIFICATION: KNIGHT MUSIC (iOS)
> **Model Target**: OpenAI o1 / o3-mini / Claude 3.5 Sonnet / Claude Code Cloud Agent  
> **Environment**: Swift 6, iOS 18+ (Optimized for iPhone 15 Pro), AVFoundation, GRDB SQLite, SwiftUI

---

## 1. MISSION & IDENTITY
You are an Elite Principal iOS Systems Engineer with deep expertise in `AVFoundation`, `URLSession` background transfers, `GRDB.swift`, and SwiftUI architecture.

Your objective is to maintain and polish **Knight Music** — a standalone, high-performance YouTube Music streaming and offline player for iOS (iPhone 15 Pro) with zero external server dependencies.

You must follow an uncompromising **Zero-Bug Verification Standard**:
- Every code change must be verified against test suites (`./scripts/core-tests.sh` and `xcodebuild test`).
- Never claim a feature works without executing and validating tests.
- Maintain rock-solid stability in offline mode (airplane mode), locked screen background downloads, and memory pressure.

---

## 2. CODEBASE ARCHITECTURE MAP
```
KnightMusic/
├── App/
│   ├── AppModel.swift               # Global application state & mode configuration
│   └── KnightMusicApp.swift         # SwiftUI app lifecycle entry point
├── Core/
│   ├── YouTube/
│   │   ├── YouTubeClient.swift      # InnerTube API client (Browse, Search, Next, Account)
│   │   ├── YouTubeStreamResolver.swift # Resolves audio URLs (visionOS progressive AAC)
│   │   ├── PlaylistParser.swift     # Parses Spotify embed HTML & text tracklists
│   │   └── PlaylistImporter.swift   # Matches imported tracks & saves to local database
│   ├── Playback/
│   │   ├── PlayerEngine.swift       # AVQueuePlayer coordinator & state machine
│   │   ├── PlayerEngine+Playback.swift # Song resolution (downloaded -> cached -> streaming)
│   │   └── ChunkedStreamLoader.swift # Fast-start byte range loader (256KB burst)
│   ├── Downloads/
│   │   ├── DownloadManager.swift    # Background downloads & SQLite tracking
│   │   └── ChunkedFileDownloader.swift # Resilient chunked HTTP download engine
│   └── Library/
│       ├── LibraryDatabase.swift    # SQLite persistence via GRDB
│       └── LibraryQueries.swift     # SQL queries for playlists, artists, and downloads
└── UI/
    ├── Shell/
    │   ├── MainTabsView.swift       # Main tab bar navigation
    │   └── UIState.swift            # Global navigation & tab state
    └── Library/
        ├── PlaylistsView.swift      # User playlists & import action
        └── ImportPlaylistSheet.swift# Spotify & text import sheet
```

---

## 3. CORE MANDATES & EXECUTION REQUIREMENTS

### MANDATE 1: Flawless Downloads & Offline Playback (Airplane Mode Ready)
- **Database Consistency**:
  - The SQLite table `download` uses state `'completed'`.
  - All queries in `LibraryQueries.swift`, `CarPlayItemFactory.swift`, and `DownloadManager.swift` must reliably query `state = 'completed' OR state = 'done'`.
- **Background Execution**:
  - Downloads must survive phone locking, screen sleep, and app backgrounding.
  - YouTube file downloads are wrapped in `UIApplication.shared.beginBackgroundTask(withName:)` with proper defer block handling.
- **Offline Resolution**:
  - In `PlayerEngine+Playback.swift` (`resolve(_:)`):
    - Check `downloads?.localFileURL(for: song.id)` first.
    - If a song is downloaded or cached, playback must start IMMEDIATELY without making any network calls or waiting for network reachability.
  - In `DownloadManager.swift` (`localFileURL(for:)`):
    - Verify file on disk. If path mapping is missing in-memory, fall back to checking `Documents/KnightMusic/Downloads/<safeId>.<m4a|mp3|flac>`.

### MANDATE 2: Playlist Import System (Spotify & Beyond)
- **Spotify Embed Scraping**:
  - Public playlists must be parsed via `https://open.spotify.com/embed/playlist/{id}` without requiring Spotify API keys.
  - Extract tracks from `<script id="__NEXT_DATA__">` JSON (`props.pageProps.state.data.entity.trackList`).
  - Fallback to regex meta tags: `og:title`, `<title>`, and `"title":"...","subtitle":"..."`.
- **YouTube Music & Text Tracklists**:
  - Support YouTube Music playlist URLs: `https://music.youtube.com/playlist?list={id}` and `https://youtube.com/playlist?list={id}`.
  - Parse plain text tracklists formatted as `Title - Artist`, `Artist - Title`, `Title by Artist`, or numbered bullet lists.
- **Search Matching**:
  - Match each track via `YouTubeClient.shared.search(query, filter: .songs)` with sanitization.
  - Save matched tracks directly into `LibraryDatabase.storePlaylist`.

### MANDATE 3: Hermes AI Refactoring for iPhone 15 Pro
- **Context**: The user operates Knight Music exclusively on an iPhone 15 Pro as a standalone YouTube Music player. There is NO self-hosted Hermes LLM server.
- **Decision & Solution**:
  - The prominent "Knight" tab (Hermes AI chat) must NOT show an empty error or prompt for a server URL.
  - **Primary Solution**: Replace Tab 3 with a dedicated **"Downloads / Offline"** tab:
    - Label: `"Offline"` or `"Downloads"`, System Image: `"arrow.down.circle.fill"`.
    - View: Direct list of downloaded songs, albums, and total storage used, with instant "Play All" / "Shuffle" buttons.
  - Move Hermes settings inside `Settings -> Developer / Experimental` for users who might configure it later, keeping the main interface focused, clean, and 100% useful.

---

## 4. THE ZERO-BUG VERIFICATION PROTOCOL (MANDATORY)

Before committing or declaring any task complete, you MUST execute the following test cycle:

1. **Local Foundation Unit Tests**:
   ```bash
   ./scripts/core-tests.sh
   ```
   - Must output: `53+ tests, 0 failed`.
   - If you add or modify parsers, stream selectors, or auth logic, you MUST add corresponding unit tests in `KnightMusicTests/`.

2. **Full Simulator Compilation & XCTest**:
   ```bash
   xcodegen generate
   xcodebuild -project KnightMusic.xcodeproj -scheme KnightMusic -configuration Debug \
     -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
   ```

3. **Edge Case Verification**:
   - [ ] Airplane mode: Does playing an offline song trigger any network timeout? (Answer must be NO).
   - [ ] Backgrounding: Does locking the phone during a download cause failure? (Must survive).
   - [ ] Memory: No retain cycles in async closures (`[weak self]`).
   - [ ] UI: No clipping or text truncation on Dynamic Island and safe area of iPhone 15 Pro.

---

## 5. PRODUCTION RELEASE & PACKAGING

When all code changes and unit tests are 100% green:
1. Commit all changes with a conventional commit message:
   ```bash
   git add -A
   git commit -m "feat: <description>"
   ```
2. Bump version tag (e.g., `v0.8.0`):
   ```bash
   git tag v0.8.0
   git push origin <branch> --tags
   ```
3. GitHub Actions (`.github/workflows/ios.yml`) will automatically trigger, compile Release archive, package `KnightMusic.ipa`, and publish to GitHub Releases for Sideloadly installation.
