/*
 * Copyright (C) 2026 Shitty team
 * MIT licensed
 * See the file LICENSE.MIT for the full license.
 */

#include "ui_csd_tabs.h"

#include "brand.h"
#include "options.h"
#include "session.h"
#include "composer.h"

#include <lib/vterm/listener.h>

#include <std/str/view.h>
#include <std/lib/buffer.h>
#include <std/mem/obj_pool.h>

#include <plt/window.h>

#define Point MacLegacyPoint
#define Rect MacLegacyRect

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#undef Rect
#undef Point

#include <stdio.h>
#include <objc/message.h>

using namespace stl;

namespace {
    struct CsdTabsUi;

    // Where the tabs sit in the title bar and how the active one is cut
    // into it: the notch lifts off the seam by inset, rounds its top
    // corners by radius and flares into the seam by fillet.
    struct TabLayout {
        CGFloat left;
        CGFloat cellWidth;
        CGFloat tabsWidth;
        CGFloat inset;
        CGFloat radius;
        CGFloat fillet;
    };

    // The colors of the well. The fill is the terminal's own background;
    // the shade is the dark cut on the material right at the edge, the
    // glow the lit rim one point further out, the lip the faint line on
    // the well's inner wall, mixed from the terminal's foreground so it
    // shows on any background. Everything on the content side is
    // opaque: the plate is the title bar's lifted material as a flat
    // color, and plateShade, plateGlow and lip are the lines already
    // mixed onto what they lie on. The content layer's top device row
    // drops translucent and vibrant layers on this platform; opaque
    // ones it keeps.
    struct WellStyle {
        NSColor* fill;
        NSColor* shade;
        NSColor* glow;
        NSColor* lip;
        NSColor* plate;
        NSColor* plateShade;
        NSColor* plateGlow;
    };
}

// The iTerm2 look, recessed: the title bar itself, split into tabs by
// hairline separators, with the active tab and the terminal below it
// forming one well sunk into the window's material. The view covers the
// tabs only and owns no model - it reads labels and the active index
// through its owner, which outlives it.
@interface CsdTabBarView: NSView {
@public
    CsdTabsUi* owner;
}
@end

// The gap between the traffic lights and the first tab: paints its
// share of the plate and the seam, and nothing else. It is a view of
// its own because AppKit decides where the title bar drags the window
// by view frames, not by hit testing - a single strip across the bar
// that refuses to move the window over its tabs refuses everywhere.
@interface CsdSeamView: NSView {
@public
    CsdTabsUi* owner;
}
@end

// One solid line of the well's edging: a layer with a background color
// and no backing store, which the compositor draws as a colored quad.
@interface CsdHairlineView: NSView {
    NSColor* color_;
}
- (void)setColor:(NSColor*)color;
@end

// One bottom corner of the window: bends the edging lines around the
// window's own corner radius, where straight lines would be cut by the
// window's corner mask and cross its edge.
@interface CsdCornerView: NSView {
@public
    CsdTabsUi* owner;
@public
    BOOL trailing;
}
@end

// One top corner of the well, where the rim meets the title bar: the
// well's edge rounds off there, and this view paints the quarter of the
// terminal's background inside the curve, the lifted material outside
// it, and bends the edging lines around it.
@interface CsdWellCornerView: NSView {
@public
    CsdTabsUi* owner;
@public
    BOOL trailing;
}
@end

namespace {
    struct CallSessionsChanged final: public Listener {
        explicit CallSessionsChanged(CsdTabsUi* parent);

        void onListen(void*) override;

        CsdTabsUi* parent;
    };

    struct CallConfigChanged final: public Listener {
        explicit CallConfigChanged(CsdTabsUi* parent);

        void onListen(void*) override;

        CsdTabsUi* parent;
    };

    // Listens to the tab model and mirrors it into the title bar. All
    // AppKit work runs on the main queue: the listener fires on client
    // fibers (the input pump delivers tab chords, the parser fiber
    // delivers titles), and AppKit layout has no business on a fiber
    // stack. The fibers themselves run on the main thread, so the
    // deferred block never races the snapshot it reads.
    struct CsdTabsUi {
        explicit CsdTabsUi(Composer& composer);

        void project();
        void apply();
        void tabSelected(size_t index);
        void tabClosed(size_t index);
        void tabOpened();
        NSWindow* nativeWindow() const;
        bool fullscreen() const;
        TabLayout layout(CGFloat width) const;
        WellStyle style(NSAppearance* appearance) const;
        CGFloat bezelWidth() const;
        bool lipVisible() const;
        void installBezel(NSWindow* window);
        void removeBezel();
        void placeBezel();
        void restyle();
        void logGeometry(NSWindow* window) const;
        CGFloat windowCornerRadius() const;

        Composer& composer;
        CallSessionsChanged sessionsChanged{this};
        CallConfigChanged configChanged{this};
        CsdTabBarView* bar = nil;
        CsdSeamView* seam = nil;
        // The window's own background from before the strip took the
        // title bar, to give back when the strip goes.
        NSColor* windowBackground = nil;
        // The projected model snapshot the view draws from; nil hides
        // the strip (a lone session keeps the clean native title).
        NSArray<NSString*>* labels = nil;
        size_t active = 0;
        bool applyPending = false;
        CGFloat tabsLeft = 0;
        // The well's edging around the terminal, all subviews of the
        // content view over the Metal layer: material strips along the
        // three window edges, the hairlines on and beside them, and the
        // two seam lines under the title bar. Owned through bezelViews;
        // the typed pointers place and restyle them.
        NSMutableArray<NSView*>* bezelViews = nil;
        id bezelObservers[3] = {};
        u16 bezelBorder = 0;
        CsdHairlineView* strips[3] = {};
        CsdHairlineView* sideLines[3][3] = {};
        CsdHairlineView* cornerMaterial[2] = {};
        CsdWellCornerView* wellCorners[2] = {};
        CsdCornerView* corners[2] = {};
    };

