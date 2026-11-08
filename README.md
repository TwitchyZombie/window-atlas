# Window Atlas

A live window overview for Omarchy and Hyprland. Search open windows, switch
workspaces, drag windows between desktops, and save app-to-desktop arrangements.
Built with Quickshell; this is an independent implementation, not a HyprExpo fork.

## Requirements

- Omarchy Quattro with the Quickshell plugin host and `qs.Commons.Style`.
- Hyprland with the Lua API (`hl.dispatch`), initially tested on 0.56.2.
- Quickshell with Wayland/Hyprland support, Qt Quick Controls and QtCore Settings.
- Python 3.11+, `hyprctl`, `gtk-launch` (gtk3), and `fc-match` (fontconfig).

No extra Python modules, network service, compositor plugin, or privileged installer.

## Install

```sh
omarchy plugin add https://github.com/TwitchyZombie/window-atlas --enable
omarchy-shell shell toggle io.github.twitchyzombie.window-atlas ''
```

The package provides an overlay, with no bar widget and no automatic keybinding changes.
For local development, copy this repository into
`~/.config/omarchy/plugins/io.github.twitchyzombie.window-atlas/`, then run
`omarchy-shell shell rescanPlugins` and
`omarchy plugin enable io.github.twitchyzombie.window-atlas`.

Bind the toggle command above to your preferred key or mouse button using your
Hyprland configuration. Your existing middle-button binding is not changed by
installing this plugin. `./toggle` runs the same command.

## Use

- Click a preview to focus its window; click a desktop to switch to it.
- Type to search app names, classes, and window titles. Enter opens a result.
- With search empty, use arrow keys and Enter to select a desktop.
- Drag a preview onto a desktop to move it without following. Drop onto + to
  create a desktop. Moves are checked against Hyprland's actual window state.
- Ctrl-click to select a group. Drag or use the Move menu for the selection.
- Right-click a preview to move, request a normal close, or toggle fullscreen.
  Apps can still show their normal save prompts.
- Right-click a desktop header to name it or launch an installed app there.
- Undo a verified move within 15 seconds using the footer.
- Use Arrangement to save app-to-desktop groups and explicitly restore them.
  Opening missing apps is a separate, explicit action. Documents, terminal
  contents, and exact geometry are not session-saved.
- Choose Auto, 2, 4, or 8 desktops. Occupied desktops outside the fixed range
  remain visible. Escape clears selection first, then dismisses the overview.

## Data and behavior

Settings, desktop names, and saved arrangements are stored in
`${XDG_CONFIG_HOME:-$HOME/.config}/window-atlas.ini`. Saved arrangements include
app identities and window titles; no personal settings ship in the repository.
No previews are saved to disk and no network requests are made by the plugin.
App launches use installed desktop entries through `gtk-launch`. Window actions
use `hyprctl`; no shell is used to evaluate window titles or search strings.
The overlay follows Omarchy's current palette and font and respects the shell's
animation duration setting. Window titles and other displayed text use plain text.

## Remove

```sh
omarchy plugin disable io.github.twitchyzombie.window-atlas
omarchy plugin remove io.github.twitchyzombie.window-atlas
```

Remove any binding you added yourself. Optional: delete `window-atlas.ini` from
your configuration directory to erase saved names and arrangements.

## Limitations

Version 0.1.0 is an initial release. The overview appears on the first screen;
special workspaces are excluded. Workspace scenes clip windows outside their
visible viewport. It does not change desktop tiling layouts. Single-instance
apps that reuse an existing window may not open on the requested desktop.
The UI is currently English.

## Validation

```sh
omarchy plugin validate .
python -m unittest -v test_backend.py
```

Backend tests cover batch validation, partial-move undo information, replaced
window guards, deterministic matching, and single-instance launch handling.

## License

MIT. See [LICENSE](LICENSE).
