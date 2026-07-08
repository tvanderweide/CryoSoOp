// rf_control.cpp — see rf_control.hpp.

#include "device/rf_control.hpp"

#include <algorithm>
#include <chrono>
#include <string>
#include <thread>
#include <vector>

namespace cryosoop {

// Poll one channel's lo_locked sensor until asserted or the deadline. `is_tx` selects the TX/RX
// sensor family. Channels without an lo_locked sensor are treated as "locked" (nothing to wait on),
// matching change_center_freq(). Returns false only on a genuine timeout.
bool wait_lo_locked(UsrpSession& session, bool is_tx, std::size_t ch, double poll_s,
                    double timeout_s) {
    auto usrp = session.usrp();
    const std::vector<std::string> names =
        is_tx ? usrp->get_tx_sensor_names(ch) : usrp->get_rx_sensor_names(ch);
    if (std::find(names.begin(), names.end(), "lo_locked") == names.end()) return true;

    const auto t0 = std::chrono::steady_clock::now();
    for (;;) {
        const bool locked =
            is_tx ? usrp->get_tx_sensor("lo_locked", ch).to_bool()
                  : usrp->get_rx_sensor("lo_locked", ch).to_bool();
        if (locked) return true;
        if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() >
            timeout_s)
            return false;
        std::this_thread::sleep_for(
            std::chrono::duration<double>(std::max(1e-4, poll_s)));
    }
}

}  // namespace cryosoop
