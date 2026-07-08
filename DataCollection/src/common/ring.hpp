// ring.hpp — SPSC (single-producer / single-consumer) ring buffer that decouples the USB recv
// thread from disk write latency. Adapted from SoOp_StressTest's `Shared` ring
// (rx_stress_capture.cpp:192-278), generalized in two ways:
//
//   1. Byte-oriented slots. StressTest hard-coded int16 slots (sc16). Here a slot is
//      `slot_samps * nchan * elem_bytes` bytes, with `elem_bytes` chosen at runtime:
//        - radiometer sc16 -> 4 bytes/sample/channel (interleaved int16 I,Q)
//      Byte-oriented slots keep the ring element-type-agnostic.
//
//   2. Ring-only state. StressTest lumped error counters into `Shared`; those move to
//      summary.hpp (Counters). This ring owns only ring-intrinsic state: geometry, the slot
//      store, per-slot valid[] sample counts, head/tail, scratch-drop accounting
//      (ring_drop_samps / RINGFULL), ring_max_occ, and the producer_done flag.
//
// Memory model is identical to StressTest: head/tail are monotonic slot counters, producer
// publishes with release, consumer reads head with acquire (and vice-versa). Exactly one
// producer thread and one consumer thread — do not share either endpoint across threads.

#ifndef CRYOSOOP_COMMON_RING_HPP
#define CRYOSOOP_COMMON_RING_HPP

#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

namespace cryosoop {

class Ring {
public:
    // slot_samps      : samples per channel per slot (radiometer: e.g. 250000)
    // nchan           : channels interleaved per slot (side-by-side, not IQ-interleaved across ch)
    // elem_bytes      : bytes per sample per channel (4 for sc16)
    // requested_bytes : desired total ring size (ring_mb << 20)
    // clamp_memavail  : on Linux, clamp so ring + 1 GiB headroom fits in MemAvailable
    // min_slots       : throw std::runtime_error if fewer than this many slots fit
    Ring(std::size_t slot_samps, std::size_t nchan, std::size_t elem_bytes,
         std::uint64_t requested_bytes, bool clamp_memavail = true,
         std::size_t min_slots = 64);

    // ---- geometry ---------------------------------------------------------
    std::size_t nslots() const { return nslots_; }
    std::size_t nchan() const { return nchan_; }
    std::size_t slot_samps() const { return slot_samps_; }
    std::size_t elem_bytes() const { return elem_bytes_; }
    std::size_t slot_bytes_per_ch() const { return slot_samps_ * elem_bytes_; }
    std::uint64_t actual_bytes() const {
        return std::uint64_t(nslots_) * nchan_ * slot_bytes_per_ch();
    }

    // ---- raw slot access (idx is a monotonic counter; wraps internally) ---
    // Returns a byte pointer to the start of channel `ch` within slot `idx`. Callers cast to
    // int16_t* (sc16) as appropriate.
    std::uint8_t* slot_ptr(std::uint64_t idx, std::size_t ch) {
        return ring_.data() + ((idx % nslots_) * nchan_ + ch) * slot_bytes_per_ch();
    }
    const std::uint8_t* slot_ptr(std::uint64_t idx, std::size_t ch) const {
        return ring_.data() + ((idx % nslots_) * nchan_ + ch) * slot_bytes_per_ch();
    }

    // ---- occupancy --------------------------------------------------------
    bool full() const {  // producer view: no free slot to write into
        return (head_.load(std::memory_order_relaxed) -
                tail_.load(std::memory_order_acquire)) >= std::uint64_t(nslots_);
    }
    std::uint64_t occupancy() const {
        return head_.load(std::memory_order_acquire) - tail_.load(std::memory_order_acquire);
    }

    // ---- producer ---------------------------------------------------------
    // Pointer to the current head slot for channel `ch` (write target when !full()).
    std::uint8_t* head_slot(std::size_t ch) {
        return slot_ptr(head_.load(std::memory_order_relaxed), ch);
    }
    // Record `n_samps` valid samples in the head slot and advance head (release). Also updates
    // ring_max_occ. Call exactly once per filled slot, only when !full().
    void publish(std::uint32_t n_samps);
    // Producer saw data it could not store because the ring was full (recv'd into scratch and
    // dropped): count the lost samples (RINGFULL accounting).
    void add_ring_drop(std::uint64_t n_samps) {
        ring_drop_samps_.fetch_add(n_samps, std::memory_order_relaxed);
    }
    void set_producer_done() { producer_done_.store(true, std::memory_order_release); }

    // ---- consumer ---------------------------------------------------------
    bool has_data() const {  // consumer view: a published slot is waiting
        return tail_.load(std::memory_order_relaxed) < head_.load(std::memory_order_acquire);
    }
    bool producer_done() const { return producer_done_.load(std::memory_order_acquire); }
    std::uint32_t tail_valid() const { return valid_[tail_.load(std::memory_order_relaxed) % nslots_]; }
    const std::uint8_t* tail_slot(std::size_t ch) const {
        return slot_ptr(tail_.load(std::memory_order_relaxed), ch);
    }
    // Done with the current tail slot; advance tail (release) so the producer may reuse it.
    void release() {
        tail_.store(tail_.load(std::memory_order_relaxed) + 1, std::memory_order_release);
    }

    // ---- stats ------------------------------------------------------------
    std::uint64_t ring_drop_samps() const { return ring_drop_samps_.load(std::memory_order_relaxed); }
    std::uint64_t ring_max_occ() const { return ring_max_occ_.load(std::memory_order_relaxed); }
    double ring_max_occ_pct() const {
        return nslots_ ? 100.0 * double(ring_max_occ_.load(std::memory_order_relaxed)) / double(nslots_)
                       : 0.0;
    }

    // ---- clamp reporting (for the driver to log at startup) ---------------
    bool was_clamped() const { return was_clamped_; }
    const std::string& clamp_message() const { return clamp_message_; }
    std::uint64_t mem_available() const { return mem_available_; }

    // Portable MemAvailable probe: reads /proc/meminfo on Linux, returns 0 elsewhere
    // (0 == "unknown", callers then trust the configured size). Exposed for pre-flight checks.
    static std::uint64_t mem_available_bytes();

private:
    std::size_t nslots_ = 0;
    std::size_t nchan_ = 0;
    std::size_t slot_samps_ = 0;
    std::size_t elem_bytes_ = 0;

    std::vector<std::uint8_t> ring_;   // nslots * nchan * slot_bytes_per_ch, pre-faulted
    std::vector<std::uint32_t> valid_; // valid sample count per slot

    std::atomic<std::uint64_t> head_{0};
    std::atomic<std::uint64_t> tail_{0};
    std::atomic<std::uint64_t> ring_drop_samps_{0};
    std::atomic<std::uint64_t> ring_max_occ_{0};
    std::atomic<bool> producer_done_{false};

    bool was_clamped_ = false;
    std::string clamp_message_;
    std::uint64_t mem_available_ = 0;
};

}  // namespace cryosoop

#endif  // CRYOSOOP_COMMON_RING_HPP
