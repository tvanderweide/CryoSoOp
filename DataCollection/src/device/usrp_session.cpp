// usrp_session.cpp — see usrp_session.hpp.

#include "device/usrp_session.hpp"

#include <uhd/types/device_addr.hpp>
#include <uhd/types/sensors.hpp>
#include <uhd/types/time_spec.hpp>
#include <uhd/usrp/subdev_spec.hpp>
#include <uhd/utils/thread.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <thread>

#include "common/types.hpp"

namespace cryosoop {

namespace {

// External-reference lock wait, in seconds. The deployed radiometer runs on the internal clock
// (clk_ref: internal), so this timeout only applies to the dormant external-reference path.
constexpr double kClockLockTimeoutS = 1.0;

// Convert the space-split "0 1" channel vector from config (std::vector<int>) into UHD's
// std::vector<size_t>. Order is preserved (it maps streamer channel index -> frontend).
std::vector<size_t> to_size_t(const std::vector<int>& v) {
    std::vector<size_t> out;
    out.reserve(v.size());
    for (int x : v) out.push_back(static_cast<size_t>(x));
    return out;
}

}  // namespace

double UsrpSession::get_time_now_s() const {
    return usrp_->get_time_now().get_real_secs();
}

void UsrpSession::set_realtime_priority(EventLog& log) {
    // uhd::set_thread_priority_safe never throws; it returns false if the OS denied the request
    // (e.g. running unprivileged). On the Pi the collector runs with the needed rtprio limits.
    if (!uhd::set_thread_priority_safe()) {
        log.warn("set_thread_priority_safe() failed (need rtprio ulimit / privileges?); "
                 "continuing at normal priority.");
    }
}

void UsrpSession::anchor_time(EventLog& log) {
    // Default (host_now) latches the device time immediately; TIMEBASE.anchor=next_pps latches on
    // the (internal) PPS edge instead. Inter-channel DDC alignment for the two RX channels is
    // established by the timed START_CONTINUOUS in the driver, not by this anchor.
    if (use_pps_anchor_) {
        usrp_->set_time_unknown_pps(uhd::time_spec_t(0.0));
        log.event(ev::TIME_ANCHOR, EventLog::kNaN, EventLog::kNaN, "", -1, "next_pps",
                  "set_time_unknown_pps(0)");
    } else {
        usrp_->set_time_now(uhd::time_spec_t(0.0));
        log.event(ev::TIME_ANCHOR, EventLog::kNaN, EventLog::kNaN, "", -1, "host_now",
                  "set_time_now(0)");
    }
}

void UsrpSession::setup(const Config& cfg, EventLog& log) {
    rx_channels_ = to_size_t(cfg.device.rx_channels);
    if (rx_channels_.empty())
        throw std::runtime_error("DEVICE.rx_channels is empty; no RX channel to stream.");

    // ---- open device -----------------------------------------------------------------------
    log.info("Opening B210 with device_args: " + cfg.device.device_args);
    usrp_ = uhd::usrp::multi_usrp::make(uhd::device_addr_t(cfg.device.device_args));
    if (!usrp_) throw std::runtime_error("multi_usrp::make returned null");

    // ---- subdev spec (frontend mapping) ----------------------------------------------------
    // RX spec from the DEVICE.subdev string ("A:A A:B" = both frontends).
    if (!cfg.device.subdev.empty())
        usrp_->set_rx_subdev_spec(uhd::usrp::subdev_spec_t(cfg.device.subdev));

    // ---- master clock rate -----------------------------------------------------------------
    // "auto": DO NOT call set_master_clock_rate — let UHD derive it from the sample rate exactly
    // as the deployed systems do (scientifically load-bearing; see config comments). Otherwise set
    // it explicitly. Either way read it back and log it so it is never silently different.
    if (!cfg.device.master_clock_rate.is_auto) {
        usrp_->set_master_clock_rate(cfg.device.master_clock_rate.value);
    }
    master_clock_rate_ = usrp_->get_master_clock_rate();
    {
        char buf[64];
        std::snprintf(buf, sizeof(buf), "%.6f", master_clock_rate_);
        log.event(ev::MASTER_CLOCK, EventLog::kNaN, EventLog::kNaN, "", -1, buf,
                  cfg.device.master_clock_rate.is_auto ? "auto (UHD-derived)" : "explicit");
        log.info(std::string("Master clock rate: ") + buf + " Hz");
    }

    // ---- sample rate (BEFORE creating streamers) -------------------------------------------
    // RADIOMETER.rate on every RX channel. Guard against silent rate coercion (|actual - requested|
    // > 1 Hz is fatal) — a coerced rate would desynchronise the sample-count stop.
    const double want_rate = cfg.radiometer.rate;
    for (size_t ch : rx_channels_) usrp_->set_rx_rate(want_rate, ch);
    actual_rate_ = usrp_->get_rx_rate(rx_channels_.front());
    if (std::fabs(actual_rate_ - want_rate) > kRateCoerceTolHz) {
        char buf[128];
        std::snprintf(buf, sizeof(buf), "requested RX rate %.3f Hz, device coerced to %.3f Hz",
                      want_rate, actual_rate_);
        throw std::runtime_error(std::string("rate coercion beyond tolerance: ") + buf);
    }
    log.info("Sample rate: " + std::to_string(actual_rate_ / 1e6) + " Msps");

    // ---- clock / time reference ------------------------------------------------------------
    // clk_ref -> clock source (10 MHz reference); pps_ref -> time source (PPS). When clk_ref is
    // not "internal" we must wait for ref_locked before trusting the timebase.
    if (!cfg.device.clk_ref.empty()) usrp_->set_clock_source(cfg.device.clk_ref);
    if (!cfg.device.pps_ref.empty()) usrp_->set_time_source(cfg.device.pps_ref);

    if (!cfg.device.clk_ref.empty() && cfg.device.clk_ref != "internal") {
        const double timeout_s = kClockLockTimeoutS;
        const auto t0 = std::chrono::steady_clock::now();
        bool locked = false;
        const size_t nmb = usrp_->get_num_mboards();
        while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() <
               timeout_s) {
            bool all = true;
            for (size_t mb = 0; mb < nmb; ++mb) {
                const auto names = usrp_->get_mboard_sensor_names(mb);
                if (std::find(names.begin(), names.end(), "ref_locked") != names.end())
                    all = all && usrp_->get_mboard_sensor("ref_locked", mb).to_bool();
            }
            if (all) { locked = true; break; }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        log.event(ev::CLOCK_LOCK, EventLog::kNaN, EventLog::kNaN, "", -1,
                  locked ? "locked" : "TIMEOUT", cfg.device.clk_ref);
        if (!locked)
            throw std::runtime_error("reference clock '" + cfg.device.clk_ref +
                                     "' never locked within the clock-lock timeout");
    }

    // ---- device-time anchor ----------------------------------------------------------------
    use_pps_anchor_ = (cfg.timebase.anchor == "next_pps");
    anchor_time(log);

    // ---- RX streamer (created ONCE, reused across all captures) ----------------------------
    uhd::stream_args_t rx_args(cfg.device.cpu_format, cfg.device.otw_format);
    rx_args.channels = rx_channels_;
    rx_stream_ = usrp_->get_rx_stream(rx_args);
    log.info("Radiometer RX streamer: cpu=" + cfg.device.cpu_format + " otw=" +
             cfg.device.otw_format + " (" + std::to_string(rx_channels_.size()) + " ch)");

    // Realtime priority on this (the recv/producer) thread.
    set_realtime_priority(log);
}

}  // namespace cryosoop
