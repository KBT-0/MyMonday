# Phone client: leads from a phone terminal

The phone is a viewer and keyboard for the same Claude Code leads the assistant drives. Nothing runs on
the phone; closing the app never stops a lead.

## Setup

1. Tailscale app on the phone, logged in to the tailnet.
2. A terminal app with mosh support. Termius (iOS/Android) works: new host = the workstation's tailnet
   IP (`WORKSTATION_HOST`), user = `WORKSTATION_USER`, *Use Mosh* on, a key you generated in the app.
   Blink Shell (iOS) or Termux (Android: `pkg install mosh openssh`) work too.
3. Put the phone's PUBLIC key on the workstation (`~/.ssh/authorized_keys` of the owner, unrestricted:
   this is the owner's own access). Termius's "Export key to host" needs a working login first, so
   paste the public key through an existing session, or ask the assistant to append it (it accepts only
   `ssh-ed25519 ...` public key lines and reports the fingerprint). That the assistant can do this at all
   is because its key reaches sessions running as you: it is effectively a shell as the owner
   (docs/remote-workstation.md, Security model).
4. On the workstation: `mosh` installed (`pacman -S mosh` on Arch), so `mosh-server` exists.

## Use

| Keys / command | Does |
|---|---|
| `lead-attach` | list leads and helper sessions |
| `lead-attach <lead>` | attach to that lead in a private viewer session (your own window choice) |
| `Ctrl-b w` | pick another lead from the list |
| `Ctrl-b n` / `Ctrl-b p` | next / previous lead |
| `Ctrl-b d` | detach (the lead keeps running) |

Viewer sessions (`view-*`) are grouped with the `leads` session: several devices can watch different
leads at the same time, and a viewer disappears when you detach. The assistant sees your typing as
screen changes it did not cause and does not type over you.

Approvals and short answers are faster in Telegram: CCGram gives each lead its own topic with one
button per menu option.
