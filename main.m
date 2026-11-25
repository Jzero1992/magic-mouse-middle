#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <os/lock.h>

// MultitouchSupport's undocumented 64-bit contact ABI. Only state and normalized X are read.
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t path;
    int32_t state;
    int32_t finger;
    int32_t hand;
    float x;
    unsigned char unused[60];
} Contact;
_Static_assert(sizeof(Contact) == 96 && offsetof(Contact, x) == 32, "Unexpected contact layout");

typedef const void *Device;
typedef void (*FrameCallback)(Device, const Contact *, size_t, double, size_t);
static CFArrayRef (*createDevices)(void);
static int (*familyID)(Device, int *);
static void (*registerFrame)(Device, FrameCallback);
static void (*unregisterFrame)(Device, FrameCallback);
static int (*startDevice)(Device, int);
static int (*stopDevice)(Device);
static CFArrayRef devices;
static Device mouse;
static os_unfair_lock touchLock = OS_UNFAIR_LOCK_INIT;
static Device trackedMouse;
static size_t fingerCount;
static float fingerX;
static uint64_t lastFrame;
static mach_timebase_info_data_t timebase;
static CFMachPortRef eventTap;
static BOOL resolveActive, enabled, globalMode;
static const float defaultWidth = 0.24f;
static float zoneWidth = 0.24f;

static float touchSnapshot(size_t *count, float *x);
static CGEventType convertedDown;
static NSString *connectionStatus;
static BOOL useEnglish;

static NSString *L(NSString *chinese) {
    if (!useEnglish) return chinese;
    static NSBundle *english;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle URLForResource:@"en" withExtension:@"lproj"];
        if (url) english = [NSBundle bundleWithURL:url];
    });
    return [english localizedStringForKey:chinese value:chinese table:nil] ?: chinese;
}
static __weak NSView *clickTestView;
static NSInteger lastTestButton = -1;
static NSTimeInterval lastTestTime;

static BOOL loadMultitouch(void) {
    void *library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                           RTLD_LAZY | RTLD_LOCAL);
    if (!library) return NO;
    createDevices = dlsym(library, "MTDeviceCreateList");
    familyID = dlsym(library, "MTDeviceGetFamilyID");
    registerFrame = dlsym(library, "MTRegisterContactFrameCallback");
    unregisterFrame = dlsym(library, "MTUnregisterContactFrameCallback");
    startDevice = dlsym(library, "MTDeviceStart");
    stopDevice = dlsym(library, "MTDeviceStop");
    return createDevices && familyID && registerFrame && unregisterFrame && startDevice && stopDevice;
}

static BOOL isMagicMouse(int family) {
    return family == 112 || family == 113 || family == 218;
}

static void readContacts(const Contact *contacts, size_t count, size_t *active, float *x) {
    *active = 0;
    *x = 0;
    for (size_t index = 0; index < count; index++) {
        if (contacts[index].state != 3 && contacts[index].state != 4) continue;
        (*active)++;
        *x = contacts[index].x;
    }
}

static void receiveFrame(Device device, const Contact *contacts, size_t count, double timestamp, size_t frame) {
    size_t active;
    float x;
    readContacts(contacts, count, &active, &x);
    os_unfair_lock_lock(&touchLock);
    if (device == trackedMouse) {
        fingerCount = active;
        fingerX = x;
        lastFrame = mach_absolute_time();
    }
    os_unfair_lock_unlock(&touchLock);
}

static void disconnectMouse(void) {
    os_unfair_lock_lock(&touchLock);
    trackedMouse = NULL;
    fingerCount = 0;
    lastFrame = 0;
    os_unfair_lock_unlock(&touchLock);
    if (mouse) {
        unregisterFrame(mouse, receiveFrame);
        stopDevice(mouse);
        mouse = NULL;
    }
    if (devices) {
        CFRelease(devices);
        devices = NULL;
    }
}

static void connectMouse(void) {
    disconnectMouse();
    if (!createDevices) {
        connectionStatus = @"此系统无法读取鼠标触点";
        return;
    }
    connectionStatus = @"未找到可用的 Magic Mouse";
    devices = createDevices();
    if (!devices) return;
    for (CFIndex index = 0; index < CFArrayGetCount(devices); index++) {
        Device candidate = CFArrayGetValueAtIndex(devices, index);
        int family = 0;
        if (familyID(candidate, &family) != 0 || !isMagicMouse(family)) continue;
        registerFrame(candidate, receiveFrame);
        if (startDevice(candidate, 0) != 0) {
            unregisterFrame(candidate, receiveFrame);
            continue;
        }
        mouse = candidate;
        os_unfair_lock_lock(&touchLock);
        trackedMouse = candidate;
        os_unfair_lock_unlock(&touchLock);
        connectionStatus = @"Magic Mouse 已连接";
        return;
    }
}

