#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; echo "ERR rc=$rc at line $LINENO: $BASH_COMMAND" >&2; exit $rc' ERR

# ============================================================
# Config loader (PyYAML)
# ============================================================
CFG=${1:-exp.yaml}
if [[ ! -f "$CFG" ]]; then
  echo "Error: config file not found: $CFG"
  exit 1
fi

yget() {
  local expr="$1"
  python3 - "$CFG" "$expr" <<'PY'
import sys
cfg_path = sys.argv[1]
expr = sys.argv[2]
try:
  import yaml
except Exception:
  print("PY_YAML_IMPORT_ERROR", file=sys.stderr)
  sys.exit(2)

with open(cfg_path, "r") as f:
  data = yaml.safe_load(f) or {}

cur = data
for part in expr.split("."):
  if not isinstance(cur, dict) or part not in cur:
    print("", end="")
    sys.exit(0)
  cur = cur[part]

if cur is None:
  print("", end="")
elif isinstance(cur, bool):
  print("true" if cur else "false", end="")
else:
  print(str(cur), end="")
PY
}

# Returns "true" if the YAML key exists (even if its value is null/empty), else "false"
yhas() {
  local expr="$1"
  python3 - "$CFG" "$expr" <<'PY'
import sys, yaml
cfg_path = sys.argv[1]
expr = sys.argv[2]
with open(cfg_path, "r") as f:
  data = yaml.safe_load(f) or {}
cur = data
for part in expr.split("."):
  if not isinstance(cur, dict) or part not in cur:
    print("false", end="")
    sys.exit(0)
  cur = cur[part]
print("true", end="")
PY
}

# ============================================================
# Read config
# ============================================================
SECS_LOG="$(yget runs.secs_per_run)"; SECS_LOG="${SECS_LOG:-30}"
NUM_RUNS="$(yget runs.num_runs)"; NUM_RUNS="${NUM_RUNS:-1}"

SETUP_SEC="$(yget runs.setup_sec)"; SETUP_SEC="${SETUP_SEC:-3}"
WARMUP_SEC="$(yget runs.warmup_sec)"; WARMUP_SEC="${WARMUP_SEC:-0}"
COOLDOWN_SEC="$(yget runs.cooldown_sec)"; COOLDOWN_SEC="${COOLDOWN_SEC:-3}"

NS_S="$(yget net.ns_s)"; NS_S="${NS_S:-ns_s}"
NS_R="$(yget net.ns_r)"; NS_R="${NS_R:-ns_r}"
VETH_DEV="$(yget net.veth_dev)"; VETH_DEV="${VETH_DEV:-veth-s}"
DST_IP="$(yget net.dst_ip)"; DST_IP="${DST_IP:-172.20.1.2}"

PORT_CLASSIC="$(yget net.port_classic)"; PORT_CLASSIC="${PORT_CLASSIC:-8080}"
PORT_L4S="$(yget net.port_l4s)"; PORT_L4S="${PORT_L4S:-8081}"

RTT_MS="$(yget net.rtt_ms)"; RTT_MS="${RTT_MS:-0}"

TC_BIN="$(yget paths.tc_bin)"; TC_BIN="${TC_BIN:-tc}"
SCREAM_DIR="$(yget paths.scream_dir)"; SCREAM_DIR="${SCREAM_DIR:-}"

RATE="$(yget qdisc.rate)"; RATE="${RATE:-12mbit}"
BURST="$(yget qdisc.burst)"; BURST="${BURST:-1k}"
TARGET="$(yget qdisc.target)"; TARGET="${TARGET:-15ms}"
TUPDATE="$(yget qdisc.tupdate)"; TUPDATE="${TUPDATE:-16ms}"
LIMIT="$(yget qdisc.limit)"; LIMIT="${LIMIT:-250}"
ALPHA="$(yget qdisc.alpha)"; ALPHA="${ALPHA:-0.16}"
BETA="$(yget qdisc.beta)"; BETA="${BETA:-3.2}"

LOG_DIR="$(yget logging.dir)"; LOG_DIR="${LOG_DIR:-./tmp}"
QDISC_SAMPLE_SEC="$(yget logging.qdisc_sample_sec)"; QDISC_SAMPLE_SEC="${QDISC_SAMPLE_SEC:-0.016}"

# Flows are presence-only
CLASSIC_ENABLED="$(yhas flows.classic)"
L4S_ENABLED="$(yhas flows.l4s)"

CLASSIC_TOS="$(yget flows.classic.tos)"; CLASSIC_TOS="${CLASSIC_TOS:-2}"
L4S_TOS="$(yget flows.l4s.tos)";         L4S_TOS="${L4S_TOS:-1}"

