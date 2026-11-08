// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#include "yuzu_cmd/ios_support.h"

#import <AVFoundation/AVFoundation.h>
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


// ---------------------------------------------------------------------------------- audio

void ConfigureAudioSession() {
    @autoreleasepool {
        AVAudioSession* session = [AVAudioSession sharedInstance];
        NSError* error = nil;
        [session setCategory:AVAudioSessionCategoryPlayback error:&error];
        [session setPreferredSampleRate:48000 error:&error];
        [session setPreferredIOBufferDuration:0.02 error:&error];
        [session setActive:YES error:&error];
    }
}

} // namespace IosSupport

// ---------------------------------------------------------------------------- touch controls

static IosSupport::TouchButtonFn g_button_fn = nullptr;
static IosSupport::TouchStickFn g_stick_fn = nullptr;

namespace {
enum : int {
    kA = 0, kB = 1, kX = 2, kY = 3, kLS = 4, kRS = 5, kL = 6, kR = 7, kZL = 8, kZR = 9,
    kPlus = 10, kMinus = 11, kLeft = 12, kUp = 13, kRight = 14, kDown = 15, kHome = 18,
};
constexpr CGFloat kIdleAlpha = 0.45;
constexpr CGFloat kPressedAlpha = 0.85;
} // Anonymous namespace

// Lets touches through to the game wherever there is no control.
@interface LichiiPassView : UIView
@end
@implementation LichiiPassView
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    UIView* hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

static void LichiiStyle(UIView* view) {
    view.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
    view.layer.borderWidth = 1.5;
    view.alpha = kIdleAlpha;
    view.multipleTouchEnabled = YES;
}

@interface LichiiButton : UIView
@property(nonatomic) int buttonId;
@property(nonatomic) NSUInteger held;
@property(nonatomic, strong) UILabel* label;
@end
@implementation LichiiButton
- (instancetype)initWithId:(int)buttonId title:(NSString*)title {
    if ((self = [super initWithFrame:CGRectZero])) {
        _buttonId = buttonId;
        LichiiStyle(self);
        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.text = title;
        _label.textColor = UIColor.whiteColor;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.label.frame = CGRectInset(self.bounds, 4, 2);
    self.label.font = [UIFont boldSystemFontOfSize:MIN(self.bounds.size.height * 0.42, 22)];
}
- (void)setDown:(BOOL)down {
    if (g_button_fn) {
        g_button_fn(self.buttonId, down);
    }
    self.alpha = down ? kPressedAlpha : kIdleAlpha;
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (self.held == 0) {
        [self setDown:YES];
    }
    self.held += touches.count;
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    self.held -= MIN(self.held, touches.count);
    if (self.held == 0) {
        [self setDown:NO];
    }
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self touchesEnded:touches withEvent:event];
}
- (void)releaseAll {
    if (self.held != 0) {
        self.held = 0;
        [self setDown:NO];
    }
}
@end

@interface LichiiStick : UIView
@property(nonatomic) int stickId;
@property(nonatomic, strong) UIView* knob;
@property(nonatomic, weak) UITouch* touch;
@end
@implementation LichiiStick
- (instancetype)initWithId:(int)stickId {
    if ((self = [super initWithFrame:CGRectZero])) {
        _stickId = stickId;
        LichiiStyle(self);
        _knob = [[UIView alloc] initWithFrame:CGRectZero];
        _knob.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.6];
        _knob.userInteractionEnabled = NO;
        [self addSubview:_knob];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat d = self.bounds.size.width * 0.42;
    self.layer.cornerRadius = self.bounds.size.width / 2;
    self.knob.bounds = CGRectMake(0, 0, d, d);
    self.knob.layer.cornerRadius = d / 2;
    if (self.touch == nil) {
        self.knob.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    }
}
- (void)moveTo:(CGPoint)p {
    const CGFloat r = self.bounds.size.width / 2;
    CGFloat dx = (p.x - r) / r;
    CGFloat dy = (p.y - r) / r;
    const CGFloat len = sqrt(dx * dx + dy * dy);
    if (len > 1.0) {
        dx /= len;
        dy /= len;
    }
    self.knob.center = CGPointMake(r + dx * r, r + dy * r);
    if (g_stick_fn) {
        g_stick_fn(self.stickId, static_cast<float>(dx), static_cast<float>(-dy));
    }
}
- (void)recenter {
    self.touch = nil;
    self.alpha = kIdleAlpha;
    self.knob.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    if (g_stick_fn) {
        g_stick_fn(self.stickId, 0.0f, 0.0f);
    }
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (self.touch == nil) {
        self.touch = touches.anyObject;
        self.alpha = kPressedAlpha;
        [self moveTo:[self.touch locationInView:self]];
    }
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (self.touch && [touches containsObject:self.touch]) {
        [self moveTo:[self.touch locationInView:self]];
    }
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (self.touch && [touches containsObject:self.touch]) {
        [self recenter];
    }
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self touchesEnded:touches withEvent:event];
}
@end

