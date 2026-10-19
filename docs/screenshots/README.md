# Screenshots

These are the pictures the root README embeds. They are rendered from the app,
not captured by hand, and named with a version suffix so a refresh does not
silently replace a picture the README still describes in the old terms.

| File | Shows |
|---|---|
| `icon.png` | App icon at 512 px, as macOS draws it; the README header |
| `hero-{light,dark}.png` | The popover open under its menu bar icon |
| `popover-v1-{light,dark}.png` | The popover: the screenshot just copied, the copy switch, the cleanup summary |
| `popover-attention-v1-{light,dark}.png` | The popover with something to fix: one attention row and "+2 more" |
| `settings-capture-v1-{light,dark}.png` | Settings > Capture: the screenshot folder and the macOS screenshot settings |
| `settings-retention-v1-{light,dark}.png` | Settings > Retention: the age limit and what would go to the Trash now |
| `onboarding-2-try-copied-v1-{light,dark}.png` | Welcome tour step 2: a screenshot taken during "Try it", copied |

## Retaking them

```sh
scripts/screenshots.sh        # English, into build/screenshots/en
scripts/screenshots.sh sk     # Slovak, for the web.pexelo portfolio (also cs de es fr)
```

The script builds Debug and runs the harness in
`ClipShot/Preview/ScreenshotHarness.swift`, which renders the real views at 2x
and exits. It writes more than this folder keeps:

- `popover-paused`, every attention row on its own (`attention-*`), all four
  Settings tabs and every welcome tour step, in light and dark;
- `banner-{light,dark}.png`, the 1920x1080 portfolio image;
- `menubar-states.png`, every menu bar icon state and every phase of the
  copied flash at 1x and 2x, on light and dark menu bars and two wallpapers.

What it shows is invented and stays on the Mac that renders:

- The screenshot folder is a throwaway directory under the temporary
  directory, shown as `~/Pictures/Screenshots`. The screenshot in it is a
  drawing of shapes, written with the markers macOS sets, and copied by the
  real pipeline to a pasteboard that never reaches the system clipboard.
- `com.apple.screencapture` is an in-memory dictionary, so your screenshot
  settings are neither read nor changed.
- Preferences come from the script's launch arguments, and every change the
  harness makes stays in memory: the Debug build's stored settings
  (`sk.moravcik.ClipShot.debug`) are not read or written.

Copy the files you need over the ones here, or bump the suffix (`-v2`) and
update the `<img>` tags in the root README so the two cannot drift apart.

The demo video of the real flow (the shortcut, the floating thumbnail, a paste
into a chat) is recorded by hand on a real screen; it is not rendered here.
