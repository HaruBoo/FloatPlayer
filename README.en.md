# FloatPlayer

[🇯🇵 日本語](./README.md) | 🇺🇸 English

A macOS floating player that always stays on top. Watch YouTube, photos (screenshots, etc.), and saved videos side-by-side with whatever else you're working on.

A native Swift/AppKit/SwiftUI app — no Xcode required, builds with the Swift command-line tools alone.

---

## Features

- **YouTube playback** — Embedded playback via the official IFrame Player API (no downloading). Pause, resume, and seek without reloading the page
- **Photo / screenshot display** — File picker, drag & drop, and clipboard paste all supported
- **Looping local video playback** — Loop a saved video file like background video (BGV)
- **Auto-floating screenshots** — The instant you take a screenshot (e.g. Cmd+Shift+4), a chrome-less, image-only window pops up automatically and can be dragged anywhere
- **Two independent opacity sliders** — Fade the "YouTube / photo / video" content and the "UI (buttons etc.)" separately
- **Smart window layering** — FloatPlayer floats on top only while it's the active app; it automatically drops behind other apps' windows otherwise (click it to bring it back to front)
- **Chapter extraction** — Automatically pulls chapter timestamps from a YouTube video's description via the YouTube Data API v3. Pick one from the menu bar to jump instantly, no reload
- **Menu bar resident** — Controllable from the Dock icon or the menu bar icon. The app keeps running even after the panel is closed

## Screenshots

*(Add app screenshots here)*

## Requirements

- macOS 13 (Ventura) or later
- No Xcode needed (Swift command-line tools only)

## Build & Run

```sh
git clone https://github.com/HaruBoo/FloatPlayer.git
cd FloatPlayer
./build_app.sh
open FloatPlayer.app
```

`build_app.sh` packages the `swift build` output into a proper `.app` bundle and ad-hoc signs it (this signature is for local execution only — it cannot be used for distribution).

After that, drag `FloatPlayer.app` to the Dock to pin it, or just launch it from Finder.

### A note on rebuilding

Because the local ad-hoc signature's hash changes with every build, macOS may re-prompt for permissions (e.g. Desktop folder access for the screenshot feature) after a rebuild. Just click "Allow" when it appears.

## Usage

### Basics

- Switch between **YouTube / Photo / Video** using the segmented control at the top (all three modes stay mounted in the background, so switching between them preserves playback position)
- The two sliders at the bottom independently control the opacity of the **media (YouTube/photo/video)** and the **UI (buttons etc.)**
- Check "Click-through" to let clicks pass through to whatever app is behind the window
- Starting YouTube playback automatically hides the UI, leaving just the video. Bring the controls back anytime via "Show UI" in the menu bar

### YouTube playback

1. On the "YouTube" tab, enter a URL or video ID and press "Play"
2. Switching to another mode while playing keeps the video running in the background (it auto-pauses/resumes as you switch)
3. Use "Chapters" in the menu bar to jump to an extracted timestamp (requires the API key setup below)

### Setting up chapters

Chapter extraction requires a YouTube Data API v3 key (the free tier is plenty).

1. Create a project in [Google Cloud Console](https://console.cloud.google.com/)
2. Enable "YouTube Data API v3"
3. Go to "Credentials" → "Create API Key". Choose **"Public data"** as the access scope (no user-data access is needed)
4. Paste the key into the API key field below the YouTube URL input (it's saved locally, so you only need to do this once)

For any video whose description has 2 or more timestamps (e.g. `0:00 Intro`), chapters will load automatically within a few seconds.

### Photos & screenshots

- Click "Choose Photo" to pick a file, or drag and drop one onto the window
- Paste an image directly from the clipboard via the "Paste" button, Cmd+Shift+V, or the menu bar

### Video files

- Click "Choose Video" to pick a saved video file, or drag and drop one onto the window (it loops automatically)

### Auto-floating screenshots

While FloatPlayer is running, taking a screenshot (e.g. Cmd+Shift+4) causes a **chrome-less, image-only** window to automatically float onto the screen a few hundred milliseconds later.

- Drag anywhere on the window to move it
- Right-click for "Close," "Save As…," or "Copy"
- Toggle this feature on/off from "Auto-float screenshots" in the menu bar

The first time, macOS will show a permission dialog for Desktop folder access — click "Allow" (if you've changed your screenshot save location, FloatPlayer reads that setting automatically).

### Menu bar

| Item | Description |
|---|---|
| Show Panel | Bring the window back to the front |
| Click-through | Toggle on/off |
| Show/Hide UI | Toggle the button controls |
| Chapters | Jump to an extracted chapter |
| Paste Screenshot | Paste a clipboard image |
| Auto-float Screenshots | Toggle on/off |
| Quit | Fully quit the app |

## Tech Stack

Swift 6 / Swift Package Manager (no Xcode) / AppKit (NSPanel, NSStatusItem) / SwiftUI (the UI) / WebKit (WKWebView for YouTube) / AVFoundation (local video playback) / Combine (state management) / URLSession (YouTube Data API)

The techniques used and bugs actually hit while building this app (window auto-growth, sudden termination, etc.) are documented in the [learning notes](docs/learning-notes/index.html) (Japanese only).

## Known Limitations

- Videos that the uploader has disabled embedding for cannot be played
- Screenshot auto-detection works by watching the save folder for changes, so it may not work if screenshots are configured to save directly to cloud storage, etc.
- Because of the ad-hoc signature, Gatekeeper may show a warning on first launch — this is expected for a local build

## License

Personal project. No license has been set.
