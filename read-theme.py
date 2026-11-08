#!/usr/bin/env python3
"""Read Omarchy's palette and shell overrides without changing the active theme."""
import json
from pathlib import Path
import re
import subprocess
import tomllib


def load(path):
    try:
        return tomllib.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def palette():
    home = Path.home()
    current = home / ".local/state/omarchy/current/theme"
    colors = load(current / "colors.toml")
    shell = load(current / "shell.toml")
    for section, values in load(home / ".config/omarchy/shell.toml").items():
        if isinstance(values, dict):
            shell.setdefault(section, {}).update(values)
    foreground = colors.get("foreground", "#eeeeee")
    background = colors.get("background", "#151515")
    accent = colors.get("accent", foreground)

    def resolve(value, fallback, depth=0):
        if depth > 5 or not isinstance(value, str):
            return fallback
        if value in colors:
            return resolve(colors[value], fallback, depth + 1)
        if "." in value:
            section, key = value.split(".", 1)
            return resolve(shell.get(section, {}).get(key), fallback, depth + 1)
        match = re.search(r"#[0-9a-fA-F]{6}\b", value)
        if match:
            return match.group()
        match = re.search(r"rgba?\(([0-9a-fA-F]{6})(?:[0-9a-fA-F]{2})?\)", value)
        return "#" + match.group(1) if match else fallback

    font = subprocess.run(["fc-match", "-f", "%{family[0]}", "monospace"], capture_output=True, text=True, timeout=2).stdout.strip()
    return {
        "background": resolve(shell.get("popups", {}).get("background"), background),
        "foreground": resolve(shell.get("popups", {}).get("text"), foreground),
        "accent": resolve(shell.get("hyprland", {}).get("active-border"), accent),
        "fontFamily": font or "monospace",
        "fontSize": max(8, min(32, float(shell.get("font", {}).get("base-size", 12)))),
    }


if __name__ == "__main__":
    print(json.dumps(palette(), sort_keys=True))
