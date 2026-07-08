// run_control.cpp — signal handling, stop flag, exec_hook. See run_control.hpp.

#include "run_control.hpp"

#include <atomic>
#include <csignal>
#include <cstdlib>
#include <mutex>

#ifdef __linux__
#include <cstring>
#include <sys/wait.h>  // WIFEXITED / WEXITSTATUS for std::system status
#endif

namespace cryosoop {
namespace run_control {

namespace {
// Async-signal-safe stop flag written from the handler; the atomic mirror is what threads poll.
volatile std::sig_atomic_t g_stop_flag = 0;
std::atomic<bool> g_stop{false};
std::atomic<int> g_signal{0};     // last signal number received (for stop_reason)

std::mutex g_reason_mtx;
std::string g_reason;             // first explicit reason (non-signal) wins
bool g_installed = false;

void handle(int sig) {
    g_stop_flag = 1;
    g_stop.store(true, std::memory_order_release);
    g_signal.store(sig, std::memory_order_release);
}
}  // namespace

void install_signal_handlers() {
    if (g_installed) return;
    g_installed = true;
#ifdef __linux__
    // sigaction so we get reliable, non-restarting semantics (default signal() varies).
    struct sigaction sa;
    std::memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;  // no SA_RESTART: let blocking recv() return so the loop can notice g_stop
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);
#else
    std::signal(SIGINT, handle);
    std::signal(SIGTERM, handle);
#endif
}

bool stop_requested() {
    return g_stop.load(std::memory_order_acquire) || g_stop_flag != 0;
}

void request_stop(const char* reason) {
    {
        std::lock_guard<std::mutex> g(g_reason_mtx);
        if (g_reason.empty() && reason != nullptr) g_reason = reason;
    }
    g_stop_flag = 1;
    g_stop.store(true, std::memory_order_release);
}

std::string stop_reason() {
    {
        std::lock_guard<std::mutex> g(g_reason_mtx);
        if (!g_reason.empty()) return g_reason;
    }
    switch (g_signal.load(std::memory_order_acquire)) {
        case SIGINT:  return "SIGINT";
        case SIGTERM: return "SIGTERM";
        default:      return stop_requested() ? "stop_requested" : "";
    }
}

int exec_hook(const std::string& cmd) {
    // std::system returns an implementation-defined status. Normalize to an exit code.
    const int rc = std::system(cmd.c_str());
    if (rc == -1) return -1;  // could not launch a shell
#ifdef __linux__
    if (WIFEXITED(rc)) return WEXITSTATUS(rc);
    if (WIFSIGNALED(rc)) return 128 + WTERMSIG(rc);
    return rc;
#else
    return rc;  // Windows: system() returns the command's exit code directly
#endif
}

}  // namespace run_control
}  // namespace cryosoop
