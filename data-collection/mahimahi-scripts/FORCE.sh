#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[!] run as root: sudo $0"
  exit 1
fi

# -----------------------------
# Ensure Prague exists
# -----------------------------
avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
if ! grep -qw prague <<<"$avail"; then
  modprobe tcp_prague 2>/dev/null || true
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
fi
if ! grep -qw prague <<<"$avail"; then
  echo "[!] Prague not available. tcp_available_congestion_control: $avail"
  exit 2
fi

# -----------------------------
# Host (init netns): Prague + ECN
# New namespaces created after this inherit these network sysctls.
# -----------------------------
echo "[*] Host: setting default CC=prague and enabling ECN"
sysctl -w net.ipv4.tcp_congestion_control=prague >/dev/null
sysctl -w net.ipv4.tcp_ecn=2 >/dev/null

echo "    host tcp_congestion_control = $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "    host tcp_ecn               = $(sysctl -n net.ipv4.tcp_ecn)"

# -----------------------------
# Existing namespaces: force Prague + ECN everywhere
# -----------------------------
ns_list="$(ip netns list | awk '{print $1}' || true)"
if [[ -n "${ns_list// }" ]]; then
  echo "[*] Forcing CC=prague and ECN=2 inside existing namespaces:"
  while read -r ns; do
    [[ -z "$ns" ]] && continue
    echo "    - $ns"
    ip netns exec "$ns" sysctl -w net.ipv4.tcp_congestion_control=prague >/dev/null || true
    ip netns exec "$ns" sysctl -w net.ipv4.tcp_ecn=2 >/dev/null || true

    cc="$(ip netns exec "$ns" cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)"
    ecn="$(ip netns exec "$ns" cat /proc/sys/net/ipv4/tcp_ecn 2>/dev/null || true)"
    echo "      tcp_congestion_control = $cc"
    echo "      tcp_ecn               = $ecn"
  done <<<"$ns_list"
else
  echo "[*] No existing namespaces found. New ones created after this will inherit prague + ECN."
fi

echo "[+] Done."
uname -r
