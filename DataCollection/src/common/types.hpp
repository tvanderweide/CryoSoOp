// types.hpp — small PODs / enums / time helpers shared by the whole cryosoop common core.
//
// UHD-free by design: nothing here (or anywhere else in src/common/) includes UHD. The device
// layer maps uhd::rx_metadata_t error codes onto the ev:: vocabulary so the common code and the
// driver speak one language without dragging UHD headers into the ring, writers, etc.
//
// Header-only on purpose (no types.cpp): all helpers are inline. Time helpers stamp UTC in code
// (gmtime, not the OS timezone) so filenames, run folders, and log timestamps are deterministic
// regardless of how the acquisition computer's local zone is configured. Legacy note: seasons
// captured before this change (2025-26 and earlier) used the Pi's LOCAL clock — the processing
// side's cfg.capture_tz exists to convert those; new data needs no conversion.

#ifndef CRYOSOOP_COMMON_TYPES_HPP
#define CRYOSOOP_COMMON_TYPES_HPP

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <string>

namespace cryosoop {

// ---------------------------------------------------------------- numeric tolerances
constexpr double kRateCoerceTolHz = 1.0;  // usrp_session: device-coerced sample rate vs requested

// ---------------------------------------------------------------- event names
// Canonical strings for the `event` column of events.csv. Kept as constants (not an enum) so
// callers can also log ad-hoc events, and so the CSV is grep-friendly and stable. The driver owns
// most of these; the common writers only emit RINGFULL / GAP / NEGGAP style events themselves.
namespace ev {
// Session / lifecycle
constexpr const char* RUN_START      = "RUN_START";
constexpr const char* RUN_END        = "RUN_END";
constexpr const char* ABORT          = "ABORT";
constexpr const char* SIGNAL         = "SIGNAL";        // SIGINT/SIGTERM received
// Timebase / clocking
constexpr const char* TIME_ANCHOR    = "TIME_ANCHOR";   // host_now / next_pps anchor set
constexpr const char* MASTER_CLOCK   = "MASTER_CLOCK";  // read-back master_clock_rate (never silent)
constexpr const char* CLOCK_LOCK     = "CLOCK_LOCK";    // ref/pps lock wait result
// Async / stream errors (from RX metadata)
constexpr const char* LATE_COMMAND   = "LATE_COMMAND";
// <math.h>/<cmath> define a legacy SVID matherr `OVERFLOW` macro; drop it so ev::OVERFLOW is ours.
#ifdef OVERFLOW
#undef OVERFLOW
#endif
constexpr const char* OVERFLOW       = "O";             // in-sequence RX overflow (counter O)
constexpr const char* OVERFLOW_OOS   = "S";             // out-of-sequence RX overflow (counter S)
constexpr const char* GAP            = "GAP";           // positive time_spec discontinuity (dropped)
constexpr const char* NEGGAP         = "NEGGAP";        // negative discontinuity (diagnostic)
constexpr const char* RINGFULL       = "RINGFULL";      // scratch-drop, ring was full
// Hooks
constexpr const char* HOOK           = "HOOK";          // exec_hook (SSH-to-BBB state_cmd) result
// Files
constexpr const char* CHUNK_ROTATE   = "CHUNK_ROTATE";
constexpr const char* FILE_WRITTEN   = "FILE_WRITTEN";
}  // namespace ev

// ---------------------------------------------------------------- host wall time
// Unix microseconds since epoch (system_clock; wall time, may jump with NTP — used for logs,
// never for scheduling, which is driven off device time in the driver).
inline uint64_t host_unix_us() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count());
}

// Portable, thread-safe-ish UTC breakdown. gmtime() itself is not reentrant, so use the
// platform reentrant variant where available.
inline std::tm utc_tm(std::time_t t) {
    std::tm out{};
#if defined(_WIN32)
    ::gmtime_s(&out, &t);
#elif defined(__unix__) || defined(__APPLE__)
    ::gmtime_r(&t, &out);
#else
    out = *std::gmtime(&t);
#endif
    return out;
}

