# CryoSoOp configuration schema

One YAML file drives the `cryosoop` radiometer binary. `MODE` must be `radiometer` — this is a
radiometer-only program (the snow-radar acquisition is a separate project). Sections: `MODE`,
`DEVICE`, `FILES`, `RING`, `TIMEBASE`, `RADIOMETER`, `CAL`, `DISK`.

Parsing (`src/common/config.{hpp,cpp}`) is **strict**:

- Unknown keys inside a known section are rejected, with an edit-distance "did you mean" hint.
- Enum-valued keys are validated against their allowed sets.
- The radiometer-only MODE rule and the per-step positivity rules are enforced
  (see [Validation rules](#validation-rules)).
- `Config::dump_effective()` writes the fully-resolved config (all values as loaded, plus a
  `duration_s:` line when a CLI `--duration` override is active) to `config_effective.yaml` in each
  run folder. A tolerated `_derived:` block from an older effective dump is ignored on re-parse.

"Consumer" below names the code that reads the key. `common` = `src/common/*`;
`radiometer` = `src/radiometer_driver.cpp`; `device` = the UHD device layer (`src/device/*`);
`main` = `src/main.cpp`.

Defaults below are the in-code struct defaults (`config.hpp`). The shipped
`config/radiometer_B210.yaml` overrides several with deployed values (noted where relevant).

---

## MODE

| Key | Type | Default | Consumer | Notes |
|---|---|---|---|---|
| `MODE` | string, must be `radiometer` | `radiometer` | main | Rejected with a clear error if not `radiometer`. |

## DEVICE

| Key | Type | Default | Consumer | Notes |
|---|---|---|---|---|
| `device_args` | string | `num_recv_frames=700,num_send_frames=700,recv_frame_size=10000,send_frame_size=10000` | device | UHD device-address / transport args. The shipped config uses `master_clock_rate=20e6,num_recv_frames=700,recv_frame_size=8200`. |
| `subdev` | string | `A:A A:B` | device | RX subdev spec (both frontends = dual RX). |
| `clk_ref` | string | `internal` | device | Clock (10 MHz reference) source. Non-`internal` triggers a `ref_locked` wait. |
| `pps_ref` | string | `internal` | device | Time (PPS) source. |
| `master_clock_rate` | `auto` or Hz | `auto` | device | `auto` lets UHD derive it (load-bearing; the 105.7° phase comb ties to the MCR). Read back and logged (`MASTER_CLOCK`). |
| `tx_channels` | string (space-split) | `0 1` | — | Unused by the RX-only radiometer; kept for symmetry / parity with the device schema. |
| `rx_channels` | string (space-split) | `0 1` | device | RX streamer channels (order = frontend map). |
| `cpu_format` | enum `fc32\|sc16\|sc8` | `sc16` | device | Host sample format; `sc16` = interleaved int16 I/Q → per-channel `.dat`. |
| `otw_format` | enum `sc16\|sc12\|sc8` | `sc16` | device | On-the-wire sample format. |
| `rx_timeout_limit` | int | `3` | radiometer | Consecutive 1 s recv timeouts before aborting a capture. |

## FILES

| Key | Type | Default | Consumer | Notes |
|---|---|---|---|---|
| `save_loc` | string | `data/B210/` | main | Acquisition root used when `--save-loc` is not given. In **both** cases the binary creates a per-run subfolder `<root>/<YYYYMMDD>/<HHMMSS>/` (UTC) under the root and writes that run's `.dat` files, `events.csv`, `RunLog.log`, `config_effective.yaml`, and `summary.json` there — nothing appends/overwrites across runs. `--save-loc` overrides `save_loc` as the root (it is no longer used verbatim); in production `radiometer_run.sh` always passes `--save-loc $DATA_DIR` from `config/site.env`, so per-site path changes go in site.env, not this key. Shipped config: `/mnt/snowData/SDR/Data/`. |

## RING

| Key | Type | Default | Consumer | Notes |
|---|---|---|---|---|
| `ring_mb` | double (MiB) | `8192` | radiometer | SPSC ring size. 8 GiB suits the dedicated 16 GB Pi (~52 s stall absorption at 160 MB/s); clamped to `MemAvailable − 1 GiB` on Linux. Overridable via `--ring-mb`. |
| `on_full` | enum `drop_newest` | `drop_newest` | radiometer | Fixed policy: drop the newest samples when the ring fills (accounted as `RINGFULL` / `ring_drop_samps`). |
| `sync_every_mb` | double (MiB) | `64` | radiometer | Page-cache flush watermark per file. |

## TIMEBASE

| Key | Type | Default | Consumer | Notes |
|---|---|---|---|---|
| `anchor` | enum `host_now\|next_pps` | `host_now` | device | Device-time anchor. `host_now` = `set_time_now(0)`; `next_pps` = `set_time_unknown_pps(0)`. |
| `events_csv` | string | `events.csv` | main/common | Machine-readable event log filename in the run folder. |
| `human_log` | string | `RunLog.log` | main/common | Human-readable log filename in the run folder. Nothing downstream consumes it. |

## RADIOMETER

| Key | Type | Default | Consumer | Notes |
|---|---|---|---|---|
| `freq` | double (Hz) | `370e6` | radiometer | RX center frequency (UHF). |
| `rate` | double (Hz) | `20e6` | radiometer/device | Sample rate; the sample-counted stop uses it. Must be > 0. |
| `gain` | double (dB) | `54` | radiometer | RX gain (all channels). |
| `bw` | double (Hz), optional | = `rate` if unset | radiometer | Analog bandwidth. |
| `rx_ant` | string | `RX2` | radiometer | RX antenna port (all channels). |
| `chunk_secs` | double (s) | `10` | radiometer | File rotation period; `>=` per-capture duration ⇒ one file per capture. |
| `settle_s` | double (s) | `2.0` | radiometer | Settle delay after a `state_cmd` before capturing. |
| `lo_lock_timeout_s` | double (s) | `2.0` | radiometer | `lo_locked` poll timeout at device setup. |
| `lo_lock_poll_s` | double (s) | `0.1` | radiometer | `lo_locked` poll interval at device setup. |
| `max_stream_errors` | int | `10` | radiometer | Unclassified stream errors before aborting a capture. |
| `final_state_cmd` | string | `""` | radiometer | Optional shell hook run once at end of sequence (restore RF-switch state). |
| `sequence` | list of steps | `[]` | radiometer | The capture sequence (below). Empty + no `--duration` = nothing to capture (warning). |

### RADIOMETER.sequence[] (per step)

| Key | Type | Default | Consumer | Notes |
|---|---|---|---|---|
| `state` | string | — | radiometer | Free-text state label (`NL` / `L` / `Signal` / …); logged, not interpreted. |
| `prefix` | string | — | radiometer | Output filename prefix (e.g. `UHF__NL_`, `UHF__L_`, `UHF_`). |
| `count` | int | `1` | radiometer | Captures in this step. Must be > 0. |
| `duration_s` | double (s) | `2.0` | radiometer | Per-capture duration. Must be > 0 and yield ≥ 1 sample. |
| `state_cmd` | string | `""` | radiometer | Out-of-band state-change hook (SSH to the BeagleBone GPIO); runs via `exec_hook`, never in the RX hot path. The shipped config calls `/usr/local/bin/bbb_set_state.sh <state>` (source: `orchestration/bbb_set_state.sh`, installed once per Pi); the BBB host address, GPIO pins, and per-state values come from `config/site.env` (exported by `radiometer_run.sh`; the script's in-code defaults apply when run standalone), ssh hardening lives in the script. `rc=0` means *verified* switch state: `set -e` (fail on first bad write) plus a read-back of the pin values against the commanded state; `BatchMode`/`ConnectTimeout=15`/`ServerAlive*` make an unreachable BBB fail fast instead of hanging. |
| `on_cmd_fail` | enum `abort\|continue` | `abort` | radiometer | Behaviour when `state_cmd` returns nonzero. |

## CAL

| Key | Type | Default | Consumer | Notes |
|---|---|---|---|---|
| `common_source_captures` | bool | `false` | radiometer | Reserved config-gated hook; currently a logged no-op (a warning is emitted if set true). |

## DISK

| Key | Type | Default | Consumer | Notes |
|---|---|---|---|---|
| `disk_floor_gb` | double (GB) | `8.0` | radiometer | Graceful-abort floor: pre-flight, per-capture, and per-chunk free-space checks. |
| `nvme_min_mbps` | double (MB/s) | `400.0` | orchestration | Pre-flight write-throughput floor used by `probe_nvme.sh` (not read by the C++). |

## CLI-only

| Key | Type | Notes |
|---|---|---|
| `duration_s` | double (s) | Not a YAML key — set by `--duration`; replaces the sequence with one Signal capture. Echoed into `config_effective.yaml`. Must be > 0. |

---

## Validation rules

- `MODE` must be `radiometer`.
- `RADIOMETER.rate` > 0.
- Each `RADIOMETER.sequence[i]`: `duration_s` > 0, `count` > 0, and `rate * duration_s` ≥ 1 sample.
- `--duration`, if given, must be > 0.
- `RING.on_full` must be `drop_newest`.
- Unknown keys (top-level or within a known section) are errors; unknown enum values are errors.
