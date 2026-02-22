#!/usr/bin/env bash
set -euo pipefail

CFG="${1:-exp_100ms_200mbps_l4s.yaml}"
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

is_true() {
  case "${1:-}" in
    1|true|True|TRUE|yes|Yes|YES|on|On|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# ----------------------------
# output_dir resolution
# ----------------------------
CFG_ABS="$(realpath -m "$CFG")"
CFG_DIR="$(dirname "$CFG_ABS")"

OUT_DIR_RAW="$(yaml_get '.output_dir')"
if [[ -z "${OUT_DIR_RAW:-}" || "${OUT_DIR_RAW}" == "null" ]]; then
  echo "[!] YAML missing .output_dir (or empty)."
  exit 2
fi

if [[ "$OUT_DIR_RAW" != /* ]]; then
  OUT_DIR_RAW="$CFG_DIR/$OUT_DIR_RAW"
fi

OUT_DIR="$(realpath -m "$OUT_DIR_RAW")"
if [[ "$OUT_DIR" == "/" ]]; then
  echo "[!] Refusing OUT_DIR=/ (check .output_dir in YAML)"
  exit 2
fi

echo "[DBG] CFG=$CFG_ABS"
echo "[DBG] OUT_DIR=$OUT_DIR"

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

DELAY_MS="$(yaml_get '.mahimahi.delay_ms')"
: "${DELAY_MS:=0}"

QUEUE_ARGS="packets=${Q_PACKETS},target=${Q_TARGET},tupdate=${Q_TUPDATE},alpha=${Q_ALPHA},beta=${Q_BETA}"

: "${SECS:=30}"
: "${NUM_RUNS:=1}"
: "${BASE_PORT:=5300}"

mkdir -p "$OUT_DIR"
chown -R "$RUN_USER:$RUN_USER" "$OUT_DIR" 2>/dev/null || true

cleanup_all() {
  # kill any leftover mm-link sessions by name (fallback)
  pkill -9 -x mm-link 2>/dev/null || true
  pkill -9 -x mm-delay 2>/dev/null || true
  pkill -9 -x iperf3 2>/dev/null || true

  # extra: if we still have a mm_pid from the last run, kill its whole process group
  if [[ -n "${mm_pid:-}" ]]; then
    kill -9 -- "-$mm_pid" 2>/dev/null || true
  fi
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

# ----------------------------
# enable logic in function
# echoes: "<classic_enabled> <l4s_enabled>"
# ----------------------------
flow_flags() {
  local classic_enabled=0
  local l4s_enabled=0

  local c="" l=""
  c="$(yaml_get '.flows.classic.enabled')"
  l="$(yaml_get '.flows.l4s.enabled')"

  is_true "$c" && classic_enabled=1
  is_true "$l" && l4s_enabled=1

  echo "$classic_enabled $l4s_enabled"
}

# ----------------------------
# start iperf3 receivers OUTSIDE mahimahi
# echoes: "<pid1> <pid2>" (empty if not started)
# ----------------------------
start_iperf3_receivers() {
  local classic_enabled="$1"
  local l4s_enabled="$2"
  local port1="$3"
  local port2="$4"
  local rx1_log="$5"
  local rx2_log="$6"

  local srv1="" srv2=""

  if [[ "$classic_enabled" == "1" ]]; then
    : > "$rx1_log"
    iperf3 -s -p "$port1" -1 >>"$rx1_log" 2>&1 &
    srv1=$!
  fi

  if [[ "$l4s_enabled" == "1" ]]; then
    : > "$rx2_log"
    iperf3 -s -p "$port2" -1 >>"$rx2_log" 2>&1 &
    srv2=$!
  fi

  echo "$srv1 $srv2"
}

stop_iperf3_receivers() {
  local pid1="${1:-}"
  local pid2="${2:-}"
  [[ -n "$pid1" ]] && kill "$pid1" 2>/dev/null || true
  [[ -n "$pid2" ]] && kill "$pid2" 2>/dev/null || true
}

run_one() {
  local idx="$1"

  read -r classic_enabled l4s_enabled < <(flow_flags)
  if [[ "$classic_enabled" == "0" && "$l4s_enabled" == "0" ]]; then
    echo "[!] No flows enabled (.flows.classic.enabled / .flows.l4s.enabled)."
    exit 2
  fi

  local port1=$((BASE_PORT + 2*idx))
  local port2=$((BASE_PORT + 2*idx + 1))

  local out="$OUT_DIR/output_duo_${idx}.txt"
  local rx1_log="$OUT_DIR/iperf3_${idx}.classic.server.log"
  local tx1_log="$OUT_DIR/iperf3_${idx}.classic.client.log"
  local rx2_log="$OUT_DIR/iperf3_${idx}.l4s.server.log"
  local tx2_log="$OUT_DIR/iperf3_${idx}.l4s.client.log"
  local mm_log="$OUT_DIR/mm_${idx}.log"

  : > "$out"
  : > "$mm_log"
  : > "$tx1_log"
  : > "$tx2_log"

  chown "$RUN_USER:$RUN_USER" "$out" "$mm_log" "$tx1_log" "$tx2_log" 2>/dev/null || true

  # receivers OUTSIDE mahimahi
  local pid1="" pid2=""
  read -r pid1 pid2 < <(start_iperf3_receivers "$classic_enabled" "$l4s_enabled" "$port1" "$port2" "$rx1_log" "$rx2_log")

  sleep 1

  # mahimahi + clients INSIDE namespace (mm-link runs as RUN_USER)
  (
    sudo -u "$RUN_USER" env \
      SECS="$SECS" \
      DELAY_MS="$DELAY_MS" \
      PORT1="$port1" \
      PORT2="$port2" \
      CLASSIC_ENABLED="$classic_enabled" \
      L4S_ENABLED="$l4s_enabled" \
      TX1_LOG="$tx1_log" \
      TX2_LOG="$tx2_log" \
      QUEUE_TYPE="$QUEUE_TYPE" \
      QUEUE_ARGS="$QUEUE_ARGS" \
      TRACE_UP="$TRACE_UP" \
      TRACE_DOWN="$TRACE_DOWN" \
    mm-link \
      --uplink-queue="$QUEUE_TYPE" \
      --uplink-queue-args="$QUEUE_ARGS" \
      "$TRACE_UP" "$TRACE_DOWN" -- \
    mm-delay "$DELAY_MS" \
    bash -lc '
      set -euo pipefail

      : "${SECS:?missing SECS}"
      : "${PORT1:?missing PORT1}"
      : "${PORT2:?missing PORT2}"
      : "${CLASSIC_ENABLED:?missing CLASSIC_ENABLED}"
      : "${L4S_ENABLED:?missing L4S_ENABLED}"
      : "${TX1_LOG:?missing TX1_LOG}"
      : "${TX2_LOG:?missing TX2_LOG}"

      cli_pids=()

      if [[ "$CLASSIC_ENABLED" == "1" ]]; then
        (
          iperf3 -c 10.0.0.1 -p "$PORT1" -t "$SECS" \
            -C cubic -S 0x02
        ) >>"$TX1_LOG" 2>&1 &
        cli_pids+=($!)
      fi

      if [[ "$L4S_ENABLED" == "1" ]]; then
        (
          iperf3 -c 10.0.0.1 -p "$PORT2" -t "$SECS" \
            -C prague -S 0x01
        ) >>"$TX2_LOG" 2>&1 &
        cli_pids+=($!)
      fi

      for p in "${cli_pids[@]}"; do
        wait "$p"
      done
    '
  ) 2>&1 | tee "$out" | tee "$mm_log"

  stop_iperf3_receivers "$pid1" "$pid2"

  chown "$RUN_USER:$RUN_USER" "$out" "$mm_log" "$rx1_log" "$rx2_log" "$tx1_log" "$tx2_log" 2>/dev/null || true

  if [[ "$classic_enabled" == "1" ]]; then
    echo "Saved classic: SERVER=$rx1_log  CLIENT=$tx1_log"
  fi
  if [[ "$l4s_enabled" == "1" ]]; then
    echo "Saved l4s:     SERVER=$rx2_log  CLIENT=$tx2_log"
  fi
  echo "Saved mm-link wrapper: $mm_log"
}

start="$(next_index)"
for ((i=0; i<NUM_RUNS; i++)); do
  run_one $((start + i))
  sleep 1
  cleanup_all
  cleanup_mm_netns
  sleep 3
done

cleanup_all
cleanup_mm_netns
