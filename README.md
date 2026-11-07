# Tabla

An offline, infinite whiteboard written in [C3](https://c3-lang.org) with raylib.
Everything stays on your machine, in a single file per board.

## Build and run

Needs `c3c` 0.8.5 or newer and the X11 development library (`libx11-dev`).

```sh
c3c build tabla                  # optimised binary in build/tabla
build/tabla                      # your default board
build/tabla ideas.tabla          # a specific board, created if it does not exist
build/tabla ideas.tabla plans.tabla   # several boards, each in its own tab
```

The default board is `~/.local/share/tabla/board.tabla`. `zenity` provides the file
dialogs; without it, you can still drop files on the window.

## What it does

- **Infinite canvas.** Zoom from 0.001% to 10,000,000%, at any distance from the origin.
  Pen sizes are in screen pixels, so you can zoom in to draw fine detail and zoom out to
  work large.
- **Pens.** Pen, brush (thins out with speed), chisel marker and highlighter, each with
  its own colour, size, opacity and smoothing. Translucent ink never darkens where it
  crosses itself. The eraser cuts strokes; hold Shift to remove whole ones.
- **Shapes.** Line, arrow, rectangle, ellipse. Shift snaps angles and makes squares
  and circles.
- **Pictures.** Drop files on the window, paste with Ctrl+V (including screenshots and
  files copied in a file manager), or press I. PNG, JPEG, BMP, GIF and QOI are supported,
  and phone photos are turned the right way up.
- **Drawing on pictures.** A stroke that starts on a picture is pinned to it: move or
  resize the picture and the drawing goes with it. Delete the picture and it goes too.
- **Text and sticky notes**, with Latin, accented and Cyrillic characters.
- **Select, move, resize, duplicate, layer order, recolour.**
- **Undo and redo** for everything, 512 steps back.
- **Tabs.** Up to five boards open at once, each with its own view and undo history.
  Ctrl+N and Ctrl+O open a board in a new tab, Ctrl+Tab moves between them and Ctrl+W
  closes one. Copy and paste works between tabs, pictures included.
- **Saving is automatic.** Changes are written a second after you stop, in every tab, and
  always when you quit. A save replaces the file atomically, so a crash cannot damage your
  board. Pictures are stored inside the board file.
- **Failed saves do not lose work.** A board that cannot be saved keeps a red dot on its
  tab, stays open when you try to close it, and keeps trying. Quitting then takes a second
  close of the window.
- **PNG export** of the whole board, or of the selection if there is one.

Press **F1** in the app for all shortcuts.

## Layout

| File | Purpose |
|------|---------|
| `src/geom.c3` | Pure 2D maths: smoothing, stroke tessellation, eraser cuts |
| `src/board.c3` | The document: items, z-order, undo history |
| `src/store.c3` | The `.tabla` file format |
| `src/render.c3` | GPU drawing: ink meshes, pictures, text, paper, PNG export |
| `src/input.c3` | One frame of input, as a plain struct |
| `src/app.c3` | Tools, pointer handling, commands, file handling |
| `src/ui.c3` | Toolbars and overlays |
| `src/clip.c3` | Reading pictures from the X11 clipboard |
| `src/dialog.c3` | File dialogs through zenity |
| `src/e2e.c3` | End-to-end test driver |

World positions are doubles, while each item's geometry is in floats relative to its own
origin. That is why precision holds up however far you travel.

## Tests

```sh
c3c test tabla-debug             # unit tests: geometry, undo, file format
scripts/e2e.sh build/e2e         # scripted run of the real app in a hidden window
```

The end-to-end run needs Python with Pillow for its fixtures. It leaves screenshots in
the directory you give it, and uses its own X11 selection, so it does not touch your
clipboard.

## Known limits

- Linux with X11 (or XWayland). The clipboard and dialog code is Linux-specific; the rest
  is portable.
- Pictures cannot be rotated or cropped yet, and WebP cannot be read.
- Pictures wider or taller than 4096 pixels are downscaled for display. The original is
  kept in the board file.
- Open pictures may use up to 2 GB of graphics memory. Past that, the ones seen longest
  ago are let go and load again when next on screen, one per frame, which is slower for
  large photos. Pictures on screen always stay, even over the limit.
- Tabs are not remembered between runs.

## Credits

`lib/raylib55.c3l` is the raylib 5.5 binding from the C3 vendor collection, with
`RLTraceLogCallback` ungated so that it compiles on Linux x64. Text is set in DejaVu Sans;
see `resources/fonts/LICENSE-DejaVu.txt`.