static BOOL inCenter(size_t count, float x, float width) {
    return count == 1 && fabsf(x - 0.5f) <= width / 2.0f;
}

static float touchSnapshot(size_t *count, float *x) {
    os_unfair_lock_lock(&touchLock);
    uint64_t snapshot = lastFrame;
    *count = fingerCount;
    *x = fingerX;
    os_unfair_lock_unlock(&touchLock);
    return snapshot ? (float)((double)(mach_absolute_time() - snapshot) * timebase.numer /
                              timebase.denom / 1000000.0) : INFINITY;
}

static BOOL shouldConvert(void) {
    NSView *preview = clickTestView;
    BOOL testing = preview.window.isKeyWindow &&
        NSPointInRect(NSEvent.mouseLocation, [preview.window convertRectToScreen:
            [preview convertRect:preview.bounds toView:nil]]);
    if (!enabled || (!globalMode && !resolveActive && !testing)) return NO;
    size_t count;
    float x;
    return touchSnapshot(&count, &x) <= 150 && inCenter(count, x, zoneWidth);
}

// Keep the down/drag/up sequence paired even if the finger moves or the app changes.
static CGEventType mapEvent(CGEventType type, BOOL center, CGEventType *held) {
    if (!*held && center && (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown)) {
        *held = type;
        return kCGEventOtherMouseDown;
    }
    if ((*held == kCGEventLeftMouseDown && type == kCGEventLeftMouseDragged) ||
        (*held == kCGEventRightMouseDown && type == kCGEventRightMouseDragged)) {
        return kCGEventOtherMouseDragged;
    }
    if ((*held == kCGEventLeftMouseDown && type == kCGEventLeftMouseUp) ||
        (*held == kCGEventRightMouseDown && type == kCGEventRightMouseUp)) {
        *held = 0;
        return kCGEventOtherMouseUp;
    }
    return type;
}

static CGEventRef handleClick(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (type == kCGEventTapDisabledByUserInput) convertedDown = 0;
        CGEventTapEnable(eventTap, true);
        return event;
    }
    BOOL down = type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown;
    CGEventType previousDown = convertedDown;
    CGEventType mapped = mapEvent(type, down && shouldConvert(), &convertedDown);
    if (mapped == type) return event;

    // Build a Quartz middle-button event so the underlying event also carries the new button.
    CGEventRef middle = CGEventCreateMouseEvent(NULL, mapped, CGEventGetLocation(event), kCGMouseButtonCenter);
    if (!middle) {
        convertedDown = previousDown;
        return event;
    }
    CGEventSetFlags(middle, CGEventGetFlags(event));
    CGEventSetTimestamp(middle, CGEventGetTimestamp(event));
    CGEventSetIntegerValueField(middle, kCGMouseEventClickState,
        CGEventGetIntegerValueField(event, kCGMouseEventClickState));
    CGEventSetIntegerValueField(middle, kCGMouseEventNumber,
        CGEventGetIntegerValueField(event, kCGMouseEventNumber));
    return middle;
}

static void installTap(void) {
    if (eventTap || !AXIsProcessTrusted()) return;
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventRightMouseDragged);
    eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                mask, handleClick, NULL);
    if (!eventTap) return;
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    CGEventTapEnable(eventTap, true);
}

static NSString *conversionStatus(void) {
    if (!enabled) return L(@"点击转换已关闭，请在菜单栏启用");
    if (eventTap && CGEventTapIsEnabled(eventTap)) return L(@"点击转换已启用");
    if (!AXIsProcessTrusted()) return L(@"系统尚未授予此副本「辅助功能」权限");
    if (!CGPreflightListenEventAccess()) return L(@"系统尚未授予此副本「输入监控」权限");
    return L(@"权限已通过，但系统未能启动点击转换");
}

@interface RangePreview : NSView
@property float touchX;
@property BOOL showsTouch;
@end

