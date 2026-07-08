# cryosoop — B210 SoOp radiometer acquisition

C++ data-acquisition binary (`cryosoop`) for the Brundage B210 **SoOp P-band radiometer**: a
single-UHD-session sequence executor that runs the NL / L / Signal calibration+signal sequence and
writes per-channel raw `.dat` captures. It replaces an earlier shell-hosted `rx_samples_to_file`
loop with one implementation that fixes the wall-clock-stop truncation, adds a drop-newest ring
buffer, and — critically — keeps every capture in a run inside one UHD session. Every config key,
unit, and default is in [`config/SCHEMA.md`](config/SCHEMA.md).

This project is radiometer-only.

## Why one UHD session (NL phase calibration)

The B210's inter-channel phase offset is constant within a single UHD session but random across
sessions. NL (Noise+Load) phase calibration only works if the cal captures and the signal captures
share that one offset, so the whole NL / L / Signal sequence must run in a single, never-re-opened
UHD session. This is the load-bearing property of the design and the reason the sequence executor
lives in the binary rather than in a per-capture shell loop.

## Repo layout

| Path | Contents |
|---|---|
| `src/common/` | UHD-free: config, ring buffer, event log, `.dat` writer, summary/exit-code policy, run control, shared types. Builds anywhere yaml-cpp is available, including MSVC. |
| `src/device/` | UHD-heavy: USRP session setup and lo-lock RF control. The only code that touches `uhd::usrp::multi_usrp` directly. |
| `src/radiometer_driver.cpp` | Single-session sequence executor (NL/L/Signal), ring-buffered dual-channel capture, sample-counted stop. |
| `src/main.cpp` | CLI parsing, config load, `MODE: radiometer` enforcement; always runs the radiometer driver. |
| `config/` | `radiometer_B210.yaml`, `SCHEMA.md` (authoritative key reference), `site.env` (per-site settings — see "Deploying at a new site"). |
| `orchestration/` | `radiometer_run.sh` (cron wrapper), `probe_nvme.sh` (storage probe), `bbb_set_state.sh` (BBB cal-switch helper). |
| `tools/` | `validate_output.py` (output-contract checker), `yaml_compat.py`. |
| `CMakeLists.txt` | Build graph (see below). |

## Build

### Prerequisites (fresh Linux OS)

On a clean Raspberry Pi OS / Debian install, install the toolchain and libraries the build needs
before configuring. The build requires **CMake ≥ 3.15**, a **C++17** compiler, **yaml-cpp** (always
required — `cryosoop_common` parses YAML), and, for the full build, **UHD** (development headers plus
the host tools). pthreads is already provided by the base system.

```
sudo apt update
sudo apt install -y build-essential cmake libyaml-cpp-dev libuhd-dev uhd-host
```

| Package | Provides | Needed for |
|---|---|---|
| `build-essential` | `g++`, `make`, C/C++ toolchain | all builds |
| `cmake` | CMake (`>= 3.15`) | all builds |
| `libyaml-cpp-dev` | yaml-cpp headers + `yaml-cppConfig.cmake` | all builds (`find_package(yaml-cpp)`) |
| `libuhd-dev` | UHD headers + libraries | full build (`src/device/`, `cryosoop`) |
| `uhd-host` | `uhd_usrp_probe`, `uhd_images_downloader` | B210 bring-up / FPGA image |

Then download the B210 FPGA/firmware image (UHD will not bring the radio up without it):

```
sudo uhd_images_downloader
```

Notes:

