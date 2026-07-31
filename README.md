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

## Keyboard

| Key | Action |
| --- | --- |
| Space | Play / pause |
| ← / → | Step one frame |
| I / O | Set trim in / out |
| ⌘R | Rotate 90° |
| ⌘S / ⇧⌘S | Export / Export As… |
| ⌘← / ⌘→ | Previous / next clip |
| ⌘⌫ | Remove clip from bin |
| ⌘O | Open videos |

## Building

```sh
xcodegen generate       # .xcodeproj is gitignored
open VideoClipper.xcodeproj
```

or `xcodebuild -scheme VideoClipper build`. Tests: `xcodebuild -scheme VideoClipper test`.
