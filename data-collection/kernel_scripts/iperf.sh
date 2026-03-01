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
  # try TERM first (lets iperf flush its final report)
  sudo ip netns exec "$NS_S" pkill -TERM iperf3 2>/dev/null || true
  sudo ip netns exec "$NS_R" pkill -TERM iperf3 2>/dev/null || true
  sleep 0.2
  # then KILL if needed
  sudo ip netns exec "$NS_S" pkill -KILL iperf3 2>/dev/null || true
  sudo ip netns exec "$NS_R" pkill -KILL iperf3 2>/dev/null || true
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

  # L4S-native knobs:
  #   step_thresh TIME|PACKETS   (we set TIME=1ms)
  #   min_qlen_step PACKETS      (we set 1 packet)
  sudo ip netns exec "$NS_S" "$TC_BIN" qdisc add dev "$VETH_DEV" parent 1:10 handle 2: dualpi2 \
    target "$TARGET" tupdate "$TUPDATE" limit "$LIMIT" alpha "$ALPHA" beta "$BETA" \
    step_thresh 1ms
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

# ============================================================
# Run enabled iperf3 flows concurrently (LOG OUTPUT)
#   - servers in NS_R
#   - clients in NS_S
#   - log server + client separately
#   - DO NOT override -C; rely on system default CC in each namespace
# ============================================================

run_both_flows() {
  local idx="$1"

  local srv_classic="" cli_classic=""
  local srv_l4s="" cli_l4s=""

  local classic_srv_log="$LOG_DIR/iperf3_${idx}.classic.server.log"
  local classic_cli_log="$LOG_DIR/iperf3_${idx}.classic.client.log"
  local l4s_srv_log="$LOG_DIR/iperf3_${idx}.l4s.server.log"
  local l4s_cli_log="$LOG_DIR/iperf3_${idx}.l4s.client.log"

  local RECV_IP="172.20.1.2"

  [[ "$CLASSIC_ENABLED" == "true" ]] && { : > "$classic_srv_log"; : > "$classic_cli_log"; }
  [[ "$L4S_ENABLED"     == "true" ]] && { : > "$l4s_srv_log";     : > "$l4s_cli_log";     }

  # Start servers
  if [[ "$CLASSIC_ENABLED" == "true" ]]; then
    sudo ip netns exec "$NS_R" stdbuf -oL -eL iperf3 -s -p "$PORT_CLASSIC" -1 \
      >>"$classic_srv_log" 2>&1 &
    srv_classic=$!
  fi

  if [[ "$L4S_ENABLED" == "true" ]]; then
    sudo ip netns exec "$NS_R" stdbuf -oL -eL iperf3 -s -p "$PORT_L4S" -1 \
      >>"$l4s_srv_log" 2>&1 &
    srv_l4s=$!
  fi

  # Start clients after 1 sec
  sleep 1

  if [[ "$CLASSIC_ENABLED" == "true" ]]; then
    sudo ip netns exec "$NS_S" stdbuf -oL -eL iperf3 \
      -c "$RECV_IP" -p "$PORT_CLASSIC" -t "$SECS_FLOW" \
      -C cubic \
      --tos "$CLASSIC_TOS" \
      >>"$classic_cli_log" 2>&1 &
    cli_classic=$!
  fi

  if [[ "$L4S_ENABLED" == "true" ]]; then
    sudo ip netns exec "$NS_S" stdbuf -oL -eL iperf3 \
      -c "$RECV_IP" -p "$PORT_L4S" -t "$SECS_FLOW" \
      -C prague \
      --tos "$L4S_TOS" \
      >>"$l4s_cli_log" 2>&1 &
    cli_l4s=$!
  fi

  if [[ -n "${cli_classic:-}" ]]; then
    wait "$cli_classic" 2>/dev/null || true
  fi

  if [[ -n "${cli_l4s:-}" ]]; then
    wait "$cli_l4s" 2>/dev/null || true
  fi

  [[ -n "$srv_classic" ]] && sudo kill "$srv_classic" >/dev/null 2>&1 || true
  [[ -n "$srv_l4s" ]] && sudo kill "$srv_l4s" >/dev/null 2>&1 || true

  cleanup_run

  [[ "$CLASSIC_ENABLED" == "true" ]] && echo "iperf3 classic logs: $classic_srv_log  $classic_cli_log"
  [[ "$L4S_ENABLED" == "true" ]] && echo "iperf3 l4s logs:     $l4s_srv_log  $l4s_cli_log"
}

# ============================================================
# One run
# ============================================================

enable_tcp_ecn_and_cc() {
  local ns="$1"
  local cc="$2"

  # enable ECN
  sudo ip netns exec "$ns" sysctl -w net.ipv4.tcp_ecn=1 >/dev/null

  # set default congestion control (optional since iperf3 -C overrides)
  sudo ip netns exec "$ns" sysctl -w "net.ipv4.tcp_congestion_control=$cc" >/dev/null

  # (optional sanity) ensure prague is available
  sudo ip netns exec "$ns" sysctl net.ipv4.tcp_available_congestion_control >/dev/null || true
}

run_once() {
  local idx="$1"
  local qdisc_log="$LOG_DIR/qdisc_${idx}.log"

  reset_namespaces_fresh
  enable_tcp_ecn_and_cc "$NS_S" prague
  enable_tcp_ecn_and_cc "$NS_R" prague
  apply_rtt_netem_delay
  apply_dualpi2_qdisc

  sleep 1
  run_both_flows "$idx" &
  local EXP_PID=$!

  if (( WARMUP_SEC > 0 )); then
    sleep "$WARMUP_SEC"
  fi

  local QDISC_PID
  QDISC_PID="$(start_qdisc_logger "$idx")"

  wait "$QDISC_PID" 2>/dev/null || true
  wait "$EXP_PID" 2>/dev/null || true
  cleanup_run

  echo "Saved: $qdisc_log"
}

# ============================================================
# Main
# ============================================================
echo "Using config: $CFG"
echo "LOG_DIR=$LOG_DIR"
echo "CLASSIC_ENABLED=$CLASSIC_ENABLED  PORT_CLASSIC=$PORT_CLASSIC  TOS=$CLASSIC_TOS"
echo "L4S_ENABLED=$L4S_ENABLED          PORT_L4S=$PORT_L4S          TOS=$L4S_TOS"
echo "RTT_MS=$RTT_MS"
echo

for ((run=0; run<NUM_RUNS; run++)); do
  IDX="$(next_free_idx)"
  run_once "$IDX"
  sleep "$COOLDOWN_SEC"
done
