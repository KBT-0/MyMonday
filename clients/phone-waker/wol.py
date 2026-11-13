#!/data/data/com.termux/files/usr/bin/python3
"""wol.py: send a Wake-on-LAN magic packet to the workstation. Runs on the waker phone in Termux as the
forced command of the server's key (authorized_keys: command="python3 ~/wol.py",restrict ...), so the
server's `monster-wake` connects without a command and greps the "wake sent" line.

Settings in ~/.config/wol.env (KEY=VALUE):
  WOL_MAC=aa:bb:cc:dd:ee:ff        the workstation's wired NIC (ip link / Settings)
  WOL_BROADCAST=192.168.1.255      LAN broadcast address (default 255.255.255.255)
  WOL_NAME=Monster                 name used in the reply
Whatever command the client asked for (SSH_ORIGINAL_COMMAND) is ignored.
Reference implementation of the waker interface; any tool that prints "wake sent" works.
"""
import os
import re
import socket
import sys

conf = {"WOL_BROADCAST": "255.255.255.255", "WOL_NAME": "Monster", "WOL_PORT": "9"}
try:
    for line in open(os.path.expanduser("~/.config/wol.env")):
        k, sep, v = line.strip().partition("=")
        if sep and not k.startswith("#"):
            conf[k.strip()] = v.strip().strip('"')
except OSError:
    pass

mac = conf.get("WOL_MAC", "")
if not re.fullmatch(r"([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}", mac):
    print("no valid WOL_MAC in ~/.config/wol.env")
    sys.exit(1)
packet = b"\xff" * 6 + bytes.fromhex(re.sub(r"[:-]", "", mac)) * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for _ in range(3):  # UDP may drop one; three cost nothing
    s.sendto(packet, (conf["WOL_BROADCAST"], int(conf["WOL_PORT"])))
print(f"wake sent to {conf['WOL_NAME']}")