if [[ "$CLASSIC_ENABLED" != "true" && "$L4S_ENABLED" != "true" ]]; then
  echo "[!] No flows enabled: YAML has neither flows.classic nor flows.l4s"
  exit 2
fi

SECS_FLOW=$(( WARMUP_SEC + SECS_LOG ))
LOG_TIME=$(( SECS_LOG ))

LOG_DIR="$(realpath -m "$LOG_DIR")"
sudo mkdir -p "$LOG_DIR"
sudo chmod 777 "$LOG_DIR"

if [[ -z "$SCREAM_DIR" ]]; then
  echo "[!] paths.scream_dir is empty. Set it to your scream repo root (contains bin/)."
  exit 2
fi
SCREAM_DIR="$(realpath -m "$SCREAM_DIR")"

SCREAM_TX="$SCREAM_DIR/bin/scream_bw_test_tx"
SCREAM_RX="$SCREAM_DIR/bin/scream_bw_test_rx"

if [[ ! -x "$SCREAM_TX" || ! -x "$SCREAM_RX" ]]; then
  echo "[!] SCReAM binaries not found/executable:"
  echo "    TX: $SCREAM_TX"
  echo "    RX: $SCREAM_RX"
  exit 2
fi

# ============================================================
# Helpers
# ============================================================
next_free_idx() {
  local i=0
  while [[ -e "$LOG_DIR/qdisc_${i}.log" ]]; do
    ((++i))
  done
  echo "$i"
}

cleanup_run() {
  sudo ip netns exec "$NS_S" pkill -9 scream_bw_test_tx 2>/dev/null || true
  sudo ip netns exec "$NS_R" pkill -9 scream_bw_test_rx 2>/dev/null || true
}

# ============================================================
# Create namespaces + attach veth pair
# ============================================================
reset_namespaces_fresh() {
  cleanup_run

  sudo ip netns del "$NS_S" 2>/dev/null || true
  sudo ip netns del "$NS_R" 2>/dev/null || true

  sudo ip link del veth-s 2>/dev/null || true
  sudo ip link del veth-r 2>/dev/null || true

  sudo ip netns add "$NS_S"
  sudo ip netns add "$NS_R"

  sudo ip link add veth-s type veth peer name veth-r
  sudo ip link set veth-s netns "$NS_S"
  sudo ip link set veth-r netns "$NS_R"

  sudo ip netns exec "$NS_S" ip addr add 172.20.1.1/30 dev veth-s
  sudo ip netns exec "$NS_R" ip addr add 172.20.1.2/30 dev veth-r

  sudo ip netns exec "$NS_S" ip link set lo up
  sudo ip netns exec "$NS_R" ip link set lo up
  sudo ip netns exec "$NS_S" ip link set veth-s up
  sudo ip netns exec "$NS_R" ip link set veth-r up
}

# ============================================================
# Apply RTT delay via IFB + netem (ingress)
# ============================================================
apply_rtt_netem_delay() {
  local rtt_ms="${RTT_MS:-0}"
  if (( rtt_ms <= 0 )); then
    return 0
  fi

  local fwd_ms=$(( rtt_ms / 2 ))
  local rev_ms=$(( rtt_ms - fwd_ms ))

  sudo modprobe ifb 2>/dev/null || true

  _add_ingress_delay() {
    local ns="$1"
    local in_dev="$2"
    local ifb_dev="$3"
    local delay_ms="$4"

    sudo ip netns exec "$ns" ip link add "$ifb_dev" type ifb 2>/dev/null || true
    sudo ip netns exec "$ns" ip link set "$ifb_dev" up

    sudo ip netns exec "$ns" "$TC_BIN" qdisc del dev "$in_dev" ingress 2>/dev/null || true
    sudo ip netns exec "$ns" "$TC_BIN" qdisc del dev "$ifb_dev" root 2>/dev/null || true
    sudo ip netns exec "$ns" "$TC_BIN" qdisc add dev "$in_dev" handle ffff: ingress

    sudo ip netns exec "$ns" "$TC_BIN" filter add dev "$in_dev" parent ffff: protocol ip u32 \
      match u32 0 0 action mirred egress redirect dev "$ifb_dev"

    sudo ip netns exec "$ns" "$TC_BIN" qdisc add dev "$ifb_dev" root netem delay "${delay_ms}ms"
  }

  _add_ingress_delay "$NS_R" "veth-r" "ifb-fwd" "$fwd_ms"
  _add_ingress_delay "$NS_S" "veth-s" "ifb-rev" "$rev_ms"
}

