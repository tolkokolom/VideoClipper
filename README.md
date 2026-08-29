# VideoClipper

Native macOS app for basic, fast video editing — ClipShot's editing tools
(trim / crop / rotate) ported to the Mac with drag-and-drop and file export.

## Layout

Video canvas on top, transport + trim strip + tools beneath, filmstrip bin of
dropped clips along the bottom. Drop video files anywhere in the window.

## Editing

- **Trim** — drag the yellow handles on the strip, or press `I` / `O` to set
  in/out at the playhead.
- **Crop** — aspect presets (Original, 1:1, 9:16, 16:9, 4:5); drag the frame to
  move it, drag corners to resize.
- **Rotate** — 90° clockwise per press (`⌘R`).

Edits are staged per clip — switching clips in the filmstrip keeps unsaved work.
The preview always shows the staged result (crop/rotation applied via
`AVPlayerItem.videoComposition`), and playback honours the trim range.

## Export

`⌘S` exports beside the original as `<name>-edit.mp4` (auto-incrementing,
never overwriting). `⇧⌘S` opens a save panel. Pure rotations take a lossless
passthrough fast-path (`.mov`, no re-encode). All AVFoundation — no FFmpeg.

## Frame handoff (markers → coding agent)

For handing a bug screenrecording to a coding agent: press `M` at the playhead
to mark frames — cyan ticks on the strip, with a pin per marker in a lane above
the timeline (hover shows the note and highlights the marker in the sidebar;
click focuses its note field). The **Mark** tool (next to Crop) opens a right
sidebar listing the markers vertically: jump, edit the optional note, remove.
Then `⌘E` — "Copy Frames for Agent". That writes a `<name>-frames/`
folder beside the video (downscaled JPEGs + a `frames.md` manifest with
timestamps, deltas between frames, and notes) and puts the manifest with
**absolute paths** on the clipboard, so one paste into Claude Code hands over
the frames, the timing, and the commentary in one go. Staged crop/rotation
applies to the exported frames; `⌥←` / `⌥→` jump between markers.

## Keyboard

| Key | Action |
| --- | --- |
| Space | Play / pause |
| ← / → | Step one frame |
| I / O | Set trim in / out |
| M | Mark / unmark frame at playhead |
| ⌥← / ⌥→ | Previous / next marker |
| ⌘R | Rotate 90° |
| ⌘S / ⇧⌘S | Export / Export As… |
| ⌘E | Copy Frames for Agent |
| ⌘← / ⌘→ | Previous / next clip |
| ⌘⌫ | Remove clip from bin |
| ⌘O | Open videos |

## Building

```sh
xcodegen generate       # .xcodeproj is gitignored
open VideoClipper.xcodeproj
```

or `xcodebuild -scheme VideoClipper build`. Tests: `xcodebuild -scheme VideoClipper test`.
