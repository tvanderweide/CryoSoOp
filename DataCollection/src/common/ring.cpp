// ring.cpp — Ring implementation. See ring.hpp for the design notes.

#include "ring.hpp"

#include <stdexcept>
#include <string>

#ifdef __linux__
#include <fstream>
#endif

namespace cryosoop {

std::uint64_t Ring::mem_available_bytes() {
#ifdef __linux__
    // Same source StressTest used: MemAvailable is the kernel's own estimate of how much can be
    // allocated without swapping, which is exactly the ceiling we want for a pre-faulted ring.
    std::ifstream f("/proc/meminfo");
    std::string key;
    std::uint64_t val = 0;
    while (f >> key >> val) {
        if (key == "MemAvailable:") return val * 1024ull;  // reported in kB
        f.ignore(256, '\n');
    }
    return 0;
#else
    // No portable equivalent worth trusting here — return 0 so the caller keeps the configured
    // ring size (the ring is only ever *reduced* by the clamp, never grown).
    return 0;
#endif
}

Ring::Ring(std::size_t slot_samps, std::size_t nchan, std::size_t elem_bytes,
           std::uint64_t requested_bytes, bool clamp_memavail, std::size_t min_slots)
    : nchan_(nchan), slot_samps_(slot_samps), elem_bytes_(elem_bytes) {
    if (slot_samps == 0 || nchan == 0 || elem_bytes == 0)
        throw std::runtime_error("Ring: slot_samps, nchan, elem_bytes must all be > 0");

    const std::uint64_t slot_bytes_total =
        std::uint64_t(nchan) * slot_samps * elem_bytes;  // bytes per slot across all channels

    std::uint64_t want = requested_bytes;
    mem_available_ = clamp_memavail ? mem_available_bytes() : 0;

    // Clamp so ring + 1 GiB headroom fits in MemAvailable (Linux only; elsewhere mem_available_
    // is 0 and we trust the configured size). Identical policy to StressTest.
    constexpr std::uint64_t kHeadroom = 1ull << 30;  // 1 GiB
    if (mem_available_ > 0 && want + kHeadroom > mem_available_) {
        const std::uint64_t clamped = mem_available_ > kHeadroom ? mem_available_ - kHeadroom : 0;
        was_clamped_ = true;
        clamp_message_ = "ring clamped to " + std::to_string(clamped >> 20) +
                         " MB (MemAvailable " + std::to_string(mem_available_ >> 20) +
                         " MB, requested " + std::to_string(requested_bytes >> 20) + " MB)";
        want = clamped;
    }

    nslots_ = static_cast<std::size_t>(want / slot_bytes_total);
    if (nslots_ < min_slots) {
        throw std::runtime_error(
            "Ring: not enough memory for a useful ring (" + std::to_string(nslots_) +
            " slots, need >= " + std::to_string(min_slots) +
            "); reduce ring_mb, slot size, or free memory");
    }

    // assign() writes every byte, which also pre-faults the pages so the first recv into the
    // ring never eats a minor-fault storm mid-capture.
    ring_.assign(nslots_ * slot_bytes_total, 0);
    valid_.assign(nslots_, 0);
}

void Ring::publish(std::uint32_t n_samps) {
    const std::uint64_t h = head_.load(std::memory_order_relaxed);
    valid_[h % nslots_] = n_samps;
    head_.store(h + 1, std::memory_order_release);

    // Track peak occupancy (relaxed CAS loop; single producer so contention is only vs. the
    // consumer's tail advance, which only ever lowers occupancy).
    const std::uint64_t occ = (h + 1) - tail_.load(std::memory_order_relaxed);
    std::uint64_t prev = ring_max_occ_.load(std::memory_order_relaxed);
    while (occ > prev && !ring_max_occ_.compare_exchange_weak(prev, occ, std::memory_order_relaxed)) {
    }
}

}  // namespace cryosoop
