// event_log.cpp — EventLog implementation. See event_log.hpp.

#include "event_log.hpp"

#include "types.hpp"

#include <cmath>
#include <cstdio>
#include <ctime>
#include <limits>
#include <sstream>
#include <thread>

namespace cryosoop {

const double EventLog::kNaN = std::numeric_limits<double>::quiet_NaN();

const char* to_string(LogLevel lvl) {
    switch (lvl) {
        case LogLevel::debug: return "DEBUG";
        case LogLevel::info:  return "INFO";
        case LogLevel::warn:  return "WARN";
        case LogLevel::error: return "ERROR";
    }
    return "INFO";
}

namespace {

// CSV-quote a field only if it needs it (comma, quote, CR or LF). Doubles embedded quotes,
// per RFC 4180, so downstream pandas/csv parses cleanly.
std::string csv_field(const std::string& s) {
    bool needs = false;
    for (char c : s) {
        if (c == ',' || c == '"' || c == '\n' || c == '\r') { needs = true; break; }
    }
    if (!needs) return s;
    std::string out;
    out.reserve(s.size() + 2);
    out.push_back('"');
    for (char c : s) {
        if (c == '"') out.push_back('"');  // escape by doubling
        out.push_back(c);
    }
    out.push_back('"');
    return out;
}

// Short thread id, e.g. "t7f...": stable within a run, used for the "(thread)" tag.
std::string thread_tag() {
    std::ostringstream ss;
    ss << std::this_thread::get_id();
    return ss.str();
}

// "HH:MM:SS.ff" local time with centisecond fraction (matches RunLog.log convention).
std::string clock_hhmmss_ff(uint64_t unix_us) {
    const std::time_t secs = static_cast<std::time_t>(unix_us / 1000000ull);
    const unsigned cs = static_cast<unsigned>((unix_us % 1000000ull) / 10000ull);  // centiseconds
    const std::tm tmv = local_tm(secs);
    char buf[16];
    std::strftime(buf, sizeof(buf), "%H:%M:%S", &tmv);
    char out[24];
    std::snprintf(out, sizeof(out), "%s.%02u", buf, cs);
    return out;
}

}  // namespace

EventLog::~EventLog() { close(); }

bool EventLog::open(const std::string& csv_path, const std::string& human_path) {
    std::lock_guard<std::mutex> g(mtx_);

    // Peek whether the CSV already has content, so we only write the header once (restart-safe).
    bool csv_has_content = false;
    {
        std::ifstream probe(csv_path, std::ios::binary | std::ios::ate);
        if (probe.good() && probe.tellg() > 0) csv_has_content = true;
    }

    csv_.open(csv_path, std::ios::out | std::ios::app);
    human_.open(human_path, std::ios::out | std::ios::app);
    if (!csv_.is_open() || !human_.is_open()) {
        csv_.close();
        human_.close();
        return false;
    }
    if (!csv_has_content) {
        csv_ << "wall_iso,host_unix_us,device_time_s,event,band_hz,ant_pair,chan,value,detail\n"
             << std::flush;
    }
    return true;
}

void EventLog::close() {
    std::lock_guard<std::mutex> g(mtx_);
    if (csv_.is_open()) csv_.close();
    if (human_.is_open()) human_.close();
}

void EventLog::event(const std::string& event, double device_time_s, double band_hz,
                     const std::string& ant_pair, int chan, const std::string& value,
                     const std::string& detail) {
    const uint64_t us = host_unix_us();
    std::lock_guard<std::mutex> g(mtx_);
    if (!csv_.is_open()) return;

    csv_ << iso_time(us) << ',' << us << ',';
    if (std::isnan(device_time_s)) csv_ << "";  // empty field
    else {
        char b[32];
        std::snprintf(b, sizeof(b), "%.9f", device_time_s);
        csv_ << b;
    }
    csv_ << ',' << csv_field(event) << ',';
    if (std::isnan(band_hz)) csv_ << "";
    else {
        char b[32];
        std::snprintf(b, sizeof(b), "%.0f", band_hz);  // Hz as integer-valued double
        csv_ << b;
    }
    csv_ << ',' << csv_field(ant_pair) << ',';
    if (chan >= 0) csv_ << chan;  // else empty
    csv_ << ',' << csv_field(value) << ',' << csv_field(detail) << '\n' << std::flush;
}

void EventLog::log(LogLevel lvl, const std::string& msg) {
    const uint64_t us = host_unix_us();
    std::lock_guard<std::mutex> g(mtx_);
    if (!human_.is_open()) return;
    human_ << clock_hhmmss_ff(us) << " [" << to_string(lvl) << "] (" << thread_tag() << ") "
           << msg << '\n' << std::flush;
}

}  // namespace cryosoop
