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
    // color, and the lip is mixed onto the terminal background. The
    // content layer's top device row drops translucent and vibrant
    // layers on this platform; opaque ones it keeps.
    struct WellStyle {
        NSColor* fill;
        NSColor* shade;
        NSColor* glow;
        NSColor* lip;
        NSColor* plate;
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
        TabLayout layout(CGFloat width) const;
        WellStyle style(NSAppearance* appearance) const;
        bool lipVisible() const;
        void observeWindow(NSWindow* window);
        void stopObservingWindow();
        void redraw();
        void logGeometry(NSWindow* window) const;

        Composer& composer;
        CallSessionsChanged sessionsChanged{this};
        CallConfigChanged configChanged{this};
        CsdTabBarView* bar = nil;
        CsdSeamView* seam = nil;
        // The projected model snapshot the view draws from; nil hides
        // the strip (a lone session keeps the clean native title).
        NSArray<NSString*>* labels = nil;
        size_t active = 0;
        bool applyPending = false;
        CGFloat tabsLeft = 0;
        id windowObservers[3] = {};
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
    // A reload may change the terminal colors or the seam's lip.
    composer.configChangedListeners.pushBack(&configChanged);
}

NSWindow* CsdTabsUi::nativeWindow() const {
    if (composer.window == nullptr) {
        return nil;
    }
    return (__bridge NSWindow*)(composer.window->renderContext().window);
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
    // The plate: the title bar's lifted material, painted by its views.
    const CGFloat plate = dark ? 55 / 255.0 : 232 / 255.0;
    WellStyle result;
    result.fill = csdColor(bg, 1.0);
    result.shade = [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:shadeAlpha];
    result.glow = [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:glowAlpha];
    result.lip = csdMix(bg.red / 255.0, bg.green / 255.0, bg.blue / 255.0, fg.red / 255.0, fg.green / 255.0, fg.blue / 255.0, 0.07);
    result.plate = [NSColor colorWithSRGBRed:plate green:plate blue:plate alpha:1.0];
    return result;
}

bool CsdTabsUi::lipVisible() const {
    return composer.opts->border >= 1;
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
            stopObservingWindow();
            [bar removeFromSuperview];
            [bar release];
            bar = nil;
            [seam removeFromSuperview];
            [seam release];
            seam = nil;
            window.titleVisibility = NSWindowTitleVisible;
            window.titlebarAppearsTransparent = NO;
            if (@available(macOS 11.0, *)) {
                window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleAutomatic;
            }
            // The native frame also draws outside the title bar. Repaint
            // it when restoring its material, including the window edges.
            window.contentView.superview.needsDisplay = YES;
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
        // neither the material nor that shadow. The strip views paint
        // the plate themselves, keeping the window background clear so
        // AppKit does not put its highlight around the content edges.
        window.titlebarAppearsTransparent = YES;
        if (@available(macOS 11.0, *)) {
            window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
        }
        // Changing the title bar also changes the frame's background.
        // Invalidate the whole frame, not just our strip, so its old edge
        // pixels do not survive until a resize or fullscreen transition.
        frameView.needsDisplay = YES;
        if (composer.opts->vt.verbose) {
            fprintf(stderr, "%s: tabs: strip installed over the title bar\n", composer.brand->identifierCString());
        }
    } else {
        bar.frame = frame;
        seam.frame = seamFrame;
    }
    if (windowObservers[0] == nil) {
        observeWindow(window);
    }
    redraw();
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
    fprintf(stderr, "%s: tabs: window frame=(%g,%g %gx%g) scale=%g content frame=(%g,%g %gx%g) contentLayoutRect=(%g,%g %gx%g) border=%u (frame layer corner radius %g) macOS %ld.%ld\n", prefix, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, window.backingScaleFactor, content.origin.x, content.origin.y, content.size.width, content.size.height, layout.origin.x, layout.origin.y, layout.size.width, layout.size.height, (unsigned)(composer.opts->border), window.contentView.superview.layer.cornerRadius, (long)(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion), (long)(NSProcessInfo.processInfo.operatingSystemVersion.minorVersion));
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

void CsdTabsUi::observeWindow(NSWindow* window) {
    NSView* const content = window.contentView;
    if (content == nil) {
        return;
    }
    // The active tab's position depends on the whole window width, so
    // both title bar views repaint in the content resize transaction.
    content.postsFrameChangedNotifications = YES;
    const auto observe = [&](NSString* name, id object) {
        return [[NSNotificationCenter.defaultCenter addObserverForName:name
                                                                object:object
                                                                 queue:nil
                                                            usingBlock:^(NSNotification* note) {
                                                              (void)note;
                                                              redraw();
                                                            }] retain];
    };
    windowObservers[0] = observe(NSViewFrameDidChangeNotification, content);
    windowObservers[1] = observe(NSWindowDidEnterFullScreenNotification, window);
    windowObservers[2] = observe(NSWindowDidExitFullScreenNotification, window);
}

void CsdTabsUi::stopObservingWindow() {
    for (id& observer : windowObservers) {
        if (observer != nil) {
            [NSNotificationCenter.defaultCenter removeObserver:observer];
            [observer release];
            observer = nil;
        }
    }
}

void CsdTabsUi::redraw() {
    bar.needsDisplay = YES;
    seam.needsDisplay = YES;
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
        // The seam reaches both window edges in every window mode.
        const CGFloat width = bounds.size.width;
        NSBezierPath* const outline = [NSBezierPath bezierPath];
        [outline moveToPoint:NSMakePoint(0, 0)];
        [outline lineToPoint:NSMakePoint(left - fillet, 0)];
        [outline appendBezierPath:notch];
        [outline lineToPoint:NSMakePoint(width, 0)];
        outline.lineJoinStyle = NSLineJoinStyleRound;
        // The fill closes below the seam, through the content's top
        // point, so the notch continues straight into the terminal.
        NSBezierPath* const well = [[notch copy] autorelease];
        [well lineToPoint:NSMakePoint(right + fillet, -2)];
        [well lineToPoint:NSMakePoint(left - fillet, -2)];
        [well closePath];
        // Paint the whole plate here, including the content's top point.
        // Giving NSWindow this color would bring back its edge highlight.
        [colors.plate setFill];
        NSRectFill(NSMakeRect(0, -1, width, height + 1));
        outline.lineWidth = 4;
        [colors.glow setStroke];
        [outline stroke];
        outline.lineWidth = 2;
        [colors.shade setStroke];
        [outline stroke];
        // The active tab is a piece of the terminal it fronts: its cell
        // wears the terminal's background and foreground. Idle tabs keep
        // the plate color underneath.
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
        // terminal background with the lip on it, from the window
        // edges to the active tab's flares.
        const CGFloat from = 0;
        const CGFloat to = width;
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
    owner->redraw();
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

void createCsdTabsUi(ObjPool& owner, Composer& composer) {
    owner.make<CsdTabsUi>(composer);
}
