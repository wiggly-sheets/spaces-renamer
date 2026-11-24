#define SPACES_RENAMER_TESTING 1

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <Cocoa/Cocoa.h>

// Integration test for the macOS 27 Spaces-bar hook in spacesRenamer.m.
//
// This file installs the real ZKSwizzle hooks (ZKSwizzle.m is imported below,
// so ZKSwizzle.h emits its real macros) and drives the actual CALayer hot
// path: -setBounds: and -layoutSublayers on a fake SpacesBar layer tree, with
// a names/monitors snapshot published to a throwaway preference domain. The
// swizzle-install idempotency is asserted separately.
//
// Safety: only layers named "SpacesBar" trigger applySpacesBarNames, and the
// dangerous sre_applySpaceNamesForFrame prefilter in -setFrame: requires a
// frame whose width matches an active display. The tree is built with
// zero-sized frames and the bar's geometry is driven through -setBounds:,
// so no QuartzCore-internal layer reaches that path.

@interface ECTextLayer : CATextLayer @end
@implementation ECTextLayer @end

#import "../ZKSwizzle.m"
#import "../spacesRenamer.m"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
  }
}

// SpacesBar -> SpacesBarPreviewContainerLayer -> holder -> PreviewLabel.
static CALayer *buildSpacesBar(CATextLayer **labelOut) {
  CALayer *bar = [CALayer layer];
  bar.name = kSpacesBarLayerName;

  CALayer *container = [CALayer layer];
  container.name = kSpacesBarContainerLayerName;

  CALayer *holder = [CALayer layer];

  CATextLayer *label = [CATextLayer layer];
  label.name = kSpacesBarLabelLayerName;
  label.string = @"Desktop 1";

  [holder addSublayer:label];
  [container addSublayer:holder];
  [bar addSublayer:container];

  *labelOut = label;
  return bar;
}

static void publishNamesSnapshot(void) {
  NSString *domain = testDomain();
  NSDictionary *names = @{ @"space-uuid-1": @"Code" };
  NSArray *monitors = @[@{
    @"Display Identifier": @"Main",
    @"Current Space": @{ @"uuid": @"space-uuid-1" },
    @"Spaces": @[@{ @"uuid": @"space-uuid-1", @"type": @0 }]
  }];
  CFPreferencesSetAppValue((CFStringRef)kNamesKey, (CFPropertyListRef)names, (CFStringRef)domain);
  CFPreferencesSetAppValue((CFStringRef)kMonitorsKey, (CFPropertyListRef)monitors, (CFStringRef)domain);
  CFPreferencesAppSynchronize((CFStringRef)domain);
}

// applySpacesBarLabel learns the desktop number from ORIGINAL_STRING, which
// the CATextLayer setString: swizzle normally sets. Mimic that here so the
// test does not depend on the setString: path.
static void rememberDesktopTitle(CATextLayer *label, NSString *title) {
  assign(label, &ORIGINAL_STRING, title);
}

static void testSetBoundsPublishesSpacesBarNames(void) {
  CATextLayer *label = nil;
  CALayer *bar = buildSpacesBar(&label);
  publishNamesSnapshot();
  rememberDesktopTitle(label, @"Desktop 1");

  // Drive the real CALayer setBounds: swizzle; it calls applySpacesBarNames
  // on the bar, which applies the custom name to PreviewLabel.
  [bar setBounds: NSMakeRect(0, 0, 1920, 1080)];
  require([label.string isEqual:@"Code"],
          @"setBounds: on the Spaces bar should publish the custom Space name on PreviewLabel");

  NSDictionary *marker = (NSDictionary *)CFPreferencesCopyAppValue(
      CFSTR("SpacesRenamerPlugin"), (CFStringRef)testDomain());
  require([marker isKindOfClass:[NSDictionary class]],
          @"a successful hook pass should write the SpacesRenamerPlugin status marker");
  require(marker[@"FirstHookAt"] != nil,
          @"the status marker should record the first hook pass");
  [marker release];

  // A second layout pass must not crash or invert the swizzle.
  [bar setBounds: NSMakeRect(0, 0, 1920, 1080)];
  require([label.string isEqual:@"Code"],
          @"a second setBounds: pass must keep the custom name");
}

