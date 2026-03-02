# Experimentation Data Scripts

Network congestion control experiments testing L4S vs Classic TCP across different conditions.

---

# Experimental Scenarios

| Regime        | RTT     | Bandwidth | Why |
|--------------|---------|-----------|------------------------------------------------|
| Low-BDP      | 20 ms   | 12 Mbps   | Tight feedback, small queues dominate |
| Mid-BDP      | 40 ms   | 50 Mbps   | Typical broadband behavior |
| High-BDP     | 100 ms  | 200 Mbps  | Stress test: large queues, long control loops |

Each regime tests:
- classic (Classic TCP only)
- l4s (L4S only)
- dual (Mixed Classic + L4S)

Total = 3 BDP × 3 traffic regimes = 9 core scenarios.

---

# Running Experiments

## Requirements

Before running:

- Update `paths.tc_bin` in the YAML file to point to your correct `tc` binary  
  (especially if using a custom iproute2 build with dualpi2 support).
- Ensure Mahimahi is installed and accessible with `sudo`.
- Install `iperf3` and verify it is available in your PATH:

  iperf3 --version

- Install Python 3 with PyYAML:

  python3 -c "import yaml"

- Run on a Linux system (required for `ip netns`, `tc`, IFB, and sysctl networking features).
- Use a kernel that includes the **Prague (TCP Prague) congestion control module**.
- Before running experiments, execute:

  sudo ./FORCE.sh

  This script enables TCP ECN and ensures the Prague congestion control module is active.

## More on YAML Configuration

Below is a description of the key fields in the example experiment YAML file.

| Field | Description |
|-------|-------------|
| `output_dir` | Directory where all logs and validation outputs are saved. |
| `secs_per_run` | Duration (seconds) of each individual experiment run. |
| `num_runs` | Total number of repeated runs for statistical analysis. |
| `MAX_DELAY_THRESH_MS` | Maximum delay threshold (ms) used in validation checks. |
| `traces.up` / `traces.down` | Bandwidth trace files used by `mm-link` to emulate capacity. |
| `mahimahi.delay_ms` | One-way propagation delay (ms). Effective RTT is doubled (forward + reverse path). |
| `queue.type` | Queue discipline used (e.g., `dualpi2`). |
| `queue.packets` | Maximum queue size (in packets). |
| `queue.target` | Target queue delay (ms) for AQM control. |
| `queue.tupdate` | Controller update interval (ms). |
| `queue.alpha` / `queue.beta` | PI2 control parameters controlling marking/dropping behavior. |
| `flows.base_port` | Starting port number. For run `i`: Classic = `base_port + 2*i`, L4S = `base_port + 2*i + 1`. |
| `flows.classic.enabled` | Enable or disable Classic flow. |
| `flows.l4s.enabled` | Enable or disable L4S flow. |

### Running Single vs Dual Flow

To run:

- **Single Classic flow** → set `classic.enabled: true`, `l4s.enabled: false`
- **Single L4S flow** → set `classic.enabled: false`, `l4s.enabled: true`
- **Dual flow experiment** → set both to `true`

> [!NOTE]
> - All experiments use `iperf3` directly (both server and client are launched inside network namespaces).
> - Classic flows use `cubic`; L4S flows use `prague`.
> - Logs are written to the directory specified in `logging.dir` in the YAML configuration file.
## Single Experiment

Currently, only iperf experiments are supported.

### Configure the YAML Path

Edit the configuration path inside the appropriate script.

Kernel scripts (line 8):
CFG=${1:-exp.yaml} <- note here this yaml does not exist thus it will run error: exp.yaml does not exist, so replace with the one you want to run

Mahimahi scripts (line 4):
CFG="${1:-exp_100ms_200mbps_classic.yaml}"

Adjust the default YAML file as needed.

### Run the Experiment


```bash
sudo ./iperf.sh
```

## All Experiments

```bash
sudo ./together.sh
```

Runs all configs (files ending in .yaml) sequentially that's in the same directory as ./together.sh. 

This does not delete previous data. It appends new runs to the existing folders.

---

# Output

Each YAML creates its own folder (e.g., `exp_20ms_l4s/`) containing:

- `iperf3_*.client.log` — iperf sender-side log  
- `iperf3_*.server.log` — iperf receiver-side log  
- `dualpi2_stats.log` or `mahimahi_output.log` — queue/network statistics  

Consult the YAML configuration files for parameter descriptions and customization options.

---

# raw_data/

