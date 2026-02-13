# Experimentation Data Scripts

Network congestion control experiments testing L4S vs Classic TCP across different conditions.

## Experimental Scenarios

| Regime | RTT | Bandwidth | Why |
|--------------|---------|-----------|------------------------------------------------|
| **Low-BDP** | 20 ms | 12 Mbps | Tight feedback, small queues dominate |
| **Mid-BDP** | 40 ms | 50 Mbps | Typical broadband behavior |
| **High-BDP** | 100 ms | 200 Mbps | Stress test: large queues, long control loops |

Each regime tests L4S-only, Classic-only, and Mixed traffic = **9 total scenarios**.

## Running Experiments

### Single Experiment
```bash
./single.sh exp_20ms_l4s.yaml
```

**Kernel scripts:** Edit line 8: `CFG=${1:-exp.yaml}`  
**Mahimahi scripts:** Edit line 4: `CFG="${1:-exp_100ms_200mbps_classic.yaml}"`

### All Experiments
```bash
./together.sh
```
Runs all configs sequentially. **Does NOT delete** previous data—only appends new runs.

## Output

Each YAML creates its own folder (e.g., `exp_20ms_l4s/`) containing:
- `rx_*.txt` / `tx_*.txt` - SCREAM traffic logs
- `dualpi2_stats.log` or `mahimahi_output.log` - Queue/network stats

Check individual YAML files for parameter descriptions and customization options.