- If `cmake` reports `Could not find a package configuration file provided by "yaml-cpp"`, the
  `libyaml-cpp-dev` package is missing (the runtime `libyaml-cpp*` alone is not enough — the build
  needs the dev package's `yaml-cppConfig.cmake`). Install it, then delete a stale `build/`
  (`rm -rf build`) before re-running `cmake`, since the failed lookup is cached.
- A similar `find_package` error later in the configure step points at UHD — install `libuhd-dev`
  (and `uhd-host` for the tools) the same way.
- The logic check below (`CRYOSOOP_COMMON_ONLY=ON`) needs only a compiler, CMake, and
  yaml-cpp — UHD is not required for it.

### On the radiometer Pi (full build, UHD)

```
cmake -S . -B build
cmake --build build -j"$(nproc)"
```

Produces `build/cryosoop`. Requires UHD. The radiometer is RX-only and has no local GPIO (cal-state
GPIO lives on the BeagleBone behind `state_cmd` hooks), so there is no local-GPIO library dependency.

### Logic check on a machine without UHD

```
cmake -S . -B build-common -DCRYOSOOP_COMMON_ONLY=ON
cmake --build build-common --config Release
```

`CRYOSOOP_COMMON_ONLY=ON` restricts the build to `cryosoop_common` (everything under `src/common/`)
and skips UHD, `src/device/`, and the `cryosoop` executable entirely — use this to compile-check the
UHD-free core on a development machine with no UHD installed (works under MSVC too). The real
target is the field Pi; skip this there and use the full build above.

## Install the BBB cal-switch helper (radiometer Pi)

The sequence's NL/L/Signal `state_cmd` hooks (and `final_state_cmd`) call
`/usr/local/bin/bbb_set_state.sh` — the **single location** for the BeagleBone host address,
cal-switch GPIO pins, per-state pin values, and ssh hardening options. To change the BBB IP or
pins, edit [`orchestration/bbb_set_state.sh`](orchestration/bbb_set_state.sh), never the YAML.
Install it once per Pi (and re-install whenever the script changes):

```
sudo install -m 0755 orchestration/bbb_set_state.sh /usr/local/bin/bbb_set_state.sh
```

Quick check (drives the RF switch — bench only): `bbb_set_state.sh Signal && echo OK`. Exit `0`
means the pin state was set **and read back verified** on the BBB; nonzero (bad write, state
mismatch, unreachable BBB) makes the run abort via `on_cmd_fail: abort`.

## Verify the binary before first use

Run these after every fresh build, before trusting the system for a real collection:

```
./build/cryosoop --help          # usage text; no crash, no device probe
uhd_usrp_probe                   # B210 enumerated: both RX frontends A:A / A:B, no FPGA/firmware mismatch
```

Then run the short smoke capture (first step of the Quick start below) and validate its output
before attempting the full sequence.

## Quick start

### Short smoke capture (run this first after a build)

A 2 s single-Signal-step capture, pointed outside the production rsync tree:

```
build/cryosoop --config config/radiometer_B210.yaml --duration 2 --save-loc /mnt/snowData/SDR/Diag
```

Expected: exit `0`; a per-run folder `/mnt/snowData/SDR/Diag/<YYYYMMDD>/<HHMMSS>/` holding one
`UHF_<stamp>_ch0.dat` / `_ch1.dat` pair, each **exactly** `round(2 * rate) * 4` bytes
(`rate=20e6` ⇒ `160,000,000` bytes/channel — confirms the sample-counted stop), plus an
`events.csv` with `RUN_START`, `TIME_ANCHOR`, `MASTER_CLOCK`, `FILE_WRITTEN`, `RUN_END`. Then
check the output contract:

```
python3 tools/validate_output.py "$(ls -1dt /mnt/snowData/SDR/Diag/*/*/ | head -n 1)" --duration 2
```

Expected: exit `0` with `---> RADIOMETER PASS`.

Note: the `--duration` override runs a single Signal capture with **no** `state_cmd`, so this
smoke test does not exercise the BeagleBone cal-switch hooks — verify those separately during
bench bring-up (passwordless SSH to the BBB, then a full-sequence run).

### One full calibration+signal sequence

```
build/cryosoop --config config/radiometer_B210.yaml --save-loc /mnt/snowData/SDR/Diag
```

Runs the configured sequence (default NL x2 -> L x2 -> Signal x15 -> NL x2 -> L x2) in one UHD
session — required for NL-based phase calibration to be valid (see
[Why one UHD session](#why-one-uhd-session-nl-phase-calibration)).

### Ad-hoc long capture

*FOR STRESS TESTING*

```
build/cryosoop --config config/radiometer_B210.yaml --duration 1800 \
               --save-loc /mnt/snowData/SDR/Diag --ring-mb 12288
```

`--duration <seconds>` replaces the sequence with one continuous Signal capture; `--ring-mb <MB>`
overrides the ring size. **Point `--save-loc` outside** the production rsync tree (`DATA_DIR`, see
Deployment) so the VM does not pull a huge diagnostic mid-write. CLI flags: `--config`,
`--duration`, `--until-stopped`, `--ring-mb`, `--save-loc`.

## Configuration

One shipped config: `config/radiometer_B210.yaml`. Every section/key — `MODE`, `DEVICE`, `FILES`,
`RING`, `TIMEBASE`, `RADIOMETER`, `CAL`, `DISK` — is documented with units, defaults, and consumers
in [`config/SCHEMA.md`](config/SCHEMA.md). Config loading is strict: `MODE` must be `radiometer`,
unknown keys inside a known section are rejected with a "did you mean" hint, and `RING.on_full` is
fixed to `drop_newest`. The binary writes a fully-resolved `config_effective.yaml` into every run
folder. The default `RING.ring_mb` is 8192 (8 GiB): the radiometer runs on a dedicated 16 GB
Raspberry Pi, and an 8 GiB ring absorbs ~52 s of write stall at 160 MB/s while leaving the OS
headroom (the ring is clamped to `MemAvailable − 1 GiB` on Linux).

## Output contract

Every run creates its own **per-run folder** `<root>/<YYYYMMDD>/<HHMMSS>/` (local time), where
`<root>` is the `--save-loc` value if given, else `FILES.save_loc`. That run folder holds the
per-channel `.dat` captures plus `events.csv`, `RunLog.log`, `config_effective.yaml`, and
`summary.json` — all scoped to the single run, so nothing appends or overwrites across runs.

Per-channel chunked `.dat` files (`sc16`, interleaved int16 I/Q) are named
`<PREFIX><YYYYmmddHHMMSS>_ch{0,1}.dat` with the configured sequence prefixes (`UHF__NL_`, `UHF__L_`,
`UHF_`), rotated every `RADIOMETER.chunk_secs`. The filename stamp is a 14-digit whole-second local
timestamp guarded against same-second collisions (the driver advances it a second at a time if a
file with that stamp already exists). Capture stop is by exact sample count (`duration_s * rate`),
which fixes the old `rx_samples_to_file` 0.05 s wall-clock truncation. Exit code `0` = clean,
`1` = completed with logged errors (dropped chunks — data still usable), `2` = fatal/aborted.
`events.csv` is the canonical event log (self-describing header row, checked by
`tools/validate_output.py`); `RunLog.log` is the human-readable mirror (nothing downstream
consumes it).

## Tooling

- `tools/validate_output.py <folder> [--rate HZ] [--duration S]` — checks the radiometer output
  contract for one acquisition: matched `<PREFIX>…_ch0.dat`/`_ch1.dat` pairs, equal per-channel
  sizes that are a whole number of `sc16` samples, known state prefixes (unexpected prefixes warn),
  the `duration*rate*4` size when rate/duration are known, and the `events.csv` header when the
  file is present — a missing `events.csv` only warns (legacy pre-`cryosoop` captures predate it);
  a present-but-mismatched header fails. Prints a final `---> RADIOMETER PASS|FAIL` line. Exit `0`
  PASS / `1` FAIL / `2` usage error.

The tools have no hard PyYAML dependency — they load YAML through `yaml_compat.py` (a bundled
minimal parser, used unless PyYAML happens to be present).

## Deployment (cron)

- `orchestration/radiometer_run.sh`, run as root, cron
  `10 */2 * * * .../radiometer_run.sh >> /var/log/cryosoop_radiometer_cron.log 2>&1`. Governed by
  env vars `MOUNT`, `DATA_DIR`, `MIN_FREE_GB` (default 8), `NVME_MIN_MBPS` (default 400; YAML key
  `DISK.nvme_min_mbps`), `CONFIG`, `CRYOSOOP_BIN`, `RX_TIMEOUT_SEC` (default 1200 — a single
  whole-sequence OS timeout, not per-capture, because the NL-calibration invariant needs the whole
  sequence in one UHD session; see the script header's TIMEOUT SCOPE note), `REBOOT_ON_FAIL`
  (default `1` — set `0` to disable the reboot-on-failure safety net during bench testing),
  `DEFAULT_GOV` (governor restored on exit, default `ondemand`). Pre-flight includes an NVMe
  write-throughput probe (`probe_nvme.sh`) plus the mount/free-space guards.
- `orchestration/probe_nvme.sh [MIN_MBPS] [TARGET_DIR]` (defaults `400`, `/mnt/snowData`) is the
  storage-throughput probe the wrapper calls at pre-flight; it can also be run standalone before
  trusting a new NVMe target (exit `0` pass / `1` below floor / `2` setup error).

The wrapper passes `--save-loc "$DATA_DIR"` unchanged, and the binary creates a per-run folder
`<DATA_DIR>/<YYYYMMDD>/<HHMMSS>/` for each invocation. Each two-hourly cron run therefore lands in
its own dated subfolder with its own `events.csv` / `RunLog.log` / `config_effective.yaml` /
`summary.json` (no cross-run append or overwrite). Point `tools/validate_output.py` at an
individual run folder (`<DATA_DIR>/<YYYYMMDD>/<HHMMSS>`), not at `DATA_DIR` itself.

## Deploying at a new site

The RF/sequence configuration carries over unchanged. Nearly everything that names *this*
deployment's hardware, network, and storage lives in **one file: `config/site.env`**
(plain `KEY=value`, sourced and exported by `orchestration/radiometer_run.sh`). Checklist:

1. **Edit `config/site.env`** — storage (`MOUNT`, `DATA_DIR` — passed to `cryosoop` as
   `--save-loc`, so the YAML needs no path edits; `MIN_FREE_GB`, `NVME_MIN_MBPS`), run
   behavior (`RX_TIMEOUT_SEC`, `REBOOT_ON_FAIL`, `DEFAULT_GOV`), and the BeagleBone
   cal switch (`BBB_HOST`, `GPIO_PINS`, per-state `NL_VALS`/`L_VALS`/`SIGNAL_VALS`).
   Keep `REBOOT_ON_FAIL=0` until bench bring-up is complete. Run `probe_nvme.sh`
   standalone against the new drive before trusting it.
2. **System clock timezone** — capture filenames and run folders use the acquisition computer's
   **local** clock. Set the OS timezone deliberately (`sudo timedatectl set-timezone <IANA zone>`,
   verify with `timedatectl`) and record it: the processing pipeline's `site_config.json`
   `capture_tz` must name the same zone (see `Processing/README.md`, "Deploying at a new site")
   or every satellite-geometry product misaligns by the UTC offset.
3. **BeagleBone SSH + install** — set up passwordless SSH from the acquisition machine to the
   BBB (`bbb_set_state.sh` runs with `BatchMode=yes`, so a password prompt is a hard failure),
   then install the helper where the YAML hooks expect it:
   `sudo install -m 0755 orchestration/bbb_set_state.sh /usr/local/bin/bbb_set_state.sh`.
   For bench use without the wrapper: `set -a; . config/site.env; set +a; bbb_set_state.sh NL`.
4. **Crontab** — install the cron entry for `radiometer_run.sh` on the new machine (see the
   script header for the reference line). The wrapper sources `site.env` itself, so the cron
   line needs no env prefixes.
5. **RX gain (in the YAML, not site.env)** — `RADIOMETER.gain` (54 dB) was set for this
   system's antenna + front-end chain.
   A different LNA/cable/antenna chain needs its own gain check (capture, inspect levels for
   clipping/quantization headroom) before season data is trusted. Center frequency, rate, and
   the NL/L/Signal sequence itself should not change.
6. **Device identity (only if multiple USRPs are attached)** — `DEVICE.device_args` carries no
   serial number, so the binary grabs the first B210 found. Add `serial=<...>` there if the new
   machine hosts more than one device.

After these edits, repeat the full bring-up order: build → `--help` / `uhd_usrp_probe` →
smoke capture + `validate_output.py` → `bbb_set_state.sh` bench check → one full sequence.

## Status

**Implemented:** `src/common/` (config, ring buffer, event log, `.dat` writer, summary/exit-code
policy, run control, shared types/event-name constants), `src/device/` (USRP session, lo-lock RF
control), `src/radiometer_driver.cpp`, the build graph (`CRYOSOOP_COMMON_ONLY` logic check
verified), orchestration scripts, `tools/`, and this documentation set.

**Bench-pending:** full bring-up on the B210 — in particular the same-session inter-channel phase
check that validates the NL-calibration design premise, the BeagleBone `state_cmd` verification,
the full single-session sequence, and a sustained-rate / ring-occupancy run — before `cryosoop` is
trusted as the field acquisition path.
