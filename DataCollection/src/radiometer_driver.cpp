// radiometer_driver.cpp — see radiometer_driver.hpp.

#include "radiometer_driver.hpp"

#include <uhd/types/metadata.hpp>
#include <uhd/types/stream_cmd.hpp>
#include <uhd/types/time_spec.hpp>
#include <uhd/types/tune_request.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

#include "common/dat_writer.hpp"
#include "common/ring.hpp"
#include "common/run_control.hpp"
#include "common/types.hpp"
#include "device/rf_control.hpp"
#include "device/usrp_session.hpp"

#ifdef __linux__
#include <sys/statvfs.h>
#endif

namespace cryosoop {
namespace {

namespace fs = std::filesystem;

// Samples per channel per ring slot. Divides both the 2 s and 10 s targets at 20 MS/s exactly, so
// a slot never straddles a chunk boundary awkwardly (matches SoOp_StressTest SLOT_SAMPS).
constexpr std::size_t kSlotSamps = 250000;
constexpr std::size_t kElemBytes = 4;  // sc16 = interleaved int16 I/Q

// One GiB in bytes; disk-floor math is expressed in GiB.
constexpr std::uint64_t kGiB = 1ull << 30;

// Free bytes on the filesystem holding `dir` (defined below; forward-declared for writer_thread).
std::uint64_t disk_free_bytes(const std::string& dir);

// One capture's fixed parameters.
struct Capture {
    std::string prefix;
    double duration_s;
};

// Consume the ring into per-channel .dat files with chunk rotation. Runs until `capture_done` and
// the ring is drained. Lifted from SoOp_StressTest's writer thread (348-424) onto DatWriter.
void writer_thread(Ring& ring, DatWriter& dat, std::size_t nchan, std::size_t chunk_samps,
                   const std::string& save_root, std::uint64_t disk_floor_bytes,
                   std::atomic<bool>& capture_done, std::atomic<bool>& writer_failed,
                   std::atomic<bool>& disk_low, Counters& counters) {
    std::size_t samps_in_chunk = 0;
    bool need_open = true;
    while (true) {
        if (!ring.has_data()) {
            if (capture_done.load(std::memory_order_acquire)) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
        }
        const std::uint32_t nval = ring.tail_valid();
        std::size_t off = 0;
        while (off < nval) {
            if (need_open) {
                // Recurring per-chunk disk guard (matches StressTest's per-chunk-open check): if
                // free space fell below the floor, stop before opening the next chunk file.
                if (disk_floor_bytes > 0) {
                    const std::uint64_t free = disk_free_bytes(save_root);
                    if (free > 0 && free < disk_floor_bytes) {
                        disk_low.store(true, std::memory_order_release);
                        return;
                    }
                }
                if (!dat.open_chunk()) {
                    writer_failed.store(true, std::memory_order_release);
                    return;
                }
                need_open = false;
            }
            const std::size_t m = std::min<std::size_t>(nval - off, chunk_samps - samps_in_chunk);
            for (std::size_t c = 0; c < nchan; ++c) {
                const std::uint8_t* src = ring.tail_slot(c) + off * kElemBytes;
                if (!dat.write_ch(c, src, m * kElemBytes)) {
                    writer_failed.store(true, std::memory_order_release);
                    return;
                }
            }
            off += m;
            samps_in_chunk += m;
            counters.bytes_written.fetch_add(static_cast<std::uint64_t>(m) * kElemBytes * nchan);
            if (samps_in_chunk == chunk_samps) {
                dat.next_chunk();  // close current chunk, ++seq
                samps_in_chunk = 0;
                need_open = true;
            }
        }
        ring.release();
    }
    dat.close();
}

// Free bytes on the filesystem holding `dir` (Linux); 0 elsewhere (skip the check).
std::uint64_t disk_free_bytes(const std::string& dir) {
#ifdef __linux__
    struct statvfs vfs {};
    if (statvfs(dir.c_str(), &vfs) != 0) return 0;
    return static_cast<std::uint64_t>(vfs.f_bavail) * vfs.f_frsize;
#else
    (void)dir;
    return 0;
#endif
}

}  // namespace

void run_radiometer(const Config& cfg, const std::string& save_root, bool until_stopped,
                    EventLog& log, Counters& counters, SummaryMeta& meta) {
    meta.mode = "radiometer";
    meta.wall_start = iso_now();
    // Wall-clock provenance for the processing side: stamps are UTC (types.hpp). Legacy runs
    // (pre-UTC builds) lack this field, which is how downstream tells the two eras apart.
    meta.extra.emplace_back("wall_clock", "\"UTC\"");

    const double rate = cfg.radiometer.rate;

    // ---- resolve the sequence (CLI --duration overrides to a single Signal step) -----------
    std::vector<RadiometerStep> sequence;
    if (cfg.duration_s.has_value()) {
        RadiometerStep s;
        s.state = "Signal";
        s.prefix = "UHF_";
        s.count = 1;
        s.duration_s = *cfg.duration_s;
        s.state_cmd = "";
        s.on_cmd_fail = "continue";
        sequence.push_back(std::move(s));
        log.info("Radiometer: --duration override -> single Signal capture of " +
                 std::to_string(*cfg.duration_s) + " s.");
    } else {
        sequence = cfg.radiometer.sequence;
    }
    if (sequence.empty()) {
        meta.fatal = true;
        meta.abort_reason = "radiometer sequence is empty and no --duration given.";
        log.error(meta.abort_reason);
        return;
    }

    // ---- pre-flight free-space check (whole sequence + disk floor) --------------------------
    std::uint64_t planned_bytes = 0;
    for (const auto& s : sequence) {
        const std::uint64_t samps =
            static_cast<std::uint64_t>(std::llround(s.duration_s * rate));
        planned_bytes += static_cast<std::uint64_t>(s.count) * samps * kElemBytes *
                         cfg.device.rx_channels.size();
    }
    {
        const std::uint64_t free = disk_free_bytes(save_root);
        const std::uint64_t need =
            planned_bytes + static_cast<std::uint64_t>(cfg.disk.disk_floor_gb * kGiB);
        if (free > 0 && free < need) {
            meta.fatal = true;
            meta.abort_reason = "insufficient free space: need " + std::to_string(need) +
                                " bytes (sequence + disk_floor_gb), have " + std::to_string(free);
            log.error(meta.abort_reason);
            return;
        }
    }

    // ---- device setup (ONCE — never re-created / re-tuned between captures) -----------------
    UsrpSession session;
    try {
        session.setup(cfg, log);
    } catch (const std::exception& e) {
        meta.fatal = true;
        meta.abort_reason = std::string("device setup failed: ") + e.what();
        log.error(meta.abort_reason);
        return;
    }
    const auto& rx_ch = session.rx_channels();
    const std::size_t nchan = rx_ch.size();
    const double actual_rate = session.actual_rate();

    // Per-channel freq / gain / bw / antenna, then lo_locked poll through the shared rf_control
    // lock-wait (poll interval / timeout from RADIOMETER.lo_lock_poll_s / lo_lock_timeout_s). The
    // poll itself absorbs the settle time, so no separate fixed pre-read sleep is needed.
    const double bw = cfg.radiometer.bw.value_or(cfg.radiometer.rate);
    for (std::size_t ch : rx_ch) {
        session.usrp()->set_rx_freq(uhd::tune_request_t(cfg.radiometer.freq), ch);
        session.usrp()->set_rx_gain(cfg.radiometer.gain, ch);
        if (bw > 0) session.usrp()->set_rx_bandwidth(bw, ch);
        if (!cfg.radiometer.rx_ant.empty())
            session.usrp()->set_rx_antenna(cfg.radiometer.rx_ant, ch);
    }
    for (std::size_t ch : rx_ch) {
        if (!wait_lo_locked(session, /*is_tx=*/false, ch, cfg.radiometer.lo_lock_poll_s,
                            cfg.radiometer.lo_lock_timeout_s)) {
            meta.fatal = true;
            meta.abort_reason = "lo_locked never asserted on RX channel " + std::to_string(ch);
            log.error(meta.abort_reason);
            return;
        }
    }
    log.info("Radiometer LO locked on all channels; freq=" +
             std::to_string(cfg.radiometer.freq / 1e6) + " MHz, rate=" +
             std::to_string(actual_rate / 1e6) + " Msps.");

    // ---- ring (allocated ONCE, reused across all captures) ---------------------------------
    std::unique_ptr<Ring> ring;
    try {
        ring = std::make_unique<Ring>(kSlotSamps, nchan, kElemBytes,
                                      static_cast<std::uint64_t>(cfg.ring.ring_mb) << 20,
                                      /*clamp_memavail=*/true, /*min_slots=*/64);
    } catch (const std::exception& e) {
        meta.fatal = true;
        meta.abort_reason = std::string("ring alloc failed: ") + e.what();
        log.error(meta.abort_reason);
        return;
    }
    if (ring->was_clamped()) log.warn(ring->clamp_message());
    meta.ring_slots = ring->nslots();
    log.event(ev::RUN_START, EventLog::kNaN, EventLog::kNaN, "", -1, "radiometer",
              std::to_string(sequence.size()) + " steps");

    // CAL.common_source_captures is a reserved hook. Surface one honest warning at sequence start
    // so config_effective.yaml's `true` is not silently ignored.
    if (cfg.cal.common_source_captures) {
        log.event(ev::HOOK, EventLog::kNaN, EventLog::kNaN, "", -1, "common_source_captures",
                  "reserved; not implemented in this version");
        log.warn("CAL.common_source_captures is set but is not implemented in this version; "
                 "ignoring it.");
    }

    auto run_final_state = [&]() {
        if (!cfg.radiometer.final_state_cmd.empty()) {
            const int rc = run_control::exec_hook(cfg.radiometer.final_state_cmd);
            log.event(ev::HOOK, EventLog::kNaN, EventLog::kNaN, "", -1, std::to_string(rc),
                      "final_state");
        }
    };

    const std::size_t chunk_samps =
        cfg.radiometer.chunk_secs > 0
            ? static_cast<std::size_t>(std::llround(cfg.radiometer.chunk_secs * rate))
            : SIZE_MAX;
    const std::uint64_t sync_every_bytes =
        static_cast<std::uint64_t>(cfg.ring.sync_every_mb) << 20;
    const std::uint64_t disk_floor_bytes =
        static_cast<std::uint64_t>(cfg.disk.disk_floor_gb * kGiB);

    // Overflow scratch (~2 MB/ch) allocated ONCE for the whole run and reused by every capture
    // (drop-newest writes land here and are never read), instead of a per-capture allocation.
    std::vector<std::vector<std::int16_t>> scratch(
        nchan, std::vector<std::int16_t>(kSlotSamps * 2));

    bool aborted = false;

    // ---- sequence loop ---------------------------------------------------------------------
    do {
        for (const auto& step : sequence) {
            if (run_control::stop_requested()) break;

            // Out-of-band state change (SSH-to-BBB GPIO). NOT in the RX hot path.
            if (!step.state_cmd.empty()) {
                const int rc = run_control::exec_hook(step.state_cmd);
                log.event(ev::HOOK, EventLog::kNaN, EventLog::kNaN, step.state, -1,
                          std::to_string(rc), "state_cmd");
                if (rc != 0) {
                    if (step.on_cmd_fail == "abort") {
                        meta.fatal = true;
                        meta.abort_reason =
                            "state_cmd failed (rc=" + std::to_string(rc) + ") in step '" +
                            step.state + "' with on_cmd_fail=abort";
                        log.error(meta.abort_reason);
                        aborted = true;
                        break;
                    }
                    log.warn("state_cmd failed (rc=" + std::to_string(rc) +
                             ") in step '" + step.state + "'; continuing (on_cmd_fail=continue).");
                }
            }
            std::this_thread::sleep_for(
                std::chrono::duration<double>(cfg.radiometer.settle_s));  // settle

            for (int cap = 0; cap < step.count && !run_control::stop_requested(); ++cap) {
                // Wall-clock 14-digit stamp at capture start, guarded against same-second
                // collisions (advances +1 s per existing ch0 file, up to 60 probes). Exhaustion
                // is unreachable in practice (>=1 s captures never collide); if it ever happens we
                // cannot name the file, so abort the run cleanly like other fatal per-capture
                // errors below.
                const std::string stamp = unique_capture_stamp(save_root, step.prefix);
                if (stamp.empty()) {
                    meta.abort_reason = "capture stamp collision (60 same-second probes exhausted)";
                    log.event(ev::ABORT, EventLog::kNaN, EventLog::kNaN, step.state, -1, "",
                              "unique_capture_stamp exhausted under " + save_root);
                    log.error("could not allocate a collision-free capture stamp for prefix '" +
                              step.prefix + "' under '" + save_root + "'; aborting run");
                    aborted = true;
                    break;
                }
                const std::uint64_t target_samps =
                    static_cast<std::uint64_t>(std::llround(step.duration_s * rate));
                const std::size_t cap_chunk =
                    (chunk_samps == SIZE_MAX)
                        ? static_cast<std::size_t>(std::min<std::uint64_t>(target_samps, SIZE_MAX))
                        : chunk_samps;
                const std::uint64_t plan_bytes_per_chunk =
                    static_cast<std::uint64_t>(std::min<std::uint64_t>(cap_chunk, target_samps)) *
                    kElemBytes;

                // Per-capture disk guard: require the whole planned capture (all channels) plus the
                // disk floor to be free before starting; graceful abort otherwise.
                {
                    const std::uint64_t cap_bytes = target_samps * kElemBytes * nchan;
                    const std::uint64_t free = disk_free_bytes(save_root);
                    const std::uint64_t need = cap_bytes + disk_floor_bytes;
                    if (free > 0 && free < need) {
                        meta.abort_reason = "disk_low";
                        log.error("insufficient free space for capture: need " +
                                  std::to_string(need) + " bytes (capture + disk_floor_gb), have " +
                                  std::to_string(free) + "; aborting run");
                        aborted = true;
                        break;
                    }
                }

                // <PREFIX><YYYYmmddHHMMSS>_ch{k}.dat  (chunk 0 = exact name Chan3ProcAll expects;
                // rotated chunks get a .<seq> suffix).
                DatWriter::NameFn namer = [&, stamp](std::size_t ch,
                                                     std::int64_t seq) -> std::string {
                    const std::string base =
                        (fs::path(save_root) / (step.prefix + stamp + "_ch" + std::to_string(ch)))
                            .string();
                    return seq == 0 ? base + ".dat" : base + "." + std::to_string(seq) + ".dat";
                };
                DatWriter dat(nchan, plan_bytes_per_chunk, sync_every_bytes, namer);

                std::atomic<bool> capture_done{false};
                std::atomic<bool> writer_failed{false};
                std::atomic<bool> disk_low{false};
                std::thread writer(writer_thread, std::ref(*ring), std::ref(dat), nchan, cap_chunk,
                                   std::cref(save_root), disk_floor_bytes, std::ref(capture_done),
                                   std::ref(writer_failed), std::ref(disk_low), std::ref(counters));

                // ---- producer: timed continuous capture, sample-counted stop ---------------
                uhd::rx_metadata_t md;
                uhd::time_spec_t expected_time;
                bool have_expected = false;
                int consec_to = 0;
                bool retried_start = false;
                std::uint64_t received = 0;

                uhd::stream_cmd_t start(uhd::stream_cmd_t::STREAM_MODE_START_CONTINUOUS);
                start.stream_now = false;  // timed start aligns both DDCs on the same tick
                start.time_spec = session.usrp()->get_time_now() + uhd::time_spec_t(0.5);
                session.rx_stream()->issue_stream_cmd(start);

                // Sample-counted stop only (never a wall clock): the loop exits when `received`
                // reaches target_samps, and a genuine hang is caught by the 1 s recv timeout with
                // the DEVICE.rx_timeout_limit consecutive-timeout abort below. This restores the
                // StressTest invariant "stop on sample count, never on wall-clock".
                std::vector<void*> buffs(nchan);  // hoisted; entries overwritten per recv
                while (!run_control::stop_requested() && received < target_samps) {
                    if (writer_failed.load(std::memory_order_acquire)) {
                        meta.abort_reason = "writer thread failed (disk error)";
                        aborted = true;
                        break;
                    }
                    if (disk_low.load(std::memory_order_acquire)) {
                        meta.abort_reason = "disk_low";
                        aborted = true;
                        break;
                    }
                    const std::size_t want = static_cast<std::size_t>(
                        std::min<std::uint64_t>(kSlotSamps, target_samps - received));
                    const bool ring_full = ring->full();
                    for (std::size_t c = 0; c < nchan; ++c)
                        buffs[c] = ring_full ? static_cast<void*>(scratch[c].data())
                                             : static_cast<void*>(ring->head_slot(c));

                    const std::size_t n = session.rx_stream()->recv(buffs, want, md, 1.0);

                    switch (md.error_code) {
                        case uhd::rx_metadata_t::ERROR_CODE_NONE:
                            consec_to = 0;
                            break;
                        case uhd::rx_metadata_t::ERROR_CODE_OVERFLOW:
                            if (md.out_of_sequence) counters.out_of_seq.fetch_add(1);
                            else counters.overflow.fetch_add(1);
                            log.event(md.out_of_sequence ? ev::OVERFLOW_OOS : ev::OVERFLOW,
                                      md.time_spec.get_real_secs(), EventLog::kNaN, "", -1, "",
                                      "overflow");
                            consec_to = 0;
                            break;
                        case uhd::rx_metadata_t::ERROR_CODE_TIMEOUT:
                            counters.timeouts.fetch_add(1);
                            log.event(ev::LATE_COMMAND, EventLog::kNaN, EventLog::kNaN, "", -1, "",
                                      "recv timeout");
                            if (++consec_to >= cfg.device.rx_timeout_limit) {
                                meta.abort_reason =
                                    std::to_string(cfg.device.rx_timeout_limit) +
                                    " consecutive recv timeouts";
                                aborted = true;
                            }
                            continue;
                        case uhd::rx_metadata_t::ERROR_CODE_LATE_COMMAND:
                            counters.late.fetch_add(1);
                            if (!retried_start && received == 0) {
                                retried_start = true;
                                log.event(ev::LATE_COMMAND, EventLog::kNaN, EventLog::kNaN, "", -1,
                                          "", "LATE start; retrying once");
                                uhd::stream_cmd_t restart(
                                    uhd::stream_cmd_t::STREAM_MODE_START_CONTINUOUS);
                                restart.stream_now = false;
                                restart.time_spec =
                                    session.usrp()->get_time_now() + uhd::time_spec_t(1.0);
                                session.rx_stream()->issue_stream_cmd(restart);
                                continue;
                            }
                            meta.abort_reason = "late stream command (no recovery)";
                            aborted = true;
                            continue;
                        case uhd::rx_metadata_t::ERROR_CODE_ALIGNMENT:
                            counters.alignment.fetch_add(1);
                            consec_to = 0;
                            break;
                        default:
                            counters.other.fetch_add(1);
                            if (counters.other.load() >
                                static_cast<std::uint64_t>(cfg.radiometer.max_stream_errors)) {
                                meta.abort_reason = "repeated stream errors";
                                aborted = true;
                            }
                            break;
                    }
                    if (aborted) break;
                    if (n == 0) continue;

                    // Gap-estimated dropped samples via time_spec discontinuity (D counter).
                    if (md.has_time_spec) {
                        if (!have_expected) {
                            have_expected = true;
                        } else {
                            const double gap = (md.time_spec - expected_time).get_real_secs();
                            const std::int64_t gap_samps =
                                static_cast<std::int64_t>(std::llround(gap * actual_rate));
                            if (gap_samps > 0) {
                                counters.dropped_samps.fetch_add(
                                    static_cast<std::uint64_t>(gap_samps));
                                log.event(ev::GAP, md.time_spec.get_real_secs(), EventLog::kNaN, "",
                                          -1, std::to_string(gap_samps), "dropped");
                            } else if (gap_samps < -1) {
                                log.event(ev::NEGGAP, md.time_spec.get_real_secs(), EventLog::kNaN,
                                          "", -1, std::to_string(gap_samps), "");
                            }
                        }
                        expected_time =
                            md.time_spec + uhd::time_spec_t::from_ticks(
                                               static_cast<std::int64_t>(n), actual_rate);
                    }

                    if (ring_full) {
                        ring->add_ring_drop(n);
                        log.event(ev::RINGFULL, md.has_time_spec ? md.time_spec.get_real_secs()
                                                                 : EventLog::kNaN,
                                  EventLog::kNaN, "", -1, std::to_string(n), "drop-newest");
                    } else {
                        ring->publish(static_cast<std::uint32_t>(n));
                    }
                    received += n;
                }

                // ---- stop + drain (device stays alive; never re-created) --------------------
                session.rx_stream()->issue_stream_cmd(
                    uhd::stream_cmd_t(uhd::stream_cmd_t::STREAM_MODE_STOP_CONTINUOUS));
                {
                    std::vector<void*> db(nchan);
                    for (std::size_t c = 0; c < nchan; ++c)
                        db[c] = static_cast<void*>(scratch[c].data());
                    uhd::rx_metadata_t dmd;
                    for (int k = 0; k < 500; ++k) {
                        if (session.rx_stream()->recv(db, kSlotSamps, dmd, 0.2) == 0 &&
                            dmd.error_code == uhd::rx_metadata_t::ERROR_CODE_TIMEOUT)
                            break;
                    }
                }

                capture_done.store(true, std::memory_order_release);
                writer.join();

                const std::string base = step.prefix + stamp;
                log.event(ev::FILE_WRITTEN, EventLog::kNaN, EventLog::kNaN, step.state, -1,
                          std::to_string(received), base);
                if (received < target_samps)
                    log.warn("capture " + base + " short: " + std::to_string(received) + "/" +
                             std::to_string(target_samps) + " samples.");
                if (writer_failed.load()) {
                    if (meta.abort_reason.empty())
                        meta.abort_reason = "writer thread failed (disk error)";
                    aborted = true;
                }
                if (disk_low.load()) {
                    meta.abort_reason = "disk_low";
                    aborted = true;
                }
                if (aborted) break;
            }  // captures
            if (aborted || run_control::stop_requested()) break;
        }  // steps
        if (aborted) break;
    } while (until_stopped && !run_control::stop_requested());

    // ---- restore state + shutdown ----------------------------------------------------------
    run_final_state();  // best-effort, also on abort
    meta.ring_max_fill_pct = ring->ring_max_occ_pct();
    counters.ring_drop_samps.fetch_add(ring->ring_drop_samps());
    meta.wall_end = iso_now();
    log.event(ev::RUN_END, EventLog::kNaN, EventLog::kNaN, "", -1,
              aborted ? "aborted" : "complete", meta.abort_reason);
}

}  // namespace cryosoop