    static bool csdDarkAppearance(NSAppearance* appearance);
    static NSColor* csdColor(Color color, CGFloat alpha);
    static NSColor* csdMix(CGFloat red, CGFloat green, CGFloat blue, CGFloat overRed, CGFloat overGreen, CGFloat overBlue, CGFloat alpha);
}

// The trailing new-tab cell is square-ish; everything left of it is
// split evenly between the tabs. The close glyph answers clicks in a
// fixed leading zone of each tab.
static const CGFloat csdTabPlusWidth = 34;
static const CGFloat csdTabCloseZone = 24;
// The notch of the active tab: how far its top sits below the window
// edge, its top corner radius, and the radius of the flare into the seam.
static const CGFloat csdTabInset = 5;
// The top corners and the flare into the seam share one radius, so the
// notch reads as one curve going in and coming back out.
static const CGFloat csdTabRadius = 5;
static const CGFloat csdTabFillet = 5;
// The radius the window's bottom corners are rounded with when neither
// the frame's layer nor its private accessor says. Before Big Sur the
// bottom corners were square; from Big Sur through Sequoia they round
// by ten points, measured off the window's own border arc at 2x. The
// Tahoe figure is a reading of its larger corners, not a measurement.
static const CGFloat csdWindowCornerBigSur = 10;
static const CGFloat csdWindowCornerTahoe = 16;
// The widest material rim the well keeps between the window edge and
// its shade line; the terminal's border must leave room for it, which
// the macOS default border does.
static const CGFloat csdBezelMax = 3;

