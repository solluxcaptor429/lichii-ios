// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#include "yuzu_cmd/ios_support.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <cstdio>
#include <string>
#include <sys/utsname.h>

namespace IosSupport {

int MajorVersion() {
    @autoreleasepool {
        return static_cast<int>([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion);
    }
}

namespace {

std::string HardwareIdentifier() {
    struct utsname info {};
    uname(&info);
    return info.machine;
}

// "iPhone14,2" -> (14, 2); false for anything else (iPad models are handled by the caller).
bool ParseModel(const std::string& id, const char* prefix, int& major, int& minor) {
    const std::string p = prefix;
    if (id.compare(0, p.size(), p) != 0) {
        return false;
    }
    return std::sscanf(id.c_str() + p.size(), "%d,%d", &major, &minor) == 2;
}

} // Anonymous namespace

bool HasTxm() {
    const int os = MajorVersion();
    if (os < 26) {
        return false;
    }
    const std::string hw = HardwareIdentifier();
    if (os >= 27) {
        // Every iOS 27 device except the 7th generation iPad (A10).
        return hw != "iPad8,11" && hw != "iPad8,12";
    }
    int major = 0, minor = 0;
    if (ParseModel(hw, "iPhone", major, minor)) {
        return major > 14 || (major == 14 && minor >= 2); // iPhone 13 (A15) and newer
    }
    if (ParseModel(hw, "iPad", major, minor)) {
        return major > 14 || (major == 14 && minor >= 5); // M1 iPads and newer
    }
    return false;
}

bool CanOpenScheme(const char* scheme) {
    @autoreleasepool {
        NSString* text = [NSString stringWithFormat:@"%s://", scheme];
        NSURL* url = [NSURL URLWithString:text];
        if (url == nil) {
            return false;
        }
        return [[UIApplication sharedApplication] canOpenURL:url];
    }
}

bool OpenUrl(const char* url) {
    @autoreleasepool {
        NSURL* target = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
        if (target == nil) {
            return false;
        }
        [[UIApplication sharedApplication] openURL:target options:@{} completionHandler:nil];
        return true;
    }
}

std::uint64_t BeginBackgroundTask(const char* name) {
    @autoreleasepool {
        __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
        task = [[UIApplication sharedApplication]
            beginBackgroundTaskWithName:[NSString stringWithUTF8String:name]
                      expirationHandler:^{
                          [[UIApplication sharedApplication] endBackgroundTask:task];
                          task = UIBackgroundTaskInvalid;
                      }];
        return task == UIBackgroundTaskInvalid ? 0 : static_cast<std::uint64_t>(task);
    }
}

void EndBackgroundTask(std::uint64_t task) {
    if (task == 0) {
        return;
    }
    @autoreleasepool {
        [[UIApplication sharedApplication] endBackgroundTask:static_cast<UIBackgroundTaskIdentifier>(task)];
    }
}

bool IsForeground() {
    @autoreleasepool {
        return [[UIApplication sharedApplication] applicationState] != UIApplicationStateBackground;
    }
}

} // namespace IosSupport
