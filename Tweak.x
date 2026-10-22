// BTRename - give any Bluetooth device a nickname that only this iPhone shows (iOS 6, armv7).
//
// Rename: Settings > Bluetooth > blue arrow next to a device > Rename (top right). Empty the
// box, or tap Use Real Name, to go back to the device's own name.
//
// Display only. The device keeps its real name, and code that works out which device is which
// keeps seeing the real name:
//   - Settings (com.apple.Preferences): -[BluetoothDevice name] answers with the nickname, looked
//     up by the device's address. Settings only shows names (Ultimate AirPods Fix already trims
//     " - Find My" the same way there), so the list, the device page and its alerts all follow.
//   - SpringBoard and apps: only picker UI is touched. MPAVRoute is the model MediaPlayer draws
//     the audio / AirPlay action sheet from (app switcher, Music, Videos, other apps);
//     MPAudioRoutingPicker is the lock screen's route alert; TPAudioDeviceView is the in-call
//     audio list. -[BluetoothDevice name] and MPAudioDeviceController's route names are NOT
//     hooked outside Settings: mikey820's AirPodsReconnectFix reads them in SpringBoard.
//
// Class and method names come from the phone's own iOS 6.1.2 shared cache (BluetoothSettings
// bundle, MediaPlayer, TelephonyUI), and every hook checks its method exists before installing.
//
// Prefs: /var/mobile/Library/Preferences/com.mbucc9000.btrename.plist
//   devices = { "AA:BB:CC:DD:EE:FF" = { alias = "Pods"; name = "<real name when last seen>"; }; };
// Pickers only get the route's name, so they match the saved real name (with or without the
// " - Find My" suffix newer AirPods add). Settings refreshes the saved name if the device renames
// itself, and posts com.mbucc9000.btrename/changed so running apps pick changes up straight away.
//
// Log: /var/mobile/BTRename.log (hooks installed per process, renames).

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <time.h>
#import <mach-o/dyld.h>
#import <libkern/OSAtomic.h>

#define kPrefs @"/var/mobile/Library/Preferences/com.mbucc9000.btrename.plist"
#define kNote  "com.mbucc9000.btrename/changed"
#define kLog   "/var/mobile/BTRename.log"

@interface BluetoothDevice : NSObject
- (NSString *)address;
- (NSString *)name;
@end

@interface PSSpecifier : NSObject
- (id)userInfo;
- (NSString *)name;
- (void)setName:(NSString *)name;
@end

@interface PSListController : UIViewController
- (NSArray *)specifiers;
- (PSSpecifier *)specifier;
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
@end

@interface BTSDeviceConfigController : PSListController
@end

@interface BTSDeviceConfigController (BTRename)
- (void)btr_rename:(id)sender;
@end

static BOOL gIsSettings = NO;
static BOOL gRaw = NO;       // YES while we ask a device for its real name

