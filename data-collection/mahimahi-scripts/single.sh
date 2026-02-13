#!/usr/bin/env bash
set -euo pipefail

CFG="${1:-exp_100ms_200mbps_classic.yaml}"
RUN_USER="${SUDO_USER:-$(id -un)}"

if [[ $EUID -ne 0 ]]; then
  echo "[!] Must run as root (use: sudo $0 $CFG)"
  exit 1
fi

yaml_get() {
  local key="$1"
  if command -v yq >/dev/null 2>&1; then
    local v
    v="$(yq -r "$key // \"\"" "$CFG" 2>/dev/null || true)"
    [[ "$v" == "null" ]] && v=""
    echo "$v"
  else
    python3 - "$CFG" "$key" <<'PY'
import sys, yaml
cfg, key = sys.argv[1], sys.argv[2]
with open(cfg) as f:
    d = yaml.safe_load(f) or {}
cur = d
ok = True
for p in key.lstrip(".").split("."):
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    else:
        ok = False
        break
if not ok or cur is None:
    print("")
else:
    print(cur)
PY
  fi
}

OUT_DIR="$(realpath -m "$(yaml_get '.output_dir')")"
SECS="$(yaml_get '.secs_per_run')"
NUM_RUNS="$(yaml_get '.num_runs')"

TRACE_UP="$(yaml_get '.traces.up')"
TRACE_DOWN="$(yaml_get '.traces.down')"

QUEUE_TYPE="$(yaml_get '.queue.type')"
Q_PACKETS="$(yaml_get '.queue.packets')"
Q_TARGET="$(yaml_get '.queue.target')"
Q_TUPDATE="$(yaml_get '.queue.tupdate')"
Q_ALPHA="$(yaml_get '.queue.alpha')"
Q_BETA="$(yaml_get '.queue.beta')"

BASE_PORT="$(yaml_get '.flows.base_port')"

SCREAM_DIR="$(yaml_get '.paths.scream_dir')"
SCREAM_TX="$SCREAM_DIR/bin/scream_bw_test_tx"
SCREAM_RX="$SCREAM_DIR/bin/scream_bw_test_rx"

CLASSIC_TOS="$(yaml_get '.flows.classic.tos')"   # e.g. 2 (ECT0)
L4S_TOS="$(yaml_get '.flows.l4s.tos')"           # e.g. 1 (ECT1)

DELAY_MS="$(yaml_get '.mahimahi.delay_ms')"
: "${DELAY_MS:=0}"

QUEUE_ARGS="packets=${Q_PACKETS},target=${Q_TARGET},tupdate=${Q_TUPDATE},alpha=${Q_ALPHA},beta=${Q_BETA}"

: "${SECS:=30}"
: "${NUM_RUNS:=1}"
: "${BASE_PORT:=5300}"

mkdir -p "$OUT_DIR"
chown -R "$RUN_USER:$RUN_USER" "$OUT_DIR" 2>/dev/null || true

if [[ -z "${SCREAM_DIR:-}" ]]; then
  echo "[!] Missing paths.scream_dir in YAML"
  exit 2
fi

SCREAM_DIR="$(realpath -m "$SCREAM_DIR")"
SCREAM_TX="$(realpath -m "$SCREAM_TX")"
SCREAM_RX="$(realpath -m "$SCREAM_RX")"

if [[ ! -x "$SCREAM_TX" || ! -x "$SCREAM_RX" ]]; then
  echo "[!] SCReAM binaries not found/executable:"
  echo "    TX: $SCREAM_TX"
  echo "    RX: $SCREAM_RX"
  exit 2
fi

cleanup_all() {
  pkill -9 -x mm-link 2>/dev/null || true
  pkill -9 -x mm-delay 2>/dev/null || true
  pkill -9 -x scream_bw_test_tx 2>/dev/null || true
  pkill -9 -x scream_bw_test_rx 2>/dev/null || true
}

