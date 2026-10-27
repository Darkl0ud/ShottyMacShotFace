# ShottyMacShotFace

*Made with the assistance of AI.*

A [Greenshot](https://getgreenshot.org/)-style screenshot tool for macOS, written in native Swift
(AppKit and ScreenCaptureKit, with SwiftUI for Preferences). It lives in the menu bar.

**Requires:** macOS 14 Sonoma or newer, and the Xcode **Command Line Tools** (`xcode-select --install`).
Full Xcode is not needed.

## Build and run

```bash
./build.sh                 # release build → build/ShottyMacShotFace.app
open build/ShottyMacShotFace.app
# or install it:
cp -R build/ShottyMacShotFace.app /Applications/

./build.sh test            # unit tests
./build.sh selftest        # renders the editor, overlay and effects to build/selftest/*.png + report.txt
```

On first launch macOS asks for **Screen Recording** permission (System Settings → Privacy & Security →
Screen & System Audio Recording). Turn it on, then quit and reopen the app.

> The build is signed *ad hoc*, and macOS ties the permission to the signature. Each rebuild therefore
> looks like a new app and needs the permission granted again. To avoid that, create a code-signing
> certificate (Keychain Access → Certificate Assistant → Create a Certificate…, type "Code Signing")
> and build with `SIGN_IDENTITY="Your Cert Name" ./build.sh`.

## Features

### Capture
| Action | Default hotkey | Notes |
|---|---|---|
| Capture Region | ⌃⇧4 | Drag a rectangle, **or click a window** to take its area. Magnifier and crosshair for pixel-exact edges. |
| Capture Window | ⌃⇧5 | Click a window. It's captured on its own (including parts covered by other windows), with or without its shadow. |
| Capture Full Screen | ⌃⇧3 | All displays as one picture. The menu also has "Capture Screen" for a single display. |
| Capture Last Region | ⌃⇧6 | Same area as last time. |

While selecting: hold **Shift** to move the pointer at quarter speed (release the hotkey's own keys first, then
press ⇧), **Space** switches between region and window mode, **arrow keys** move the pointer by 1 pt (⇧ for 10),
**Return** accepts, **Esc** or right-click cancels. Esc during a drag drops just that drag, and a second Esc cancels.
Switching to another app while selecting cancels the capture.

The screen is frozen the moment you press the hotkey (like Greenshot), so open menus and tooltips can be
captured. You can select across several displays. Each display keeps its own resolution; only a region spanning
displays with different scales is stitched at the higher one. The app's own editor and Preferences windows appear in
captures too.

The hotkeys can be changed in Preferences. The defaults avoid macOS's own ⌘⇧3/4/5.

### After capture (pick any combination)
Open in the image editor · copy to clipboard · save with the filename pattern · Save As… · ask each time
(a pop-up menu).
With Ask each time, copying and saving with the pattern still happen straight away; the menu then offers what's
left (editor, Save As…), so Editor and Save As ticked alongside it are chosen from the menu.

### Image editor
| Tool | Key | |
|---|---|---|
| Select / move | V or Esc | Shift-click to add to the selection, drag on empty space for a selection rectangle, grips to resize |
| Rectangle, Ellipse | R, E | ⇧ for square/circle; line colour, fill, width, shadow |
| Line, Arrow | L, A | ⇧ snaps to 45°; arrowheads at the start, end, both or none |
| Freehand | F | |
| Text box | T | Font, size, bold, italic, text colour, background |
| Speech bubble | S | Drag the tail's grip to point it |
| Step counter | I | Click to place 1, 2, 3…; renumbers when one is deleted. Size control in the bar; the starting number is set in Preferences |
| Highlight | H | Text marker, dim the rest, grayscale the rest, or magnify |
| Obfuscate | O | Pixelate (default, 4 pt blocks) or blur with soft edges, adjustable strength |
| Crop | C | Drag, then Return (Esc cancels) |

Also: undo/redo (up to 100 steps; fewer after many whole-picture effects on very large captures), cut/copy/paste/duplicate of annotations, pasting an image from the clipboard
or inserting one from a file, z-order (⌘[ ⌘] and Page Up/Down), arrow-key nudging, zoom (⌘+ ⌘- ⌘0 ⌘9).
Tool settings are remembered between captures. Text boxes grow to fit what you type. Opened and inserted photos are
shown upright.

**Unsaved work:** closing an editor, or quitting the app, asks first if the capture hasn't been saved or copied
anywhere yet, including a brand-new capture with no edits.

**Effects** (wand menu / Image menu): drop shadow, torn edges (all sides or bottom only), border, grayscale,
invert, rotate, resize, auto-crop. These apply to the whole picture: the annotations are baked in, and
⌘Z brings them back as editable objects.

### Output
PNG, JPEG, TIFF, BMP, GIF or HEIC. Formats without transparency get a white background rather than black. GIF keeps
full transparency only: pixels under half opacity become transparent, the rest are put on white (no black halos).
Notifications after saving also show while the app is in front.

Filename pattern, e.g. `${YYYY}-${MM}-${DD} ${hh}.${mm}.${ss} ${title}`. Variables: `${YYYY} ${YY} ${MM}
${DD} ${hh} ${mm} ${ss} ${title} ${user} ${hostname} ${NUM}`. A `/` creates subfolders. Files are never
overwritten; a later one becomes `name (2).png`.

## Not included (yet)
Greenshot's printing, e-mail, Office, Imgur/Jira/Confluence/Dropbox exporters, OCR and Internet Explorer
capture are not in this version.

## Project layout
```
Sources/ShottyCore/          model, renderer, effects, export, filename patterns, settings (unit-tested)
Sources/ShottyMacShotFace/  menu-bar app: capture, selection overlay, editor, preferences, self-test
Tests/ShottyCoreTests/       swift-testing unit tests
Resources/Info.plist
build.sh
```

Inspired by Greenshot (GPL). No Greenshot code is used.
