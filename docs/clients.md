# Clients

| Client | Folder | Role |
|---|---|---|
| Telegram | (Hermes, CCGram) | primary interface: talk to the assistant; per-lead topics with buttons |
| Mac | [`clients/mac/`](../clients/mac/README.md) | work mode 2: leads as iTerm2 windows (mosh + tmux), layout save/restore driven by the assistant |
| Phone terminal | [`clients/phone/`](../clients/phone/README.md) | Termius/mosh to the workstation, `lead-attach` to attach to a lead |
| Phone waker | [`clients/phone-waker/`](../clients/phone-waker/README.md) | an always-on Android phone on the workstation's LAN that sends Wake-on-LAN |

## Work modes

| | Mode 1 (default) | Mode 2 |
|---|---|---|
| Where the owner is | anywhere, on Telegram | at the Mac, in the lead windows |
| Lead pings | everything, at once | failures at once; anything else after 15 min of waiting |
| Started by | default; "mode 1" | `ssh mac open` / `ssh mac restore` (the assistant writes `state/work_mode`) |
| Ends | – | owner says so, Mac offline on the tailnet, or a lead waits 30+ min on the owner (since mode 2 began) |

## Access summary

| From → to | Key | Restriction |
|---|---|---|
| server → workstation | `id_ed25519_workstation` | `from=<server>`, forced `workstation-ctl --ssh`, `restrict` |
| server → phone waker | `id_ed25519_workstation` | forced `python3 ~/wol.py`, `restrict` (optional `from=`) |
| server → Mac | `id_ed25519_mac` | forced `~/bin/mac-ctl`, `restrict` (optional `from=`) |
| owner's Mac/phone → workstation | the owner's own keys | none (the owner's own access) |
| owner → server | operator key | Tailscale only, sudo with password |

All hosts talk over Tailscale; nothing listens on a public interface.
