// test_time_stamps.cpp — regression checks for the UTC wall-clock stamp helpers (types.hpp)
// and the summary.json wall-clock provenance marker (summary.hpp).
//
// The stamp helpers deliberately format in UTC (gmtime) so capture filenames, run folders, and
// log timestamps are independent of the acquisition computer's OS timezone. These checks pin
// that contract with hardcoded epoch → string pairs: on any machine whose local zone is not
// UTC, a regression back to localtime produces different strings and the test fails. Runs
// under CRYOSOOP_COMMON_ONLY (no UHD), so it works on the MSVC compile-check host as well as
// the Pi.
//
// Exit code 0 = all checks pass; 1 = at least one failure (each printed to stderr).

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

#include "summary.hpp"
#include "types.hpp"

namespace {

int g_failures = 0;

void check_eq(const std::string& what, const std::string& got, const std::string& expect) {
    if (got != expect) {
        std::fprintf(stderr, "FAIL %s: got \"%s\", expected \"%s\"\n",
                     what.c_str(), got.c_str(), expect.c_str());
        ++g_failures;
    }
}

void check_true(const std::string& what, bool ok) {
    if (!ok) {
        std::fprintf(stderr, "FAIL %s\n", what.c_str());
        ++g_failures;
    }
}

}  // namespace

int main() {
    using namespace cryosoop;

    // --- epoch 0: 1970-01-01T00:00:00Z. A localtime regression on a UTC-7 host yields
    // "19691231170000" here, so this line alone discriminates UTC from local stamping.
    check_eq("stamp_compact(0)", stamp_compact(0), "19700101000000");
    check_eq("iso_time(0)", iso_time(0), "1970-01-01T00:00:00.000000Z");
    check_eq("date_folder(0)", date_folder(0), "19700101");
    check_eq("time_folder(0)", time_folder(0), "000000");

    // --- 2026-07-08T12:34:56.789012Z (northern-summer epoch: local-DST hosts would shift it).
    constexpr uint64_t kSummer = 1783514096789012ull;
    check_eq("stamp_compact(summer)", stamp_compact(kSummer), "20260708123456");
    check_eq("iso_time(summer)", iso_time(kSummer), "2026-07-08T12:34:56.789012Z");
    check_eq("date_folder(summer)", date_folder(kSummer), "20260708");
    check_eq("time_folder(summer)", time_folder(kSummer), "123456");

    // --- 2026-01-15T03:00:00Z (winter epoch chosen so a UTC-7 localtime regression also flips
    // the DATE folder to 20260114, catching a half-converted date_folder specifically).
    constexpr uint64_t kWinter = 1768446000000000ull;
    check_eq("stamp_compact(winter)", stamp_compact(kWinter), "20260115030000");
    check_eq("date_folder(winter)", date_folder(kWinter), "20260115");
    check_eq("time_folder(winter)", time_folder(kWinter), "030000");

    // --- unique_capture_stamp collision handling: once <prefix><stamp>_ch0.dat exists, the
    // next call must return a different (later) 14-digit stamp.
    std::error_code ec;
    const auto tmp = std::filesystem::temp_directory_path(ec) / "cryosoop_stamp_test";
    std::filesystem::create_directories(tmp, ec);
    const std::string prefix = "TEST_";
    const std::string s1 = unique_capture_stamp(tmp.string(), prefix);
    check_true("unique_capture_stamp first call returns 14 digits", s1.size() == 14);
    { std::ofstream((tmp / (prefix + s1 + "_ch0.dat")).string()) << "x"; }
    const std::string s2 = unique_capture_stamp(tmp.string(), prefix);
    check_true("unique_capture_stamp collision returns 14 digits", s2.size() == 14);
    check_true("unique_capture_stamp collision advances the stamp", s2 > s1);
    std::filesystem::remove_all(tmp, ec);

    // --- summary.json provenance: the driver adds a wall_clock extra; wall_start/wall_end come
    // from iso_time and must carry the Z suffix. Written to a file so the build script can
    // additionally validate it with an external JSON parser.
    Counters c;
    SummaryMeta meta;
    meta.mode = "radiometer";
    meta.wall_start = iso_time(kSummer);
    meta.wall_end = iso_time(kSummer + 5000000ull);
    meta.extra.emplace_back("wall_clock", "\"UTC\"");
    const std::string json = summary_json(c, meta);
    check_true("summary_json contains wall_clock marker",
               json.find("\"wall_clock\": \"UTC\"") != std::string::npos);
    check_true("summary_json wall_start carries Z",
               json.find("2026-07-08T12:34:56.789012Z") != std::string::npos);
    const char* out_path = std::getenv("CRYOSOOP_TEST_SUMMARY_OUT");
    if (out_path && *out_path) {
        std::ofstream f(out_path);
        f << json << "\n";
    }

    if (g_failures) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("all timestamp checks passed\n");
    return 0;
}
