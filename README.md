# SeekPop

Lightning-fast macOS file search powered by Hammerspoon and ripgrep. Search, open, and copy files with a keystroke.

SeekPop opens a search palette when you press Option+Space in any app. It searches the contents and the names of the folders you add, hidden folders included, and shows the matching text next to the results. SeekPop keeps no index. Each search runs ripgrep over the files as they are now, so a file you saved a second ago is already searchable.

## Requirements

- macOS with [Hammerspoon](https://www.hammerspoon.org). SeekPop is tested with Hammerspoon 1.1.1 on macOS 26.
- [ripgrep](https://github.com/BurntSushi/ripgrep). Install it with `brew install ripgrep`.
- Optional. Screen Recording permission for Hammerspoon, to blur the desktop behind the palette.

## Install SeekPop

1. Clone the repository.

	```sh
	git clone https://github.com/duarbdhks/seekpop.git ~/develop/seekpop
	```

2. Link the Spoon into your Hammerspoon folder.

	```sh
	ln -s ~/develop/seekpop/SeekPop.spoon ~/.hammerspoon/Spoons/SeekPop.spoon
	```

3. Add these lines to `~/.hammerspoon/init.lua`.

	```lua
	hs.loadSpoon("SeekPop")
	spoon.SeekPop:bindHotkeys({ toggle = { { "alt" }, "space" } })
	spoon.SeekPop:start()
	```

4. Reload the Hammerspoon config.
5. Press Option+Space, click **Folders**, and add the folders you want to search.

## Add folders to search

SeekPop starts with no folders. To add one, press ⌘, in the palette, then click **Add folder…**. To pick a hidden folder such as `~/.codex/plans`, press ⌘⇧. in the picker to show hidden folders, or press ⌘⇧G and type the path. SeekPop saves the list in the Hammerspoon setting `SeekPop.roots`.

## Keys

| Key | Action |
| --- | --- |
| ⌥Space | Open or close the palette |
| ↑ and ↓, or ⌃P and ⌃N | Move the selection |
| Return | Open the file in its default app |
| ⌘Return | Show the file in Finder |
| ⌘C | Copy the file. You can paste it in Finder or attach it in a chat app. |
| ⌘⇧C | Copy the file path |
| ⌘, | Show or hide the folder list |
| Esc | Close the folder list, then the palette |

## How search matches files

A file matches when every word of the query appears somewhere in the file, on any line and in any letter case. A file also matches when its name contains every word. SeekPop sorts results by modification time, newest first, and shows at most 50.

Each row shows the first Markdown heading of the file, or the file name when the file has no heading, and the first matching line. The preview shows the file text with the query words highlighted.

SeekPop skips binary files, files larger than 2 MB, and the folders `.git`, `node_modules`, `dist`, `build`, and `.next`. ripgrep also skips files that a `.gitignore` file excludes.

## Settings

Set these fields after `hs.loadSpoon` and before `start()`.

| Field | Default | Meaning |
| --- | --- | --- |
| `rgPath` | First of `/opt/homebrew/bin/rg` and `/usr/local/bin/rg` | Path to the ripgrep binary |
| `maxResults` | `50` | Maximum number of results |
| `maxFileSize` | `"2M"` | Files larger than this are not searched by content |
| `exclude` | `{".git", "node_modules", "dist", "build", ".next", ".DS_Store"}` | Names that ripgrep skips at any depth |

The palette follows the system light or dark appearance and the Reduce motion setting.

## Desktop blur and privacy

If Hammerspoon has Screen Recording permission, SeekPop captures the area behind the palette just before the palette opens and shows that image blurred. The image stays in memory and SeekPop never writes it to disk. The blur is a still image, so it does not change while the palette is open.

Without the permission, the palette uses a tinted glass background. To turn the blur on, click **Turn on** in the folder list, or enable Hammerspoon in System Settings > Privacy & Security > Screen & System Audio Recording. macOS asks again from time to time to confirm the permission.

## Troubleshooting

- **Option+Space does nothing.** Another app can own the same shortcut. The ChatGPT desktop app uses Option+Space for its launcher by default. Turn the launcher off in ChatGPT, or bind SeekPop to another key.
- **The palette says ripgrep was not found.** Install ripgrep with Homebrew, or set `spoon.SeekPop.rgPath` to the binary.

## Roadmap

- Show the selected file in a running Yazi instance with `ya emit-to`.
- Search the text inside PDF files.

## Run the tests

The tests run inside Hammerspoon through its `hs` command-line tool, which needs `require("hs.ipc")` in your config.

```sh
hs -c "dofile('$PWD/tests/search_test.lua')"
```

## License

[MIT](LICENSE)

