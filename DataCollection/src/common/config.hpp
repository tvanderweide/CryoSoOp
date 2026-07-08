// config.hpp — typed configuration for cryosoop (radiometer-only), parsed from YAML (yaml-cpp).
//
// One YAML file drives the whole program. The `mode:` key is kept and MUST be `radiometer`;
// anything else is rejected (this binary is radiometer-only; the snow-radar acquisition is a
// separate project). Sections: MODE, DEVICE, FILES, RING, TIMEBASE, RADIOMETER, CAL,
// DISK. Every key, unit, default, and consumer is documented in config/SCHEMA.md; this header is
// the typed mirror.
//
// Loading is strict: unknown keys inside a known section are rejected (with an edit-distance
// "did you mean" hint) and enum-valued keys are validated. No UHD here.

#ifndef CRYOSOOP_COMMON_CONFIG_HPP
#define CRYOSOOP_COMMON_CONFIG_HPP

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace cryosoop {

// master_clock_rate: "auto" (let UHD derive it from the sample rate — scientifically
// load-bearing, the measured 105.7 deg phase comb ties to the master clock) or an explicit Hz.
struct MasterClockRate {
    bool is_auto = true;
    double value = 0.0;  // valid only when !is_auto
};

struct DeviceCfg {
    std::string device_args =
        "num_recv_frames=700,num_send_frames=700,recv_frame_size=10000,send_frame_size=10000";
    std::string subdev = "A:A A:B";
    std::string clk_ref = "internal";
    std::string pps_ref = "internal";
    MasterClockRate master_clock_rate;   // "auto" by default
    std::vector<int> tx_channels{0, 1};  // space-split "0 1"; unused by RX-only radiometer, kept for symmetry
    std::vector<int> rx_channels{0, 1};  // space-split "0 1"
    std::string cpu_format = "sc16";     // fc32 | sc16 | sc8
    std::string otw_format = "sc16";     // sc16 | sc12 | sc8
    int rx_timeout_limit = 3;            // consecutive 1 s recv timeouts before declaring a problem
};

struct FilesCfg {
    std::string save_loc = "data/B210/";
};

struct RingCfg {
    double ring_mb = 8192.0;             // [MiB] 8 GiB default (dedicated 16 GB radiometer Pi)
    std::string on_full = "drop_newest"; // radiometer policy is fixed to drop_newest
    double sync_every_mb = 64.0;         // page-cache flush watermark per file
};

struct TimebaseCfg {
    std::string anchor = "host_now";     // host_now | next_pps
    std::string events_csv = "events.csv";
    std::string human_log = "RunLog.log";
};

struct RadiometerStep {
    std::string state;                   // free text label (NL | L | Signal | ...)
    std::string prefix;                  // file prefix (e.g. "UHF__NL_")
    int count = 1;                       // captures in this step
    double duration_s = 2.0;             // [s] per capture
    std::string state_cmd;               // SSH-to-BBB GPIO command (may be empty)
    std::string on_cmd_fail = "abort";   // abort | continue
};

struct RadiometerCfg {
    double freq = 370e6;                 // [Hz]
    double rate = 20e6;                  // [Hz]
    double gain = 54.0;                  // [dB]
    std::optional<double> bw;            // [Hz] default = rate if unset
    std::string rx_ant = "RX2";
    double chunk_secs = 10.0;            // [s] file rotation period
    double settle_s = 2.0;               // [s] settle after a state_cmd before capturing
    double lo_lock_timeout_s = 2.0;      // [s] lo_locked poll timeout at device setup
    double lo_lock_poll_s = 0.1;         // [s] lo_locked poll interval at device setup
    int max_stream_errors = 10;          // unclassified stream errors before aborting a capture
    std::string final_state_cmd;         // restore state at end of sequence
    std::vector<RadiometerStep> sequence;
};

struct CalCfg {
    bool common_source_captures = false; // reserved: per-session common-source cal step (config-gated no-op)
};

struct DiskCfg {
    double disk_floor_gb = 8.0;          // graceful abort below this free space
    double nvme_min_mbps = 400.0;        // pre-flight throughput floor (probe_nvme)
};

class Config {
public:
    std::string mode = "radiometer";     // MODE : radiometer (only)
    DeviceCfg device;
    FilesCfg files;
    RingCfg ring;
    TimebaseCfg timebase;
    RadiometerCfg radiometer;
    CalCfg cal;
    DiskCfg disk;

    // Runtime overrides (from CLI, not YAML). duration_s unset -> run the full sequence; set ->
    // one long Signal capture of duration_s seconds.
    std::optional<double> duration_s;

    // ---- load / validate --------------------------------------------------
    // Parse `path`. Appends messages to `errors`/`warnings`. Returns true iff no errors (the
    // Config is still populated on failure, for diagnostics). Validation covers unknown keys,
    // enum values, the radiometer-only MODE rule, and per-step positivity.
    static Config from_file(const std::string& path, std::vector<std::string>& errors,
                            std::vector<std::string>& warnings);

    // Re-run validation on the current (possibly CLI-overridden) values.
    bool validate(std::vector<std::string>& errors, std::vector<std::string>& warnings) const;

    // ---- CLI override entry points ---------------------------------------
    void set_ring_mb(double mb) { ring.ring_mb = mb; }
    void set_save_loc(const std::string& loc) { files.save_loc = loc; }
    void set_duration(double seconds) { duration_s = seconds; }

    // ---- effective config dump -------------------------------------------
    // Write the fully-resolved config to `path` as YAML (config_effective.yaml). Note:
    // DEVICE.master_clock_rate stays "auto" here if auto — the *actual* MCR is only known at
    // device time and is logged to events.csv (MASTER_CLOCK) by the driver.
    bool dump_effective(const std::string& path) const;
};

}  // namespace cryosoop

#endif  // CRYOSOOP_COMMON_CONFIG_HPP