// ---------- log ----------
static void BLog(NSString *fmt, ...) {
    static int lines = 0;
    if (lines++ > 300) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen(kLog, "a");
    if (!f) return;      // sandboxed apps can't write it
    char when[32];
    time_t now = time(NULL);
    strftime(when, sizeof(when), "%Y-%m-%d %H:%M:%S", localtime(&now));
    fprintf(f, "%s [%s] %s\n", when, [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "?", [s UTF8String]);
    fclose(f);
}

// ---------- nicknames ----------
static OSSpinLock gLock = OS_SPINLOCK_INIT;
static NSDictionary *gDevices;   // ADDRESS -> { alias, name }
static NSDictionary *gByName;    // real name, raw and trimmed -> alias (for the pickers)

// Same rule as Ultimate AirPods Fix: newer AirPods add " - Find My" to their name.
static NSString *TrimFindMy(NSString *s) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"\\s*[-\\u2013\\u2014]\\s*Find My\\s*$"
                                                       options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    NSString *t = (m && m.range.location > 0) ? [s substringToIndex:m.range.location] : s;
    return [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

static NSDictionary *BTRDevices(void) {
    OSSpinLockLock(&gLock);
    NSDictionary *d = gDevices;
    OSSpinLockUnlock(&gLock);
    return d ?: @{};
}

static NSDictionary *BTREntry(NSString *addr) {
    NSDictionary *e = addr ? BTRDevices()[addr] : nil;
    return [e isKindOfClass:[NSDictionary class]] ? e : nil;
}

static NSString *BTRString(id v) {
    return ([v isKindOfClass:[NSString class]] && [v length]) ? v : nil;
}

static void BTRSetDevices(NSDictionary *devices) {
    NSMutableDictionary *byName = [NSMutableDictionary dictionary];
    for (NSString *addr in devices) {
        NSDictionary *e = devices[addr];
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *alias = BTRString(e[@"alias"]);
        NSString *name = BTRString(e[@"name"]);
        if (!alias || !name) continue;
        byName[name] = alias;
        NSString *t = TrimFindMy(name);
        if (t.length && !byName[t]) byName[t] = alias;
    }
    NSDictionary *d = [devices copy], *n = [byName copy];
    NSDictionary *oldD, *oldN;   // released after the lock is dropped
    OSSpinLockLock(&gLock);
    oldD = gDevices;
    oldN = gByName;
    gDevices = d;
    gByName = n;
    OSSpinLockUnlock(&gLock);
    oldD = nil;
    oldN = nil;
}

static void BTRLoad(void) {
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:kPrefs];
    NSDictionary *saved = [root[@"devices"] isKindOfClass:[NSDictionary class]] ? root[@"devices"] : nil;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (id k in saved)
        if ([k isKindOfClass:[NSString class]]) d[[k uppercaseString]] = saved[k];
    BTRSetDevices(d);
}

static BOOL BTRSave(NSDictionary *devices) {
    NSMutableDictionary *root = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefs] ?: [NSMutableDictionary dictionary];
    root[@"devices"] = devices;
    BOOL ok = [root writeToFile:kPrefs atomically:YES];
    BTRSetDevices(devices);
    notify_post(kNote);
    return ok;
}

// The nickname for a picker / list label, or nil.
static NSString *BTRAliasForName(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || !name.length) return nil;
    OSSpinLockLock(&gLock);
    NSDictionary *m = gByName;
    OSSpinLockUnlock(&gLock);
    if (!m.count) return nil;
    return m[name] ?: m[TrimFindMy(name)];
}

static BOOL BTRHaveNicknames(void) {
    OSSpinLockLock(&gLock);
    BOOL have = gByName.count > 0;
    OSSpinLockUnlock(&gLock);
    return have;
}

// Settings: the device renamed itself (e.g. renamed from another phone), so save the new real
// name - that's what the pickers in SpringBoard and apps match on.
static void BTRRememberName(NSString *addr, NSString *real) {
    static NSMutableDictionary *queued;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!queued) queued = [NSMutableDictionary dictionary];
        if ([queued[addr] isEqualToString:real]) return;
        queued[addr] = real;
        NSDictionary *e = BTREntry(addr);
        if (!e || [e[@"name"] isEqual:real]) return;
        NSMutableDictionary *d = [BTRDevices() mutableCopy];
        NSMutableDictionary *ne = [e mutableCopy];
        ne[@"name"] = real;
        d[addr] = ne;
        BTRSave(d);
        BLog(@"%@ is now called \"%@\" - pickers will match the new name", addr, real);
    });
}

// ---------- Settings: the name everywhere in Settings > Bluetooth ----------
%group SettingsName
%hook BluetoothDevice
- (id)name {
    id orig = %orig;
    if (gRaw) return orig;
    NSString *addr = [[self address] uppercaseString];
    NSDictionary *e = BTREntry(addr);
    NSString *alias = BTRString(e[@"alias"]);
    if (!alias) return orig;
    if (BTRString(orig) && ![orig isEqual:e[@"name"]]) BTRRememberName(addr, orig);
    return alias;
}
%end
%end

static NSString *BTRRealName(BluetoothDevice *dev) {
    gRaw = YES;
    NSString *real = [dev name];
    gRaw = NO;
    return BTRString(real) ?: @"";
}

static BluetoothDevice *BTRConfigDevice(id controller) {
    Ivar iv = class_getInstanceVariable(object_getClass(controller), "_device");
    id dev = iv ? object_getIvar(controller, iv) : nil;
    return [dev respondsToSelector:@selector(address)] ? dev : nil;
}

