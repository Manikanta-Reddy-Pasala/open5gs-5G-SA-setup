#!/bin/bash
#
# Configure iptables inside the UPF container.
# Called by the UPF entrypoint (start-upf.sh) at container startup.
#
# Rules:
#   - MASQUERADE: UE traffic leaving ogstun goes out as UPF's IP
#   - FORWARD ACCEPT: allow all forwarded traffic (UE <-> internet)
#
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -I FORWARD 1 -j ACCEPT