# ============================================================
# Apply DualPI2 qdisc (ALWAYS)
# ============================================================
apply_dualpi2_qdisc() {
  sudo ip netns exec "$NS_S" "$TC_BIN" qdisc del dev "$VETH_DEV" root 2>/dev/null || true
  sudo ip netns exec "$NS_S" "$TC_BIN" qdisc add dev "$VETH_DEV" root handle 1: htb default 10
  sudo ip netns exec "$NS_S" "$TC_BIN" class add dev "$VETH_DEV" parent 1: classid 1:10 htb \
    rate "$RATE" ceil "$RATE" burst "$BURST"
  sudo ip netns exec "$NS_S" "$TC_BIN" qdisc add dev "$VETH_DEV" parent 1:10 handle 2: dualpi2 \
    target "$TARGET" tupdate "$TUPDATE" limit "$LIMIT" alpha "$ALPHA" beta "$BETA"
}

# ============================================================
# Qdisc Logger
# ============================================================
start_qdisc_logger() {
  local idx="$1"
  local qdisc_log="$LOG_DIR/qdisc_${idx}.log"
  : > "$qdisc_log"

  local dt_ns start end
  dt_ns="$(awk -v dt="$QDISC_SAMPLE_SEC" 'BEGIN{printf "%.0f\n", dt*1e9}')"

  start="$("./nsclock")"
  end=$(( start + SECS_LOG*1000000000 ))

  {
    echo "RUN_START_TS_NS $start"
    echo "DT_NS $dt_ns"
  } >> "$qdisc_log"

  (
    timeout "${LOG_TIME}s" \
      ip netns exec "$NS_S" env \
        VETH_DEV="$VETH_DEV" \
        QDISC_LOG="$qdisc_log" \
        END_NS="$end" \
        DT_NS="$dt_ns" \
        TC_BIN="$TC_BIN" \
        NSCLOCK="$(pwd)/nsclock" \
      bash -Eeuo pipefail -c '
        : "${VETH_DEV:?}" "${QDISC_LOG:?}" "${END_NS:?}" "${DT_NS:?}" "${TC_BIN:?}" "${NSCLOCK:?}"

        i=1
        START_NS=$("$NSCLOCK")
        next=$((START_NS + DT_NS))

        while :; do
          now=$("$NSCLOCK")
          if (( now >= END_NS )); then break; fi

          t0=$("$NSCLOCK")
          out=$("$TC_BIN" -s qdisc show dev "$VETH_DEV" parent 1:10)
          t1=$("$NSCLOCK")

          tick_ns=$("$NSCLOCK")

          {
            echo "TICK_NS $tick_ns"
            echo "TC_DUR_NS $((t1 - t0))"
            echo "NEXT $next"
            echo "PLACEMENT i=$i"
            echo "$out"
            echo
          } >> "$QDISC_LOG"

          now=$("$NSCLOCK")
          diff_ns=$(( next - now ))
          if (( diff_ns > 0 )); then
             sec=$((diff_ns / 1000000000))
             nsec=$((diff_ns % 1000000000))
             sleep "$(printf "%d.%09d" "$sec" "$nsec")"
          fi

          i=$((i+1))
          next=$((START_NS + i*DT_NS))
        done

        echo "RUN_END_TS_NS $("$NSCLOCK")" >> "$QDISC_LOG"
      '
  ) &

  echo $!
}

# apply_ecn_tos_marks_in_sender_ns() {
#   # Mark ECN/TOS per UDP destination port for SCReAM flows.
#   # Must run inside NS_S because packets originate there.
#   sudo ip netns exec "$NS_S" iptables -t mangle -F OUTPUT 2>/dev/null || true

#   if [[ "$CLASSIC_ENABLED" == "true" ]]; then
#     local tos_hex
#     tos_hex="$(printf '0x%02x' "$CLASSIC_TOS")"
#     sudo ip netns exec "$NS_S" iptables -t mangle -A OUTPUT \
#       -p udp --dport "$PORT_CLASSIC" -j TOS --set-tos "$tos_hex"
#   fi

#   if [[ "$L4S_ENABLED" == "true" ]]; then
#     local tos_hex
#     tos_hex="$(printf '0x%02x' "$L4S_TOS")"
#     sudo ip netns exec "$NS_S" iptables -t mangle -A OUTPUT \
#       -p udp --dport "$PORT_L4S" -j TOS --set-tos "$tos_hex"
#   fi
# }