// ISO-8601 UTC with microsecond fraction and explicit Z marker:
// "YYYY-MM-DDTHH:MM:SS.ffffffZ". Used for the wall_iso column in events.csv and the
// wall_start/wall_end fields of summary.json.
inline std::string iso_time(uint64_t unix_us) {
    const std::time_t secs = static_cast<std::time_t>(unix_us / 1000000ull);
    const unsigned us = static_cast<unsigned>(unix_us % 1000000ull);
    const std::tm tmv = utc_tm(secs);
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S", &tmv);
    char out[48];
    std::snprintf(out, sizeof(out), "%s.%06uZ", buf, us);
    return out;
}

inline std::string iso_now() { return iso_time(host_unix_us()); }

// Compact filename stamp: "%Y%m%d%H%M%S" in UTC — matches `date -u "+%Y%m%d%H%M%S"` and the
// radiometer file-naming contract <PREFIX><YYYYMMDDHHmmss>_ch{0,1}.dat. Deliberately stays
// 14 digits with no zone marker: every downstream parser matches \d{14}.
inline std::string stamp_compact(uint64_t unix_us) {
    const std::time_t secs = static_cast<std::time_t>(unix_us / 1000000ull);
    const std::tm tmv = utc_tm(secs);
    char buf[20];
    std::strftime(buf, sizeof(buf), "%Y%m%d%H%M%S", &tmv);
    return buf;
}

inline std::string stamp_now() { return stamp_compact(host_unix_us()); }

// Per-run folder stamps. A run's output lands in <root>/<YYYYMMDD>/<HHMMSS>/, split into a date
// folder and a time folder so successive runs group by day. UTC, matching the capture
// filename convention (stamp_compact / utc_tm) — day boundaries are UTC midnight. Sample
// host_unix_us() ONCE and pass the same value to both so a run that straddles midnight does not
// split across two date folders.
inline std::string date_folder(uint64_t unix_us) {
    const std::time_t secs = static_cast<std::time_t>(unix_us / 1000000ull);
    const std::tm tmv = utc_tm(secs);
    char buf[16];
    std::strftime(buf, sizeof(buf), "%Y%m%d", &tmv);
    return buf;
}

inline std::string time_folder(uint64_t unix_us) {
    const std::time_t secs = static_cast<std::time_t>(unix_us / 1000000ull);
    const std::tm tmv = utc_tm(secs);
    char buf[16];
    std::strftime(buf, sizeof(buf), "%H%M%S", &tmv);
    return buf;
}

// Collision-free capture stamp. Capture files are named
// <save_root>/<prefix><stamp>_ch{k}.dat with a 14-digit whole-second UTC stamp (stamp_compact),
// so two captures inside the same wall-clock second would silently collide (only possible if a
// config sets duration_s < 1 s). Start from the current host time and, while a ch0 file with the
// candidate stamp already exists, advance the candidate by +1 s and re-format. Bounded at 60
// probes; returns an empty string if exhausted, which the caller treats as a fatal per-capture
// error. Uses <filesystem> so the UHD-free core compile-checks it under MSVC even though the
// driver call site is Pi-build-only.
inline std::string unique_capture_stamp(const std::string& save_root, const std::string& prefix) {
    constexpr int kMaxStampAttempts = 60;
    uint64_t t_us = host_unix_us();
    for (int attempt = 0; attempt < kMaxStampAttempts; ++attempt) {
        std::string stamp = stamp_compact(t_us);
        const std::filesystem::path probe =
            std::filesystem::path(save_root) / (prefix + stamp + "_ch0.dat");
        std::error_code ec;
        if (!std::filesystem::exists(probe, ec)) return stamp;
        t_us += 1000000ull;  // advance one whole second and re-format
    }
    return std::string();  // exhausted — caller aborts the capture
}

}  // namespace cryosoop

#endif  // CRYOSOOP_COMMON_TYPES_HPP
