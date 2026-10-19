// MRzefvRotate.m
// Makes the host app follow the phone's physical orientation: rotate the phone,
// the app + UI rotate with it (portrait / landscape left / landscape right).
// Overrides the host's Info.plist, app delegate and view controller orientation locks,
// then re-flows the host's fixed-frame layout so nothing is left stale after a rotation.
// Build: clang -dynamiclib -fobjc-arc -framework UIKit -framework Foundation (arm64 + arm64e)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

static const UIInterfaceOrientationMask kMRMask = UIInterfaceOrientationMaskAllButUpsideDown;
static NSMutableSet<NSString *> *gHooked;
static const void *kMRSizeKey = &kMRSizeKey;

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

#pragma mark - Keep the host's size maths portrait-sized
//
// The host sizes its fonts and frames from [UIScreen mainScreen].bounds.size.width. In landscape
// that width is ~2.2x bigger, so everything it builds comes out oversized. Whenever code from the
// host app asks for the screen bounds in landscape, we answer with the portrait-shaped rect, so
// the host builds a normal-sized UI; the re-flow below then stretches that to the real window.

static CGRect (*gOrigBounds)(id, SEL);
static const char *gAppPath;
static size_t gAppPathLen;
static void *gSelfBase;

static CGSize MRRealScreenSize(void) {
    CGRect r = gOrigBounds(UIScreen.mainScreen, @selector(bounds));
    return r.size;
}

__attribute__((noinline))
static CGRect MRScreenBounds(id self, SEL _cmd) {
    CGRect real = gOrigBounds(self, _cmd);
    if (real.size.width <= real.size.height) return real;

    void *ra = __builtin_return_address(0);
#if __has_feature(ptrauth_calls)
    ra = ptrauth_strip(ra, ptrauth_key_return_address);
#endif
    Dl_info info;
    if (!dladdr(ra, &info) || !info.dli_fname || info.dli_fbase == gSelfBase) return real;
    if (strncmp(info.dli_fname, gAppPath, gAppPathLen) != 0) return real;   // system code: untouched

    return CGRectMake(real.origin.x, real.origin.y, real.size.height, real.size.width);
}

static void MRHookScreenBounds(void) {
    Dl_info me;
    if (dladdr((void *)&MRHookScreenBounds, &me)) gSelfBase = me.dli_fbase;
    gAppPath = strdup(NSBundle.mainBundle.bundlePath.fileSystemRepresentation);
    gAppPathLen = strlen(gAppPath);

    Method m = class_getInstanceMethod(UIScreen.class, @selector(bounds));
    gOrigBounds = (CGRect (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)MRScreenBounds);
}

#pragma mark - Re-flow of fixed-frame layouts
//
// The host builds its UI with absolute frames at whatever size the screen had when a screen
// loaded, and never re-lays out on rotation. That leaves a portrait-width UI floating in a
// landscape window (and the reverse), with the header sitting under the status bar.
// On the first layout pass after a width change we rewrite those frames:
//   - horizontal: x / width scale with the container (images keep their size, re-centered)
//   - vertical:   top block grows by the safe-area delta, bottom block stays pinned,
//                 the block in between fills what is left
// Auto Layout views and views with an autoresizing mask are left to UIKit.

static BOOL MRNear(CGFloat a, CGFloat b) { return fabs(a - b) < 1.5; }

static BOOL MRIsSystemChrome(UIView *v) {
    if ([v isKindOfClass:UITabBar.class] || [v isKindOfClass:UINavigationBar.class] ||
        [v isKindOfClass:UIToolbar.class]) return YES;
    return object_getClassName(v)[0] == '_';
}

