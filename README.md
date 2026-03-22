# devtools

Lightweight zsh helpers for inspecting local dev servers.

## Commands

- **`devview`** — Lists listening TCP servers and common dev processes (Vite, Next, esbuild, etc.)
- **`devwho`** — Shows a table of dev servers on tracked ports (3000, 5173, 8080, 8081) with the tool that launched them (Claude, Cursor, Ghostty, tmux, etc.)

## Install

```sh
git clone https://github.com/YOUR_USER/devtools.git ~/Documents/GitHub/devtools
cd ~/Documents/GitHub/devtools
bash install.sh
```

This copies `devtools.zsh` to `~/.devtools.zsh` and adds a small source block to `~/.zshrc`.

## Uninstall

```sh
cd ~/Documents/GitHub/devtools
bash uninstall.sh
```

## Updating

After editing `devtools.zsh` in the repo:

```sh
cp ~/Documents/GitHub/devtools/devtools.zsh ~/.devtools.zsh
source ~/.zshrc
```

Or just re-run `bash install.sh`.

## Customization

Edit `devtools.zsh` directly. Add ports, tools, or new commands as needed.