cleanup_mm_netns() {
  command -v ip >/dev/null 2>&1 || return 0
  while read -r ns _; do
    [[ -z "${ns:-}" ]] && continue
    if [[ "$ns" =~ ^mm- ]] || [[ "$ns" =~ ^mahimahi ]] || [[ "$ns" =~ ^mml- ]]; then
      ip netns del "$ns" 2>/dev/null || true
    fi
  done < <(ip netns list 2>/dev/null || true)
}

next_index() {
  local max=-1
  shopt -s nullglob
  for f in "$OUT_DIR"/output_duo_*.txt; do
    local n="${f##*_}"
    n="${n%.txt}"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > max )) && max="$n"
  done
  shopt -u nullglob
  echo $((max + 1))
}

run_one() {
  local idx="$1"

  local classic_enabled=0
  local l4s_enabled=0

  if [[ -n "${CLASSIC_TOS:-}" && "${CLASSIC_TOS:-}" != "null" ]]; then classic_enabled=1; fi
  if [[ -n "${L4S_TOS:-}" && "${L4S_TOS:-}" != "null" ]]; then l4s_enabled=1; fi

  if [[ $classic_enabled -eq 0 && $l4s_enabled -eq 0 ]]; then
    echo "[!] No flows enabled."
    exit 2
  fi

  local port1=$((BASE_PORT + 2*idx))
  local port2=$((BASE_PORT + 2*idx + 1))
  local out="$OUT_DIR/output_duo_${idx}.txt"

  local rx1_log="$OUT_DIR/scream_${idx}.classic.rx.log"
  local tx1_log="$OUT_DIR/scream_${idx}.classic.tx.log"
  local rx2_log="$OUT_DIR/scream_${idx}.l4s.rx.log"
  local tx2_log="$OUT_DIR/scream_${idx}.l4s.tx.log"

  cleanup_all
  cleanup_mm_netns
  sleep 1

  local rx1="" rx2=""
  if [[ $classic_enabled -eq 1 ]]; then
    : > "$rx1_log"
    "$SCREAM_RX" 10.0.0.2 "$port1" >>"$rx1_log" 2>&1 &
    rx1=$!
  fi
  if [[ $l4s_enabled -eq 1 ]]; then
    : > "$rx2_log"
    "$SCREAM_RX" 10.0.0.2 "$port2" >>"$rx2_log" 2>&1 &
    rx2=$!
  fi

  if [[ $classic_enabled -eq 1 ]]; then : > "$tx1_log"; fi
  if [[ $l4s_enabled -eq 1 ]]; then : > "$tx2_log"; fi
  chown "$RUN_USER:$RUN_USER" "$tx1_log" "$tx2_log" 2>/dev/null || true

  sleep 1
  (
    sudo -u "$RUN_USER" env \
      SCREAM_TX="$SCREAM_TX" \
      CLASSIC_TOS="${CLASSIC_TOS:-}" \
      L4S_TOS="${L4S_TOS:-}" \
      SECS="$SECS" \
      PORT1="$port1" \
      PORT2="$port2" \
      CLASSIC_ENABLED="$classic_enabled" \
      L4S_ENABLED="$l4s_enabled" \
      TX1_LOG="$tx1_log" \
      TX2_LOG="$tx2_log" \
      mm-link \
        --uplink-queue="$QUEUE_TYPE" \
        --uplink-queue-args="$QUEUE_ARGS" \
        "$TRACE_UP" "$TRACE_DOWN" -- \
        mm-delay "$DELAY_MS" \
      bash -lc '
    set -euo pipefail

    echo "[DBG] whoami=$(whoami) uid=$(id -u) euid=$EUID"
    echo "[DBG] PATH=$PATH"
    echo "[DBG] SUDO_USER=${SUDO_USER:-} USER=${USER:-}"

    SUDO=/usr/bin/sudo
    IPTABLES=/usr/sbin/iptables
    CHAIN=MZ_SCREAM_MARK

    must_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

    ipt() {
      echo "[DBG] ipt $*"
      # run and show stderr if it fails
      if ! out=$("$SUDO" -n "$IPTABLES" -w "$@" 2>&1); then
        echo "[ERR] iptables failed: $out" >&2
        return 1
      fi
      return 0
    }

    echo "[DBG] checking sudo -n true"
    # Verify iptables is allowed
    if ! "$SUDO" -n "$IPTABLES" -L >/dev/null 2>&1; then
      echo "[ERR] sudo iptables not permitted inside mahimahi"
      exit 51
    fi

    echo "[DBG] sudo OK"

    echo "[DBG] iptables version:"
    "$SUDO" -n "$IPTABLES" -V 2>&1 || true

    echo "[DBG] create/flush chain"
    "$SUDO" -n "$IPTABLES" -w -t mangle -N "$CHAIN" 2>/dev/null || true
    ipt -t mangle -F "$CHAIN"

    echo "[DBG] hook chain to OUTPUT if missing"
    if ! "$SUDO" -n "$IPTABLES" -w -t mangle -C OUTPUT -j "$CHAIN" 2>/dev/null; then
      ipt -t mangle -A OUTPUT -j "$CHAIN"
    fi

    if [[ "${CLASSIC_ENABLED}" == "1" ]]; then
      must_int "${CLASSIC_TOS}" || { echo "[ERR] Bad CLASSIC_TOS=${CLASSIC_TOS}" >&2; exit 2; }
      tos_hex=$(printf "0x%02x" "${CLASSIC_TOS}")
      echo "[DBG] classic mark dport=${PORT1} tos=${tos_hex}"
      ipt -t mangle -A "$CHAIN" -p udp --dport "${PORT1}" -j TOS --set-tos "${tos_hex}"
    fi

    if [[ "${L4S_ENABLED}" == "1" ]]; then
      must_int "${L4S_TOS}" || { echo "[ERR] Bad L4S_TOS=${L4S_TOS}" >&2; exit 2; }
      tos_hex=$(printf "0x%02x" "${L4S_TOS}")
      echo "[DBG] l4s mark dport=${PORT2} tos=${tos_hex}"
      ipt -t mangle -A "$CHAIN" -p udp --dport "${PORT2}" -j TOS --set-tos "${tos_hex}"
    fi

    echo "[DBG] dump rules"
    "$SUDO" -n "$IPTABLES" -w -t mangle -S OUTPUT 2>&1 || true
    "$SUDO" -n "$IPTABLES" -w -t mangle -S "$CHAIN" 2>&1 || true

    echo "[DBG] launching scream"
    pids=()
    if [[ "${CLASSIC_ENABLED}" == "1" ]]; then
      ( "${SCREAM_TX}" -time "${SECS}" 10.0.0.1 "${PORT1}" >>"${TX1_LOG}" 2>&1 ) &
      pids+=($!)
    fi
    if [[ "${L4S_ENABLED}" == "1" ]]; then
      ( "${SCREAM_TX}" -time "${SECS}" 10.0.0.1 "${PORT2}" >>"${TX2_LOG}" 2>&1 ) &
      pids+=($!)
    fi

    for p in "${pids[@]}"; do wait "$p"; done'
  ) 2>&1 | tee "$out"

  [[ -n "${rx1:-}" ]] && kill "$rx1" 2>/dev/null || true
  [[ -n "${rx2:-}" ]] && kill "$rx2" 2>/dev/null || true

  chown "$RUN_USER:$RUN_USER" "$out" "$rx1_log" "$rx2_log" "$tx1_log" "$tx2_log" 2>/dev/null || true
  cleanup_mm_netns

  if [[ $classic_enabled -eq 1 ]]; then
    echo "Saved classic: RX=$rx1_log  TX=$tx1_log"
  fi
  if [[ $l4s_enabled -eq 1 ]]; then
    echo "Saved l4s:     RX=$rx2_log  TX=$tx2_log"
  fi
}

start="$(next_index)"
for ((i=0; i<NUM_RUNS; i++)); do
  run_one $((start + i))
  sleep 3
done

cleanup_all
cleanup_mm_netns