@implementation RangePreview
- (void)recordClick:(NSEvent *)event {
    lastTestButton = event.buttonNumber;
    lastTestTime = NSProcessInfo.processInfo.systemUptime;
}
- (void)mouseDown:(NSEvent *)event { [self recordClick:event]; }
- (void)rightMouseDown:(NSEvent *)event { [self recordClick:event]; }
- (void)otherMouseDown:(NSEvent *)event { [self recordClick:event]; }

- (void)drawRect:(NSRect)dirtyRect {
    NSRect mouseRect = NSMakeRect(NSMidX(self.bounds) - 82, 8, 164, NSHeight(self.bounds) - 16);
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:mouseRect xRadius:55 yRadius:55];
    [NSColor.controlBackgroundColor setFill];
    [outline fill];

    [NSGraphicsContext saveGraphicsState];
    [outline addClip];
    CGFloat width = NSWidth(mouseRect) * zoneWidth;
    NSRect band = NSMakeRect(NSMidX(mouseRect) - width / 2, NSMinY(mouseRect), width, NSHeight(mouseRect));
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.30] setFill];
    NSRectFill(band);
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.75] setFill];
    NSRectFill(NSMakeRect(NSMinX(band), NSMinY(band), 1, NSHeight(band)));
    NSRectFill(NSMakeRect(NSMaxX(band) - 1, NSMinY(band), 1, NSHeight(band)));

    if (self.showsTouch) {
        CGFloat x = NSMinX(mouseRect) + NSWidth(mouseRect) * fminf(1, fmaxf(0, self.touchX));
        NSBezierPath *marker = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - 7, NSMidY(mouseRect) - 7, 14, 14)];
        [(inCenter(1, self.touchX, zoneWidth) ? NSColor.controlAccentColor : NSColor.labelColor) setFill];
        [marker fill];
        [NSColor.controlBackgroundColor setStroke];
        marker.lineWidth = 2;
        [marker stroke];
    }
    [NSGraphicsContext restoreGraphicsState];

    [NSColor.separatorColor setStroke];
    outline.lineWidth = 1.5;
    [outline stroke];
}
@end

@interface Controller : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property NSStatusItem *item;
@property NSWindow *settingsWindow;
@property RangePreview *rangePreview;
@property NSSlider *rangeSlider;
@property NSTextField *rangeValue;
@property NSTextField *previewStatus;
@property NSTextField *testStatus;
@property NSTimer *previewTimer;
@end