namespace {
    static bool csdDarkAppearance(NSAppearance* appearance) {
        if (@available(macOS 10.14, *)) {
            NSAppearanceName const name = [appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
            return [name isEqualToString:NSAppearanceNameDarkAqua];
        }
        return false;
    }

    // sRGB, the space the terminal itself renders in: a calibrated color
    // would land beside the grid it is supposed to continue.
    static NSColor* csdColor(Color color, CGFloat alpha) {
        return [NSColor colorWithSRGBRed:color.red / 255.0 green:color.green / 255.0 blue:color.blue / 255.0 alpha:alpha];
    }

    // An opaque color: the second one laid over the first at alpha.
    static NSColor* csdMix(CGFloat red, CGFloat green, CGFloat blue, CGFloat overRed, CGFloat overGreen, CGFloat overBlue, CGFloat alpha) {
        return [NSColor colorWithSRGBRed:red + (overRed - red) * alpha green:green + (overGreen - green) * alpha blue:blue + (overBlue - blue) * alpha alpha:1.0];
    }
}

CallSessionsChanged::CallSessionsChanged(CsdTabsUi* parent_)
    : parent(parent_)
{
}

void CallSessionsChanged::onListen(void*) {
    parent->project();
}

CallConfigChanged::CallConfigChanged(CsdTabsUi* parent_)
    : parent(parent_)
{
}

void CallConfigChanged::onListen(void*) {
    parent->project();
}

CsdTabsUi::CsdTabsUi(Composer& composer_)
    : composer(composer_)
{
    composer.sessionsChangedListeners.pushBack(&sessionsChanged);
    // A reload may change the terminal colors or the border the well's
    // rim lives in; the strip repaints and re-places its edging.
    composer.configChangedListeners.pushBack(&configChanged);
}

NSWindow* CsdTabsUi::nativeWindow() const {
    if (composer.window == nullptr) {
        return nil;
    }
    return (__bridge NSWindow*)(composer.window->renderContext().window);
}

bool CsdTabsUi::fullscreen() const {
    return (nativeWindow().styleMask & NSWindowStyleMaskFullScreen) != 0;
}

TabLayout CsdTabsUi::layout(CGFloat width) const {
    TabLayout result;
    result.left = tabsLeft;
    result.tabsWidth = width - tabsLeft - csdTabPlusWidth;
    if (result.tabsWidth < 0) {
        result.tabsWidth = 0;
    }
    const NSUInteger count = labels.count;
    result.cellWidth = count == 0 ? 0 : result.tabsWidth / (CGFloat)(count);
    // A narrow cell keeps its notch a notch: the curves shrink before
    // they could cross each other.
    const CGFloat quarter = result.cellWidth / 4;
    result.inset = csdTabInset;
    result.radius = csdTabRadius < quarter ? csdTabRadius : quarter;
    result.fillet = csdTabFillet < quarter ? csdTabFillet : quarter;
    return result;
}

WellStyle CsdTabsUi::style(NSAppearance* appearance) const {
    const bool dark = csdDarkAppearance(appearance);
    const Color bg = composer.opts->vt.bg;
    const Color fg = composer.opts->vt.fg;
    const CGFloat shadeAlpha = dark ? 0.6 : 0.2;
    const CGFloat glowAlpha = dark ? 0.1 : 0.6;
    // The plate: what the title bar's material measured with a lift on
    // it, now the window's own background under a transparent title bar
    // and the rim's color alike.
    const CGFloat plate = dark ? 55 / 255.0 : 232 / 255.0;
    WellStyle result;
    result.fill = csdColor(bg, 1.0);
    result.shade = [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:shadeAlpha];
    result.glow = [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:glowAlpha];
    result.lip = csdMix(bg.red / 255.0, bg.green / 255.0, bg.blue / 255.0, fg.red / 255.0, fg.green / 255.0, fg.blue / 255.0, 0.07);
    result.plate = [NSColor colorWithSRGBRed:plate green:plate blue:plate alpha:1.0];
    result.plateShade = csdMix(plate, plate, plate, 0, 0, 0, shadeAlpha);
    result.plateGlow = csdMix(plate, plate, plate, 1, 1, 1, glowAlpha);
    return result;
}

// The material rim between the window edge and the shade line, in
// points. It comes out of the terminal's border: the border's innermost
// point stays bare for the lip, the rest becomes rim up to csdBezelMax.
CGFloat CsdTabsUi::bezelWidth() const {
    const u16 border = composer.opts->border;
    if (border < 1) {
        return 0;
    }
    const CGFloat room = (CGFloat)(border - 1);
    return room < csdBezelMax ? room : csdBezelMax;
}

bool CsdTabsUi::lipVisible() const {
    return composer.opts->border >= 1;
}

// The radius the window rounds its bottom corners with. Asked of the
// frame first: its layer's corner radius, then the private accessor
// AppKit keeps on the frame and the window, reached only when they
// answer to it. Failing all that, the release's known figure.
CGFloat CsdTabsUi::windowCornerRadius() const {
    NSWindow* const window = nativeWindow();
    NSView* const frame = window.contentView.superview;
    const CGFloat layerRadius = frame.layer.cornerRadius;
    if (layerRadius > 0) {
        return layerRadius;
    }
    const SEL accessor = NSSelectorFromString(@"_cornerRadius");
    for (id candidate in @[ frame, window ]) {
        if ([candidate respondsToSelector:accessor]) {
            const CGFloat radius = ((CGFloat (*)(id, SEL))(objc_msgSend))(candidate, accessor);
            if (radius > 0) {
                return radius;
            }
        }
    }
    const NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    if (version.majorVersion < 11) {
        return 0;
    }
    return version.majorVersion >= 26 ? csdWindowCornerTahoe : csdWindowCornerBigSur;
}

void CsdTabsUi::project() {
    SessionSet* const sessions = composer.sessions;
    if (sessions == nullptr || composer.window == nullptr) {
        return;
    }
    const size_t count = sessions->count();
    NSMutableArray<NSString*>* next = nil;
    if (count >= 2) {
        next = [NSMutableArray arrayWithCapacity:(NSUInteger)(count)];
        for (size_t at = 0; at < count; ++at) {
            // A tab whose shell never set a title shows the brand name,
            // like a fresh window does.
            StringView title = sessions->title(at);
            if (title.length() == 0) {
                title = composer.brand->displayName();
            }
            Buffer label(title);
            NSString* const text = [NSString stringWithUTF8String:label.cStr()];
            [next addObject:text == nil ? @"" : text];
        }
    }
    [next retain];
    [labels release];
    labels = next;
    active = sessions->activeIndex();
    if (applyPending) {
        return;
    }
    applyPending = true;
    dispatch_async(dispatch_get_main_queue(), ^{
      apply();
    });
}

void CsdTabsUi::apply() {
    applyPending = false;
    NSWindow* const window = nativeWindow();
    if (window == nil) {
        if (composer.opts->vt.verbose) {
            fprintf(stderr, "%s: tabs: no native window in the render context\n", composer.brand->identifierCString());
        }
        return;
    }
    if (labels == nil) {
        if (bar != nil) {
            removeBezel();
            [bar removeFromSuperview];
            [bar release];
            bar = nil;
            [seam removeFromSuperview];
            [seam release];
            seam = nil;
            window.titleVisibility = NSWindowTitleVisible;
            window.titlebarAppearsTransparent = NO;
            window.backgroundColor = windowBackground;
            [windowBackground release];
            windowBackground = nil;
            if (@available(macOS 11.0, *)) {
                window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleAutomatic;
            }
        }
        return;
    }
    NSButton* const zoom = [window standardWindowButton:NSWindowZoomButton];
    NSView* titlebar = zoom != nil ? zoom.superview : nil;
    // The strip wants a view spanning the whole title bar. The zoom
    // button's parent is that view on the releases seen so far; should
    // a release keep the buttons in a narrower box of their own, climb
    // until the view is as wide as the window, stopping short of the
    // frame itself.
    NSView* const frameView = window.contentView.superview;
    while (titlebar != nil && titlebar.superview != frameView && titlebar.bounds.size.width < window.contentView.bounds.size.width) {
        titlebar = titlebar.superview;
    }
    if (titlebar == nil || titlebar == frameView) {
        if (composer.opts->vt.verbose) {
            fprintf(stderr, "%s: tabs: no titlebar container to draw into\n", composer.brand->identifierCString());
        }
        return;
    }
    // Only a direct child of the title bar can order the strip below the
    // buttons; from a wider ancestor the strip goes in at the bottom.
    NSView* const buttons = zoom.superview == titlebar ? zoom : nil;
    // The gap before the first tab keeps dragging the window natively,
    // double-click zoom included: it belongs to the seam view, which
    // lets the window move; the tab strip does not.
    tabsLeft = NSMaxX([zoom.superview convertRect:zoom.frame toView:titlebar]) + 56;
    // Both views reach one point below the title bar, over the
    // content's top point: whatever the content view's own layers put
    // there, its top device row does not show translucent or vibrant
    // material, only opaque paint. The title bar views draw over the
    // content, so they paint that row themselves, opaquely.
    const NSRect bounds = titlebar.bounds;
    const NSRect frame = NSMakeRect(tabsLeft, -1, bounds.size.width - tabsLeft, bounds.size.height + 1);
    const NSRect seamFrame = NSMakeRect(0, -1, tabsLeft, bounds.size.height + 1);
    if (bar == nil) {
        seam = [[CsdSeamView alloc] initWithFrame:seamFrame];
        seam.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
        seam->owner = this;
        bar = [[CsdTabBarView alloc] initWithFrame:frame];
        bar.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        bar->owner = this;
        // Below the traffic lights: the seam runs under them, the
        // buttons stay on top.
        [titlebar addSubview:seam positioned:NSWindowBelow relativeTo:buttons];
        [titlebar addSubview:bar positioned:NSWindowBelow relativeTo:buttons];
        window.titleVisibility = NSWindowTitleHidden;
        // The frame draws a shadow under the title bar onto the content's
        // top device rows, black at the first and a quarter at the
        // second, over everything but its own border, and the separator
        // style does not govern it. A transparent title bar draws
        // neither the material nor that shadow; the plate then is the
        // window's background, set in restyle() to the flat plate color
        // the rim continues.
        windowBackground = [window.backgroundColor retain];
        window.titlebarAppearsTransparent = YES;
        if (@available(macOS 11.0, *)) {
            window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
        }
        if (composer.opts->vt.verbose) {
            fprintf(stderr, "%s: tabs: strip installed over the title bar\n", composer.brand->identifierCString());
        }
    } else {
        bar.frame = frame;
        seam.frame = seamFrame;
    }
    if (bezelViews != nil && bezelBorder != composer.opts->border) {
        removeBezel();
    }
    if (bezelViews == nil) {
        installBezel(window);
    }
    restyle();
    placeBezel();
    bar.needsDisplay = YES;
    if (composer.opts->vt.verbose) {
        logGeometry(window);
    }
}

namespace {
    static void csdLogSubtree(const char* prefix, NSView* view, int depth) {
        const NSRect frame = view.frame;
        const NSRect bounds = view.bounds;
        fprintf(stderr, "%s: tabs: %*s%s frame=(%g,%g %gx%g) bounds=(%g,%g %gx%g)%s\n", prefix, depth * 2, "", view.className.UTF8String, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height, view.hidden ? " hidden" : "");
        if (depth >= 3) {
            return;
        }
        for (NSView* child in view.subviews) {
            csdLogSubtree(prefix, child, depth + 1);
        }
    }
}

// Everything the seam depends on, for a bug report from a machine this
// code cannot be run on: where the title bar, its container and the
// content view actually sit, and what AppKit put between them.
void CsdTabsUi::logGeometry(NSWindow* window) const {
    const char* const prefix = composer.brand->identifierCString();
    const NSRect frame = window.frame;
    const NSRect content = window.contentView.frame;
    const NSRect layout = window.contentLayoutRect;
    fprintf(stderr, "%s: tabs: window frame=(%g,%g %gx%g) scale=%g content frame=(%g,%g %gx%g) contentLayoutRect=(%g,%g %gx%g) border=%u bezel=%g cornerRadius=%g (frame layer %g) macOS %ld.%ld\n", prefix, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, window.backingScaleFactor, content.origin.x, content.origin.y, content.size.width, content.size.height, layout.origin.x, layout.origin.y, layout.size.width, layout.size.height, (unsigned)(composer.opts->border), bezelWidth(), windowCornerRadius(), window.contentView.superview.layer.cornerRadius, (long)(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion), (long)(NSProcessInfo.processInfo.operatingSystemVersion.minorVersion));
    NSView* titlebar = bar.superview;
    NSView* root = titlebar;
    while (root.superview != nil && root.superview != window.contentView.superview) {
        root = root.superview;
    }
    if (root != nil) {
        csdLogSubtree(prefix, root, 0);
    }
    if (titlebar != nil) {
        const NSRect inWindow = [titlebar convertRect:titlebar.bounds toView:nil];
        fprintf(stderr, "%s: tabs: titlebar in window coordinates=(%g,%g %gx%g)\n", prefix, inWindow.origin.x, inWindow.origin.y, inWindow.size.width, inWindow.size.height);
    }
}

void CsdTabsUi::installBezel(NSWindow* window) {
    NSView* const content = window.contentView;
    if (content == nil) {
        return;
    }
    bezelBorder = composer.opts->border;
    bezelViews = [[NSMutableArray alloc] init];
    const CGFloat bezel = bezelWidth();
    const bool lip = lipVisible();
    const auto add = [&](NSView* view) {
        view.wantsLayer = YES;
        [content addSubview:view];
        [bezelViews addObject:view];
        [view release];
    };
    // Strips first, so every line lands above the material: flat plate
    // color, opaque, the title bar's lifted material continued.
    for (size_t side = 0; side < 3; ++side) {
        if (bezel >= 1) {
            strips[side] = [[CsdHairlineView alloc] initWithFrame:NSZeroRect];
            add(strips[side]);
        }
    }
    for (size_t side = 0; side < 3; ++side) {
        for (size_t line = 0; line < 3; ++line) {
            const bool present = line == 0 ? lip : line == 1 ? bezel >= 1 : bezel >= 2;
            if (!present) {
                continue;
            }
            sideLines[side][line] = [[CsdHairlineView alloc] initWithFrame:NSZeroRect];
            add(sideLines[side][line]);
        }
    }
    if (bezel >= 1) {
        for (size_t at = 0; at < 2; ++at) {
            cornerMaterial[at] = [[CsdHairlineView alloc] initWithFrame:NSZeroRect];
            add(cornerMaterial[at]);
            wellCorners[at] = [[CsdWellCornerView alloc] initWithFrame:NSZeroRect];
            wellCorners[at]->owner = this;
            wellCorners[at]->trailing = at == 1;
            add(wellCorners[at]);
        }
    }
    if (lip || bezel >= 1) {
        for (size_t at = 0; at < 2; ++at) {
            corners[at] = [[CsdCornerView alloc] initWithFrame:NSZeroRect];
            corners[at]->owner = this;
            corners[at]->trailing = at == 1;
            add(corners[at]);
        }
    }
    // The seam lines end where the active tab flares out, which moves
    // with the window width; every other frame is replaced along with
    // them, in the same transaction as the content view's own resize.
    content.postsFrameChangedNotifications = YES;
    const auto observe = [&](NSString* name, id object) {
        return [[NSNotificationCenter.defaultCenter addObserverForName:name
                                                                object:object
                                                                 queue:nil
                                                            usingBlock:^(NSNotification* note) {
                                                              (void)note;
                                                              placeBezel();
                                                            }] retain];
    };
    bezelObservers[0] = observe(NSViewFrameDidChangeNotification, content);
    // The style mask may change after the last content resize during
    // a fullscreen transition; repaint once AppKit has settled it.
    bezelObservers[1] = observe(NSWindowDidEnterFullScreenNotification, window);
    bezelObservers[2] = observe(NSWindowDidExitFullScreenNotification, window);
}

void CsdTabsUi::removeBezel() {
    for (id& observer : bezelObservers) {
        if (observer != nil) {
            [NSNotificationCenter.defaultCenter removeObserver:observer];
            [observer release];
            observer = nil;
        }
    }
    for (NSView* view in bezelViews) {
        [view removeFromSuperview];
    }
    [bezelViews release];
    bezelViews = nil;
    for (size_t side = 0; side < 3; ++side) {
        strips[side] = nil;
        for (size_t line = 0; line < 3; ++line) {
            sideLines[side][line] = nil;
        }
    }
    for (size_t at = 0; at < 2; ++at) {
        cornerMaterial[at] = nil;
        wellCorners[at] = nil;
        corners[at] = nil;
    }
}

void CsdTabsUi::placeBezel() {
    NSWindow* const window = nativeWindow();
    if (window == nil || bezelViews == nil) {
        return;
    }
    const bool edgeToEdge = fullscreen();
    for (NSView* view in bezelViews) {
        view.hidden = edgeToEdge;
    }
    bar.needsDisplay = YES;
    seam.needsDisplay = YES;
    if (edgeToEdge) {
        return;
    }
    const NSRect bounds = window.contentView.bounds;
    const CGFloat width = bounds.size.width;
    const CGFloat height = bounds.size.height;
    const CGFloat bezel = bezelWidth();
    // With a rim the well's top corners round off by the tab fillet;
    // the side lines stop under the curve and the corner views take
    // over. Without one the lines run straight up to the seam.
    const CGFloat corner = strips[0] != nil ? csdTabFillet : 0;
    const CGFloat radius = corners[0] != nil ? windowCornerRadius() : 0;
    const CGFloat rise = height > corner + radius ? height - corner - radius : 0;
    const CGFloat span = width > 2 * radius ? width - 2 * radius : 0;
    if (corners[0] != nil) {
        corners[0].frame = NSMakeRect(0, 0, radius, radius);
        corners[1].frame = NSMakeRect(width - radius, 0, radius, radius);
        corners[0].needsDisplay = YES;
        corners[1].needsDisplay = YES;
    }
    if (strips[0] != nil) {
        strips[0].frame = NSMakeRect(0, 0, bezel, height);
        strips[1].frame = NSMakeRect(width - bezel, 0, bezel, height);
        strips[2].frame = NSMakeRect(0, 0, width, bezel);
        const CGFloat top = height > corner ? height - corner : 0;
        cornerMaterial[0].frame = NSMakeRect(bezel, top, corner, corner);
        cornerMaterial[1].frame = NSMakeRect(width - bezel - corner, top, corner, corner);
        wellCorners[0].frame = NSMakeRect(0, top, bezel + corner, corner);
        wellCorners[1].frame = NSMakeRect(width - bezel - corner, top, bezel + corner, corner);
        wellCorners[0].needsDisplay = YES;
        wellCorners[1].needsDisplay = YES;
    }
    // Line 0 is the lip on the terminal's own border, line 1 the shade
    // at the rim's inner edge, line 2 the glow beside it: each one point
    // further out from the well. They stop short of the window's bottom
    // corners, where the corner views bend them around the radius.
    for (size_t line = 0; line < 3; ++line) {
        const CGFloat distance = bezel - (CGFloat)(line);
        if (sideLines[0][line] != nil) {
            sideLines[0][line].frame = NSMakeRect(distance, radius, 1, rise);
        }
        if (sideLines[1][line] != nil) {
            sideLines[1][line].frame = NSMakeRect(width - distance - 1, radius, 1, rise);
        }
        if (sideLines[2][line] != nil) {
            sideLines[2][line].frame = NSMakeRect(radius, distance, span, 1);
        }
    }
}

void CsdTabsUi::restyle() {
    NSWindow* const window = nativeWindow();
    if (window == nil) {
        return;
    }
    const WellStyle colors = style(window.effectiveAppearance);
    if (bar != nil) {
        window.backgroundColor = colors.plate;
    }
    NSColor* const byLine[3] = {colors.lip, colors.plateShade, colors.plateGlow};
    for (size_t side = 0; side < 3; ++side) {
        if (strips[side] != nil) {
            [strips[side] setColor:colors.plate];
        }
        for (size_t line = 0; line < 3; ++line) {
            if (sideLines[side][line] != nil) {
                [sideLines[side][line] setColor:byLine[line]];
            }
        }
    }
    for (size_t at = 0; at < 2; ++at) {
        if (cornerMaterial[at] != nil) {
            [cornerMaterial[at] setColor:colors.plate];
        }
        if (wellCorners[at] != nil) {
            wellCorners[at].needsDisplay = YES;
        }
        if (corners[at] != nil) {
            corners[at].needsDisplay = YES;
        }
    }
    if (bar != nil) {
        bar.needsDisplay = YES;
        seam.needsDisplay = YES;
    }
}

void CsdTabsUi::tabSelected(size_t index) {
    SessionSet* const sessions = composer.sessions;
    if (sessions == nullptr || index >= sessions->count()) {
        return;
    }
    sessions->activate(index);
    composer.window->requestFrame();
}

void CsdTabsUi::tabClosed(size_t index) {
    SessionSet* const sessions = composer.sessions;
    if (sessions == nullptr || index >= sessions->count()) {
        return;
    }
    if (sessions->close(index)) {
        composer.window->requestFrame();
    } else {
        // The strip only shows with two or more tabs, so this is
        // unreachable in practice; the chord path's semantics anyway.
        composer.window->requestClose();
    }
}

void CsdTabsUi::tabOpened() {
    if (composer.sessions == nullptr) {
        return;
    }
    // Use the same recoverable spawn path as the new-tab chord.
    for (IntrusiveNode* node = composer.newTabListeners.mutFront(); node != composer.newTabListeners.mutEnd();) {
        Listener* const listener = static_cast<Listener*>(node);
        node = node->next;
        listener->onListen();
    }
}

namespace {
    // The well in title bar coordinates: the plate's lift, the seam
    // with its glow and shade, the notch of the active tab filled with
    // the terminal's background, and the lip inside. Both views over
    // the title bar draw it whole and clip to their own frames, so the
    // strokes meet at their shared edge without a seam of their own.
    static void csdDrawWell(CsdTabsUi* owner, NSRect titlebar, NSAppearance* appearance) {
        const NSUInteger active = (NSUInteger)(owner->active);
        const NSRect bounds = titlebar;
        const TabLayout tabs = owner->layout(bounds.size.width);
        const WellStyle colors = owner->style(appearance);
        const CGFloat cellWidth = tabs.cellWidth;
        const CGFloat height = bounds.size.height;
        // The notch of the active tab, drawn from the seam up and back down
        // to it, y up: a flare out of the seam, two rounded top corners, a
        // flare back in.
        const CGFloat left = tabs.left + cellWidth * (CGFloat)(active);
        const CGFloat right = left + cellWidth;
        const CGFloat fillet = tabs.fillet;
        const CGFloat radius = tabs.radius;
        const CGFloat top = height - tabs.inset;
        NSBezierPath* const notch = [NSBezierPath bezierPath];
        [notch moveToPoint:NSMakePoint(left - fillet, 0)];
        [notch appendBezierPathWithArcWithCenter:NSMakePoint(left - fillet, fillet) radius:fillet startAngle:270 endAngle:360 clockwise:NO];
        [notch lineToPoint:NSMakePoint(left, top - radius)];
        [notch appendBezierPathWithArcWithCenter:NSMakePoint(left + radius, top - radius) radius:radius startAngle:180 endAngle:90 clockwise:YES];
        [notch lineToPoint:NSMakePoint(right - radius, top)];
        [notch appendBezierPathWithArcWithCenter:NSMakePoint(right - radius, top - radius) radius:radius startAngle:90 endAngle:0 clockwise:YES];
        [notch lineToPoint:NSMakePoint(right, fillet)];
        [notch appendBezierPathWithArcWithCenter:NSMakePoint(right + fillet, fillet) radius:fillet startAngle:180 endAngle:270 clockwise:NO];
        // The well outline: the seam along the whole bar, lifted into the
        // notch. Strokes centered on it leave their outer half on the
        // material; the fill covers the inner half.
        // With a rim the seam starts and ends where the well's rounded top
        // corners come up to it; the curve itself lies mostly below the
        // seam, drawn by the corner views, and only the outer half of the
        // strokes shows up here. Without a rim, including fullscreen,
        // the seam spans the bar all the way to the window edges.
        const CGFloat bezel = owner->fullscreen() ? 0 : owner->bezelWidth();
        const CGFloat corner = bezel >= 1 ? csdTabFillet : 0;
        const CGFloat width = bounds.size.width;
        NSBezierPath* const outline = [NSBezierPath bezierPath];
        if (corner > 0) {
            [outline moveToPoint:NSMakePoint(bezel, -corner)];
            [outline appendBezierPathWithArcWithCenter:NSMakePoint(bezel + corner, -corner) radius:corner startAngle:180 endAngle:90 clockwise:YES];
        } else {
            [outline moveToPoint:NSMakePoint(0, 0)];
        }
        [outline lineToPoint:NSMakePoint(left - fillet, 0)];
        [outline appendBezierPath:notch];
        if (corner > 0) {
            [outline lineToPoint:NSMakePoint(width - bezel - corner, 0)];
            [outline appendBezierPathWithArcWithCenter:NSMakePoint(width - bezel - corner, -corner) radius:corner startAngle:90 endAngle:0 clockwise:YES];
        } else {
            [outline lineToPoint:NSMakePoint(width, 0)];
        }
        outline.lineJoinStyle = NSLineJoinStyleRound;
        // The fill closes below the seam, through the content's top
        // point, so the notch continues straight into the terminal. With
        // a rim the well's rounded top corners add their discs: the part
        // of each inside the top point is well, too.
        NSBezierPath* const well = [[notch copy] autorelease];
        [well lineToPoint:NSMakePoint(right + fillet, -2)];
        [well lineToPoint:NSMakePoint(left - fillet, -2)];
        [well closePath];
        if (corner > 0) {
            [well appendBezierPathWithOvalInRect:NSMakeRect(bezel, -2 * corner, 2 * corner, 2 * corner)];
            [well appendBezierPathWithOvalInRect:NSMakeRect(width - bezel - 2 * corner, -2 * corner, 2 * corner, 2 * corner)];
        }
        // The content's top point, painted opaquely: the plate's
        // material as a flat color, which is what the rim and the
        // corners hold there; the well and the seam lip go over it.
        [colors.plate setFill];
        NSRectFill(NSMakeRect(0, -1, width, 1));
        outline.lineWidth = 4;
        [colors.glow setStroke];
        [outline stroke];
        outline.lineWidth = 2;
        [colors.shade setStroke];
        [outline stroke];
        // The active tab is a piece of the terminal it fronts: its cell
        // wears the terminal's background and foreground. Idle tabs stay
        // bare, so the title bar's own material shows through.
        [colors.fill setFill];
        [well fill];
        if (owner->lipVisible()) {
            [NSGraphicsContext saveGraphicsState];
            [well addClip];
            [colors.lip setStroke];
            [outline stroke];
            [NSGraphicsContext restoreGraphicsState];
        }
        // The seam under the idle tabs, in the content's top point:
        // terminal background with the lip on it, between the well's
        // top corners and the active tab's flares.
        const CGFloat from = bezel + corner;
        const CGFloat to = width - bezel - corner;
        const NSRect bands[2] = {
            NSMakeRect(from, -1, left - fillet > from ? left - fillet - from : 0, 1),
            NSMakeRect(right + fillet, -1, to > right + fillet ? to - right - fillet : 0, 1),
        };
        for (size_t at = 0; at < 2; ++at) {
            if (bands[at].size.width <= 0) {
                continue;
            }
            [owner->lipVisible() ? colors.lip : colors.fill setFill];
            NSRectFill(bands[at]);
        }
    }
}

@implementation CsdTabBarView

- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    owner->restyle();
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    // The seam strokes are centered on the view's bottom edge and the
    // well fill reaches below it. Since macOS 14 a view no longer clips
    // to its bounds by default, and the outer halves would land on the
    // terminal's top points as stray lines.
    NSRectClip(self.bounds);
    NSArray<NSString*>* const labels = owner->labels;
    const NSUInteger count = labels.count;
    if (count == 0) {
        return;
    }
    // Title bar coordinates, the seam at y = 0: this view starts at the
    // first tab and one point below the seam; the seam view covers the
    // gap before it.
    const CGFloat offset = self.frame.origin.x;
    const NSRect bounds = NSMakeRect(0, 0, self.frame.size.width + offset, self.bounds.size.height - 1);
    NSAffineTransform* const shift = [NSAffineTransform transform];
    [shift translateXBy:-offset yBy:1];
    [shift concat];
    csdDrawWell(owner, bounds, self.effectiveAppearance);
    const NSUInteger active = (NSUInteger)(owner->active);
    const TabLayout tabs = owner->layout(bounds.size.width);
    const CGFloat cellWidth = tabs.cellWidth;
    const CGFloat height = bounds.size.height;
    const Color terminalForeground = owner->composer.opts->vt.fg;
    NSColor* const activeText = csdColor(terminalForeground, 1.0);
    NSColor* const activeGlyphs = [activeText colorWithAlphaComponent:0.75];
    // The strip is our own surface, and the system label tiers are tuned
    // for controls on the standard material: tertiary label over a dark
    // title bar measures 1.16:1 against it (issue 84), which is nothing.
    // Every idle tier moves one step up, and the hairlines are mixed from
    // the label color so they keep following the appearance.
    NSColor* const idleText = NSColor.labelColor;
    NSColor* const idleGlyphs = NSColor.secondaryLabelColor;
    NSColor* const hairline = [NSColor.labelColor colorWithAlphaComponent:0.4];
    NSMutableParagraphStyle* const centered = [[[NSMutableParagraphStyle alloc] init] autorelease];
    centered.alignment = NSTextAlignmentCenter;
    // Long shell titles differ at the tail; keep it, iTerm style.
    centered.lineBreakMode = NSLineBreakByTruncatingHead;
    NSFont* const activeFont = [NSFont titleBarFontOfSize:0];
    NSFont* const idleFont = [NSFont systemFontOfSize:activeFont.pointSize];
    NSDictionary* const activeAttributes = @{
        NSFontAttributeName : activeFont,
        NSForegroundColorAttributeName : activeText,
        NSParagraphStyleAttributeName : centered,
    };
    NSDictionary* const idleAttributes = @{
        NSFontAttributeName : idleFont,
        NSForegroundColorAttributeName : idleText,
        NSParagraphStyleAttributeName : centered,
    };
    NSDictionary* const activeGlyphAttributes = @{
        NSFontAttributeName : activeFont,
        NSForegroundColorAttributeName : activeGlyphs,
    };
    NSDictionary* const idleGlyphAttributes = @{
        NSFontAttributeName : idleFont,
        NSForegroundColorAttributeName : idleGlyphs,
    };
    const auto drawGlyph = [&](NSString* glyph, CGFloat x, NSDictionary* attributes) {
        const NSSize size = [glyph sizeWithAttributes:attributes];
        [glyph drawAtPoint:NSMakePoint(x, bounds.origin.y + (height - size.height) / 2) withAttributes:attributes];
    };
    for (NSUInteger at = 0; at < count; ++at) {
        const NSRect cell = NSMakeRect(tabs.left + cellWidth * (CGFloat)(at), bounds.origin.y, cellWidth, height);
        // Hairlines separate bare cells only; the well draws its own
        // edges. The leftmost tab has the drag gap to its left, and that
        // seam wants the same line unless the tab itself is the well.
        if (at != active && (at == 0 || at - 1 != active)) {
            [hairline setFill];
            NSRectFillUsingOperation(NSMakeRect(cell.origin.x, cell.origin.y + 7, 1, height - 14), NSCompositingOperationSourceOver);
        }
        NSDictionary* const glyphAttributes = at == active ? activeGlyphAttributes : idleGlyphAttributes;
        drawGlyph(@"×", cell.origin.x + 9, glyphAttributes);
        CGFloat trailing = 8;
        if (at < 9) {
            NSString* const hint = [NSString stringWithFormat:@"⌘%u", (unsigned)(at + 1)];
            const NSSize hintSize = [hint sizeWithAttributes:glyphAttributes];
            trailing += hintSize.width + 8;
            drawGlyph(hint, NSMaxX(cell) - 8 - hintSize.width, glyphAttributes);
        }
        NSDictionary* const attributes = at == active ? activeAttributes : idleAttributes;
        NSString* const label = labels[at];
        const NSSize size = [label sizeWithAttributes:attributes];
        const CGFloat leading = csdTabCloseZone;
        const CGFloat available = cell.size.width - leading - trailing;
        if (available <= 0) {
            continue;
        }
        const NSRect text = NSMakeRect(cell.origin.x + leading, cell.origin.y + (height - size.height) / 2, available, size.height);
        [label drawWithRect:text options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes context:nil];
    }
    // The trailing new-tab cell: bare material, a plus, and a hairline
    // against the last tab unless the well already draws that edge.
    const CGFloat plusLeft = tabs.left + tabs.tabsWidth;
    if (count - 1 != active) {
        [hairline setFill];
        NSRectFillUsingOperation(NSMakeRect(plusLeft, bounds.origin.y + 7, 1, height - 14), NSCompositingOperationSourceOver);
    }
    NSString* const plus = @"+";
    const NSSize plusSize = [plus sizeWithAttributes:idleGlyphAttributes];
    drawGlyph(plus, plusLeft + (csdTabPlusWidth - plusSize.width) / 2, idleGlyphAttributes);
}

