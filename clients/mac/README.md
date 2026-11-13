# Mac client: work mode 2

When the owner sits at the Mac, the leads open as terminal windows there (iTerm2 + mosh + tmux), and the
assistant arranges them: `ssh mac open`, `ssh mac save` before the workstation goes down,
`ssh mac restore` after the leads are back up. lead_watch then holds back instant pings (mode 2).

## Pieces

| File | Where | Does |
|---|---|---|
| `mac-ctl` | `~/bin/mac-ctl` | forced command of the assistant's Mac key: `open [lead...]`, `save`, `restore`, `layout`, `list`, `check`, `idle` |
| `install.sh` | run once | mosh (Homebrew), mac-ctl, `~/.config/monday-mac/mac.env`, iTerm2 dynamic profile, authorized_keys line |
| `mac-leads.sh` | optional | open leads through tmux control mode (`tmux -CC`): each lead as a native iTerm2 window |

## Setup

1. Tailscale on the Mac, logged in. Its tailnet IP is `MAC_HOST` in local.env, its user `MAC_USER`;
   `MAC_HOSTNAME_PREFIX` is the start of its Tailscale host name (lowercase).
2. System Settings > General > Sharing > **Remote Login** on (for your user only).
3. iTerm2 (recommended; Terminal.app works for `open` only) and Homebrew.
4. Your own SSH key from the Mac to the workstation (mac-ctl lists leads with it, mosh uses it).
5. On the server, with `MAC_HOST` set: `sudo bash server/bootstrap.sh <admin> monster` prints the Mac key.
6. On the Mac, from a checkout of this repo:

   ```sh
   zsh clients/mac/install.sh --monster <MONSTER_USER>@<MONSTER_HOST> \
       --key 'ssh-ed25519 AAAA... monday-mac@monday' --from <SERVER_IP>
   ~/bin/mac-ctl check
   ```

7. From the server: `ssh mac check`. The first `open`/`restore` triggers a macOS Automation prompt
   ("sshd wants to control iTerm"): Allow once.

## Layout save / restore

`save` reads every iTerm2 window, tab and split pane (bounds, size, which lead each pane shows: the part
of the pane title after the last `:`) into `~/.config/monday-mac/layout.tsv`; column 11 marks native
full-screen windows. `restore` recreates windows by id (focus stays on your own window), splits in the
original order, opens full-screen windows with the dynamic profile "Monday Lead Fullscreen"
(`"Window Type":4`), skips panes that are not current leads and closes iTerm's automatic default
window. Full-screen windows open on their own Spaces: check Mission Control before deciding nothing
opened.

## Updating mac-ctl

The assistant cannot update mac-ctl: it is the forced command of its own key, and a self-update verb
would let a compromised server push code to the Mac. Re-run `install.sh` from a fresh checkout, or
fetch the file over the tailnet when the assistant serves it temporarily, then `~/bin/mac-ctl check`.

## Quirks

- osascript commands run without the login PATH: mac-ctl uses absolute paths for mosh, or the window
  opens and closes at once while osascript still reports success.
- In iTerm2's AppleScript `tab` is a class name, not a tab character (`ASCII character 9`).
- Copy out of tmux: iTerm2 Settings > General > Selection > allow clipboard access (OSC 52), or
  Option-drag to bypass tmux's mouse mode.
- Lid closed / asleep = unreachable; lead_watch leaves mode 2 when the Mac drops off the tailnet.
