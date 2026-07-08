// dat_writer.hpp — chunked, per-channel raw sample writer for the radiometer path (sc16 .dat).
//
// Lifted near-verbatim from SoOp_StressTest's OutFile (rx_stress_capture.cpp:143-189) and its
// writer thread's chunk rotation (348-424), with two changes:
//   * file naming is delegated to a caller-supplied callback (the radiometer driver owns the
//     <PREFIX><YYYYMMDDHHmmss>_ch{k}.dat contract that Chan3ProcAll expects);
//   * all Linux-only I/O (fallocate / sync_file_range / posix_fadvise / ftruncate / fdatasync)
//     is #ifdef __linux__-guarded with std fallbacks so the TU compiles under MSVC. On the Pi
//     the Linux path is the real one; the fallback is a logic-check convenience only.
//
// The DatWriter drives N per-channel OutFiles in lockstep: one open_chunk() opens all N files
// for the current sequence number, write_ch() appends to one channel, next_chunk() rolls all N
// to the next sequence. Rotation never stops the stream — the ring absorbs the close/open gap.

#ifndef CRYOSOOP_COMMON_DAT_WRITER_HPP
#define CRYOSOOP_COMMON_DAT_WRITER_HPP

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#ifndef __linux__
#include <cstdio>  // std::FILE fallback
#endif

namespace cryosoop {

// One output file (one channel, one chunk). Public so a driver can also drive a single file if
// it ever needs to; DatWriter is the normal entry point.
class OutFile {
public:
    OutFile() = default;
    ~OutFile();
    OutFile(const OutFile&) = delete;
    OutFile& operator=(const OutFile&) = delete;
    OutFile(OutFile&&) noexcept;
    OutFile& operator=(OutFile&&) noexcept;

    // Open path, reserving `plan_bytes` extents (fallocate) so allocation can't stall mid-stream
    // and ENOSPC surfaces here, not deep in write(). sync_every_bytes = page-cache flush
    // watermark (0 disables periodic flush).
    bool open_file(const std::string& path, std::uint64_t plan_bytes, std::uint64_t sync_every_bytes);
    // Append `bytes` from `p`, retrying short/EINTR writes. Periodically hands earlier bytes to
    // writeback and drops the clean pages so dirty/cached memory stays flat.
    bool write_block(const void* p, std::size_t bytes);
    // Trim the fallocate over-reserve (ftruncate), fdatasync, close. Idempotent.
    bool close_file();

    std::uint64_t written() const { return written_; }
    const std::string& path() const { return path_; }
    bool is_open() const;

private:
    void move_from(OutFile& o) noexcept;
#ifdef __linux__
    int fd_ = -1;
#else
    std::FILE* fp_ = nullptr;
#endif
    std::uint64_t written_ = 0;      // bytes written so far
    std::uint64_t synced_ = 0;       // bytes already handed to writeback
    std::uint64_t sync_every_ = 0;   // flush watermark
    std::string path_;
};

class DatWriter {
public:
    // namer(ch, chunk_seq) -> absolute path for that channel/chunk.
    // plan_bytes_per_chunk_per_ch is the fallocate reservation per file (0 to skip reserving).
    using NameFn = std::function<std::string(std::size_t ch, std::int64_t chunk_seq)>;

    DatWriter(std::size_t nchan, std::uint64_t plan_bytes_per_chunk_per_ch,
              std::uint64_t sync_every_bytes, NameFn namer);
    ~DatWriter();

    // Open all N channel files for the current chunk_seq. Returns false on any open failure
    // (last_error() explains). Call once before writing a chunk.
    bool open_chunk();
    // Append to channel `ch` of the current chunk.
    bool write_ch(std::size_t ch, const void* p, std::size_t bytes);
    // Close the current chunk, ++seq. Caller then calls open_chunk() for the next chunk. Does
    // NOT stop or drain the ring.
    bool next_chunk();
    // Close all files (end of capture). Idempotent.
    bool close();

    std::int64_t chunk_seq() const { return seq_; }
    std::size_t nchan() const { return nchan_; }
    // Total bytes written to channel 0 (all channels are written in lockstep, so this doubles as
    // the per-channel byte count used by summary/status).
    std::uint64_t bytes_written_per_ch() const;
    const std::string& last_error() const { return last_error_; }

private:
    std::size_t nchan_;
    std::uint64_t plan_bytes_;
    std::uint64_t sync_every_;
    NameFn namer_;
    std::vector<OutFile> files_;
    std::int64_t seq_ = 0;
    bool open_ = false;
    std::string last_error_;
};

}  // namespace cryosoop

#endif  // CRYOSOOP_COMMON_DAT_WRITER_HPP