static void testLayoutSublayersPublishesSpacesBarNames(void) {
  CATextLayer *label = nil;
  CALayer *bar = buildSpacesBar(&label);
  publishNamesSnapshot();
  rememberDesktopTitle(label, @"Desktop 1");

  [bar layoutSublayers];
  require([label.string isEqual:@"Code"],
          @"layoutSublayers on the Spaces bar should publish the custom Space name");
}

static void testReSwizzlingSameSourceIsIdempotent(void) {
  Class src = NSClassFromString(@"_SRCALayer");
  require(src != nil, @"the _SRCALayer swizzle source class must exist");

  // _SRCALayer was already swizzled into CALayer at class load; re-swizzling
  // the same source must return YES without re-installing or inverting.
  BOOL ok = _ZKSwizzle(src, [CALayer class]);
  require(ok, @"re-swizzling the same source class must return YES idempotently");

  CATextLayer *label = nil;
  CALayer *bar = buildSpacesBar(&label);
  publishNamesSnapshot();
  rememberDesktopTitle(label, @"Desktop 1");
  [bar setBounds: NSMakeRect(0, 0, 1920, 1080)];
  require([label.string isEqual:@"Code"],
          @"after a re-swizzle the custom name must still be published");
}

// Two displays of two desktops each: a1 a2 on the first, b1 b2 on the second.
static NSArray<Monitor *> *twoDisplayMonitors(void) {
  NSArray *raw = @[
    @{ @"Display Identifier": @"Main",
       @"Current Space": @{ @"uuid": @"a1" },
       @"Spaces": @[ @{ @"uuid": @"a1", @"type": @0 }, @{ @"uuid": @"a2", @"type": @0 } ] },
    @{ @"Display Identifier": @"Second",
       @"Current Space": @{ @"uuid": @"b1" },
       @"Spaces": @[ @{ @"uuid": @"b1", @"type": @0 }, @{ @"uuid": @"b2", @"type": @0 } ] }
  ];
  NSDictionary *names = @{ @"a1": @"A1", @"a2": @"A2", @"b1": @"B1", @"b2": @"B2" };
  return parseMonitorsFromRaw(names, raw);
}

static void publishSpans(BOOL spans) {
  NSString *domain = testDomain();
  CFPreferencesSetAppValue((CFStringRef)kSpansKey, (CFPropertyListRef)@(spans), (CFStringRef)domain);
  CFPreferencesAppSynchronize((CFStringRef)domain);
}

static void testDesktopNumbering(void) {
  NSArray<Monitor *> *monitors = twoDisplayMonitors();
  require(monitors.count == 2, @"the fixture must parse two displays");
  Monitor *first = monitors[0];
  Monitor *second = monitors[1];
  BOOL undecided = NO;

  // Without evidence the second display's numbering is unknown, so the hook
  // must not guess and show a name on the wrong Space.
  [numberedAcross release];
  numberedAcross = nil;
  publishSpans(NO);
  require(spaceForDesktopNumber(monitors, second, 2, &undecided) == nil && undecided,
          @"an unknown numbering must be reported as undecided");

  // "Desktop 1" on a later display proves the desktops restart per display.
  NSDictionary *space = spaceForDesktopNumber(monitors, second, 1, &undecided);
  require([space[@"name"] isEqual:@"B1"] && !undecided,
          @"desktop 1 on a later display is that display's first desktop");

  // A number above the display's own count proves numbering continues across.
  space = spaceForDesktopNumber(monitors, second, 3, &undecided);
  require([space[@"name"] isEqual:@"B1"] && !undecided,
          @"a desktop number past the second display's count is numbered across");

  // When macOS numbers every desktop across displays, the offsets are known.
  [numberedAcross release];
  numberedAcross = nil;
  publishSpans(YES);
  space = spaceForDesktopNumber(monitors, second, 3, &undecided);
  require([space[@"name"] isEqual:@"B1"] && !undecided,
          @"shared Spaces map desktop 3 to the second display's first desktop");
  space = spaceForDesktopNumber(monitors, first, 2, &undecided);
  require([space[@"name"] isEqual:@"A2"],
          @"shared Spaces keep the first display's desktop order");
}

int main(void) {
  @autoreleasepool {
    testSetBoundsPublishesSpacesBarNames();
    testLayoutSublayersPublishesSpacesBarNames();
    testReSwizzlingSameSourceIsIdempotent();
    testDesktopNumbering();
    NSLog(@"PASS: Dock hook integration (applySpacesBarNames + swizzle idempotency + desktop numbering)");
  }
  return 0;
}