@implementation Controller
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *settings = NSUserDefaults.standardUserDefaults;
    [settings registerDefaults:@{@"enabled": @YES, @"width": @0.24}];
    NSString *language = [settings stringForKey:@"interfaceLanguage"];
    useEnglish = language ? [language isEqualToString:@"en"] :
        ![NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
    enabled = [settings boolForKey:@"enabled"];
    globalMode = [settings boolForKey:@"global"];
    zoneWidth = fminf(.70f, fmaxf(.06f, [settings floatForKey:@"width"]));

    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    [self updateStatusItem];
    self.item.menu = [[NSMenu alloc] init];
    self.item.menu.delegate = self;
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspace addObserver:self selector:@selector(updateActiveApp:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
    [workspace addObserver:self selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
    [self updateActiveApp:nil];
    if (loadMultitouch()) connectMouse();
    else connectionStatus = @"此系统无法读取鼠标触点";
    installTap();
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--settings"]) [self showSettings:nil];
    [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *timer) {
        if (!mouse && createDevices) connectMouse();
        installTap();
    }];
}

- (void)updateActiveApp:(NSNotification *)notification {
    NSString *identifier = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier.lowercaseString;
    resolveActive = [identifier isEqualToString:@"com.blackmagic-design.davinciresolve"] ||
        [identifier isEqualToString:@"com.blackmagic-design.davinciresolvestudio"] ||
        [identifier hasPrefix:@"com.blackmagic-design.davinciresolve."];
}

- (void)didWake:(NSNotification *)notification {
    [self performSelector:@selector(reconnect:) withObject:nil afterDelay:2];
}

- (void)updateStatusItem {
    NSImage *mouseIcon = [NSImage imageWithSystemSymbolName:@"computermouse" accessibilityDescription:L(@"Magic Mouse 中键")];
    self.item.button.image = mouseIcon;
    self.item.button.title = mouseIcon ? @"" : L(@"中键");
    self.item.button.toolTip = L(@"Magic Mouse 中键");
}

- (void)changeLanguage:(NSMenuItem *)sender {
    BOOL english = [sender.representedObject isEqualToString:@"en"];
    if (useEnglish == english) return;
    useEnglish = english;
    [NSUserDefaults.standardUserDefaults setObject:sender.representedObject forKey:@"interfaceLanguage"];
    [self updateStatusItem];

    BOOL reopen = self.settingsWindow.isVisible;
    [self.previewTimer invalidate];
    [self.settingsWindow close];
    self.settingsWindow = nil;
    if (reopen) [self showSettings:nil];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    [menu addItemWithTitle:L(connectionStatus) action:nil keyEquivalent:@""];
    [menu addItemWithTitle:conversionStatus() action:nil keyEquivalent:@""];
    NSMenuItem *toggle = [menu addItemWithTitle:L(@"启用单指中央按下") action:@selector(toggle:) keyEquivalent:@""];
    toggle.target = self;
    toggle.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *scope = [menu addItemWithTitle:L(@"仅在 DaVinci Resolve 生效") action:@selector(changeScope:) keyEquivalent:@""];
    scope.target = self;
    scope.state = globalMode ? NSControlStateValueOff : NSControlStateValueOn;

    NSMenuItem *settings = [menu addItemWithTitle:L(@"设置…") action:@selector(showSettings:) keyEquivalent:@","];
    settings.target = self;

    NSMenuItem *language = [menu addItemWithTitle:L(@"语言 / Language") action:nil keyEquivalent:@""];
    language.submenu = [[NSMenu alloc] init];
    NSArray<NSString *> *titles = @[@"简体中文", @"English"];
    NSArray<NSString *> *identifiers = @[@"zh-Hans", @"en"];
    for (NSUInteger index = 0; index < titles.count; index++) {
        NSMenuItem *option = [language.submenu addItemWithTitle:titles[index]
            action:@selector(changeLanguage:) keyEquivalent:@""];
        option.target = self;
        option.representedObject = identifiers[index];
        option.state = (useEnglish == (index == 1)) ? NSControlStateValueOn : NSControlStateValueOff;
    }

    [menu addItem:NSMenuItem.separatorItem];
    if (!eventTap) {
        NSMenuItem *permissions = [menu addItemWithTitle:L(@"启用权限…") action:@selector(requestPermissions:) keyEquivalent:@""];
        permissions.target = self;
    }
    NSMenuItem *resetPermissions = [menu addItemWithTitle:L(@"重置权限记录…") action:@selector(resetPermissions:) keyEquivalent:@""];
    resetPermissions.target = self;
    NSMenuItem *refresh = [menu addItemWithTitle:L(@"重新检测鼠标") action:@selector(reconnect:) keyEquivalent:@""];
    refresh.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *about = [menu addItemWithTitle:L(@"关于 Magic Mouse 中键") action:@selector(showAbout:) keyEquivalent:@""];
    about.target = self;
    NSMenuItem *quit = [menu addItemWithTitle:L(@"退出") action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
}

- (void)showAbout:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *about = [[NSAlert alloc] init];
    about.icon = NSApp.applicationIconImage;
    about.messageText = L(@"Magic Mouse 中键");
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    about.informativeText = [NSString stringWithFormat:@"%@\n%@", [NSString stringWithFormat:L(@"版本 %@"), version],
                             L(@"设计与权利归 J.zero 所有")];
    [about addButtonWithTitle:L(@"好")];
    [about runModal];
}

- (void)toggle:(id)sender {
    enabled = !enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"enabled"];
}
- (void)changeScope:(id)sender {
    globalMode = !globalMode;
    [NSUserDefaults.standardUserDefaults setBool:globalMode forKey:@"global"];
}
- (void)showSettings:(id)sender {
    if (!self.settingsWindow) {
        self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 450, 435)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            backing:NSBackingStoreBuffered defer:NO];
        self.settingsWindow.title = L(@"Magic Mouse 中键设置");
        self.settingsWindow.releasedWhenClosed = NO;
        [self.settingsWindow center];
        NSView *content = self.settingsWindow.contentView;

        NSTextField *title = [NSTextField labelWithString:L(@"中央中键区域")];
        title.font = [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold];
        title.frame = NSMakeRect(28, 375, 394, 32);
        [content addSubview:title];

        self.rangePreview = [[RangePreview alloc] initWithFrame:NSMakeRect(28, 149, 394, 218)];
        [content addSubview:self.rangePreview];
        clickTestView = self.rangePreview;

        self.previewStatus = [NSTextField labelWithString:@""];
        self.previewStatus.frame = NSMakeRect(28, 123, 394, 22);
        self.previewStatus.alignment = NSTextAlignmentCenter;
        self.previewStatus.textColor = NSColor.secondaryLabelColor;
        [content addSubview:self.previewStatus];

        self.testStatus = [NSTextField labelWithString:@""];
        self.testStatus.frame = NSMakeRect(28, 99, 394, 22);
        self.testStatus.alignment = NSTextAlignmentCenter;
        self.testStatus.textColor = NSColor.secondaryLabelColor;
        [content addSubview:self.testStatus];

        NSTextField *sliderLabel = [NSTextField labelWithString:L(@"横向宽度")];
        sliderLabel.frame = NSMakeRect(28, 69, 88, 22);
        [content addSubview:sliderLabel];

        self.rangeSlider = [NSSlider sliderWithValue:zoneWidth * 100 minValue:6 maxValue:70
                                               target:self action:@selector(sliderChanged:)];
        self.rangeSlider.continuous = YES;
        self.rangeSlider.frame = NSMakeRect(113, 66, 244, 27);
        [self.rangeSlider setAccessibilityLabel:L(@"中央中键区域横向宽度")];
        [content addSubview:self.rangeSlider];

        self.rangeValue = [NSTextField labelWithString:@""];
        self.rangeValue.alignment = NSTextAlignmentRight;
        self.rangeValue.font = [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightMedium];
        self.rangeValue.frame = NSMakeRect(365, 69, 57, 22);
        [content addSubview:self.rangeValue];

        NSButton *reset = [NSButton buttonWithTitle:L(@"恢复默认") target:self action:@selector(resetWidth:)];
        reset.frame = NSMakeRect(284, 22, 138, 30);
        [content addSubview:reset];

        NSButton *refresh = [NSButton buttonWithTitle:L(@"重新检测鼠标") target:self action:@selector(reconnect:)];
        refresh.frame = NSMakeRect(28, 22, 150, 30);
        [content addSubview:refresh];

        __weak Controller *controller = self;
        self.previewTimer = [NSTimer timerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *timer) {
            if (controller.settingsWindow.isVisible) [controller updateRangePreview];
        }];
        [NSRunLoop.mainRunLoop addTimer:self.previewTimer forMode:NSRunLoopCommonModes];
    }
    [self updateRangePreview];
    [NSApp activateIgnoringOtherApps:YES];
    [self.settingsWindow makeKeyAndOrderFront:nil];
}