`raw_data/` contains all collected experiment outputs.  
This is the ground-truth dataset used for validation, DTW analysis, plotting, and statistical testing.

Structure:

```
raw_data/
├── kernel/
├── mahimahi_step_q_thresh/
├── mahimahi_step_target/
├── mahimahi-finale/
└── mahimahi-original/
```

Each top-level folder corresponds to a different experiment family.

---

# raw_data/kernel/

Native Linux kernel DualPI2 experiments (no Mahimahi emulation).

Organized by bandwidth:

```
raw_data/kernel/
├── 12mbps/
│   ├── classic/
│   ├── l4s/
│   └── dual/
├── 50mbps/
│   ├── classic/
│   ├── l4s/
│   └── dual/
└── 200mbps/
    ├── classic/
    ├── l4s/
    └── dual/
```

Bandwidth folders correspond to BDP regimes:

- 12mbps  → Low-BDP (20 ms RTT)
- 50mbps  → Mid-BDP (40 ms RTT)
- 200mbps → High-BDP (100 ms RTT)

Traffic regime folders:

- classic → Classic TCP only
- l4s     → L4S only
- dual    → Mixed Classic + L4S

Each scenario contains repeated iperf3 runs:

```
iperf3_<k>.<flow>.client.log
iperf3_<k>.<flow>.server.log
```

Where:
- `<k>` is the run index (0, 1, 2, ...)
- `<flow>` is `classic` or `l4s`

In dual experiments, both classic and l4s logs exist per run index.

---

# raw_data/mahimahi_step_q_thresh/

Mahimahi experiments sweeping the L4S queue threshold (q_thresh).

Example structure:

```
raw_data/mahimahi_step_q_thresh/
├── 12mbps/
├── 50mbps-5/
├── 50mbps-10/
├── 50mbps-15/
├── 200mbps-5/
├── 200mbps-10/
└── 200mbps-15/
```

Naming format:

- 50mbps-5   → 50 Mbps bandwidth, q_thresh = 5 ms
- 50mbps-10  → q_thresh = 10 ms
- 200mbps-15 → 200 Mbps bandwidth, q_thresh = 15 ms

These experiments isolate the effect of varying the L4S marking threshold.

---

# raw_data/mahimahi_step_target/

Mahimahi experiments sweeping the DualPI2 target delay parameter (`target_ms`).

Structure:

```
raw_data/mahimahi_step_target/
├── target-30ms/
└── target-45ms/
```

Used to study sensitivity to the target delay configuration.

---

# raw_data/mahimahi-finale/

Final tuned Mahimahi configurations used in the paper.

Structure:

```
raw_data/mahimahi-finale/
├── 12mbps/
│   └── dual-5-30/
├── 50mbps/
│   └── dual-5-30/
└── 200mbps/
    └── dual-10-45/
```

Naming format:

`<traffic>-<q_thresh>-<target>`

Examples:
- dual-5-30  → q_thresh = 5 ms, target = 30 ms
- dual-10-45 → q_thresh = 10 ms, target = 45 ms

These represent the final configurations reported in the paper.

---

# raw_data/mahimahi-original/

Baseline Mahimahi configuration (untuned reference).

- target = 15 ms
- thresh = 1 ms

Structure mirrors bandwidth folders:

```
raw_data/mahimahi-original/
├── 12mbps/
├── 50mbps/
└── 200mbps/
```

Used as the original comparison baseline before parameter tuning.

---

# Log File Descriptions

`iperf3_*.client.log`
- Sender-side throughput per interval
- Congestion window behavior
- Retransmissions (Classic)
- ECN behavior (L4S when enabled)
- Final summary statistics

`iperf3_*.server.log`
- Receiver-side measured throughput
- Final throughput summary
- Interval statistics
- Ground-truth throughput measurement

`dualpi2_stats.log`
- Queue delay
- Marking probability
- ECN marks
- Packet drops
- Internal DualPI2 state metrics

`mahimahi_output.log`
- Emulated link behavior
- Delay trace behavior
- Queue events (depending on configuration)

---

# Summary

- Three BDP regimes: 12 Mbps, 50 Mbps, 200 Mbps
- Three traffic regimes per BDP: classic, l4s, dual
- Native kernel DualPI2 and Mahimahi-based implementations
- Parameter sweeps for q_thresh and target delay
- Final tuned configuration for paper results
- Original untuned baseline
- Repeated iperf3 sender and receiver logs per scenario

All raw logs are preserved and appended across runs to ensure reproducibility and statistical validation.