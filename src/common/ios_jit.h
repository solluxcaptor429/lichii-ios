// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include <cstddef>
#include <string>

// iOS JIT substrate.
//
// A sideloaded app cannot create executable memory itself. On iOS 17-25 it is enough that a
// debugger has been attached once (CS_DEBUGGED): RWX mappings then work. On iOS 26+ with the
// Trusted Execution Monitor (TXM) that is no longer enough: every executable page has to be
// prepared through the debug connection. StikDebug (on-device debugger) attaches and runs its
// "universal" script, which services a breakpoint-based RPC: the app executes `brk #0xf00d` with
// x16 = command, x0/x1 = arguments; the debugger allocates an R-X region in the process, touches
// every 16 KiB page through the debugger (which is what makes the pages usable) and returns the
// address in x0. The app then makes a writable alias of the same pages with vm_remap and emits
// code through the alias while executing through the R-X view.
//
// Allocation is one-shot: after the pool is acquired the debugger is detached and no further
// `brk` may be issued (an unserviced `brk` is a fatal SIGTRAP, guarded here by a SIGTRAP handler
// that turns it into a null result). Every dynarmic code block is therefore carved out of this
// single pool, which must exist before the emulated CPU starts.
namespace Common::IosJit {

enum class State {
    Waiting,   ///< no debugger yet
    Acquiring, ///< debugger attached, pool being prepared
    Ready,     ///< pool ready, code may be emitted
    Failed,    ///< see GetError()
};

/// True while a debugger is attached (P_TRACED).
bool DebuggerAttached();
/// True once the process has been debugged (CS_DEBUGGED).
bool Debugged();
/// True after the pool is ready.
bool PoolReady();

/// Start the background thread that waits for the debugger and acquires a pool of `bytes`.
/// `txm`: this device requires the breakpoint protocol (iOS 26+ with TXM); otherwise a plain
/// RWX mapping is used once CS_DEBUGGED is set.
void StartAcquire(std::size_t bytes, bool txm);
State GetState();
std::string GetError();

/// Carve a dual-mapped block out of the pool. *wmem is the writable alias, *xmem the executable
/// view of the same pages. Returns false when the pool is missing or exhausted.
bool Alloc(std::size_t bytes, void** wmem, void** xmem);

} // namespace Common::IosJit

extern "C" {
/// C entry point used by the patched oaknut::CodeBlock.
int lichii_ios_jit_alloc(std::size_t bytes, void** wmem, void** xmem);
}
