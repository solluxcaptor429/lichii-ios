// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

// Small UIKit/Foundation helpers for the iOS build of the SDL frontend (implemented in
// ios_support.mm). Everything here is safe to call from the main thread; the background-task
// helpers may be called from any thread.

#include <cstdint>

namespace IosSupport {

/// iOS major version (17, 26, 27, ...).
int MajorVersion();

/// True when this device runs the Trusted Execution Monitor (iOS 26+ on A15/M-class and newer,
/// every device on iOS 27+). Mirrors StikDebug's own detection, so the two agree on whether a
/// JIT script is required.
bool HasTxm();

/// True when an app handling `scheme://` is installed (the scheme must be listed in
/// LSApplicationQueriesSchemes).
bool CanOpenScheme(const char* scheme);

/// Open a URL with UIApplication (asynchronous; returns false only when iOS refused the request).
bool OpenUrl(const char* url);

/// Ask iOS for background execution time (about 30 s) while another app handles our request.
/// Returns 0 when unavailable.
std::uint64_t BeginBackgroundTask(const char* name);
void EndBackgroundTask(std::uint64_t task);

/// True while the app is in the foreground (active or inactive but visible).
bool IsForeground();

/// Audio: playback category (plays with the silent switch on) and a 20 ms hardware buffer.
/// Call before SDL opens the audio device.
void ConfigureAudioSession();

/// On-screen controls. Button ids are InputCommon::VirtualGamepad::VirtualButton values, stick
/// ids VirtualStick values; stick y is +1 at the top.
using TouchButtonFn = void (*)(int button, bool pressed);
using TouchStickFn = void (*)(int stick, float x, float y);

/// Adds the overlay on top of the SDL window (`ui_window` is its UIWindow*). Touches outside
/// the controls still reach the game's touch screen. Main thread only.
void InstallTouchControls(void* ui_window, TouchButtonFn button, TouchStickFn stick);

/// Shows or hides the overlay (hidden while a physical controller is connected). Releases
/// everything held when hiding. Main thread only.
void SetTouchControlsVisible(bool visible);

} // namespace IosSupport
