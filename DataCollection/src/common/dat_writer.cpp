// dat_writer.cpp — OutFile + DatWriter. See dat_writer.hpp for design notes.
//
// Linux path lifts StressTest's OutFile verbatim (raw fd, fallocate, sync_file_range +
// posix_fadvise page-cache hygiene, ftruncate + fdatasync on close). Non-Linux path is a
// std::FILE* stand-in so every common TU compiles under MSVC — it drops the syscalls to no-ops
// and relies on buffered fwrite. Do NOT deploy the non-Linux path for real captures.

#include "dat_writer.hpp"

#include <utility>

#ifdef __linux__
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#else
#include <cstdio>
#endif

namespace cryosoop {

// ============================================================ OutFile

OutFile::~OutFile() { close_file(); }

OutFile::OutFile(OutFile&& o) noexcept { move_from(o); }

OutFile& OutFile::operator=(OutFile&& o) noexcept {
    if (this != &o) {
        close_file();
        move_from(o);
    }
    return *this;
}

void OutFile::move_from(OutFile& o) noexcept {
#ifdef __linux__
    fd_ = o.fd_;
    o.fd_ = -1;
#else
    fp_ = o.fp_;
    o.fp_ = nullptr;
#endif
    written_ = o.written_;
    synced_ = o.synced_;
    sync_every_ = o.sync_every_;
    path_ = std::move(o.path_);
    o.written_ = o.synced_ = 0;
}

bool OutFile::is_open() const {
#ifdef __linux__
    return fd_ >= 0;
#else
    return fp_ != nullptr;
#endif
}

bool OutFile::open_file(const std::string& path, std::uint64_t plan_bytes,
                        std::uint64_t sync_every_bytes) {
    path_ = path;
    written_ = synced_ = 0;
    sync_every_ = sync_every_bytes;
#ifdef __linux__
    fd_ = ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd_ < 0) return false;
    // Reserve extents so allocation can't stall mid-stream and ENOSPC hits here, not mid-write.
    // Tolerate failure (e.g. filesystems without fallocate support).
    if (plan_bytes > 0) { (void)::fallocate(fd_, 0, 0, off_t(plan_bytes)); }
    return true;
#else
    (void)plan_bytes;
    fp_ = std::fopen(path.c_str(), "wb");
    return fp_ != nullptr;
#endif
}

bool OutFile::write_block(const void* p, std::size_t bytes) {
#ifdef __linux__
    const char* c = static_cast<const char*>(p);
    std::size_t left = bytes;
    while (left > 0) {
        ssize_t n = ::write(fd_, c, left);
        if (n < 0) {
            if (errno == EINTR) continue;  // retry interrupted write
            return false;
        }
        c += n;
        left -= std::size_t(n);
    }
    written_ += bytes;
    if (sync_every_ > 0 && written_ - synced_ >= sync_every_) {
        // Start writeback early in bounded bursts and drop clean pages: keeps dirty/cached
        // memory flat instead of letting the kernel hoard GBs and then throttle write().
        ::sync_file_range(fd_, off_t(synced_), off_t(written_ - synced_), SYNC_FILE_RANGE_WRITE);
        ::posix_fadvise(fd_, 0, off_t(synced_), POSIX_FADV_DONTNEED);
        synced_ = written_;
    }
    return true;
#else
    if (!fp_) return false;
    if (std::fwrite(p, 1, bytes, fp_) != bytes) return false;
    written_ += bytes;
    return true;  // no page-cache management off Linux
#endif
}

bool OutFile::close_file() {
#ifdef __linux__
    if (fd_ < 0) return true;
    bool ok = true;
    if (::ftruncate(fd_, off_t(written_)) != 0) ok = false;  // trim fallocate over-reserve
    if (::fdatasync(fd_) != 0) ok = false;
    if (::close(fd_) != 0) ok = false;
    fd_ = -1;
    return ok;
#else
    if (!fp_) return true;
    bool ok = (std::fflush(fp_) == 0);
    if (std::fclose(fp_) != 0) ok = false;
    fp_ = nullptr;
    return ok;
#endif
}

// ============================================================ DatWriter

DatWriter::DatWriter(std::size_t nchan, std::uint64_t plan_bytes_per_chunk_per_ch,
                     std::uint64_t sync_every_bytes, NameFn namer)
    : nchan_(nchan),
      plan_bytes_(plan_bytes_per_chunk_per_ch),
      sync_every_(sync_every_bytes),
      namer_(std::move(namer)),
      files_(nchan) {}

DatWriter::~DatWriter() { close(); }

bool DatWriter::open_chunk() {
    for (std::size_t i = 0; i < nchan_; ++i) {
        const std::string path = namer_(i, seq_);
        if (!files_[i].open_file(path, plan_bytes_, sync_every_)) {
            last_error_ = "open_failed:" + path;
            // Roll back any files already opened for this chunk.
            for (std::size_t j = 0; j < i; ++j) files_[j].close_file();
            open_ = false;
            return false;
        }
    }
    open_ = true;
    return true;
}

bool DatWriter::write_ch(std::size_t ch, const void* p, std::size_t bytes) {
    if (ch >= nchan_ || !open_) {
        last_error_ = "write_ch: bad channel or chunk not open";
        return false;
    }
    if (!files_[ch].write_block(p, bytes)) {
        last_error_ = "write_failed:" + files_[ch].path();
        return false;
    }
    return true;
}

bool DatWriter::next_chunk() {
    bool ok = true;
    for (std::size_t i = 0; i < nchan_; ++i) {
        if (!files_[i].close_file()) {
            ok = false;
            last_error_ = "close_failed:" + files_[i].path();
        }
    }
    open_ = false;
    ++seq_;
    return ok;
}

bool DatWriter::close() {
    if (!open_) return true;
    bool ok = true;
    for (std::size_t i = 0; i < nchan_; ++i) {
        if (!files_[i].close_file()) {
            ok = false;
            last_error_ = "close_failed:" + files_[i].path();
        }
    }
    open_ = false;
    return ok;
}

std::uint64_t DatWriter::bytes_written_per_ch() const {
    return files_.empty() ? 0 : files_[0].written();
}

}  // namespace cryosoop
