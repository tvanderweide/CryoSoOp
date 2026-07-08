// summary.hpp — run counters, SUMMARY_JSON emission, and the exit-code policy.
//
// Adapted from SoOp_StressTest's summary block (rx_stress_capture.cpp:585-634), extended with
// extra reliability counters (retries, bands_ok/degraded/failed, retained for schema stability) and made a reusable struct
// instead of inline main() code. StressTest's exit-code contract is preserved and stated
// explicitly here:
//   0 = clean (completed, all error counters zero, no bands failed, not fatal)
//   1 = completed with errors (any error counter nonzero, or a band degraded/failed)
//   2 = fatal / aborted (device setup failed, internal abort, interrupted before completion)
//
// The counters are atomics because the hot RX thread bumps O/S/A/timeouts/dropped/ring_drops
// while the writer/consumer thread bumps bytes_written — same split as StressTest. bands_* and
// retries are driver-thread-only but kept atomic for uniformity.

#ifndef CRYOSOOP_COMMON_SUMMARY_HPP
#define CRYOSOOP_COMMON_SUMMARY_HPP

#include <atomic>
#include <cstdint>
#include <ostream>
#include <string>
#include <utility>
#include <vector>

namespace cryosoop {

struct Counters {
    // RX error taxonomy (mirror StressTest O/S/A/timeouts + extra counters)
    std::atomic<std::uint64_t> overflow{0};      // O : in-sequence overflow
    std::atomic<std::uint64_t> out_of_seq{0};    // S : out-of-sequence overflow
    std::atomic<std::uint64_t> alignment{0};     // A : alignment error
    std::atomic<std::uint64_t> timeouts{0};      // recv timeouts
    std::atomic<std::uint64_t> late{0};          // LATE_COMMAND occurrences
    std::atomic<std::uint64_t> dropped_samps{0}; // D : gap-estimated dropped samples
    std::atomic<std::uint64_t> ring_drop_samps{0};// RINGFULL scratch drops
    std::atomic<std::uint64_t> other{0};         // unclassified stream errors
    // Reliability counters: unused by the radiometer path but emitted (as zeros) for a
    // stable summary.json schema.
    std::atomic<std::uint64_t> retries{0};       // band/burst retry attempts
    std::atomic<std::uint64_t> bands_ok{0};
    std::atomic<std::uint64_t> bands_degraded{0};// saved anyway after retry exhaustion
    std::atomic<std::uint64_t> bands_failed{0};  // not saved
    // Throughput
    std::atomic<std::uint64_t> bytes_written{0}; // total bytes to disk (all channels)

    // Sum of the "something went wrong" error counters (not throughput / band tallies).
    std::uint64_t error_total() const {
        return overflow.load() + out_of_seq.load() + alignment.load() + timeouts.load() +
               late.load() + dropped_samps.load() + ring_drop_samps.load() + other.load();
    }
};

// Metadata for the SUMMARY_JSON block. Core fields are typed; `extra` carries pre-formatted JSON
// values (already valid JSON: numbers, "strings", [arrays], true/false) appended verbatim so a
// driver can add mode-specific fields (freq range, ring slots, nbands, etc.) without this header
// having to know every one.
struct SummaryMeta {
    std::string mode;          // "radiometer"
    std::string wall_start;    // ISO
    std::string wall_end;      // ISO
    std::string abort_reason;  // "" if none
    bool interrupted = false;  // stopped before planned completion
    bool fatal = false;        // device/internal fatal condition
    double ring_max_fill_pct = 0.0;
    std::uint64_t ring_slots = 0;
    std::vector<std::pair<std::string, std::string>> extra;  // key -> raw JSON value
};

// Exit code from counters + meta, per the policy above.
int exit_code(const Counters& c, const SummaryMeta& meta);

// True if any error counter is nonzero or any band degraded/failed.
bool has_errors(const Counters& c);

// Emit the SUMMARY_JSON block (including the markers and trailing exit-code line) to `os`.
// Format follows StressTest: a "==== SUMMARY_JSON ====" line, the JSON object, then a
// "==== END_SUMMARY_JSON ====" line. Returns the computed exit code for convenience.
int emit_summary_json(std::ostream& os, const Counters& c, const SummaryMeta& meta);

// Build the JSON object string only (no markers) — useful for also writing a summary.json file.
std::string summary_json(const Counters& c, const SummaryMeta& meta);

}  // namespace cryosoop

#endif  // CRYOSOOP_COMMON_SUMMARY_HPP
