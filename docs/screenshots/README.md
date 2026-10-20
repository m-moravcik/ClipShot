# Screenshots

These are the pictures the [root README](../../README.md) embeds. They are
rendered from the app by the Debug screenshot harness, not captured by hand, so a
UI change (or a new menu bar symbol) is one command away from the README:

```sh
scripts/readme-screenshots.sh
```

It renders English with `scripts/screenshots.sh` and copies the set below over the
files here. Look at the diff and read the README against the new pictures before
committing; the names stay the same, so nothing else needs editing.

| File | Shows |
|---|---|
| `icon.png` | App icon at 512 px, as macOS draws it; the README header |
| `popover-{light,dark}.png` | The popover: copying on, the four most recent screenshots, the switch and the cleanup summary |
| `popover-paused-focus-{light,dark}.png` | The popover while a Focus filter paused copying |
| `preview-hover-{light,dark}.png` | ClipShot's floating preview under the pointer, just taken: Copied, the Markup pencil, Close and Move to Trash |
| `popover-undo-{light,dark}.png` | The popover just after Move to Trash, with the Undo strip in place of the trashed row |
| `settings-capture-{light,dark}.png` | Settings > Capture: the save folder, the Preview picker, Restore previous settings |
| `settings-retention-{light,dark}.png` | Settings > Retention: the period and what would go to the Trash now |

## Rendering more

```sh
scripts/screenshots.sh          # English, into build/screenshots/en
scripts/screenshots.sh sk       # one language (sk cs de es fr), e.g. for the web.pexelo portfolio
scripts/screenshots.sh all      # all six, one build
```

The harness writes far more than this folder keeps: every popover state and
attention row, all Settings tabs, every welcome tour step, the floating preview
and its motion key frames, the menu bar states, and the 1920x1080 portfolio
banner, in light and dark. The header of `scripts/screenshots.sh` lists them.

What it shows is invented and stays on the Mac that renders:

- The screenshot folder is a throwaway directory under
  `build/screenshots-scratch`, shown as `~/Pictures/Screenshots`. The screenshots
  in it are drawings of shapes, written with the attributes macOS sets, and copied
  by the real pipeline to a pasteboard that never reaches the system clipboard.
  The previous run's folder goes to the Trash when the next run starts.
- `com.apple.screencapture` is an in-memory dictionary, so your screenshot
  settings are neither read nor changed. The demo Trash refuses every move.
- Preferences come from the script's launch arguments, and every change the
  harness makes stays in memory: the Debug build's stored settings
  (`sk.moravcik.ClipShot.debug`) are not read or written.
- English renders use a 12-hour clock and the other languages a 24-hour one,
  whatever this Mac is set to.

Popover pictures are drawn off-screen, so the popover's material is a solid fill.
With `CLIPSHOT_SCREENSHOTS_LIVE=1` they come from a window on screen through
ScreenCaptureKit instead; that needs Screen Recording for the Debug build, which
the harness never asks for.

The animated hero at the top of the README (`docs/hero.gif`, `docs/hero-dark.gif`) is
rendered too, frame by frame off screen, by `scripts/readme-hero.sh`; see
[DEVELOPMENT.md](../../DEVELOPMENT.md#reviewing-the-ui).
