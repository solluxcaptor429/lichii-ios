// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#include "common/ios_jit.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <thread>

#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/ucontext.h>
#include <unistd.h>

#include "common/logging.h"

extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

namespace Common::IosJit {
namespace {

constexpr unsigned int kCsOpsStatus = 0;
constexpr int kCsDebugged = 0x10000000;
constexpr std::size_t kJitPageSize = 0x4000;
constexpr std::uint32_t kBrkF00d = 0xD43E01A0; // brk #0xf00d

struct Pool {
    std::uint8_t* rx{};
    std::uint8_t* rw{};
    std::size_t size{};
    std::size_t used{};
};
Pool g_pool;
std::mutex g_pool_mutex;
std::atomic<bool> g_pool_ready{false};
std::atomic<State> g_state{State::Waiting};
std::mutex g_error_mutex;
std::string g_error;
std::atomic<bool> g_thread_started{false};

void SetFailed(const std::string& error) {
    {
        std::scoped_lock lock{g_error_mutex};
        g_error = error;
    }
    LOG_CRITICAL(Common, "iOS JIT: {}", error);
    g_state = State::Failed;
}

// brk-based "syscalls" serviced by StikDebug's universal.js (x16 = command).
__attribute__((noinline, optnone)) void* Jit26PrepareRegion(void* addr, std::size_t len) {
    register void* x0 __asm__("x0") = addr;
    register std::size_t x1 __asm__("x1") = len;
    __asm__ volatile(
        "mov x16, #1\n"
        "brk #0xf00d\n"
        : "+r"(x0)
        : "r"(x1)
        : "x16", "memory");
    return x0;
}

__attribute__((noinline, optnone)) void Jit26Detach() {
    __asm__ volatile(
        "mov x16, #0\n"
        "brk #0xf00d\n" ::
            : "x16", "memory");
}

// If nobody services our brk (debugger gone, or attached without the universal script), skip it
// and return nullptr instead of dying. Any other trap gets the default action back so real
// crashes still produce reports. While a debugger is attached the exception goes to it first and
// this handler never runs.
void SigtrapHandler(int sig, siginfo_t*, void* context) {
    auto* uc = static_cast<ucontext_t*>(context);
    const std::uint64_t pc = uc->uc_mcontext->__ss.__pc;
    if ((pc & 3) != 0 || *reinterpret_cast<const std::uint32_t*>(pc) != kBrkF00d) {
        struct sigaction dfl {};
        dfl.sa_handler = SIG_DFL;
        sigaction(sig, &dfl, nullptr);
        return;
    }
    uc->uc_mcontext->__ss.__pc += 4;
    uc->uc_mcontext->__ss.__x[0] = 0;
}

void InstallTrapGuard() {
    struct sigaction sa {};
    sa.sa_flags = SA_SIGINFO;
    sa.sa_sigaction = SigtrapHandler;
    sigaction(SIGTRAP, &sa, nullptr);
}

std::size_t AlignUp(std::size_t v, std::size_t a) {
    return (v + a - 1) & ~(a - 1);
}

bool SelfTest(std::uint8_t* rw, std::uint8_t* rx) {
    // mov w0, #42 ; ret
    const std::uint32_t code[2] = {0x52800540, 0xD65F03C0};
    std::memcpy(rw, code, sizeof(code));
    sys_icache_invalidate(rx, sizeof(code));
    auto fn = reinterpret_cast<int (*)()>(rx);
    return fn() == 42;
}

bool PublishPool(std::uint8_t* rx, std::uint8_t* rw, std::size_t bytes) {
    if (!SelfTest(rw, rx)) {
        SetFailed("JIT self-test failed: code written through the alias did not execute");
        return false;
    }
    {
        std::scoped_lock lock{g_pool_mutex};
        g_pool = Pool{rx, rw, bytes, 0};
        g_pool_ready = true;
    }
    g_state = State::Ready;
    LOG_INFO(Common, "iOS JIT: pool ready ({} MiB), self-test passed", bytes >> 20);
    return true;
}

// TXM: ask the attached universal script for the region, alias it writable, detach.
bool AcquireThroughDebugger(std::size_t bytes) {
    g_state = State::Acquiring;
    InstallTrapGuard();
    LOG_INFO(Common, "iOS JIT: debugger attached, requesting {} MiB from the universal script",
             bytes >> 20);
    auto* rx = static_cast<std::uint8_t*>(Jit26PrepareRegion(nullptr, bytes));
    if (rx == nullptr) {
        SetFailed("the attached debugger did not provide executable memory. In StikDebug the "
                  "script for this app must be universal.js (or let this app request JIT itself).");
        return false;
    }
    vm_address_t alias = 0;
    vm_prot_t cur = 0, max = 0;
    kern_return_t kr = vm_remap(mach_task_self(), &alias, bytes, 0, VM_FLAGS_ANYWHERE,
                                mach_task_self(), reinterpret_cast<vm_address_t>(rx), FALSE, &cur,
                                &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        Jit26Detach();
        SetFailed(std::string("vm_remap of the JIT pool failed: ") + mach_error_string(kr));
        return false;
    }
    kr = vm_protect(mach_task_self(), alias, bytes, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        Jit26Detach();
        SetFailed(std::string("vm_protect(RW) of the JIT alias failed: ") + mach_error_string(kr));
        return false;
    }
    auto* rw = reinterpret_cast<std::uint8_t*>(alias);
    LOG_INFO(Common, "iOS JIT: debugger-provided pool rx={} rw={} ({} MiB)", fmt::ptr(rx),
             fmt::ptr(rw), bytes >> 20);
    const bool ok = PublishPool(rx, rw, bytes);
    // Done with the debugger; StikDebug returns to its UI (and to this app when it was asked
    // through its URL scheme).
    Jit26Detach();
    return ok;
}

// Pre-TXM: a debugged process may map RWX directly.
bool AcquireRwx(std::size_t bytes) {
    g_state = State::Acquiring;
    void* p = mmap(nullptr, bytes, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) {
        SetFailed(std::string("RWX mapping refused (") + strerror(errno) +
                  "): this iOS version needs StikDebug's universal script");
        return false;
    }
    auto* mem = static_cast<std::uint8_t*>(p);
    LOG_INFO(Common, "iOS JIT: RWX pool at {} ({} MiB)", fmt::ptr(mem), bytes >> 20);
    return PublishPool(mem, mem, bytes);
}

void AcquireThread(std::size_t bytes, bool txm) {
    using namespace std::chrono_literals;
    LOG_INFO(Common, "iOS JIT: waiting for a debugger (TXM: {}, debugged: {}, traced: {})", txm,
             Debugged(), DebuggerAttached());
    std::chrono::steady_clock::time_point debugged_since{};
    while (true) {
        if (txm) {
            if (DebuggerAttached()) {
                AcquireThroughDebugger(bytes);
                return;
            }
            // Debugged without a debugger attached: somebody enabled "JIT" the pre-TXM way (plain
            // attach/detach). Give the script a few seconds to show up, then explain.
            if (Debugged()) {
                const auto now = std::chrono::steady_clock::now();
                if (debugged_since == std::chrono::steady_clock::time_point{}) {
                    debugged_since = now;
                } else if (now - debugged_since > 5s) {
                    SetFailed("JIT was enabled without the universal script, which iOS 26+ needs. "
                              "Close this app, open StikDebug and enable JIT for it from this "
                              "app's own request.");
                    return;
                }
            }
        } else if (Debugged()) {
            AcquireRwx(bytes);
            return;
        }
        std::this_thread::sleep_for(50ms);
    }
}

} // Anonymous namespace

bool DebuggerAttached() {
    struct kinfo_proc info {};
    std::size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &info, &size, nullptr, 0) != 0) {
        return false;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

bool Debugged() {
    int flags = 0;
    if (csops(getpid(), kCsOpsStatus, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & kCsDebugged) != 0;
}

bool PoolReady() {
    return g_pool_ready.load();
}

void StartAcquire(std::size_t bytes, bool txm) {
    if (g_thread_started.exchange(true)) {
        return;
    }
    std::thread(AcquireThread, AlignUp(bytes, kJitPageSize), txm).detach();
}

State GetState() {
    return g_state.load();
}

std::string GetError() {
    std::scoped_lock lock{g_error_mutex};
    return g_error;
}

bool Alloc(std::size_t bytes, void** wmem, void** xmem) {
    std::scoped_lock lock{g_pool_mutex};
    if (!g_pool_ready) {
        LOG_CRITICAL(Common, "iOS JIT: code block requested before the pool exists");
        return false;
    }
    bytes = AlignUp(bytes, kJitPageSize);
    if (g_pool.used + bytes > g_pool.size) {
        LOG_CRITICAL(Common, "iOS JIT: pool exhausted ({} MiB requested, {} of {} MiB used)",
                     bytes >> 20, g_pool.used >> 20, g_pool.size >> 20);
        return false;
    }
    *wmem = g_pool.rw + g_pool.used;
    *xmem = g_pool.rx + g_pool.used;
    g_pool.used += bytes;
    LOG_INFO(Common, "iOS JIT: handed out {} MiB (x={}, w={}), {} MiB left", bytes >> 20,
             fmt::ptr(*xmem), fmt::ptr(*wmem), (g_pool.size - g_pool.used) >> 20);
    return true;
}

} // namespace Common::IosJit

extern "C" int lichii_ios_jit_alloc(std::size_t bytes, void** wmem, void** xmem) {
    return Common::IosJit::Alloc(bytes, wmem, xmem) ? 1 : 0;
}