// After a rename: the device page's title and its row in the Bluetooth list.
static void BTRRefreshSettings(BTSDeviceConfigController *page, NSString *addr, NSString *shown) {
    if (!page) return;
    page.title = shown;
    page.navigationItem.title = shown;
    if ([page respondsToSelector:@selector(specifier)]) [[page specifier] setName:shown];
    NSString *how = @"list row not found (it updates next time the list loads)";
    Class listClass = objc_getClass("BTSDevicesController");
    for (UIViewController *vc in page.navigationController.viewControllers) {
        if (vc == page || !listClass || ![vc isKindOfClass:listClass]) continue;
        PSListController *list = (PSListController *)vc;
        for (PSSpecifier *s in [list specifiers]) {
            id info = [s respondsToSelector:@selector(userInfo)] ? [s userInfo] : nil;
            if (![info respondsToSelector:@selector(address)]) continue;
            if (![[[info address] uppercaseString] isEqualToString:addr]) continue;
            [s setName:shown];
            [list reloadSpecifier:s animated:NO];
            how = @"list row updated";
        }
    }
    BLog(@"Settings: %@", how);
}

@interface BTRRenamePrompt : NSObject <UIAlertViewDelegate>
@property (nonatomic, copy) NSString *address;
@property (nonatomic, copy) NSString *realName;
@property (nonatomic, weak) BTSDeviceConfigController *page;
@property (nonatomic) NSInteger saveIndex;
@property (nonatomic) NSInteger resetIndex;
@end

@implementation BTRRenamePrompt
- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    if (index == alert.cancelButtonIndex) return;
    NSString *alias = nil;
    if (index == self.saveIndex) {
        alias = [[alert textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!alias.length || [alias isEqualToString:self.realName]) alias = nil;
    } else if (index != self.resetIndex) {
        return;
    }
    NSMutableDictionary *d = [BTRDevices() mutableCopy];
    if (alias) d[self.address] = @{ @"alias": alias, @"name": self.realName };
    else [d removeObjectForKey:self.address];
    BOOL ok = BTRSave(d);
    BLog(@"%@ \"%@\" -> %@%@", self.address, self.realName, alias ? [NSString stringWithFormat:@"\"%@\"", alias] : @"real name",
         ok ? @"" : @" (SAVE FAILED)");
    BTRRefreshSettings(self.page, self.address, alias ?: self.realName);
}
@end

static char kPromptKey;

// ---------- Settings: Rename button on the device page ----------
%group SettingsRename
%hook BTSDeviceConfigController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        BluetoothDevice *dev = BTRConfigDevice(self);
        BLog(@"device page: %@", dev ? [dev address] : @"no _device - no Rename button");
    }
    if (!self.navigationItem.rightBarButtonItem && BTRConfigDevice(self)) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Rename"
                                                                                  style:UIBarButtonItemStyleBordered
                                                                                 target:self
                                                                                 action:@selector(btr_rename:)];
    }
}

%new
- (void)btr_rename:(id)sender {
    BluetoothDevice *dev = BTRConfigDevice(self);
    NSString *addr = [[dev address] uppercaseString];
    if (!addr.length) {
        BLog(@"Rename: the page has no device address");
        return;
    }
    NSString *real = BTRRealName(dev);
    NSString *alias = BTRString(BTREntry(addr)[@"alias"]);

    BTRRenamePrompt *p = [BTRRenamePrompt new];
    p.address = addr;
    p.realName = real;
    p.page = self;
    NSString *msg = [NSString stringWithFormat:@"Only this iPhone shows the new name.\nReal name: %@", real.length ? real : @"(none)"];
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Rename Device" message:msg delegate:p
                                      cancelButtonTitle:@"Cancel" otherButtonTitles:nil];
    a.alertViewStyle = UIAlertViewStylePlainTextInput;
    p.saveIndex = [a addButtonWithTitle:@"Save"];
    p.resetIndex = alias ? [a addButtonWithTitle:@"Use Real Name"] : -1;
    UITextField *tf = [a textFieldAtIndex:0];
    tf.text = alias ?: real;
    tf.placeholder = real;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
    objc_setAssociatedObject(a, &kPromptKey, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);   // the delegate is assign
    [a show];
}
%end
%end

// ---------- pickers (SpringBoard + apps): UI only ----------
static void BTRRelabel(UIView *v, int depth) {
    if (!v || depth > 6) return;
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        NSString *a = BTRAliasForName([b titleForState:UIControlStateNormal]);
        if (a) [b setTitle:a forState:UIControlStateNormal];
        return;
    }
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        NSString *a = BTRAliasForName(l.text);
        if (a) l.text = a;
        return;
    }
    for (UIView *sub in v.subviews) BTRRelabel(sub, depth + 1);
}

