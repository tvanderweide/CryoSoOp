// summary.cpp — Counters/SummaryMeta emission + exit-code policy. See summary.hpp.

#include "summary.hpp"

#include <sstream>

namespace cryosoop {

bool has_errors(const Counters& c) {
    return c.error_total() > 0 || c.bands_degraded.load() > 0 || c.bands_failed.load() > 0;
}

int exit_code(const Counters& c, const SummaryMeta& meta) {
    if (meta.fatal || meta.interrupted || !meta.abort_reason.empty()) return 2;
    if (has_errors(c)) return 1;
    return 0;
}

namespace {
// Minimal JSON string escaper for the free-form fields (abort_reason, mode). Handles the
// characters that would otherwise break the object; the summary strings are our own, so this is
// belt-and-suspenders rather than a full JSON encoder.
std::string jstr(const std::string& s) {
    std::string out = "\"";
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:   out += c; break;
        }
    }
    out += "\"";
    return out;
}
}  // namespace

std::string summary_json(const Counters& c, const SummaryMeta& meta) {
    const int code = exit_code(c, meta);
    std::ostringstream js;
    js << "{\n"
       << "  \"mode\": " << jstr(meta.mode) << ",\n"
       << "  \"wall_start\": " << jstr(meta.wall_start) << ",\n"
       << "  \"wall_end\": " << jstr(meta.wall_end) << ",\n"
       << "  \"counters\": {"
       << "\"O\": " << c.overflow.load()
       << ", \"S\": " << c.out_of_seq.load()
       << ", \"A\": " << c.alignment.load()
       << ", \"timeouts\": " << c.timeouts.load()
       << ", \"late\": " << c.late.load()
       << ", \"D_samps\": " << c.dropped_samps.load()
       << ", \"ring_drop_samps\": " << c.ring_drop_samps.load()
       << ", \"other\": " << c.other.load()
       << ", \"retries\": " << c.retries.load()
       << "},\n"
       << "  \"bands\": {"
       << "\"ok\": " << c.bands_ok.load()
       << ", \"degraded\": " << c.bands_degraded.load()
       << ", \"failed\": " << c.bands_failed.load()
       << "},\n"
       << "  \"bytes_written\": " << c.bytes_written.load() << ",\n"
       << "  \"ring_slots\": " << meta.ring_slots << ",\n"
       << "  \"ring_max_fill_pct\": " << meta.ring_max_fill_pct << ",\n"
       << "  \"interrupted\": " << (meta.interrupted ? "true" : "false") << ",\n"
       << "  \"abort_reason\": " << jstr(meta.abort_reason) << ",\n";
    // Driver-supplied extra fields (raw JSON values), emitted before exit_code.
    for (const auto& kv : meta.extra) {
        js << "  " << jstr(kv.first) << ": " << kv.second << ",\n";
    }
    js << "  \"exit_code\": " << code << "\n"
       << "}\n";
    return js.str();
}

int emit_summary_json(std::ostream& os, const Counters& c, const SummaryMeta& meta) {
    const int code = exit_code(c, meta);
    os << "==== SUMMARY_JSON ====\n" << summary_json(c, meta) << "==== END_SUMMARY_JSON ====\n";
    os << "Exit code " << code << " (0=clean, 1=complete-with-errors, 2=fatal)\n";
    return code;
}

}  // namespace cryosoop