- (void)updateRangePreview {
    size_t count;
    float x;
    BOOL active = touchSnapshot(&count, &x) <= 150;
    BOOL showTouch = active && count == 1;
    self.rangePreview.touchX = x;
    self.rangePreview.showsTouch = showTouch;
    self.rangePreview.needsDisplay = YES;
    NSString *status = L(@"用一根手指触摸鼠标，查看横向位置");
    if (!mouse) status = L(connectionStatus);
    else if (active && count > 1) status = L(@"请只用一根手指触摸");
    else if (showTouch) status = inCenter(count, x, zoneWidth) ? L(@"触点在中键区域内") : L(@"触点在中键区域外");
    if (![self.previewStatus.stringValue isEqualToString:status]) self.previewStatus.stringValue = status;
    NSString *test = L(@"将光标移到上方图示，按下鼠标测试");
    if (!enabled || !eventTap || !CGEventTapIsEnabled(eventTap)) test = conversionStatus();
    if (NSProcessInfo.processInfo.systemUptime - lastTestTime < 3 && lastTestButton >= 0) {
        switch (lastTestButton) {
            case 0: test = L(@"收到左键"); break;
            case 1: test = L(@"收到右键"); break;
            case 2: test = L(@"收到中键"); break;
            default: test = L(@"收到其他鼠标按键"); break;
        }
    }
    if (![self.testStatus.stringValue isEqualToString:test]) self.testStatus.stringValue = test;
    self.rangeValue.stringValue = [NSString stringWithFormat:@"%ld%%", lroundf(zoneWidth * 100)];
}

- (void)sliderChanged:(NSSlider *)sender {
    zoneWidth = lround(sender.doubleValue) / 100.0f;
    sender.doubleValue = zoneWidth * 100;
    [NSUserDefaults.standardUserDefaults setFloat:zoneWidth forKey:@"width"];
    [self updateRangePreview];
}

