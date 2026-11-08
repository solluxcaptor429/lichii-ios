// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include <cstddef>
#include <string>

// iOS 26+/TXM JIT substrate.
//
// A sideloaded app cannot create executable memory itself. StikDebug (on-device debugger) attaches
// and runs its "universal" script, which services a breakpoint-based RPC: the app executes
// `brk #0xf00d` with x16 = command, x0/x1 = arguments, and the debugger allocates an R-X region in
// the process, touches every 16 KiB page through the debugger (which is what makes the pages
// usable), and returns the address in x0. The app then makes a writable alias of the same pages
// with vm_remap and emits code through the alias while executing through the R-X view.
//
// Allocation is one-shot: after the pool is acquired the debugger is detached and no further
// `brk` may be issued (an unserviced `brk` is a fatal SIGTRAP). Every dynarmic code block is
// therefore carved out of this single pool.
namespace Common::IosJit {

/// True while a debugger is attached (P_TRACED).
bool DebuggerAttached();
/// True once the process has been debugged (CS_DEBUGGED); JIT pages may then be used.
bool Debugged();
/// True after AcquirePool succeeded.
bool PoolReady();

/// Acquire the JIT pool. Must run while StikDebug's universal script is attached; falls back to a
/// plain RWX mapping (pre-TXM devices) when the breakpoint is not serviced.
bool AcquirePool(std::size_t bytes, std::string& error);

/// Carve a dual-mapped block out of the pool. *wmem is the writable alias, *xmem the executable
/// view of the same pages. Returns false when the pool is missing or exhausted.
bool Alloc(std::size_t bytes, void** wmem, void** xmem);

} // namespace Common::IosJit

extern "C" {
/// C entry point used by the patched oaknut::CodeBlock.
int lichii_ios_jit_alloc(std::size_t bytes, void** wmem, void** xmem);
}