static void BTRRelabelCell(id obj) {
    if (![obj isKindOfClass:[UITableViewCell class]] || !BTRHaveNicknames()) return;
    UITableViewCell *cell = obj;
    NSString *a = BTRAliasForName(cell.textLabel.text);
    if (a) cell.textLabel.text = a;
    BTRRelabel(cell.contentView, 0);
}

// the audio / AirPlay action sheet's rows are drawn from these
%group RouteName
%hook MPAVRoute
- (id)name {
    id orig = %orig;
    return BTRAliasForName(orig) ?: orig;
}
%end
%end

// the lock screen's audio route alert
%group RoutingPicker
%hook MPAudioRoutingPicker
- (id)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    id cell = %orig;
    BTRRelabelCell(cell);
    return cell;
}
%end
%end

// the in-call audio list (iPhone / Speaker / headset)
%group InCallList
%hook TPAudioDeviceView
- (id)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    id cell = %orig;
    BTRRelabelCell(cell);
    return cell;
}

- (void)_setupButtons {
    %orig;
    if (BTRHaveNicknames()) BTRRelabel((UIView *)self, 0);
}
%end
%end

// ---------- install ----------
static BOOL Has(const char *cls, SEL sel) {
    Class c = objc_getClass(cls);
    return c && class_getInstanceMethod(c, sel);
}

// Settings loads BluetoothManager / the Bluetooth pane, and apps load MediaPlayer / TelephonyUI,
// after launch, so this runs whenever an image is added; each group goes in once.
// Two threads can get here at once (image callback + bundle notification). A group installed
// twice would make its hook call itself, so only one pass runs at a time; a pass that finds the
// lock busy just skips, since the other one is doing the work (no waiting on it under dyld's lock).
static OSSpinLock gHookLock = OS_SPINLOCK_INIT;

static void BTRTryHookLocked(void) {
    static BOOL route, picker, incall, btName, renameButton;
    if (!route && Has("MPAVRoute", @selector(name))) {
        route = YES;
        %init(RouteName);
        BLog(@"hooked the audio picker (MPAVRoute name)");
    }
    if (!picker && Has("MPAudioRoutingPicker", @selector(tableView:cellForRowAtIndexPath:))) {
        picker = YES;
        %init(RoutingPicker);
        BLog(@"hooked the route alert (MPAudioRoutingPicker)");
    }
    if (!incall && Has("TPAudioDeviceView", @selector(tableView:cellForRowAtIndexPath:)) &&
        Has("TPAudioDeviceView", @selector(_setupButtons))) {
        incall = YES;
        %init(InCallList);
        BLog(@"hooked the in-call audio list (TPAudioDeviceView)");
    }
    if (!gIsSettings) return;
    if (!btName && Has("BluetoothDevice", @selector(name)) && Has("BluetoothDevice", @selector(address))) {
        btName = YES;
        %init(SettingsName);
        BLog(@"hooked BluetoothDevice name (Settings only)");
    }
    if (!renameButton && Has("BTSDeviceConfigController", @selector(viewWillAppear:))) {
        renameButton = YES;
        %init(SettingsRename);
        BLog(@"added Rename to the Bluetooth device page");
    }
}

static void BTRTryHook(void) {
    if (!OSSpinLockTry(&gHookLock)) return;
    BTRTryHookLocked();
    OSSpinLockUnlock(&gHookLock);
}

static void ImageAdded(const struct mach_header *mh, intptr_t slide) {
    BTRTryHook();
}

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid.length) return;
        gIsSettings = [bid isEqualToString:@"com.apple.Preferences"];
        BTRLoad();
        int token;
        notify_register_dispatch(kNote, &token, dispatch_get_main_queue(), ^(int t) {
            BTRLoad();
        });
        _dyld_register_func_for_add_image(ImageAdded);   // also runs for the images already loaded
        // and again once a bundle (e.g. Settings' Bluetooth pane) has fully loaded, in case its
        // classes weren't registered yet when the image callback ran
        [[NSNotificationCenter defaultCenter] addObserverForName:NSBundleDidLoadNotification object:nil
                                                           queue:nil usingBlock:^(NSNotification *n) {
            BTRTryHook();
        }];
    }
}