- (void)resetWidth:(id)sender {
    self.rangeSlider.doubleValue = defaultWidth * 100;
    [self sliderChanged:self.rangeSlider];
}
- (void)reconnect:(id)sender { connectMouse(); }
- (void)requestPermissions:(id)sender {
    if (!AXIsProcessTrusted()) {
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
    }
    if (!CGPreflightListenEventAccess()) CGRequestListenEventAccess();
    installTap();
}
- (void)resetPermissions:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *confirmation = [[NSAlert alloc] init];
    confirmation.messageText = L(@"重置 Magic Mouse 中键的权限记录？");
    confirmation.informativeText = L(@"这会清除本工具的「辅助功能」和「输入监控」授权。重置后请重新打开本工具，并在菜单栏点「启用权限…」。");
    [confirmation addButtonWithTitle:L(@"取消")];
    [confirmation addButtonWithTitle:L(@"重置权限")];
    if ([confirmation runModal] != NSAlertSecondButtonReturn) return;

    NSDictionary<NSString *, NSString *> *services = @{
        @"Accessibility": L(@"辅助功能"),
        @"ListenEvent": L(@"输入监控")
    };
    NSMutableArray<NSString *> *failed = [NSMutableArray array];
    for (NSString *service in services) {
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tccutil"];
        task.arguments = @[@"reset", service, NSBundle.mainBundle.bundleIdentifier];
        task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        if (![task launchAndReturnError:NULL]) {
            [failed addObject:services[service]];
            continue;
        }
        [task waitUntilExit];
        if (task.terminationStatus != 0) [failed addObject:services[service]];
    }

    NSAlert *result = [[NSAlert alloc] init];
    if (failed.count) {
        result.messageText = L(@"部分权限记录未能重置");
        result.informativeText = [NSString stringWithFormat:
            L(@"请在「系统设置 → 隐私与安全性」中检查「%@」，移除此工具的旧条目，再重新打开本工具并授权。"),
            [failed componentsJoinedByString:useEnglish ? @", " : @"」「"]];
    } else {
        result.messageText = L(@"权限记录已重置");
        result.informativeText = L(@"请从「应用程序」重新打开 Magic Mouse 中键，然后在菜单栏点「启用权限…」重新授权。");
    }
    [result addButtonWithTitle:L(@"退出工具")];
    [result runModal];
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (eventTap) CFMachPortInvalidate(eventTap);
    disconnectMouse();
}
@end

static int selfTest(void) {
    useEnglish = YES;
    if (![L(@"设置…") isEqualToString:@"Settings…"]) return 1;
    useEnglish = NO;
    if (![L(@"设置…") isEqualToString:@"设置…"]) return 1;
    Contact contacts[] = {{.state = 4, .x = .5f}, {.state = 5, .x = .8f}};
    size_t count;
    float x;
    readContacts(contacts, 2, &count, &x);
    if (!inCenter(count, x, .24f) || inCenter(1, .2f, .24f) ||
        inCenter(2, .5f, .24f) || inCenter(0, .5f, .24f)) return 1;
    const CGEventType sequences[][3] = {
        {kCGEventLeftMouseDown, kCGEventLeftMouseDragged, kCGEventLeftMouseUp},
        {kCGEventRightMouseDown, kCGEventRightMouseDragged, kCGEventRightMouseUp}
    };
    for (size_t i = 0; i < 2; i++) {
        CGEventType held = 0;
        if (mapEvent(sequences[i][0], NO, &held) != sequences[i][0] || held ||
            mapEvent(sequences[i][0], YES, &held) != kCGEventOtherMouseDown ||
            mapEvent(sequences[i][1], NO, &held) != kCGEventOtherMouseDragged ||
            mapEvent(sequences[i][2], NO, &held) != kCGEventOtherMouseUp || held) return 1;
    }
    puts("Gesture and mouse event self-test passed.");
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        mach_timebase_info(&timebase);
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return selfTest();
        if (argc == 2 && strcmp(argv[1], "--probe") == 0) {
            if (!loadMultitouch()) return 1;
            connectMouse();
            puts(connectionStatus.UTF8String);
            disconnectMouse();
            return 0;
        }
        if ([NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier].count > 1) return 0;
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Controller *controller __attribute__((objc_precise_lifetime)) = [[Controller alloc] init];
        application.delegate = controller;
        [application run];
    }
}
