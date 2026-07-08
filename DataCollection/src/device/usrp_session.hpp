// usrp_session.hpp — owns the uhd::usrp::multi_usrp handle plus the RX streamer.
//
// This is the single place where the device is opened and clocked. It mirrors the setup steps of
// the reference program (SoOp_StressTest rx_stress_capture.cpp:241-345) concentrated in one
// UHD-heavy translation unit.
//
// Setup order (see setup()):
//   make(device_args) -> subdev spec -> master_clock_rate (skip when "auto") -> read back MCR ->
//   sample rate (before streamers, with a hard rate-coercion guard) -> clock/time source with a
//   ref_locked wait when clk_ref != internal -> device-time anchor -> RX streamer -> RT priority.
//
// Everything per-frequency (tune, lo_lock) lives in rf_control; everything per-capture lives in
// the driver. This object is created ONCE per process and reused across all captures — the
// single-session requirement is load-bearing for the radiometer's inter-channel phase stability
// (NL phase calibration).

#ifndef CRYOSOOP_DEVICE_USRP_SESSION_HPP
#define CRYOSOOP_DEVICE_USRP_SESSION_HPP

#include <uhd/usrp/multi_usrp.hpp>

#include <cstddef>
#include <string>
#include <vector>

#include "common/config.hpp"
#include "common/event_log.hpp"

namespace cryosoop {

class UsrpSession {
public:
    UsrpSession() = default;

    // Open and configure the device from `cfg`. Emits MASTER_CLOCK / CLOCK_LOCK / TIME_ANCHOR rows
    // to `log`. Throws std::runtime_error on any fatal setup failure (bad device, ref-lock
    // timeout, rate coercion beyond 1 Hz) — the driver catches this and reports exit code 2.
    void setup(const Config& cfg, EventLog& log);

    // Accessors (valid only after a successful setup()).
    uhd::usrp::multi_usrp::sptr usrp() const { return usrp_; }
    uhd::rx_streamer::sptr rx_stream() const { return rx_stream_; }

    double master_clock_rate() const { return master_clock_rate_; }
    double actual_rate() const { return actual_rate_; }
    const std::vector<size_t>& rx_channels() const { return rx_channels_; }

    // Current device time in seconds (get_time_now). Used for capture scheduling.
    double get_time_now_s() const;

    // Set realtime scheduling priority on the *current* thread (the recv/producer thread). Safe
    // no-throw wrapper around uhd::set_thread_priority_safe; logs a warning on failure.
    static void set_realtime_priority(EventLog& log);

private:
    void anchor_time(EventLog& log);  // apply the device-time anchor per TIMEBASE.anchor

    uhd::usrp::multi_usrp::sptr usrp_;
    uhd::rx_streamer::sptr rx_stream_;
    std::vector<size_t> rx_channels_;
    double master_clock_rate_ = 0.0;
    double actual_rate_ = 0.0;
    bool use_pps_anchor_ = false;  // set_time_unknown_pps vs set_time_now
};

}  // namespace cryosoop

#endif  // CRYOSOOP_DEVICE_USRP_SESSION_HPP