static void MRReflow(UIView *p, CGSize oldP, CGSize newP, CGFloat shiftY, BOOL root, CGFloat dTop) {
    if (oldP.width < 1) return;
    CGFloat sx = newP.width / oldP.width;

    CGFloat bottomBlock = 0;
    if (root) {
        for (UIView *s in p.subviews) {
            if (s.hidden || MRIsSystemChrome(s)) continue;
            CGRect f = s.frame;
            if (MRNear(CGRectGetMaxY(f), oldP.height) && !MRNear(f.origin.y, 0)) {
                bottomBlock = MAX(bottomBlock, f.size.height);
            }
        }
    }

    for (UIView *s in p.subviews) {
        if (MRIsSystemChrome(s)) continue;
        if (!s.translatesAutoresizingMaskIntoConstraints) continue;   // Auto Layout owns it

        CGRect f = s.frame;
        CGSize oldS = f.size;
        CGSize newS = f.size;
        CGFloat childShift = 0;

        if (s.autoresizingMask != UIViewAutoresizingNone) {
            // UIKit already resized this one; reconstruct its old size so its children can follow.
            UIViewAutoresizing m = s.autoresizingMask;
            if (m & UIViewAutoresizingFlexibleWidth)  oldS.width  = f.size.width  - (newP.width  - oldP.width);
            if (m & UIViewAutoresizingFlexibleHeight) oldS.height = f.size.height - (newP.height - oldP.height);
        } else {
            CGRect nf = f;
            if ([s isKindOfClass:UIImageView.class]) {
                nf.origin.x = CGRectGetMidX(f) * sx - f.size.width / 2.0;
            } else {
                nf.origin.x = f.origin.x * sx;
                nf.size.width = f.size.width * sx;
            }

            if (root) {
                BOOL top = MRNear(f.origin.y, 0);
                BOOL bottom = MRNear(CGRectGetMaxY(f), oldP.height);
                if (top && bottom) {
                    nf.size.height = newP.height;
                } else if (top) {
                    nf.size.height += dTop;
                    childShift = dTop;
                } else if (bottom && f.size.height < oldP.height * 0.4) {
                    nf.origin.y = newP.height - (oldP.height - CGRectGetMaxY(f)) - f.size.height;
                } else if (bottom) {
                    // tall block that runs to the bottom = the content area: fill what is left
                    nf.origin.y += dTop;
                    nf.size.height += (newP.height - oldP.height) - dTop;
                } else {
                    nf.origin.y += dTop;
                    if (CGRectGetMaxY(f) >= oldP.height - bottomBlock - 1.5) {
                        nf.size.height += (newP.height - oldP.height) - dTop;
                    }
                }
            } else {
                nf.origin.y += shiftY;
            }

            s.frame = nf;
            newS = nf.size;
        }

        if ([s isKindOfClass:UICollectionView.class]) {
            [((UICollectionView *)s).collectionViewLayout invalidateLayout];
            continue;
        }
        if ([s isKindOfClass:UITableView.class]) {
            [((UITableView *)s) reloadData];
            continue;
        }
        if ([s isKindOfClass:UIImageView.class] || [s isKindOfClass:UILabel.class] ||
            [s isKindOfClass:UIButton.class]) {
            continue;
        }

        CGFloat ssx = oldS.width > 1 ? newS.width / oldS.width : 1;
        if ([s isKindOfClass:UIScrollView.class]) {
            UIScrollView *sv = (UIScrollView *)s;
            CGSize cs = sv.contentSize;
            if (cs.width > 1 && !MRNear(ssx, 1)) {
                cs.width *= ssx;
                sv.contentSize = cs;
                CGPoint o = sv.contentOffset;
                o.x *= ssx;
                sv.contentOffset = o;
            }
        }

        if (!MRNear(ssx, 1) || !MRNear(oldS.height, newS.height) || childShift != 0) {
            MRReflow(s, oldS, newS, childShift, NO, dTop);
        }
    }
}

static void MRCheckReflow(UIViewController *vc) {
    if (!vc.isViewLoaded || !vc.view.window) return;
    const char *n = class_getName(vc.class);
    if (n[0] == '_' || (n[0] == 'U' && n[1] == 'I')) return;   // host screens only

    UIView *v = vc.view;
    CGSize now = v.bounds.size;
    CGFloat top = v.window.safeAreaInsets.top;

    NSArray<NSNumber *> *prev = objc_getAssociatedObject(v, kMRSizeKey);
    objc_setAssociatedObject(v, kMRSizeKey, @[@(now.width), @(now.height), @(top)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!prev) {
        // First layout while the screen is landscape: the host built this view with portrait-sized
        // maths (see MRScreenBounds), so treat it as laid out at the portrait width.
        CGSize real = MRRealScreenSize();
        if (real.width > real.height && fabs(now.width - real.height) > 1) {
            CGFloat extent = 0;
            for (UIView *s in v.subviews) {
                if (MRIsSystemChrome(s) || s.hidden) continue;
                extent = MAX(extent, CGRectGetMaxY(s.frame));
            }
            if (extent > 1 && now.width > 1) {
                MRReflow(v, CGSizeMake(real.height, extent), now, 0, YES, 0);
            }
        }
        return;
    }

    CGSize old = CGSizeMake(prev[0].doubleValue, prev[1].doubleValue);
    if (fabs(old.width - now.width) < 1) return;   // only react to rotations / width changes

    MRReflow(v, old, now, 0, YES, top - prev[2].doubleValue);
}

static void MRHookLayout(void) {
    Method m = class_getInstanceMethod(UIViewController.class, @selector(viewDidLayoutSubviews));
    void (*orig)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(UIViewController *vc) {
        orig(vc, @selector(viewDidLayoutSubviews));
        MRCheckReflow(vc);
    }));
}

#pragma mark - Entry

__attribute__((constructor))
static void MRRotateInit(void) {
    gHooked = [NSMutableSet set];

    MRHookSetDelegate();
    if (UIApplication.sharedApplication.delegate) MRHookDelegate(UIApplication.sharedApplication.delegate);
    MRHookVCClasses();
    MRHookLayout();
    MRHookScreenBounds();

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

    // Phone rotates -> scene rotates -> layout re-flows.
    [nc addObserverForName:UIDeviceOrientationDidChangeNotification object:nil
                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        MRSyncToDevice();
    }];
}
