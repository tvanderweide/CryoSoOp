// run_control.hpp — process-lifecycle glue: SIGINT/SIGTERM handling, duration
// deadlines, and the exec_hook() shell wrapper used for out-of-band state changes.
//
// The stop flag is a global sig_atomic_t set from the signal handler (async-signal-safe), plus a
// std::atomic mirror so worker threads can poll cheaply without racing. Drivers poll
// stop_requested() at band/chunk boundaries for a clean stop (GPIO cleanup, drain, summary).
//
// exec_hook() runs a shell command via std::system and returns its exit code. It is used for the
// radiometer state_cmd (SSH-to-BeagleBone GPIO switch). It BLOCKS and
// must NEVER be called from the RX hot path — only from the driver control thread between
// captures. Documented here and at the call sites.

#ifndef CRYOSOOP_COMMON_RUN_CONTROL_HPP
#define CRYOSOOP_COMMON_RUN_CONTROL_HPP

#include <chrono>
#include <string>

namespace cryosoop {
namespace run_control {

// Install SIGINT + SIGTERM handlers (POSIX sigaction on Linux, signal() on Windows). Idempotent.
void install_signal_handlers();

// True once a stop has been requested (signal or explicit request_stop()).
bool stop_requested();

// Request a clean stop programmatically (e.g. an internal abort). `reason` is stored for the
// summary and is optional. Safe to call from any thread; first reason wins.
void request_stop(const char* reason = nullptr);

// The reason recorded by the first stop request ("SIGINT", "SIGTERM", or a caller string), or ""
// if none / stop not requested.
std::string stop_reason();

// A steady-clock deadline. `none()` never expires (cron single-sweep with no --duration).
class Deadline {
public:
    Deadline() : active_(false) {}

    static Deadline in_seconds(double seconds) {
        Deadline d;
        d.active_ = true;
        d.end_ = std::chrono::steady_clock::now() +
                 std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                     std::chrono::duration<double>(seconds));
        return d;
    }
    static Deadline none() { return Deadline(); }

    bool active() const { return active_; }
    bool expired() const {
        return active_ && std::chrono::steady_clock::now() >= end_;
    }
    // Seconds until expiry (<=0 if expired); a large sentinel if inactive.
    double remaining_s() const {
        if (!active_) return 1e18;
        return std::chrono::duration<double>(end_ - std::chrono::steady_clock::now()).count();
    }

private:
    bool active_;
    std::chrono::steady_clock::time_point end_{};
};

// Run a shell command, blocking until it finishes. Returns the process exit code (0 == success),
// or -1 if the command could not be launched. NEVER call from the RX hot path.
int exec_hook(const std::string& cmd);

}  // namespace run_control
}  // namespace cryosoop

#endif  // CRYOSOOP_COMMON_RUN_CONTROL_HPP
