# Live Wallpaper

Keep choosing Apple's aerial wallpapers in System Settings. This small Swift menu bar app follows your selection and plays the downloaded video behind your desktop icons, at its original 1× speed.

No separate video picker. No second video library. No changes to Apple's wallpaper settings.

## Install

Tested on macOS 27 with two displays. Requires Xcode Command Line Tools or Xcode. Earlier macOS versions may store videos elsewhere and have not been validated.

```sh
git clone https://github.com/johnjyang/live-wallpaper.git
cd live-wallpaper
bash test.sh
bash install.sh
```

Then select a downloaded aerial in **System Settings → Wallpaper**. If it still has a download arrow, let macOS finish downloading it first.

The app installs to `~/Applications/Live Wallpaper.app` and starts at login. It is built locally and signed ad hoc; no developer account, packages, or third-party runtime dependencies are required. Apple's videos are not included or redistributed.

## Controls

Click the play-rectangle icon in the menu bar:

- **Play When Desktop Is Visible**: pause when at least 95% of the desktop is covered; resume below 90%. This is the default. Matching displays share playback, so the video runs while any matching display needs it.
- **Always Play**: keep playing behind windows.
- **Pause**: hide the helper's windows and show Apple's normal wallpaper.

Apple's **Shuffle All**, **Shuffle Landscape**, **Shuffle Cityscape**, **Shuffle Underwater**, and **Shuffle Earth** selections also work. The helper chooses from downloaded, shuffle-eligible videos in the selected collection without repeating a video until the collection has been visited. **Continuously** advances at the end of a clip; the 12-hour, daily, two-day, weekly, and monthly settings loop the current clip until their interval expires. Timed rotation sleeps while playback is inactive and catches up when playback resumes.

**Next Shuffle Video** advances immediately within the selected collection. Matching displays share the same shuffled video and player. The helper manages its live rotation independently of Apple's frozen wallpaper frame and screen-saver shuffle; it does not write a replacement selection into Apple's store.

The app also observes display sleep, session inactivity, screen lock, and screen saver notifications. Choosing a still image returns to normal macOS behavior. If the selected video is missing or not ready, the helper leaves Apple's background visible.

## How it works

Two Swift source files, using AppKit and AVFoundation:

1. Read the selected aerial's asset ID from `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`.
2. Open the corresponding video in `~/Library/Application Support/com.apple.wallpaper/aerials/videos/`.
3. Present it in a mouse-transparent window above the system wallpaper and below desktop icons.
4. Follow selection and download changes through filesystem notifications.

The OS-default aerial is a special case: macOS stores it as `Provider: default` with an empty configuration, so there is no asset ID. The helper resolves the single bundled movie in `/System/Library/Wallpapers/.default/` instead. This supports Golden Gate Sunset on macOS 27 without hardcoding its catalog UUID or filename. If the default has no movie or several ambiguous movies, normal macOS behavior is preserved.

Matching displays share an `AVQueuePlayer` and `AVPlayerLooper`. Different scenes use separate players. `AVPlayerLayer` presents the video; the app does not copy or process individual frames. Playback uses `AVPlayer.rate = 1`.

Visibility mode queries window geometry about once per second and calculates the union of covered rectangles. Always and Pause modes disable that timer. There are no screenshots, pixel analysis, eye tracking, or screen-recording permission requests.

The wallpaper store, Space preferences, and lock/screen-saver notification names are undocumented interfaces. This app reads or observes them; it does not patch system binaries, inject into another process, or change SIP.

## Build and test

```sh
bash test.sh
bash build.sh
```

Builds target macOS 14+ and are staged outside the source directory to avoid Finder metadata interfering with signing. The output is `~/Library/Caches/com.local.LiveWallpaper/build/Live Wallpaper.app`. A successful build on an older OS does not establish desktop compatibility there.

The test suite covers:

- Rectangle-union coverage against an independent cell-counting oracle.
- Overlapping windows, gaps, and offset displays.
- Playback-policy hysteresis and suspend behavior.
- Wallpaper selection precedence and non-aerial fallbacks.
- Invalid asset IDs and undefined playback timestamps.

The suite currently passes **315 checks**. Selection changes, original-speed playback, shared playback across two displays, and manual pause/resume were also checked on a running macOS 27 system.

An optional playback integration test uses a one-second local extract of an existing downloaded aerial to exercise the production loop callback and pause behavior:

```sh
bash test-playback.sh
```

The temporary extract stays on your Mac and is removed after a successful test. This test is separate from CI, which has no Apple videos.

CI builds and runs the noninteractive tests. It does not validate desktop rendering, permissions, or sleep/wake behavior.

### Resource measurements

To sample an installed, running instance:

```sh
python3 Tests/performance.py
```

This measures each mode and restores the starting mode. Set `SAMPLE_SECONDS` to change the default 15-second interval. If you have identified its VideoToolbox decoder process, set `DECODER_PID` to sample that separately.

In one short local sample with a single player shared across two displays, the helper and decoder together used approximately 0.4% of one CPU core while playing. The decoder retained roughly 0.5 GiB of video buffers. These numbers vary by video and hardware; they exclude GPU and WindowServer costs and are not a battery-life benchmark or a comparison against Aerial.

Measurements and diagnostics stay local and are ignored by Git. The app writes status and event logs under `~/Library/Application Support/LiveWallpaper/`.

## Compatibility limits

- Direct aerial thumbnails, the bundled default aerial, and standard aerial shuffle collections are supported. Unknown shuffle interval identifiers fall back to normal macOS behavior.
- The video-store path is the newer per-user location. Sonoma/Sequoia's legacy system store is not implemented.
- Apple still images and shader-based dynamic wallpapers retain their normal behavior.
- Display and Space overrides are parsed. Per-Space transitions, display hot-plug, screen lock, and sleep/wake have not been tested end to end.
- Coverage is estimated from window rectangles and alpha. Transparent content inside otherwise opaque windows can affect it.
- Pausing retains the player and its video buffers for fast resumption.
- Apple's undocumented store format and notifications may change in a future release.

## Local commands

```sh
"$HOME/Applications/Live Wallpaper.app/Contents/MacOS/LiveWallpaper" --mode visible
"$HOME/Applications/Live Wallpaper.app/Contents/MacOS/LiveWallpaper" --mode always
"$HOME/Applications/Live Wallpaper.app/Contents/MacOS/LiveWallpaper" --mode paused
"$HOME/Applications/Live Wallpaper.app/Contents/MacOS/LiveWallpaper" --refresh-status
"$HOME/Applications/Live Wallpaper.app/Contents/MacOS/LiveWallpaper" --next
"$HOME/Applications/Live Wallpaper.app/Contents/MacOS/LiveWallpaper" --quit
```

Quit from the menu to stop the current session. The login agent restarts the app after unexpected crashes, but not after a normal quit.

## Uninstall

```sh
launchctl bootout "gui/$(id -u)/com.local.live-wallpaper"
```

Remove `~/Library/LaunchAgents/com.local.live-wallpaper.plist` and move `~/Applications/Live Wallpaper.app` to Trash. Diagnostics under `~/Library/Application Support/LiveWallpaper/` and logs under `~/Library/Logs/LiveWallpaper/` can also be removed. Your Apple wallpaper selection and downloaded videos stay in place.

## References

- [AVPlayerLooper](https://developer.apple.com/documentation/avfoundation/avplayerlooper) — the system video-looping API.
- [PaperSaver](https://github.com/AerialScreensaver/PaperSaver) — research and tooling around the undocumented wallpaper store and Space configuration.
- [Aerial](https://github.com/AerialScreensaver/Aerial) — a fuller wallpaper/screensaver app using a different integration approach.

MIT licensed. Apple media and system frameworks remain Apple's property.