- (void)mouseDown:(NSEvent*)event {
    const NSUInteger count = owner->labels.count;
    if (count == 0) {
        return;
    }
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    const TabLayout tabs = owner->layout(self.frame.size.width + self.frame.origin.x);
    // Local x runs from the first tab.
    const CGFloat x = point.x;
    if (x < 0) {
        return;
    }
    if (x >= tabs.tabsWidth) {
        owner->tabOpened();
        return;
    }
    NSUInteger index = (NSUInteger)(x / tabs.cellWidth);
    if (index >= count) {
        index = count - 1;
    }
    if (x - tabs.cellWidth * (CGFloat)(index) < csdTabCloseZone) {
        owner->tabClosed((size_t)(index));
        return;
    }
    owner->tabSelected((size_t)(index));
}

@end

@implementation CsdSeamView

- (BOOL)mouseDownCanMoveWindow {
    return YES;
}

- (NSView*)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRectClip(self.bounds);
    if (owner->labels.count == 0) {
        return;
    }
    const NSRect titlebar = NSMakeRect(0, 0, self.superview.bounds.size.width, self.bounds.size.height - 1);
    NSAffineTransform* const shift = [NSAffineTransform transform];
    [shift translateXBy:0 yBy:1];
    [shift concat];
    csdDrawWell(owner, titlebar, self.effectiveAppearance);
}

