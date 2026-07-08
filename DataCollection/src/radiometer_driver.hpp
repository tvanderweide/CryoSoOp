// radiometer_driver.hpp — SoOp radiometer sequence executor (continuous ring-buffered capture).
//
// Reproduces the SoOp_StressTest recv engine (rx_stress_capture.cpp) as a sequence of captures that
// all share ONE UHD session — the device is never re-created or re-tuned between captures, which is
// load-bearing: every NL/L/Signal capture in a run carries the same inter-channel phase offset (the
// prerequisite for NL phase calibration). For each SequenceStep:
//   exec_hook(state_cmd) -> settle_s -> count x { timed START_CONTINUOUS capture -> ring -> per-
//   channel sc16 .dat via DatWriter (planned-size fallocate + chunk rotation) -> stop + drain }.
//
// Fixes the stock rx_samples_to_file wall-clock-stop defect by stopping on an exact sample count
// (duration_s * rate). A CLI --duration replaces the whole sequence with one Signal step.

#ifndef CRYOSOOP_RADIOMETER_DRIVER_HPP
#define CRYOSOOP_RADIOMETER_DRIVER_HPP

#include <string>

#include "common/config.hpp"
#include "common/event_log.hpp"
#include "common/summary.hpp"

namespace cryosoop {

void run_radiometer(const Config& cfg, const std::string& save_root, bool until_stopped,
                    EventLog& log, Counters& counters, SummaryMeta& meta);

}  // namespace cryosoop

#endif  // CRYOSOOP_RADIOMETER_DRIVER_HPP
