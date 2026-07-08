// config.cpp — Config parse / validate / dump. See config.hpp and config/SCHEMA.md.
//
// The only third-party dependency is yaml-cpp. Parsing is deliberately strict: every known
// section has an explicit allowed-key list, and any key not on it is reported with an
// edit-distance "did you mean" hint (guards against silent typos like `chnk_secs`).

#include "config.hpp"

#include <yaml-cpp/yaml.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <initializer_list>
#include <sstream>

namespace cryosoop {

namespace {

// ---------------------------------------------------------------- string helpers
std::vector<int> parse_int_list(const std::string& s) {
    std::vector<int> out;
    std::istringstream ss(s);
    int v;
    while (ss >> v) out.push_back(v);  // whitespace-split "0 1"
    return out;
}

// Levenshtein edit distance, for near-miss key suggestions.
std::size_t levenshtein(const std::string& a, const std::string& b) {
    const std::size_t n = a.size(), m = b.size();
    std::vector<std::size_t> prev(m + 1), cur(m + 1);
    for (std::size_t j = 0; j <= m; ++j) prev[j] = j;
    for (std::size_t i = 1; i <= n; ++i) {
        cur[0] = i;
        for (std::size_t j = 1; j <= m; ++j) {
            const std::size_t cost = (a[i - 1] == b[j - 1]) ? 0 : 1;
            cur[j] = std::min({prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost});
        }
        std::swap(prev, cur);
    }
    return prev[m];
}

// Nearest allowed key within a small edit distance, or "" if none is close enough.
std::string nearest_key(const std::string& unknown, const std::vector<std::string>& allowed) {
    std::string best;
    std::size_t best_d = 3;  // only suggest reasonably close matches
    for (const auto& k : allowed) {
        const std::size_t d = levenshtein(unknown, k);
        if (d < best_d) { best_d = d; best = k; }
    }
    return best;
}

// Reject unknown keys in a known section, with suggestions.
void check_keys(const YAML::Node& sec, const char* section,
                const std::vector<std::string>& allowed, std::vector<std::string>& err) {
    if (!sec || !sec.IsMap()) return;
    for (const auto& kv : sec) {
        const std::string key = kv.first.as<std::string>();
        if (std::find(allowed.begin(), allowed.end(), key) != allowed.end()) continue;
        std::string msg = std::string(section) + ": unknown key '" + key + "'";
        const std::string suggest = nearest_key(key, allowed);
        if (!suggest.empty()) msg += " (did you mean '" + suggest + "'?)";
        err.push_back(msg);
    }
}

// ---------------------------------------------------------------- typed field readers
bool present(const YAML::Node& sec, const char* key) {
    return sec && sec[key] && !sec[key].IsNull();
}

void rd_double(const YAML::Node& sec, const char* key, double& out, const char* section,
               std::vector<std::string>& err) {
    if (!present(sec, key)) return;
    try { out = sec[key].as<double>(); }
    catch (const std::exception&) { err.push_back(std::string(section) + "." + key + ": expected a number"); }
}
void rd_opt_double(const YAML::Node& sec, const char* key, std::optional<double>& out,
                   const char* section, std::vector<std::string>& err) {
    if (!present(sec, key)) return;
    try { out = sec[key].as<double>(); }
    catch (const std::exception&) { err.push_back(std::string(section) + "." + key + ": expected a number"); }
}
void rd_int(const YAML::Node& sec, const char* key, int& out, const char* section,
            std::vector<std::string>& err) {
    if (!present(sec, key)) return;
    try { out = sec[key].as<int>(); }
    catch (const std::exception&) { err.push_back(std::string(section) + "." + key + ": expected an integer"); }
}
void rd_bool(const YAML::Node& sec, const char* key, bool& out, const char* section,
             std::vector<std::string>& err) {
    if (!present(sec, key)) return;
    try { out = sec[key].as<bool>(); }
    catch (const std::exception&) { err.push_back(std::string(section) + "." + key + ": expected true/false"); }
}
void rd_string(const YAML::Node& sec, const char* key, std::string& out, const char* section,
               std::vector<std::string>& err) {
    if (!present(sec, key)) return;
    try { out = sec[key].as<std::string>(); }
    catch (const std::exception&) { err.push_back(std::string(section) + "." + key + ": expected a string"); }
}

bool check_enum(const char* section, const char* key, const std::string& val,
                std::initializer_list<const char*> allowed, std::vector<std::string>& err) {
    for (const char* a : allowed) if (val == a) return true;
    std::string msg = std::string(section) + "." + key + ": invalid value '" + val + "' (allowed:";
    for (const char* a : allowed) msg += std::string(" ") + a;
    msg += ")";
    err.push_back(msg);
    return false;
}

// "%.10g" formatting: compact yet round-trip-safe for the effective-config dump.
std::string num(double v) {
    char b[32];
    std::snprintf(b, sizeof(b), "%.10g", v);
    return b;
}

}  // namespace

// ============================================================ from_file
Config Config::from_file(const std::string& path, std::vector<std::string>& errors,
                         std::vector<std::string>& warnings) {
    Config cfg;
    YAML::Node root;
    try {
        root = YAML::LoadFile(path);
    } catch (const std::exception& e) {
        errors.push_back(std::string("cannot load YAML '") + path + "': " + e.what());
        return cfg;
    }
    if (!root || !root.IsMap()) {
        errors.push_back("top-level YAML is not a mapping");
        return cfg;
    }

    // Allowed top-level sections (unknown top-level keys are also flagged). `_derived` and
    // `duration_s` are tolerated (ignored) so a config_effective.yaml written by dump_effective
    // re-parses cleanly: `duration_s` is a CLI-only override that dump_effective echoes back, and
    // `_derived` is tolerated for backward compatibility with older effective dumps.
    check_keys(root, "(root)",
               {"MODE", "DEVICE", "FILES", "RING", "TIMEBASE", "RADIOMETER", "CAL", "DISK",
                "_derived", "duration_s"},
               errors);

    // ---- MODE ----
    if (present(root, "MODE")) {
        rd_string(root, "MODE", cfg.mode, "(root)", errors);
    }

    // ---- DEVICE ----
    if (root["DEVICE"]) {
        const YAML::Node d = root["DEVICE"];
        check_keys(d, "DEVICE",
                   {"device_args", "subdev", "clk_ref", "pps_ref", "master_clock_rate",
                    "tx_channels", "rx_channels", "cpu_format", "otw_format", "rx_timeout_limit"},
                   errors);
        rd_string(d, "device_args", cfg.device.device_args, "DEVICE", errors);
        rd_string(d, "subdev", cfg.device.subdev, "DEVICE", errors);
        rd_string(d, "clk_ref", cfg.device.clk_ref, "DEVICE", errors);
        rd_string(d, "pps_ref", cfg.device.pps_ref, "DEVICE", errors);
        if (present(d, "master_clock_rate")) {
            std::string s;
            try { s = d["master_clock_rate"].as<std::string>(); } catch (...) {}
            if (s == "auto" || s == "AUTO" || s == "Auto") {
                cfg.device.master_clock_rate.is_auto = true;
            } else {
                try {
                    cfg.device.master_clock_rate.value = d["master_clock_rate"].as<double>();
                    cfg.device.master_clock_rate.is_auto = false;
                } catch (...) {
                    errors.push_back("DEVICE.master_clock_rate: expected 'auto' or a number");
                }
            }
        }
        std::string txs, rxs;
        if (present(d, "tx_channels")) { rd_string(d, "tx_channels", txs, "DEVICE", errors);
            if (!txs.empty()) cfg.device.tx_channels = parse_int_list(txs); }
        if (present(d, "rx_channels")) { rd_string(d, "rx_channels", rxs, "DEVICE", errors);
            if (!rxs.empty()) cfg.device.rx_channels = parse_int_list(rxs); }
        rd_string(d, "cpu_format", cfg.device.cpu_format, "DEVICE", errors);
        rd_string(d, "otw_format", cfg.device.otw_format, "DEVICE", errors);
        rd_int(d, "rx_timeout_limit", cfg.device.rx_timeout_limit, "DEVICE", errors);
        check_enum("DEVICE", "cpu_format", cfg.device.cpu_format, {"fc32", "sc16", "sc8"}, errors);
        check_enum("DEVICE", "otw_format", cfg.device.otw_format, {"sc16", "sc12", "sc8"}, errors);
    }

    // ---- FILES ----
    if (root["FILES"]) {
        const YAML::Node f = root["FILES"];
        check_keys(f, "FILES", {"save_loc"}, errors);
        rd_string(f, "save_loc", cfg.files.save_loc, "FILES", errors);
    }

    // ---- RING ----
    if (root["RING"]) {
        const YAML::Node r = root["RING"];
        check_keys(r, "RING", {"ring_mb", "on_full", "sync_every_mb"}, errors);
        rd_double(r, "ring_mb", cfg.ring.ring_mb, "RING", errors);
        rd_string(r, "on_full", cfg.ring.on_full, "RING", errors);
        rd_double(r, "sync_every_mb", cfg.ring.sync_every_mb, "RING", errors);
        check_enum("RING", "on_full", cfg.ring.on_full, {"drop_newest"}, errors);
    }

    // ---- TIMEBASE ----
    if (root["TIMEBASE"]) {
        const YAML::Node t = root["TIMEBASE"];
        check_keys(t, "TIMEBASE", {"anchor", "events_csv", "human_log"}, errors);
        rd_string(t, "anchor", cfg.timebase.anchor, "TIMEBASE", errors);
        rd_string(t, "events_csv", cfg.timebase.events_csv, "TIMEBASE", errors);
        rd_string(t, "human_log", cfg.timebase.human_log, "TIMEBASE", errors);
        check_enum("TIMEBASE", "anchor", cfg.timebase.anchor, {"host_now", "next_pps"}, errors);
    }

    // ---- RADIOMETER ----
    if (root["RADIOMETER"]) {
        const YAML::Node r = root["RADIOMETER"];
        check_keys(r, "RADIOMETER",
                   {"freq", "rate", "gain", "bw", "rx_ant", "chunk_secs", "settle_s",
                    "lo_lock_timeout_s", "lo_lock_poll_s", "max_stream_errors",
                    "final_state_cmd", "sequence"},
                   errors);
        rd_double(r, "freq", cfg.radiometer.freq, "RADIOMETER", errors);
        rd_double(r, "rate", cfg.radiometer.rate, "RADIOMETER", errors);
        rd_double(r, "gain", cfg.radiometer.gain, "RADIOMETER", errors);
        rd_opt_double(r, "bw", cfg.radiometer.bw, "RADIOMETER", errors);
        rd_string(r, "rx_ant", cfg.radiometer.rx_ant, "RADIOMETER", errors);
        rd_double(r, "chunk_secs", cfg.radiometer.chunk_secs, "RADIOMETER", errors);
        rd_double(r, "settle_s", cfg.radiometer.settle_s, "RADIOMETER", errors);
        rd_double(r, "lo_lock_timeout_s", cfg.radiometer.lo_lock_timeout_s, "RADIOMETER", errors);
        rd_double(r, "lo_lock_poll_s", cfg.radiometer.lo_lock_poll_s, "RADIOMETER", errors);
        rd_int(r, "max_stream_errors", cfg.radiometer.max_stream_errors, "RADIOMETER", errors);
        rd_string(r, "final_state_cmd", cfg.radiometer.final_state_cmd, "RADIOMETER", errors);
        if (present(r, "sequence") && r["sequence"].IsSequence()) {
            cfg.radiometer.sequence.clear();
            int idx = 0;
            for (const auto& step_node : r["sequence"]) {
                const std::string tag = "RADIOMETER.sequence[" + std::to_string(idx) + "]";
                check_keys(step_node, tag.c_str(),
                           {"state", "prefix", "count", "duration_s", "state_cmd", "on_cmd_fail"},
                           errors);
                RadiometerStep step;
                rd_string(step_node, "state", step.state, tag.c_str(), errors);
                rd_string(step_node, "prefix", step.prefix, tag.c_str(), errors);
                rd_int(step_node, "count", step.count, tag.c_str(), errors);
                rd_double(step_node, "duration_s", step.duration_s, tag.c_str(), errors);
                rd_string(step_node, "state_cmd", step.state_cmd, tag.c_str(), errors);
                rd_string(step_node, "on_cmd_fail", step.on_cmd_fail, tag.c_str(), errors);
                check_enum(tag.c_str(), "on_cmd_fail", step.on_cmd_fail, {"abort", "continue"},
                           errors);
                cfg.radiometer.sequence.push_back(std::move(step));
                ++idx;
            }
        }
    }

    // ---- CAL ----
    if (root["CAL"]) {
        const YAML::Node c = root["CAL"];
        check_keys(c, "CAL", {"common_source_captures"}, errors);
        rd_bool(c, "common_source_captures", cfg.cal.common_source_captures, "CAL", errors);
    }

    // ---- DISK ----
    if (root["DISK"]) {
        const YAML::Node d = root["DISK"];
        check_keys(d, "DISK", {"disk_floor_gb", "nvme_min_mbps"}, errors);
        rd_double(d, "disk_floor_gb", cfg.disk.disk_floor_gb, "DISK", errors);
        rd_double(d, "nvme_min_mbps", cfg.disk.nvme_min_mbps, "DISK", errors);
    }

    // Cross-section validation on top of the per-key checks above.
    cfg.validate(errors, warnings);
    return cfg;
}

// ============================================================ validate
bool Config::validate(std::vector<std::string>& errors, std::vector<std::string>& warnings) const {
    const std::size_t before = errors.size();

    // Radiometer-only MODE rule.
    if (mode != "radiometer")
        errors.push_back("MODE must be 'radiometer': the cryosoop binary is radiometer-only; the "
                         "snow-radar acquisition is a separate project.");

    if (radiometer.rate <= 0) errors.push_back("RADIOMETER.rate must be > 0");
    if (radiometer.sequence.empty() && !duration_s.has_value())
        warnings.push_back("RADIOMETER.sequence is empty and no --duration given; nothing to "
                           "capture unless a CLI duration override is supplied.");

    // Each sequence step must capture a positive number of samples.
    for (std::size_t i = 0; i < radiometer.sequence.size(); ++i) {
        const RadiometerStep& s = radiometer.sequence[i];
        const std::string tag = "RADIOMETER.sequence[" + std::to_string(i) + "]";
        if (s.duration_s <= 0.0) errors.push_back(tag + ".duration_s must be > 0");
        if (s.count <= 0) errors.push_back(tag + ".count must be > 0");
        if (s.duration_s > 0.0 && radiometer.rate > 0.0 &&
            std::llround(s.duration_s * radiometer.rate) < 1)
            errors.push_back(tag + ": rate * duration_s < 1 sample (nothing to capture).");
    }

    // If --duration is given, it replaces the sequence with one Signal capture; it must be positive.
    if (duration_s.has_value() && *duration_s <= 0.0)
        errors.push_back("--duration must be > 0 seconds.");

    // on_full is fixed: the radiometer's only ring-full policy is to drop the newest samples.
    if (ring.on_full != "drop_newest")
        errors.push_back("RING.on_full must be 'drop_newest': the radiometer driver drops the "
                         "newest samples when the ring fills.");

    return errors.size() == before;
}

// ============================================================ dump_effective
bool Config::dump_effective(const std::string& path) const {
    std::ofstream o(path);
    if (!o.is_open()) return false;

    auto qs = [](const std::string& s) { return std::string("\"") + s + "\""; };
    auto tf = [](bool b) { return b ? "true" : "false"; };

    o << "# CryoSoOp effective (fully-resolved) configuration.\n";
    o << "# Generated by Config::dump_effective. NOTE: DEVICE.master_clock_rate stays 'auto' here\n";
    o << "# if auto; the actual master clock rate is only known at device time and is logged to\n";
    o << "# events.csv (MASTER_CLOCK) by the driver.\n\n";

    o << "MODE: " << qs(mode) << "\n\n";

    o << "DEVICE:\n";
    o << "    device_args: " << qs(device.device_args) << "\n";
    o << "    subdev: " << qs(device.subdev) << "\n";
    o << "    clk_ref: " << qs(device.clk_ref) << "\n";
    o << "    pps_ref: " << qs(device.pps_ref) << "\n";
    o << "    master_clock_rate: "
      << (device.master_clock_rate.is_auto ? std::string("\"auto\"")
                                            : num(device.master_clock_rate.value))
      << "\n";
    auto join_ints = [](const std::vector<int>& v) {
        std::string s;
        for (std::size_t i = 0; i < v.size(); ++i) { if (i) s += " "; s += std::to_string(v[i]); }
        return s;
    };
    o << "    tx_channels: " << qs(join_ints(device.tx_channels)) << "\n";
    o << "    rx_channels: " << qs(join_ints(device.rx_channels)) << "\n";
    o << "    cpu_format: " << qs(device.cpu_format) << "\n";
    o << "    otw_format: " << qs(device.otw_format) << "\n";
    o << "    rx_timeout_limit: " << device.rx_timeout_limit << "\n\n";

    o << "FILES:\n";
    o << "    save_loc: " << qs(files.save_loc) << "\n\n";

    o << "RING:\n";
    o << "    ring_mb: " << num(ring.ring_mb) << "\n";
    o << "    on_full: " << qs(ring.on_full) << "\n";
    o << "    sync_every_mb: " << num(ring.sync_every_mb) << "\n\n";

    o << "TIMEBASE:\n";
    o << "    anchor: " << qs(timebase.anchor) << "\n";
    o << "    events_csv: " << qs(timebase.events_csv) << "\n";
    o << "    human_log: " << qs(timebase.human_log) << "\n\n";

    o << "RADIOMETER:\n";
    o << "    freq: " << num(radiometer.freq) << "\n";
    o << "    rate: " << num(radiometer.rate) << "\n";
    o << "    gain: " << num(radiometer.gain) << "\n";
    if (radiometer.bw) o << "    bw: " << num(*radiometer.bw) << "\n";
    o << "    rx_ant: " << qs(radiometer.rx_ant) << "\n";
    o << "    chunk_secs: " << num(radiometer.chunk_secs) << "\n";
    o << "    settle_s: " << num(radiometer.settle_s) << "\n";
    o << "    lo_lock_timeout_s: " << num(radiometer.lo_lock_timeout_s) << "\n";
    o << "    lo_lock_poll_s: " << num(radiometer.lo_lock_poll_s) << "\n";
    o << "    max_stream_errors: " << radiometer.max_stream_errors << "\n";
    o << "    final_state_cmd: " << qs(radiometer.final_state_cmd) << "\n";
    o << "    sequence:\n";
    for (const auto& s : radiometer.sequence) {
        o << "        - state: " << qs(s.state) << "\n";
        o << "          prefix: " << qs(s.prefix) << "\n";
        o << "          count: " << s.count << "\n";
        o << "          duration_s: " << num(s.duration_s) << "\n";
        o << "          state_cmd: " << qs(s.state_cmd) << "\n";
        o << "          on_cmd_fail: " << qs(s.on_cmd_fail) << "\n";
    }
    o << "\n";

    o << "CAL:\n";
    o << "    common_source_captures: " << tf(cal.common_source_captures) << "\n\n";

    o << "DISK:\n";
    o << "    disk_floor_gb: " << num(disk.disk_floor_gb) << "\n";
    o << "    nvme_min_mbps: " << num(disk.nvme_min_mbps) << "\n\n";

    if (duration_s) o << "# CLI override\nduration_s: " << num(*duration_s) << "\n";
    return static_cast<bool>(o);
}

}  // namespace cryosoop