@end

@implementation CsdHairlineView

- (void)dealloc {
    [color_ release];
    [super dealloc];
}

- (void)setColor:(NSColor*)color {
    [color retain];
    [color_ release];
    color_ = color;
    self.needsDisplay = YES;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    self.layer.backgroundColor = color_.CGColor;
}

- (NSView*)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

@end

@implementation CsdCornerView

- (NSView*)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRectClip(self.bounds);
    const WellStyle colors = owner->style(self.effectiveAppearance);
    const CGFloat bezel = owner->bezelWidth();
    const CGFloat radius = owner->windowCornerRadius();
    if (radius <= 0) {
        return;
    }
    // The window's corner circle, seen from this view: its center is
    // inset by the radius from the two outer edges.
    const NSPoint center = NSMakePoint(trailing ? 0 : radius, radius);
    const CGFloat startAngle = trailing ? 270 : 180;
    const CGFloat endAngle = startAngle + 90;
    // The strips are rectangles along the edges; around the window's
    // rounded corner the rim swings farther in than they reach, so the
    // corner paints the ring between the window's arc and the well's
    // in the plate's color itself.
    if (bezel >= 1) {
        const CGFloat inner = radius - bezel;
        NSBezierPath* const ring = [NSBezierPath bezierPathWithRect:self.bounds];
        [ring appendBezierPathWithOvalInRect:NSMakeRect(center.x - inner, center.y - inner, 2 * inner, 2 * inner)];
        ring.windingRule = NSWindingRuleEvenOdd;
        [colors.plate setFill];
        [ring fill];
    }
    // The same lines as along the edges, at the same distances from
    // the window edge, bent around the corner circle.
    const auto drawLine = [&](CGFloat distance, NSColor* color) {
        const CGFloat lineRadius = radius - distance - 0.5;
        if (lineRadius <= 0) {
            return;
        }
        NSBezierPath* const arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:center radius:lineRadius startAngle:startAngle endAngle:endAngle clockwise:NO];
        arc.lineWidth = 1;
        [color setStroke];
        [arc stroke];
    };
    if (bezel >= 2) {
        drawLine(bezel - 2, colors.plateGlow);
    }
    if (bezel >= 1) {
        drawLine(bezel - 1, colors.plateShade);
    }
    if (owner->lipVisible()) {
        drawLine(bezel, colors.lip);
    }
}

