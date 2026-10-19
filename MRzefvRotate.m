// MRzefvRotate.m
// Makes the host app follow the phone's physical orientation: rotate the phone,
// the app + UI rotate with it (portrait / landscape left / landscape right).
// Overrides the host's Info.plist, app delegate and view controller orientation locks.
// Build: clang -dynamiclib -fobjc-arc -framework UIKit -framework Foundation (arm64 + arm64e)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const UIInterfaceOrientationMask kMRMask = UIInterfaceOrientationMaskAllButUpsideDown;
static NSMutableSet<NSString *> *gHooked;

#pragma mark - Push the scene to match the device

static UIInterfaceOrientationMask MRMaskForDevice(void) {
    switch (UIDevice.currentDevice.orientation) {
        case UIDeviceOrientationLandscapeLeft:  return UIInterfaceOrientationMaskLandscapeRight; // device/interface are mirrored
        case UIDeviceOrientationLandscapeRight: return UIInterfaceOrientationMaskLandscapeLeft;
        case UIDeviceOrientationPortrait:       return UIInterfaceOrientationMaskPortrait;
        default:                                return kMRMask;
    }
}

static void MRRelayout(void) {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            [w setNeedsLayout];
            [w.rootViewController.view setNeedsLayout];
            [w.rootViewController.view layoutIfNeeded];
        }
    }
}

static void MRSyncToDevice(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIDeviceOrientation d = UIDevice.currentDevice.orientation;
        if (d == UIDeviceOrientationFaceUp || d == UIDeviceOrientationFaceDown ||
            d == UIDeviceOrientationUnknown || d == UIDeviceOrientationPortraitUpsideDown) return;

        if (@available(iOS 16.0, *)) {
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                if (![sc isKindOfClass:UIWindowScene.class]) continue;
                UIWindowScene *ws = (UIWindowScene *)sc;
                for (UIWindow *w in ws.windows) {
                    [w.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
                }
                UIWindowSceneGeometryPreferencesIOS *p =
                    [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:MRMaskForDevice()];
                [ws requestGeometryUpdateWithPreferences:p errorHandler:^(NSError *e) {}];
            }
        } else {
            UIInterfaceOrientation want =
                d == UIDeviceOrientationLandscapeLeft  ? UIInterfaceOrientationLandscapeRight :
                d == UIDeviceOrientationLandscapeRight ? UIInterfaceOrientationLandscapeLeft  :
                                                         UIInterfaceOrientationPortrait;
            [UIDevice.currentDevice setValue:@(want) forKey:@"orientation"];
            [UIViewController attemptRotationToDeviceOrientation];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ MRRelayout(); });
    });
}

#pragma mark - App delegate hook (beats Info.plist + delegate mask)

static void MRHookDelegate(id delegate) {
    if (!delegate) return;
    Class c = [delegate class];
    NSString *key = [@"D:" stringByAppendingString:NSStringFromClass(c)];
    if ([gHooked containsObject:key]) return;
    [gHooked addObject:key];

    SEL s = @selector(application:supportedInterfaceOrientationsForWindow:);
    IMP imp = imp_implementationWithBlock(^NSUInteger(id _s, UIApplication *a, UIWindow *w) {
        return kMRMask;
    });
    if (!class_addMethod(c, s, imp, "Q@:@@")) {
        method_setImplementation(class_getInstanceMethod(c, s), imp);
    }
}

static void MRHookSetDelegate(void) {
    Method m = class_getInstanceMethod(UIApplication.class, @selector(setDelegate:));
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id _s, id d) {
        orig(_s, @selector(setDelegate:), d);
        MRHookDelegate(d);
    }));
}

#pragma mark - View controller hooks (beats per-VC locks)

static void MRHookVC(Class c) {
    SEL sels[3] = {
        @selector(supportedInterfaceOrientations),
        @selector(shouldAutorotate),
        @selector(preferredInterfaceOrientationForPresentation)
    };
    IMP imps[3] = {
        imp_implementationWithBlock(^NSUInteger(id _s) { return kMRMask; }),
        imp_implementationWithBlock(^BOOL(id _s) { return YES; }),
        imp_implementationWithBlock(^NSInteger(id _s) { return UIInterfaceOrientationPortrait; })
    };
    for (int i = 0; i < 3; i++) {
        Method own = class_getInstanceMethod(c, sels[i]);
        if (!own) continue;
        Class sup = class_getSuperclass(c);
        Method inherited = sup ? class_getInstanceMethod(sup, sels[i]) : NULL;
        // Only replace methods this class actually defines (or the UIViewController base).
        if (own != inherited || c == UIViewController.class) {
            method_setImplementation(own, imps[i]);
        }
    }
}

static void MRHookVCClasses(void) {
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    Class vc = UIViewController.class;

    for (unsigned int i = 0; i < n; i++) {
        Class c = list[i];
        BOOL isVC = NO;
        for (Class k = c; k; k = class_getSuperclass(k)) { if (k == vc) { isVC = YES; break; } }
        if (!isVC) continue;

        const char *name = class_getName(c);
        BOOL core = (c == vc || c == UINavigationController.class || c == UITabBarController.class);
        if (!core) {
            if (name[0] == '_') continue;
            if (name[0] == 'U' && name[1] == 'I') continue;   // leave system VCs alone
            if (name[0] == 'S' && name[1] == 'F') continue;
        }

        NSString *key = [@"V:" stringByAppendingString:NSStringFromClass(c)];
        if ([gHooked containsObject:key]) continue;
        [gHooked addObject:key];
        MRHookVC(c);
    }
    free(list);
}

#pragma mark - Entry

__attribute__((constructor))
static void MRRotateInit(void) {
    gHooked = [NSMutableSet set];

    MRHookSetDelegate();
    if (UIApplication.sharedApplication.delegate) MRHookDelegate(UIApplication.sharedApplication.delegate);
    MRHookVCClasses();

    [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;

    [nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        MRHookDelegate(UIApplication.sharedApplication.delegate);
        MRHookVCClasses();
        MRSyncToDevice();
    }];

    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        MRHookVCClasses();   // catch classes loaded after launch
        MRSyncToDevice();
    }];

    // The core of it: phone rotates -> scene rotates -> UI relayouts.
    [nc addObserverForName:UIDeviceOrientationDidChangeNotification object:nil
                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        MRSyncToDevice();
    }];
}
