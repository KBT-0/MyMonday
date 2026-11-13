# Phone waker: Wake-on-LAN relay at the workstation's home

A Wake-on-LAN magic packet is a layer-2 broadcast: it cannot cross the internet or a Tailscale tunnel.
Something already awake on the workstation's LAN has to send it. Here that is an old Android phone,
always on charge, running Termux sshd on the tailnet. The server's `monster-wake` connects to it and
the phone's forced command sends the packet.

```
server: monster-wake ──ssh (tailnet, key only)──▶ phone :8022 ── forced command wol.py ──▶ LAN broadcast ──▶ workstation NIC
```

`monster-wake` (server/monster/monster-wake) tries `monster-phone1`, then `monster-phone2`, and succeeds
when the reply contains `wake sent`. A second phone is optional redundancy.

## What you need

- An Android phone that stays on Wi-Fi of the same LAN as the workstation, on a charger.
- The workstation's wired NIC MAC address, and Wake-on-LAN enabled in its BIOS/UEFI and OS
  (`ethtool <nic> | grep Wake-on` shows `g`; NetworkManager: `nmcli c modify <conn> 802-3-ethernet.wake-on-lan magic`).
  Wi-Fi WoL is unreliable; use Ethernet.
- The server's workstation key (printed by `bootstrap.sh <admin> monster`, `~/.ssh/id_ed25519_monster.pub`
  of the agent user) and the server's tailnet IP (`SERVER_IP` in local.env).

## Setup

1. **Termux** from F-Droid or its GitHub releases (the Play Store build is outdated), and **Termux:Boot**
   from the same source. Open Termux:Boot once so Android registers it.
2. **Tailscale** Android app: log in to your tailnet, enable *Always-on VPN* (Android Settings > Network
   > VPN > Tailscale > Always-on) so it reconnects after reboots. Note the phone's tailnet IP: it is
   `MONSTER_PHONE1` in local.env.
3. **Battery**: Settings > Apps > Termux, Termux:Boot and Tailscale > Battery > *Unrestricted* / no
   optimisation. On MIUI/HyperOS also enable *Autostart* for all three and lock Termux in the recents
   screen. Without this Android kills sshd within hours.
4. In Termux, copy this folder over (e.g. `git clone` the repo, or `termux-setup-storage` and a file
   copy), then:

   ```sh
   sh setup.sh aa:bb:cc:dd:ee:ff 192.168.1.255 'ssh-ed25519 AAAA... monday@monday' 100.x.y.z
   ```

   It installs `openssh` and `python`, puts `wol.py` and the boot script in place, writes
   `~/.config/wol.env`, adds the key as `from="<server>",command="python3 ~/wol.py",restrict` and turns
   password login off. `termux-wake-lock` in the boot script keeps the CPU awake.
5. From the server, as the agent user: `monster-wake` → `wake sent via monster-phone1`.
   Then power the workstation off and test a real wake.

## Security

The phone accepts the server key only from the server's tailnet address and only into `wol.py`, which
ignores the requested command: a compromised server can wake the workstation and nothing else. Your
own key for maintenance is a separate, unrestricted line you add by hand. Keep the phone's Android
updates on; it holds no secrets beyond its sshd host key.

## Notes

- The live phone's `wol.py` is not readable through its forced command, so the version here is a
  reference implementation of the same interface (silent SSH call, `wake sent` line). Any WoL tool works
  as long as the forced command prints `wake sent`.
- `pkg install wakeonlan` (if available in your Termux repo) is an alternative to the Python sender.
