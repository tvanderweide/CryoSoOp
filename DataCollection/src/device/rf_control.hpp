// rf_control.hpp — LO-lock verification shared by the device layer.
//
// The radiometer sets each RX channel's freq/gain/bw/antenna once at device setup and then polls
// lo_locked before streaming. This header exposes that lock-wait so the driver does not hand-roll
// its own poll loop. Adapts the run_20260311.py change_center_freq() lo_locked polling (314-344):
// a fixed sleep is replaced by an lo_locked poll (lo_lock_poll_s interval, lo_lock_timeout_s cap)
// on every channel that exposes an lo_locked sensor.

#ifndef CRYOSOOP_DEVICE_RF_CONTROL_HPP
#define CRYOSOOP_DEVICE_RF_CONTROL_HPP

#include <cstddef>

#include "device/usrp_session.hpp"

namespace cryosoop {

// Poll channel `ch`'s lo_locked sensor (TX family when `is_tx`, else RX) until it asserts or
// `timeout_s` elapses, sampling every `poll_s`. Channels with no lo_locked sensor count as locked.
// Returns false only on a genuine timeout.
bool wait_lo_locked(UsrpSession& session, bool is_tx, std::size_t ch, double poll_s,
                    double timeout_s);

}  // namespace cryosoop

#endif  // CRYOSOOP_DEVICE_RF_CONTROL_HPP
