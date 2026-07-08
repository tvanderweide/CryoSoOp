// event_log.hpp — two paired, append-mode logs opened together:
//
//   1. events.csv   — machine-readable, one row per event, fixed schema:
//        wall_iso,host_unix_us,device_time_s,event,band_hz,ant_pair,chan,value,detail
//      device_time_s is passed in by the caller (drivers know device time; common code does
//      not). NaN device_time_s / band_hz -> empty field; chan < 0 -> empty field.
//
//   2. RunLog.log — human-readable view, one line per message:
//        "HH:MM:SS.ff [LEVEL] (thread) message"
//
// Thread-safe via a single mutex. NOT a hot-path facility: events are logged at band/chunk
// granularity and on errors, never per-sample. The mutex is fine there. Fields with commas or
// quotes are CSV-quoted so the file stays parseable.

#ifndef CRYOSOOP_COMMON_EVENT_LOG_HPP
#define CRYOSOOP_COMMON_EVENT_LOG_HPP

#include <fstream>
#include <mutex>
#include <string>

namespace cryosoop {

enum class LogLevel { debug, info, warn, error };

const char* to_string(LogLevel lvl);

class EventLog {
public:
    EventLog() = default;
    ~EventLog();

    EventLog(const EventLog&) = delete;
    EventLog& operator=(const EventLog&) = delete;

    // Open both files (append mode). The CSV header is written only if the file is new/empty so
    // that a restart appends rather than duplicating the header. Returns false if either file
    // cannot be opened.
    bool open(const std::string& csv_path, const std::string& human_path);
    bool is_open() const { return csv_.is_open(); }
    void close();

    // Emit one events.csv row. Pass a NaN for device_time_s or band_hz to leave that field
    // empty; pass chan < 0 to leave the chan field empty. `value` and `detail` are free-form.
    void event(const std::string& event,
               double device_time_s = kNaN,
               double band_hz = kNaN,
               const std::string& ant_pair = "",
               int chan = -1,
               const std::string& value = "",
               const std::string& detail = "");

    // Emit one RunLog.log line only.
    void log(LogLevel lvl, const std::string& msg);

    // Convenience wrappers.
    void debug(const std::string& m) { log(LogLevel::debug, m); }
    void info(const std::string& m) { log(LogLevel::info, m); }
    void warn(const std::string& m) { log(LogLevel::warn, m); }
    void error(const std::string& m) { log(LogLevel::error, m); }

    static const double kNaN;

private:
    std::ofstream csv_;
    std::ofstream human_;
    std::mutex mtx_;
};

}  // namespace cryosoop

#endif  // CRYOSOOP_COMMON_EVENT_LOG_HPP