@end

@implementation CsdWellCornerView

- (NSView*)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    // The arcs continue above this view, where the title bar strip
    // draws its share of them; this view keeps to its own points.
    NSRectClip(self.bounds);
    const WellStyle colors = owner->style(self.effectiveAppearance);
    const CGFloat bezel = owner->bezelWidth();
    const CGFloat corner = csdTabFillet;
    // The material square beside the rim, in the plate's color; the
    // quarter of the well inside the curve is filled over it.
    const NSRect square = trailing ? NSMakeRect(0, 0, corner, corner) : NSMakeRect(bezel, 0, corner, corner);
    [colors.plate setFill];
    NSRectFill(square);
    // The well's corner circle: its center sits at the bottom of this
    // view, a fillet in from the rim.
    const NSPoint center = trailing ? NSMakePoint(0, 0) : NSMakePoint(bezel + corner, 0);
    const CGFloat startAngle = trailing ? 90 : 180;
    const CGFloat endAngle = trailing ? 0 : 90;
    NSBezierPath* const quarter = [NSBezierPath bezierPath];
    [quarter moveToPoint:center];
    [quarter appendBezierPathWithArcWithCenter:center radius:corner startAngle:startAngle endAngle:endAngle clockwise:YES];
    [quarter closePath];
    [colors.fill setFill];
    [quarter fill];
    // The same lines as along the rim, bent around the curve: the glow
    // and the shade outside it, the lip inside.
    const auto drawLine = [&](CGFloat radius, NSColor* color) {
        NSBezierPath* const arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:center radius:radius startAngle:startAngle endAngle:endAngle clockwise:YES];
        arc.lineWidth = 1;
        [color setStroke];
        [arc stroke];
    };
    if (bezel >= 2) {
        drawLine(corner + 1.5, colors.plateGlow);
    }
    drawLine(corner + 0.5, colors.plateShade);
    if (owner->lipVisible()) {
        drawLine(corner - 0.5, colors.lip);
    }
}

@end

void createCsdTabsUi(ObjPool& owner, Composer& composer) {
    owner.make<CsdTabsUi>(composer);
}