@interface LichiiOverlay : LichiiPassView
@property(nonatomic, strong) NSDictionary<NSNumber*, LichiiButton*>* buttons;
@property(nonatomic, strong) LichiiStick* leftStick;
@property(nonatomic, strong) LichiiStick* rightStick;
@end
@implementation LichiiOverlay
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES;
        self.backgroundColor = UIColor.clearColor;
        NSMutableDictionary* b = [NSMutableDictionary dictionary];
        struct Def {
            int id;
            NSString* title;
        };
        const Def defs[] = {
            {kA, @"A"}, {kB, @"B"}, {kX, @"X"}, {kY, @"Y"}, {kL, @"L"}, {kR, @"R"},
            {kZL, @"ZL"}, {kZR, @"ZR"}, {kPlus, @"+"}, {kMinus, @"-"}, {kLeft, @"\u25C0"},
            {kUp, @"\u25B2"}, {kRight, @"\u25B6"}, {kDown, @"\u25BC"}, {kLS, @"L3"}, {kRS, @"R3"},
            {kHome, @"\u2302"},
        };
        for (const Def& d : defs) {
            LichiiButton* button = [[LichiiButton alloc] initWithId:d.id title:d.title];
            [self addSubview:button];
            b[@(d.id)] = button;
        }
        _buttons = b;
        _leftStick = [[LichiiStick alloc] initWithId:0];
        _rightStick = [[LichiiStick alloc] initWithId:1];
        [self addSubview:_leftStick];
        [self addSubview:_rightStick];
    }
    return self;
}
- (void)place:(int)buttonId cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h round:(BOOL)round {
    LichiiButton* button = self.buttons[@(buttonId)];
    button.frame = CGRectMake(cx - w / 2, cy - h / 2, w, h);
    button.layer.cornerRadius = round ? MIN(w, h) / 2 : h * 0.3;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    const UIEdgeInsets safe = self.safeAreaInsets;
    const CGFloat W = self.bounds.size.width;
    const CGFloat H = self.bounds.size.height - safe.bottom;
    const CGFloat L = MAX(safe.left, 12);
    const CGFloat R = W - MAX(safe.right, 12);
    const CGFloat T = MAX(safe.top, 8);
    const CGFloat u = MIN(W, self.bounds.size.height) / 7.0;

    // Left: stick above, d-pad below and inward. Right: face buttons above, stick below/inward.
    const CGFloat stick = 2.3 * u;
    self.leftStick.frame = CGRectMake(L + 0.4 * u, H - 4.3 * u, stick, stick);
    const CGFloat dx = L + 3.9 * u, dy = H - 1.15 * u, ds = 0.78 * u, doff = 0.8 * u;
    [self place:kUp cx:dx cy:dy - doff w:ds h:ds round:NO];
    [self place:kDown cx:dx cy:dy + doff w:ds h:ds round:NO];
    [self place:kLeft cx:dx - doff cy:dy w:ds h:ds round:NO];
    [self place:kRight cx:dx + doff cy:dy w:ds h:ds round:NO];

    const CGFloat fx = R - 1.6 * u, fy = H - 3.15 * u, fs = 0.85 * u, foff = 0.9 * u;
    [self place:kX cx:fx cy:fy - foff w:fs h:fs round:YES];
    [self place:kB cx:fx cy:fy + foff w:fs h:fs round:YES];
    [self place:kY cx:fx - foff cy:fy w:fs h:fs round:YES];
    [self place:kA cx:fx + foff cy:fy w:fs h:fs round:YES];
    const CGFloat rstick = 1.9 * u;
    self.rightStick.frame = CGRectMake(R - 3.9 * u - rstick / 2,
                                       H - 1.15 * u - rstick / 2 - 0.2 * u, rstick, rstick);

    const CGFloat sw = 1.35 * u, sh = 0.62 * u;
    [self place:kZL cx:L + 0.4 * u + sw / 2 cy:T + sh / 2 w:sw h:sh round:NO];
    [self place:kL cx:L + 0.4 * u + sw * 1.5 + 0.15 * u cy:T + sh / 2 w:sw h:sh round:NO];
    [self place:kZR cx:R - 0.4 * u - sw / 2 cy:T + sh / 2 w:sw h:sh round:NO];
    [self place:kR cx:R - 0.4 * u - sw * 1.5 - 0.15 * u cy:T + sh / 2 w:sw h:sh round:NO];

    const CGFloat ms = 0.62 * u;
    [self place:kMinus cx:W / 2 - 1.1 * u cy:T + ms / 2 w:ms h:ms round:YES];
    [self place:kPlus cx:W / 2 + 1.1 * u cy:T + ms / 2 w:ms h:ms round:YES];
    [self place:kHome cx:W / 2 cy:T + ms / 2 w:ms h:ms round:YES];
    [self place:kLS cx:L + 0.4 * u + stick + 0.25 * u cy:H - 4.3 * u w:ms h:ms round:YES];
    [self place:kRS cx:R - 3.9 * u - rstick / 2 - 0.35 * u cy:H - 2.4 * u w:ms h:ms round:YES];
}
- (void)releaseAll {
    for (LichiiButton* button in self.buttons.allValues) {
        [button releaseAll];
    }
    [self.leftStick recenter];
    [self.rightStick recenter];
}
@end

static LichiiOverlay* g_overlay = nil;

namespace IosSupport {

void InstallTouchControls(void* ui_window, TouchButtonFn button, TouchStickFn stick) {
    @autoreleasepool {
        g_button_fn = button;
        g_stick_fn = stick;
        UIWindow* window = (__bridge UIWindow*)ui_window;
        UIView* host = window.rootViewController.view ?: window;
        if (g_overlay == nil) {
            g_overlay = [[LichiiOverlay alloc] initWithFrame:host.bounds];
            g_overlay.autoresizingMask =
                UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
        [g_overlay removeFromSuperview];
        g_overlay.frame = host.bounds;
        host.multipleTouchEnabled = YES;
        [host addSubview:g_overlay];
    }
}

void SetTouchControlsVisible(bool visible) {
    if (g_overlay == nil) {
        return;
    }
    if (!visible) {
        [g_overlay releaseAll];
    }
    g_overlay.hidden = !visible;
}

} // namespace IosSupport
