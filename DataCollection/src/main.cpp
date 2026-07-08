// main.cpp — cryosoop entry point: parse argv, load + override config, open logs, write the
// effective config, run the radiometer sequence, emit SUMMARY_JSON, return the summary exit code.
//
// This binary is radiometer-only (the SoOp P-band signals-of-opportunity system). The config
// `mode:` key is kept and validated: it MUST be `radiometer`, otherwise the run is rejected with a
// clear error. The snow-radar acquisition is a separate project.
//
// CLI (hand-rolled, no getopt):
//   --config <path>    (required) YAML configuration file
//   --duration <s>     run one long capture of N seconds instead of the full sequence
//   --until-stopped    repeat the sequence until SIGINT/SIGTERM at a clean boundary
//   --ring-mb <n>      override RING.ring_mb
//   --save-loc <dir>   acquisition root; a per-run <YYYYMMDD>/<HHMMSS>/ subfolder is created
//                      under it holding events.csv, summary.json, config_effective.yaml, and the
//                      per-channel .dat files
//   --help
//
// Exit codes are exactly 0/1/2 (summary.hpp policy).

#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "common/config.hpp"
#include "common/event_log.hpp"
#include "common/run_control.hpp"
#include "common/summary.hpp"
#include "common/types.hpp"
#include "radiometer_driver.hpp"

namespace {

namespace fs = std::filesystem;

void print_usage() {
    std::cout <<
        "cryosoop --config <path> [options]\n"
        "  --config <path>     YAML config (required; MODE must be radiometer)\n"
        "  --duration <s>      run one long capture of N seconds instead of the full sequence\n"
        "  --until-stopped     repeat the sequence until SIGINT/SIGTERM at a clean boundary\n"
        "  --ring-mb <n>       override RING.ring_mb\n"
        "  --save-loc <dir>    acquisition root (per-run <YYYYMMDD>/<HHMMSS>/ subfolder created here)\n"
        "  --help\n";
}

// Fetch the value following a flag; prints an error and returns false if missing.
bool need_value(int argc, char** argv, int& i, const char* flag, std::string& out) {
    if (i + 1 >= argc) {
        std::cerr << "error: " << flag << " requires a value\n";
        return false;
    }
    out = argv[++i];
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    using namespace cryosoop;

    std::string config_path;
    std::string save_loc_override;
    bool have_duration = false;
    double duration = 0.0;
    bool have_ring_mb = false;
    double ring_mb = 0.0;
    bool until_stopped = false;

    // ---- arg parsing -----------------------------------------------------------------------
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        std::string v;
        if (a == "--help" || a == "-h") { print_usage(); return 0; }
        else if (a == "--config") { if (!need_value(argc, argv, i, "--config", config_path)) return 2; }
        else if (a == "--duration") {
            if (!need_value(argc, argv, i, "--duration", v)) return 2;
            duration = std::atof(v.c_str());
            have_duration = true;
        } else if (a == "--ring-mb") {
            if (!need_value(argc, argv, i, "--ring-mb", v)) return 2;
            ring_mb = std::atof(v.c_str());
            have_ring_mb = true;
        } else if (a == "--save-loc") {
            if (!need_value(argc, argv, i, "--save-loc", save_loc_override)) return 2;
        } else if (a == "--until-stopped") {
            until_stopped = true;
        } else {
            std::cerr << "error: unknown argument '" << a << "'\n";
            print_usage();
            return 2;
        }
    }
    if (config_path.empty()) {
        std::cerr << "error: --config is required\n";
        print_usage();
        return 2;
    }

    // ---- load config -----------------------------------------------------------------------
    std::vector<std::string> errors, warnings;
    Config cfg = Config::from_file(config_path, errors, warnings);
    for (const auto& w : warnings) std::cerr << "warning: " << w << "\n";
    if (!errors.empty()) {
        for (const auto& e : errors) std::cerr << "config error: " << e << "\n";
        return 2;
    }

    // ---- apply CLI overrides, then re-validate ---------------------------------------------
    if (have_duration) cfg.set_duration(duration);
    if (have_ring_mb) cfg.set_ring_mb(ring_mb);
    if (!save_loc_override.empty()) cfg.set_save_loc(save_loc_override);
    {
        std::vector<std::string> verrs, vwarn;
        if (!cfg.validate(verrs, vwarn)) {
            for (const auto& e : verrs) std::cerr << "config error: " << e << "\n";
            return 2;
        }
        for (const auto& w : vwarn) std::cerr << "warning: " << w << "\n";
    }

    // ---- resolve the acquisition root ------------------------------------------------------
    // Both modes create a per-run folder <root>/<YYYYMMDD>/<HHMMSS>/ so every run keeps its own
    // events.csv / RunLog.log / config_effective.yaml / summary.json / .dat files instead of
    // appending or overwriting across runs. `root` = --save-loc if given, else FILES.save_loc. The
    // cron orchestrator still passes --save-loc "$DATA_DIR"; the binary now creates the dated run
    // subfolders under it (no orchestration change needed). Folder stamps are UTC (types.hpp), so
    // the day boundary is UTC midnight — local evening runs land under the next UTC date. One
    // host_unix_us() sample feeds both folder components so a run straddling midnight does not
    // split across two date folders.
    std::string save_root;
    {
        const std::string root = save_loc_override.empty() ? cfg.files.save_loc : save_loc_override;
        const uint64_t run_us = host_unix_us();
        save_root =
            (fs::path(root) / date_folder(run_us) / time_folder(run_us)).string();
    }
    {
        std::error_code ec;
        fs::create_directories(save_root, ec);
        if (ec) {
            std::cerr << "error: cannot create save_loc '" << save_root << "': " << ec.message()
                      << "\n";
            return 2;
        }
    }

    // ---- signal handlers + logs ------------------------------------------------------------
    run_control::install_signal_handlers();

    EventLog log;
    const std::string csv_path = (fs::path(save_root) / cfg.timebase.events_csv).string();
    const std::string human_path = (fs::path(save_root) / cfg.timebase.human_log).string();
    if (!log.open(csv_path, human_path)) {
        std::cerr << "error: cannot open logs in '" << save_root << "'\n";
        return 2;
    }
    log.info("CryoSoOp start; mode=" + cfg.mode + " save_loc=" + save_root);

    // Effective config (fully-resolved provenance copy).
    if (!cfg.dump_effective((fs::path(save_root) / "config_effective.yaml").string()))
        log.warn("could not write config_effective.yaml");

    // ---- run the radiometer sequence -------------------------------------------------------
    Counters counters;
    SummaryMeta meta;
    run_radiometer(cfg, save_root, until_stopped, log, counters, meta);

    // ---- summary + exit code ---------------------------------------------------------------
    {
        std::ofstream sj((fs::path(save_root) / "summary.json").string());
        if (sj) sj << summary_json(counters, meta);
    }
    const int code = emit_summary_json(std::cout, counters, meta);
    log.info("CryoSoOp done; exit_code=" + std::to_string(code));
    log.close();
    return code;
}
