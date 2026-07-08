# CryoSoOp

P-band SoOp (signals-of-opportunity) radiometer for snow observation on the Brundage
Mountain B210 system: a C++ acquisition program plus a MATLAB post-processing pipeline
and interactive viewer.

The acquisition program (`cryosoop`) is a single-UHD-session sequence executor that runs an
NL / L / Signal calibration+signal sequence on an Ettus B210 and writes ring-buffered
dual-channel raw `.dat` captures. Keeping the whole sequence inside one UHD session is the
load-bearing design property — it is what makes NL-based inter-channel phase calibration valid.
The processing pipeline turns those raw two-channel captures into calibrated,
geometry-corrected phase measurements sensitive to snow depth.

## Layout

| Path | Contents |
|---|---|
| [`DataCollection/`](DataCollection/README.md) | `cryosoop` acquisition program — C++ source, config + schema, cron orchestration scripts, output-contract validator. Builds and runs on a Raspberry Pi driving the B210. |
| [`Processing/`](Processing/README.md) | MATLAB post-processing pipeline (L1 cross-correlation → calibration → satellite ID → L2 corrected phase, plus a season-wide RFI diagnostic) and an interactive viewer. Runs locally or on an HPC via SLURM. |

Start with each folder's README; the acquisition config-key reference is
[`DataCollection/config/SCHEMA.md`](DataCollection/config/SCHEMA.md) and the processing
`cfg`-field reference is
[`Processing/docs/config-reference.md`](Processing/docs/config-reference.md).

## Dependencies

- **DataCollection**: CMake ≥ 3.15, C++17, yaml-cpp, and [UHD](https://github.com/EttusResearch/uhd)
  (headers + host tools) for the full build. UHD is not vendored — install it from your
  distribution (`libuhd-dev uhd-host`) or build it from the Ettus repository. A UHD-free
  compile check of the core is available via `-DCRYOSOOP_COMMON_ONLY=ON`.
- **Processing**: MATLAB (developed on R2026a); Parallel Computing Toolbox recommended for the
  batch pipeline.