# ============================================================
# Run enabled SCReAM flows concurrently (LOG OUTPUT)
# ============================================================
run_both_flows() {
  local idx="$1"

  local rx_classic="" tx_classic=""
  local rx_l4s="" tx_l4s=""

  local classic_rx_log="$LOG_DIR/scream_${idx}.classic.rx.log"
  local classic_tx_log="$LOG_DIR/scream_${idx}.classic.tx.log"
  local l4s_rx_log="$LOG_DIR/scream_${idx}.l4s.rx.log"
  local l4s_tx_log="$LOG_DIR/scream_${idx}.l4s.tx.log"

  # our namespace setup addresses
  local SENDER_IP="172.20.1.1"
  local RECV_IP="172.20.1.2"

  [[ "$CLASSIC_ENABLED" == "true" ]] && { : > "$classic_rx_log"; : > "$classic_tx_log"; }
  [[ "$L4S_ENABLED"     == "true" ]] && { : > "$l4s_rx_log";     : > "$l4s_tx_log";     }

  # Start both receivers
  if [[ "$CLASSIC_ENABLED" == "true" ]]; then
    sudo ip netns exec "$NS_R" stdbuf -oL -eL "$SCREAM_RX" "$SENDER_IP" "$PORT_CLASSIC" \
      >>"$classic_rx_log" 2>&1 &
    rx_classic=$!
  fi

  if [[ "$L4S_ENABLED" == "true" ]]; then
    sudo ip netns exec "$NS_R" stdbuf -oL -eL "$SCREAM_RX" "$SENDER_IP" "$PORT_L4S" \
      >>"$l4s_rx_log" 2>&1 &
    rx_l4s=$!
  fi

  # Start both senders at the same time after 1 sec
  sleep 1

  if [[ "$CLASSIC_ENABLED" == "true" ]]; then
    sudo ip netns exec "$NS_S" stdbuf -oL -eL "$SCREAM_TX" -time "$SECS_FLOW" "$RECV_IP" "$PORT_CLASSIC" \
      >>"$classic_tx_log" 2>&1 &
    tx_classic=$!
  fi

  if [[ "$L4S_ENABLED" == "true" ]]; then
    sudo ip netns exec "$NS_S" stdbuf -oL -eL "$SCREAM_TX" -ect 1 -time "$SECS_FLOW" "$RECV_IP" "$PORT_L4S" \
      >>"$l4s_tx_log" 2>&1 &
    tx_l4s=$!
  fi

  [[ -n "$tx_classic" ]] && wait "$tx_classic" 2>/dev/null || true
  [[ -n "$tx_l4s" ]] && wait "$tx_l4s" 2>/dev/null || true

  [[ -n "$rx_classic" ]] && sudo kill "$rx_classic" >/dev/null 2>&1 || true
  [[ -n "$rx_l4s" ]] && sudo kill "$rx_l4s" >/dev/null 2>&1 || true

  cleanup_run

  [[ "$CLASSIC_ENABLED" == "true" ]] && echo "SCReAM classic logs: $classic_rx_log  $classic_tx_log"
  [[ "$L4S_ENABLED" == "true" ]] && echo "SCReAM l4s logs:     $l4s_rx_log  $l4s_tx_log"
}

# ============================================================
# One run
# ============================================================
run_once() {
  local idx="$1"
  local qdisc_log="$LOG_DIR/qdisc_${idx}.log"

  reset_namespaces_fresh
  apply_rtt_netem_delay
  apply_dualpi2_qdisc
  # apply_ecn_tos_marks_in_sender_ns

  sleep 1
  run_both_flows "$idx" &
  local EXP_PID=$!

  if (( WARMUP_SEC > 0 )); then
    sleep "$WARMUP_SEC"
  fi

  # sleep 1
  local QDISC_PID
  QDISC_PID="$(start_qdisc_logger "$idx")"

  # sleep "$SETUP_SEC"

  wait "$QDISC_PID" 2>/dev/null || true

  cleanup_run
  wait "$EXP_PID" 2>/dev/null || true

  echo "Saved: $qdisc_log"
}

# ============================================================
# Main
# ============================================================
echo "Using config: $CFG"
echo "LOG_DIR=$LOG_DIR"
echo "SCREAM_DIR=$SCREAM_DIR"
echo "SCREAM_TX=$SCREAM_TX"
echo "SCREAM_RX=$SCREAM_RX"
echo "CLASSIC_ENABLED=$CLASSIC_ENABLED  PORT_CLASSIC=$PORT_CLASSIC"
echo "L4S_ENABLED=$L4S_ENABLED          PORT_L4S=$PORT_L4S"
echo "RTT_MS=$RTT_MS"
echo

for ((run=0; run<NUM_RUNS; run++)); do
  IDX="$(next_free_idx)"
  run_once "$IDX"
  sleep "$COOLDOWN_SEC"
done
