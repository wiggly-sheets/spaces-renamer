@import Foundation;
@import CoreText;
#import "ZKSwizzle.h"
#import <QuartzCore/QuartzCore.h>
#import <Cocoa/Cocoa.h>
#import <os/signpost.h>
#import <unistd.h>

#ifndef SPACES_RENAMER_VERSION
#define SPACES_RENAMER_VERSION "unknown"
#endif
#ifndef SPACES_RENAMER_BUILD
#define SPACES_RENAMER_BUILD "unknown"
#endif

// `make DEBUG=1` compiles verbose tracing of the layer tree into the unified log:
//   log stream --predicate 'subsystem == "com.alexbeals.spaces-renamer"'
#ifdef SR_DEBUG
#define SRLog(fmt, ...) os_log(os_log_create("com.alexbeals.spaces-renamer", "hook"), fmt, ##__VA_ARGS__)
#else
#define SRLog(fmt, ...) do {} while (0)
#endif

// Data channel between the app and the plugin: preference domains, not files.
//
// WindowManager (which draws the Spaces bar from macOS 27) runs under
// /System/Library/Sandbox/Profiles/com.apple.WindowManager.sb: `(deny default)`, no file reads
// under ~/Library, but `user-preference-read` for the `com.apple.dock` domain and
// `user-preference-write` for its own `com.apple.WindowManager` domain. Dock is unsandboxed.
// So:
//   - the app publishes names and the current layout as keys of the `com.apple.dock` domain,
//     which every host can read;
//   - the plugin publishes its status marker in the host's own domain, which the host can
//     write and the app can read.
// The hook test redirects both to a throwaway domain through SPACES_RENAMER_DOMAIN; no host
// process ever sets that variable.
static NSString *const kNamesDomain = @"com.apple.dock";
static NSString *const kNamesKey = @"SpacesRenamerNames";       // { space uuid : name }
static NSString *const kMonitorsKey = @"SpacesRenamerMonitors"; // CGSCopyManagedDisplaySpaces array
static NSString *const kStatusKey = @"SpacesRenamerPlugin";     // status marker dictionary

static NSString *testDomain(void) {
  const char *override = getenv("SPACES_RENAMER_DOMAIN");
  return (override && *override) ? [NSString stringWithUTF8String:override] : nil;
}

static NSString *namesDomain(void) {
  return testDomain() ?: kNamesDomain;
}

static NSString *statusDomain(void) {
  return testDomain() ?: [NSBundle mainBundle].bundleIdentifier;
}

static id readPreference(NSString *key, NSString *domain) {
  CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)domain);
  return value ? [(id)value autorelease] : nil;
}

// Status marker read by the app's diagnostics pane. Written once when the dylib loads into
// the host and once more when the Spaces bar hook first fires, so the app can tell
// "installed but never injected" from "injected but the layer tree changed again".
static void writePluginStatus(BOOL hookFired) {
  @autoreleasepool {
    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    if (hookFired) {
      id previous = readPreference(kStatusKey, statusDomain());
      if ([previous isKindOfClass:[NSDictionary class]]) {
        [status addEntriesFromDictionary:previous];
      }
      status[@"FirstHookAt"] = [NSDate date];
    } else {
      status[@"Version"] = @SPACES_RENAMER_VERSION;
      status[@"Build"] = @SPACES_RENAMER_BUILD;
      status[@"HostPID"] = @(getpid());
      status[@"HostBundleID"] = [NSBundle mainBundle].bundleIdentifier ?: @"";
      status[@"LoadedAt"] = [NSDate date];
    }
    CFPreferencesSetAppValue((CFStringRef)kStatusKey, (CFPropertyListRef)status, (CFStringRef)statusDomain());
    CFPreferencesAppSynchronize((CFStringRef)statusDomain());
  }
}

// The hooks are only installed inside the process that draws the Spaces bar: Dock up to
// macOS 26, WindowManager from macOS 27. Injection mechanisms such as DYLD_INSERT_LIBRARIES
// can land the dylib in unrelated processes, which must not overwrite the status marker.
// The hook test opts in through the domain override.
#ifndef SPACES_RENAMER_TESTING
__attribute__((constructor))
#endif
static void spacesRenamerDidLoad(void) {
  @autoreleasepool {
    NSString *host = [NSBundle mainBundle].bundleIdentifier;
    if (![host isEqualToString:@"com.apple.dock"] &&
        ![host isEqualToString:@"com.apple.WindowManager"] &&
        !testDomain()) {
      return; // loaded into some other process (DYLD injects everywhere) — no-op
    }
    // Swizzles install at class load (the target's ZKSwizzleInterface style); the status
    // marker is the only constructor work, gated to real hosts above.
    writePluginStatus(NO);
  }
}

static char OVERRIDDEN_STRING;
static char ORIGINAL_STRING;
static char OVERRIDDEN_WIDTH;
static char OFFSET;
static char NEW_X;
static char TYPE;
static char PENDING_APPLY;
static char CACHED_TEXT_LAYER;
static char OBSERVING_PROPERTIES_CHANGED;

@class Monitor;

@interface Monitor : NSObject
@property (nonatomic, strong) NSString *displayUUID;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *spaces;
@end

@implementation Monitor
- (void)dealloc {
  [_displayUUID release];
  [_spaces release];
  [super dealloc];
}
@end

#define kMaxDisplays 12

int monitorIndex = 0;

static os_log_t performanceLog(void) {
  static os_log_t log;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    log = os_log_create("com.wiggly-sheets.spaces-renamer", "DockHook");
  });
  return log;
}

static Class textLayerClass(void) {
  static Class layerClass;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    layerClass = NSClassFromString(@"ECTextLayer");
  });
  return layerClass;
}

static void refreshFrames(CALayer *frame) {
  for (CALayer *layer in frame.sublayers) {
    [layer setFrame:layer.frame];
    refreshFrames(layer);
  }
}

static void refreshChangedViews(NSArray<CALayer *> *views) {
  for (CALayer *view in views) {
    [view setFrame:view.frame];
    refreshFrames(view);
  }
}

static void assign(id a, void *key, id assigned) {
  objc_setAssociatedObject(a, key, assigned, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL assignIfChanged(id object, void *key, id value) {
  if (object == nil) {
    return NO;
  }
  id existing = objc_getAssociatedObject(object, key);
  if (existing == value || [existing isEqual:value]) {
    return NO;
  }
  assign(object, key, value);
  if (key != &NEW_X) {
    assign(object, &NEW_X, nil);
  }
  return YES;
}

static BOOL isDescendant(CALayer *candidate, CALayer *ancestor) {
  for (CALayer *layer = candidate; layer != nil; layer = layer.superlayer) {
    if (layer == ancestor) {
      return YES;
    }
  }
  return NO;
}

static CATextLayer *getTextLayer(CALayer *view) {
  CATextLayer *cached = objc_getAssociatedObject(view, &CACHED_TEXT_LAYER);
  if (cached != nil && isDescendant(cached, view)) {
    return cached;
  }
  if (cached != nil) {
    assign(view, &CACHED_TEXT_LAYER, nil);
  }

  CATextLayer *layer = nil;
  if (view.class == textLayerClass()) {
    layer = (CATextLayer *)view;
  } else {
    for (CALayer *sublayer in view.sublayers) {
      CATextLayer *tempLayer = getTextLayer(sublayer);
      if (tempLayer != nil) {
        layer = tempLayer;
        break;
      }
    }
  }
  if (layer != nil) {
    assign(view, &CACHED_TEXT_LAYER, layer);
  }
  return layer;
}

static BOOL setOffset(CALayer *view, double offset, bool modify) {
  CATextLayer *textLayer = getTextLayer(view);
  BOOL changed = NO;

  if (textLayer != nil) {
    CALayer *parent = textLayer.superlayer;
    if (modify) {
      id possibleOffset = objc_getAssociatedObject(parent, &OFFSET);
      if (possibleOffset && [possibleOffset isKindOfClass:[NSNumber class]]) {
        changed |= assignIfChanged(
          parent,
          &OFFSET,
          [NSNumber numberWithDouble:offset + [possibleOffset doubleValue]]
        );
      }
    } else {
      changed |= assignIfChanged(parent, &OFFSET, [NSNumber numberWithDouble:offset]);
    }
    for (CALayer *sublayer in parent.sublayers) {
      if (modify) {
        id possibleOffset = objc_getAssociatedObject(sublayer, &OFFSET);
        if (possibleOffset && [possibleOffset isKindOfClass:[NSNumber class]]) {
          changed |= assignIfChanged(
            sublayer,
            &OFFSET,
            [NSNumber numberWithDouble:offset + [possibleOffset doubleValue]]
          );
        }
      } else {
        changed |= assignIfChanged(sublayer, &OFFSET, [NSNumber numberWithDouble:offset]);
      }
    }
  }
  return changed;
}

static BOOL clearOffset(CALayer *view) {
  CATextLayer *textLayer = getTextLayer(view);
  if (textLayer == nil) {
    return NO;
  }

  BOOL changed = NO;
  CALayer *parent = textLayer.superlayer;
  changed |= assignIfChanged(parent, &OFFSET, nil);
  for (CALayer *sublayer in parent.sublayers) {
    changed |= assignIfChanged(sublayer, &OFFSET, nil);
  }
  return changed;
}

static BOOL overrideTextLayer(CALayer *view, NSString *newString, double width, NSString *type) {
  CATextLayer *textLayer = getTextLayer(view);
  BOOL changed = NO;

  if (textLayer != nil) {
    id originalString = objc_getAssociatedObject(textLayer, &ORIGINAL_STRING);
    id currentString = textLayer.string;
    if (
      originalString == nil
      && (
        [currentString isKindOfClass:[NSString class]]
        || [currentString isKindOfClass:[NSAttributedString class]]
      )
    ) {
      assign(textLayer, &ORIGINAL_STRING, currentString);
    }

    CALayer *parent = textLayer.superlayer;
    changed |= assignIfChanged(parent, &OVERRIDDEN_STRING, newString);
    changed |= assignIfChanged(parent, &TYPE, type);
    if (width != -1) {
      changed |= assignIfChanged(parent, &OVERRIDDEN_WIDTH, [NSNumber numberWithDouble:width]);
    }
    for (CALayer *sublayer in parent.sublayers) {
      changed |= assignIfChanged(sublayer, &OVERRIDDEN_STRING, newString);
      changed |= assignIfChanged(sublayer, &TYPE, type);
      if (width != -1) {
        changed |= assignIfChanged(sublayer, &OVERRIDDEN_WIDTH, [NSNumber numberWithDouble:width]);
      }
    }
    if (![textLayer.string isEqual:newString]) {
      textLayer.string = newString;
      changed = YES;
    }
  }
  return changed;
}

static BOOL clearTextLayerOverride(CALayer *view) {
  CATextLayer *textLayer = getTextLayer(view);
  if (textLayer == nil) {
    return NO;
  }

  CALayer *parent = textLayer.superlayer;
  if (
    objc_getAssociatedObject(textLayer, &OVERRIDDEN_STRING) == nil
    && objc_getAssociatedObject(textLayer, &ORIGINAL_STRING) == nil
  ) {
    return NO;
  }

  BOOL changed = NO;
  changed |= assignIfChanged(parent, &OVERRIDDEN_STRING, nil);
  changed |= assignIfChanged(parent, &OVERRIDDEN_WIDTH, nil);
  changed |= assignIfChanged(parent, &TYPE, nil);
  for (CALayer *sublayer in parent.sublayers) {
    changed |= assignIfChanged(sublayer, &OVERRIDDEN_STRING, nil);
    changed |= assignIfChanged(sublayer, &OVERRIDDEN_WIDTH, nil);
    changed |= assignIfChanged(sublayer, &TYPE, nil);
  }

  id originalString = objc_getAssociatedObject(textLayer, &ORIGINAL_STRING);
  if (originalString != nil && ![textLayer.string isEqual:originalString]) {
    textLayer.string = originalString;
    changed = YES;
  }
  assign(textLayer, &ORIGINAL_STRING, nil);
  return changed;
}

static void enforceTextLayerOverride(CATextLayer *textLayer) {
  id overridden = objc_getAssociatedObject(textLayer, &OVERRIDDEN_STRING);
  if (![overridden isKindOfClass:[NSString class]] || [textLayer.string isEqual:overridden]) {
    return;
  }

  id currentString = textLayer.string;
  if (
    [currentString isKindOfClass:[NSString class]]
    || [currentString isKindOfClass:[NSAttributedString class]]
  ) {
    assign(textLayer, &ORIGINAL_STRING, currentString);
  }
  textLayer.string = overridden;
}

static double getTextSizeHelper(CATextLayer *textLayer, NSString *string) {
  CFRange textRange = CFRangeMake(0, string.length);
  CFMutableAttributedStringRef attributedString = CFAttributedStringCreateMutable(kCFAllocatorDefault, string.length);
  CFAttributedStringReplaceString(attributedString, CFRangeMake(0, 0), (CFStringRef) string);
  CFAttributedStringSetAttribute(attributedString, textRange, kCTFontAttributeName, ((CATextLayer *)textLayer).font);
  CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString(attributedString);
  CFRange fitRange;
  CGSize frameSize = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, textRange, NULL, CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX), &fitRange);
  CFRelease(framesetter);
  CFRelease(attributedString);
  return frameSize.width;
}

static double getTextSize(CALayer *view, NSString *string) {
  CATextLayer *textLayer = getTextLayer(view);
  if (textLayer != nil) {
    static NSCache<NSString *, NSNumber *> *widthCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      widthCache = [[NSCache alloc] init];
      widthCache.countLimit = 512;
    });
    NSString *cacheKey = [NSString stringWithFormat:
      @"%p|%.3f|%@",
      textLayer.font,
      textLayer.fontSize,
      string
    ];
    NSNumber *cachedWidth = [widthCache objectForKey:cacheKey];
    if (cachedWidth != nil) {
      return cachedWidth.doubleValue;
    }

    // Avoid a CoreText zero-width result for whitespace-only strings.
    double width = getTextSizeHelper(textLayer, [string stringByAppendingString:@".."])
      - getTextSizeHelper(textLayer, @".");
    [widthCache setObject:@(width) forKey:cacheKey];
    return width;
  }
  return -1;
}

static int getSelected(NSArray<CALayer *> *views) {
  for (NSUInteger index = 0; index < views.count; index++) {
    if (views[index].sublayers.count > 1) {
      return (int)index;
    }
  }
  return -1;
}

// Core parser for the preference-domain data. names is the raw { space-uuid : name }
// dictionary; monitors is the raw CGS monitor array. Each parsed space carries:
//   selected  (uuid == the display's Current Space uuid)
//   name      (the custom name, empty when absent)
//   type      (0 desktop, 4 full-screen; old plists may lack it, default 0)
static NSArray<Monitor *> *parseMonitorsFromRaw(NSDictionary *names, NSArray *monitors) {
  NSMutableArray<Monitor *> *parsedMonitors = [NSMutableArray
    arrayWithCapacity:[monitors count]
  ];
  for (id monitorValue in monitors) {
    if (![monitorValue isKindOfClass:[NSDictionary class]]) {
      return @[];
    }
    NSDictionary *monitorDictionary = monitorValue;

    id spaces = [monitorDictionary objectForKey:@"Spaces"];
    if (![spaces isKindOfClass:[NSArray class]]) {
      return @[];
    }

    id currentSpace = [monitorDictionary objectForKey:@"Current Space"];
    if (currentSpace != nil && ![currentSpace isKindOfClass:[NSDictionary class]]) {
      return @[];
    }
    id selected = [currentSpace objectForKey:@"uuid"];
    if (selected != nil && ![selected isKindOfClass:[NSString class]]) {
      return @[];
    }

    id displayUUID = [monitorDictionary objectForKey:@"Display Identifier"];
    if (displayUUID != nil && ![displayUUID isKindOfClass:[NSString class]]) {
      return @[];
    }

    NSMutableArray<NSMutableDictionary *> *spaceNames = [NSMutableArray
      arrayWithCapacity:[spaces count]
    ];
    for (id spaceValue in spaces) {
      if (![spaceValue isKindOfClass:[NSDictionary class]]) {
        return @[];
      }
      id uuid = [spaceValue objectForKey:@"uuid"];
      if (![uuid isKindOfClass:[NSString class]]) {
        return @[];
      }

      id name = [names objectForKey:uuid];
      if (name != nil && ![name isKindOfClass:[NSString class]]) {
        return @[];
      }
      id type = [spaceValue objectForKey:@"type"];
      NSMutableDictionary *parsedSpace = [@{
        @"selected": @([uuid isEqualToString:selected]),
        @"name": name ?: @"",
        @"type": [type isKindOfClass:[NSNumber class]] ? type : @0
      } mutableCopy];
      [spaceNames addObject:parsedSpace];
      [parsedSpace release];
    }

    Monitor *monitor = [[[Monitor alloc] init] autorelease];
    monitor.displayUUID = displayUUID;
    monitor.spaces = spaceNames;
    [parsedMonitors addObject:monitor];
  }
  return parsedMonitors;
}

static NSArray<Monitor *> *getNamesFromPlist(BOOL *cacheHit) {
  // The app publishes names and monitors to the `com.apple.dock` preference
  // domain (readable by every possible host, including the macOS 27
  // WindowManager sandbox). cfprefsd caches the values, so a fresh read here
  // is cheap and needs no mtime cache.
  id publishedNames = readPreference(kNamesKey, namesDomain());
  if (publishedNames != nil) {
    if (cacheHit != NULL) {
      *cacheHit = NO;
    }
    if (![publishedNames isKindOfClass:[NSDictionary class]]) {
      return @[];
    }
    id publishedMonitors = readPreference(kMonitorsKey, namesDomain());
    if (![publishedMonitors isKindOfClass:[NSArray class]]) {
      return @[];
    }
    return parseMonitorsFromRaw(publishedNames, publishedMonitors);
  }

  if (cacheHit != NULL) {
    *cacheHit = NO;
  }
  return @[];
}

// =====================================================================================
// macOS 27+: Mission Control's Spaces bar is drawn by WindowManager, not Dock.
//
// Layer tree (per display):
//   CALayer (root, CAContext bound to one display)
//     CALayer "SpacesBar" (delegate WindowManagerAgent.SpacesBarLayerController)
//       WindowManagerAgent.SpacesBarPreviewContainerLayer "SpacesBarPreviewContainerLayer" ×N
//         CALayer
//           WindowManagerAgent.TextLayer "PreviewLabel"   (CATextLayer, string "Desktop N")
//       CALayer "SpacesBarAddSpaceButton", "Material", "Shadow", ...
// The bar receives -setBounds: on every layout pass and -layoutSublayers once per show.
// =====================================================================================

static NSString *const kSpacesBarLayerName = @"SpacesBar";
static NSString *const kSpacesBarContainerLayerName = @"SpacesBarPreviewContainerLayer";
static NSString *const kSpacesBarLabelLayerName = @"PreviewLabel";

// The display a layer is shown on: WindowManager binds each root layer to a CAContext whose
// (private) displayId is the CGDirectDisplayID. Returns nil while the context is not attached.
static NSString *displayUUIDForLayer(CALayer *layer) {
  CALayer *root = layer;
  while (root.superlayer) {
    root = root.superlayer;
  }
  if (![root respondsToSelector:@selector(context)]) {
    return nil;
  }
  id context = [root performSelector:@selector(context)];
  NSNumber *displayID = nil;
  @try {
    displayID = [context valueForKey:@"displayId"];
  } @catch (NSException *ignored) {
    return nil;
  }
  if (![displayID isKindOfClass:[NSNumber class]] || displayID.unsignedIntValue == 0) {
    return nil;
  }
  CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displayID.unsignedIntValue);
  if (!uuid) {
    return nil;
  }
  NSString *string = (NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
  CFRelease(uuid);
  return [string autorelease];
}

// The names entry for a display. CGSCopyManagedDisplaySpaces reports the display either by
// UUID or as "Main" (the main display); accept both spellings.
static Monitor *monitorForDisplayUUID(NSArray<Monitor *> *names, NSString *displayUUID) {
  if (!displayUUID) {
    return nil;
  }
  NSString *mainUUID = nil;
  CFUUIDRef main = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID());
  if (main) {
    mainUUID = [(NSString *)CFUUIDCreateString(kCFAllocatorDefault, main) autorelease];
    CFRelease(main);
  }
  for (Monitor *monitor in names) {
    if ([monitor.displayUUID isEqualToString:displayUUID]) {
      return monitor;
    }
    if ([monitor.displayUUID isEqualToString:@"Main"] && [mainUUID isEqualToString:displayUUID]) {
      return monitor;
    }
  }
  return nil;
}

static NSString *const kSpacesBarLabelSelectionLayerName = @"SpacesBarPreviewLabelSelection";
static const CGFloat kSpacesBarLabelPillPadding = 10;  // selection pill extends this far past the label
static const CGFloat kSpacesBarLabelMargin = 10;       // keep the label inside the container

// WindowManager sizes the label, its holder and the selection pill for its own "Desktop N"
// string and centers the holder in the container; a custom name needs the same geometry
// recomputed for its own width, capped at the container width.
//
//   container (190×129)
//     CALayer holder {x, 105, w, 24}            centered: x = (190 - w) / 2
//       CALayer "SpacesBarPreviewLabelSelection" {-10, 0, w + 20, 24}   (only when selected)
//       TextLayer "PreviewLabel" {0, 4, w, 17}  truncationMode=end, alignment=center
static void fitSpacesBarLabel(CATextLayer *label, CALayer *container) {
  CALayer *holder = label.superlayer;
  if (!holder || holder.superlayer != container) {
    return;
  }
  CGFloat maxWidth = container.bounds.size.width - 2 * kSpacesBarLabelMargin;
  CGFloat width = MIN(ceil([label preferredFrameSize].width), maxWidth);
  if (width <= 0 || fabs(width - label.bounds.size.width) < 0.5) {
    return;
  }
  CGRect holderFrame = holder.frame;
  holderFrame.origin.x = floor((container.bounds.size.width - width) / 2);
  holderFrame.size.width = width;
  holder.frame = holderFrame;
  CGRect labelFrame = label.frame;
  labelFrame.origin.x = 0;
  labelFrame.size.width = width;
  label.frame = labelFrame;
  for (CALayer *sibling in holder.sublayers) {
    if ([sibling.name isEqualToString:kSpacesBarLabelSelectionLayerName]) {
      CGRect pill = sibling.frame;
      pill.origin.x = -kSpacesBarLabelPillPadding;
      pill.size.width = width + 2 * kSpacesBarLabelPillPadding;
      sibling.frame = pill;
    }
  }
}

static CATextLayer *findLabelLayer(CALayer *layer) {
  if ([layer.name isEqualToString:kSpacesBarLabelLayerName] && [layer isKindOfClass:[CATextLayer class]]) {
    return (CATextLayer *)layer;
  }
  for (CALayer *sublayer in layer.sublayers) {
    CATextLayer *found = findLabelLayer(sublayer);
    if (found) {
      return found;
    }
  }
  return nil;
}

// The localized word WindowManager uses for a desktop ("Desktop", "Schreibtisch", ...), learned
// from the first numbered title seen so the unnumbered single-desktop title can be told apart
// from a full-screen app's name. English until something is learned.
static NSString *desktopWord = @"Desktop";

static void learnDesktopWord(NSString *title) {
  NSUInteger end = title.length;
  while (end > 0 && isdigit([title characterAtIndex:end - 1])) {
    end--;
  }
  if (end == title.length || end == 0) {
    return;
  }
  NSString *word = [[title substringToIndex:end] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (word.length && ![word isEqualToString:desktopWord]) {
    [desktopWord release];
    desktopWord = [word copy];
  }
}

// The desktop number WindowManager put in a label ("Desktop 3" -> 3). A display with a single
// desktop is labelled with the bare word (-> 1). Full-screen app spaces carry the app name and
// have no number; they are left alone (0).
static NSInteger desktopNumberFromTitle(NSString *title) {
  if (title.length == 0) {
    return 0;
  }
  NSUInteger end = title.length, start = end;
  while (start > 0 && isdigit([title characterAtIndex:start - 1])) {
    start--;
  }
  if (start < end) {
    return [[title substringFromIndex:start] integerValue];
  }
  return [title isEqualToString:desktopWord] ? 1 : 0;
}

// The space a desktop number refers to: the Nth desktop-type space (type 0) of the display,
// or, if the display does not have that many, the Nth desktop across all displays in order
// (macOS numbers desktops per display when each display has its own Spaces, globally otherwise).
static NSDictionary *spaceForDesktopNumber(NSArray<Monitor *> *names, Monitor *monitor, NSInteger number) {
  if (number <= 0) {
    return nil;
  }
  NSInteger remaining = number;
  for (NSDictionary *space in monitor.spaces) {
    if ([space[@"type"] integerValue] == 0 && --remaining == 0) {
      return space;
    }
  }
  remaining = number;
  for (Monitor *candidate in names) {
    for (NSDictionary *space in candidate.spaces) {
      if ([space[@"type"] integerValue] == 0 && --remaining == 0) {
        return space;
      }
    }
  }
  return nil;
}

// Applies the custom name to one "PreviewLabel". The label sits in a per-space container,
// which is either a child of the collapsed bar (pointer away from the top edge) or the root of
// its own window when Mission Control opens with the bar expanded (pointer at the top edge);
// the display comes from the container's root context either way.
// Returns whether it reached a definitive decision. NO means the label's container or its
// display context is not attached yet, so the caller should try again on a later turn rather
// than leave WindowManager's "Desktop N" showing.
static BOOL applySpacesBarLabel(CATextLayer *label) {
  CALayer *container = label.superlayer.superlayer;
  if (![container.name isEqualToString:kSpacesBarContainerLayerName]) {
    return NO;  // label not yet attached to its per-space container
  }
  NSString *original = objc_getAssociatedObject(label, &ORIGINAL_STRING);
  NSInteger number = desktopNumberFromTitle(original);
  if (number == 0) {
    return YES;  // full-screen app label (no desktop number): nothing to rename
  }
  NSArray<Monitor *> *names = getNamesFromPlist(NULL);
  if (names.count == 0) {
    return YES;  // no custom names published: leave WindowManager's own title
  }
  NSString *displayUUID = displayUUIDForLayer(container);
  Monitor *monitor = monitorForDisplayUUID(names, displayUUID) ?: (names.count == 1 ? names[0] : nil);
  if (!monitor) {
    SRLog("label %{public}@ on unknown display %{public}@", original, displayUUID);
    return NO;  // root CAContext (and thus the display) not attached yet
  }

  static BOOL hookReported = NO;
  if (!hookReported) {
    hookReported = YES;
    writePluginStatus(YES);
  }

  NSString *name = spaceForDesktopNumber(names, monitor, number)[@"name"];
  if (name.length == 0) {
    // Names are read fresh on every pass, so a cleared name must also clear the override;
    // WindowManager keeps re-applying its own title on its own.
    assign(label, &OVERRIDDEN_STRING, nil);
    return YES;
  }
  assign(label, &OVERRIDDEN_STRING, name);
  if (![label.string isEqual:name]) {
    label.string = name;
  }
  fitSpacesBarLabel(label, container);
  SRLog("display %{public}@ %{public}@ -> %{public}@ (label %{public}@)", monitor.displayUUID, original, label.string, NSStringFromRect(label.frame));
  return YES;
}

// Applies the names to every container currently attached to the collapsed bar.
static void applySpacesBarNames(CALayer *bar) {
  for (CALayer *sublayer in bar.sublayers) {
    if ([sublayer.name isEqualToString:kSpacesBarContainerLayerName]) {
      CATextLayer *label = findLabelLayer(sublayer);
      if (label) {
        applySpacesBarLabel(label);
      }
    }
  }
}

// Re-attempts applySpacesBarLabel over the next frames until it resolves, so the custom name
// appears on the first painted frame it can. WindowManager sets the title before the label's
// container and display context are attached; a single deferred pass often runs too early and
// then nothing retries until WindowManager repaints ~1s later, which is the visible flash of
// "Desktop N". Retries are spaced in real time (not back-to-back main-queue hops, which would
// all fire before the tree is ready) and bounded so a genuinely unnamed label stops quickly.
static const int kApplyRetryAttempts = 60;      // ~1s at kApplyRetryInterval
static const double kApplyRetryInterval = 1.0 / 60.0;

static void scheduleApplyRetry(CATextLayer *label, int remaining) {
  if (remaining <= 0) {
    return;
  }
  if (objc_getAssociatedObject(label, &PENDING_APPLY)) {
    return;  // a retry chain is already in flight for this label
  }
  assign(label, &PENDING_APPLY, @YES);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApplyRetryInterval * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    assign(label, &PENDING_APPLY, nil);
    if (!applySpacesBarLabel(label)) {
      scheduleApplyRetry(label, remaining - 1);
    }
  });
}

@interface CALayer (SpacesRenamerMissionControl)
- (void)sre_applySpaceNamesForFrame:(CGRect)frame;
- (BOOL)sre_isDesktopSwitcherFrame:(CGRect)frame;
- (NSString *)sre_displayUUIDForFrame:(CGRect)frame;
@end

ZKSwizzleInterface(_SRCALayer, CALayer, CALayer);
@implementation _SRCALayer
- (void)setFrame:(CGRect)arg1 {
  // Use a stable geometry/parent prefilter because Mission Control layers vary by macOS release.
  if (arg1.origin.x == 0 && self.superlayer.class == [CALayer class]) {
    [self sre_applySpaceNamesForFrame:arg1];
  }

  CGRect orig = arg1;
  id possibleWidth = objc_getAssociatedObject(self, &OVERRIDDEN_WIDTH);
  if (possibleWidth && [possibleWidth isKindOfClass:[NSNumber class]] && self.class == [CALayer class]) {
    arg1.size.width = [possibleWidth doubleValue] + 20;
  }

  int textIndex = self.sublayers.lastObject.class == textLayerClass()
  ? (int)self.sublayers.count - 1
  : -1;

  if (textIndex != -1) {
    id possibleWidth = objc_getAssociatedObject(self.sublayers[textIndex], &OVERRIDDEN_WIDTH);
    if (possibleWidth && [possibleWidth isKindOfClass:[NSNumber class]]) {
      arg1.size.width = [possibleWidth doubleValue];
    }

    id possibleType = objc_getAssociatedObject(self, &TYPE);
    if (possibleType && [possibleType isEqualToString:@"expanded"]) {
      arg1.origin.x = self.superlayer.frame.size.width / 2 - arg1.size.width / 2;
    } else {
      id possibleOffset = objc_getAssociatedObject(self.sublayers[textIndex], &OFFSET);
      id newX = objc_getAssociatedObject(self, &NEW_X);
      if (possibleOffset && [possibleOffset isKindOfClass:[NSNumber class]] && (newX == nil || [newX doubleValue] != arg1.origin.x)) {
        arg1.origin.x += [possibleOffset doubleValue];

        assign(self, &NEW_X, @(arg1.origin.x));
      }
    }
  }
  if (arg1.size.width == 0.0 && orig.size.width != 0.0) {
    return ZKOrig(void, orig);
  }

  return ZKOrig(void, arg1);
}

// WindowManager (macOS 27+) lays the Spaces bar out through bounds, never frame.
- (void)setBounds:(CGRect)bounds {
  ZKOrig(void, bounds);
  if ([self.name isEqualToString:kSpacesBarLayerName]) {
    applySpacesBarNames(self);
  }
}

- (void)layoutSublayers {
  ZKOrig(void);
  if ([self.name isEqualToString:kSpacesBarLayerName]) {
    applySpacesBarNames(self);
  }
}

@end

// WindowManager's per-space labels: remember the title WindowManager wants ("Desktop N", which
// identifies the space), apply the custom name once the label is in its container, and keep
// the custom name when WindowManager re-applies its own title on later passes. Only acts on
// layers named "PreviewLabel", so it never touches Dock's ECTextLayer labels.
ZKSwizzleInterface(_SRCATextLayer, CATextLayer, CATextLayer);
@implementation _SRCATextLayer
- (void)setString:(id)string {
  if ([self.name isEqualToString:kSpacesBarLabelLayerName]) {
    id overridden = objc_getAssociatedObject(self, &OVERRIDDEN_STRING);
    if ([string isKindOfClass:[NSString class]] && ![string isEqual:overridden]) {
      assign(self, &ORIGINAL_STRING, string);
      learnDesktopWord(string);
      // Apply immediately so the first painted frame already carries the custom name. If the
      // container/display is not attached yet, retry over the next frames instead of showing
      // WindowManager's "Desktop N" until its next repaint.
      if (!applySpacesBarLabel(self)) {
        scheduleApplyRetry(self, kApplyRetryAttempts);
      }
      overridden = objc_getAssociatedObject(self, &OVERRIDDEN_STRING);
    }
    if ([overridden isKindOfClass:[NSString class]]) {
      string = overridden;
    }
  }
  ZKOrig(void, string);
}
@end

ZKSwizzleInterface(_SRECTextLayer, ECTextLayer, CATextLayer);
@implementation _SRECTextLayer
- (void)setFrame:(CGRect)arg1 {
  if (![objc_getAssociatedObject(self, &OBSERVING_PROPERTIES_CHANGED) boolValue]) {
    @try {
      [self addObserver:self
             forKeyPath:@"propertiesChanged"
                options:NSKeyValueObservingOptionNew
                context:&OBSERVING_PROPERTIES_CHANGED];
      assign(self, &OBSERVING_PROPERTIES_CHANGED, @YES);
    } @catch(id anException) {}
  }

  id possibleWidth = objc_getAssociatedObject(self, &OVERRIDDEN_WIDTH);
  if (possibleWidth && [possibleWidth isKindOfClass:[NSNumber class]]) {
    arg1.size.width = [possibleWidth doubleValue];
  }

  ZKOrig(void, arg1);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-missing-super-calls"
-(void)dealloc {
  if ([objc_getAssociatedObject(self, &OBSERVING_PROPERTIES_CHANGED) boolValue]) {
    @try {
      [self removeObserver:self
                forKeyPath:@"propertiesChanged"
                   context:&OBSERVING_PROPERTIES_CHANGED];
    } @catch(id anException) {}
  }
  ZKOrig(void);
}
#pragma clang diagnostic pop

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
  if (context != &OBSERVING_PROPERTIES_CHANGED) {
    ZKOrig(void, keyPath, object, change, context);
    return;
  }
  enforceTextLayerOverride(self);
}

- (id)propertiesChanged {
  return nil;
}

+(NSSet *)keyPathsForValuesAffectingPropertiesChanged {
  return [NSSet setWithObjects:@"string", nil];
}

@end

@implementation CALayer (SpacesRenamerMissionControl)
- (void)sre_applySpaceNamesForFrame:(CGRect)arg1 {
  if ([self sre_isDesktopSwitcherFrame:arg1]) {
    NSOperatingSystemVersion macOS = NSProcessInfo.processInfo.operatingSystemVersion;
    bool bigSurOrNewer = (macOS.majorVersion >= 11 || macOS.minorVersion >= 16);

    CALayer *rootLayer;
    if (bigSurOrNewer) {
      rootLayer = self.superlayer;
    } else {
      rootLayer = self;
    }
    CALayer *switcherContainer = rootLayer.sublayers.lastObject;
    if (switcherContainer.sublayers.count < 2) {
      return;
    }
    NSArray<CALayer *> *unexpandedViews = switcherContainer.sublayers[0].sublayers;
    NSArray<CALayer *> *expandedViews = switcherContainer.sublayers[1].sublayers;

    int numMonitors = MAX((int)unexpandedViews.count, (int)expandedViews.count);

    int selected = getSelected((!unexpandedViews || !unexpandedViews.count) ? expandedViews : unexpandedViews);

    os_log_t log = performanceLog();
    os_signpost_id_t signpostID = os_signpost_id_generate(log);
    os_signpost_interval_begin(log, signpostID, "ApplyNames");

    BOOL cacheHit = NO;
    NSArray<Monitor *> *names = getNamesFromPlist(&cacheHit);
    if (names.count == 0) {
      BOOL layoutChanged = NO;
      NSMutableArray<CALayer *> *viewsNeedingRefresh = [NSMutableArray array];
      for (CALayer *view in expandedViews) {
        if (clearTextLayerOverride(view)) {
          layoutChanged = YES;
          [viewsNeedingRefresh addObject:view];
        }
      }
      for (CALayer *view in unexpandedViews) {
        BOOL viewChanged = clearTextLayerOverride(view);
        viewChanged |= clearOffset(view);
        if (viewChanged) {
          layoutChanged = YES;
          [viewsNeedingRefresh addObject:view];
        }
      }
      if (layoutChanged) {
        refreshChangedViews(viewsNeedingRefresh);
      }
      os_signpost_interval_end(
        log,
        signpostID,
        "ApplyNames",
        "cache_hit=%d changed=%d spaces=0 refreshed_views=%lu",
        cacheHit,
        layoutChanged,
        (unsigned long)viewsNeedingRefresh.count
      );
      return;
    }

    int matchingMonitor = -1;
    int matchingMonitorCount = 0;
    for (int i = 0; i < names.count; i++) {
      if (
          names[i].spaces.count == numMonitors &&
          selected >= 0 &&
          selected < names[i].spaces.count &&
          [names[i].spaces[selected][@"selected"] boolValue]
          ) {
        matchingMonitor = i;
        matchingMonitorCount += 1;
      }
    }
    if (matchingMonitorCount == 1) {
      monitorIndex = matchingMonitor;
    } else {
      NSString *displayUUID = [self sre_displayUUIDForFrame:arg1];
      if (displayUUID != nil) {
        for (int i = 0; i < names.count; i++) {
          if ([names[i].displayUUID isEqualToString:displayUUID]) {
            monitorIndex = i;
          }
        }
      }
    }
    monitorIndex = monitorIndex % names.count;
    NSUInteger processedSpaceCount = names[monitorIndex].spaces.count;

    BOOL layoutChanged = NO;
    NSMutableArray<CALayer *> *viewsNeedingRefresh = [NSMutableArray array];
    double unexpandedOffset = 0;
    for (int i = 0; i < names[monitorIndex].spaces.count; i++) {
      NSString *name = names[monitorIndex].spaces[i][@"name"];
      if (name != nil && ![name isEqualToString:@""]) {
        if (i < expandedViews.count) {
          double textSize = getTextSize(expandedViews[i], name);
          if (overrideTextLayer(
            expandedViews[i],
            name,
            MIN(textSize, expandedViews[i].frame.size.width),
            @"expanded"
          )) {
            layoutChanged = YES;
            [viewsNeedingRefresh addObject:expandedViews[i]];
          }
        }
        if (i < unexpandedViews.count) {
          double textSize = getTextSize(unexpandedViews[i], name);
          BOOL viewChanged = overrideTextLayer(
            unexpandedViews[i],
            name,
            textSize,
            @"unexpanded"
          );
          viewChanged |= setOffset(unexpandedViews[i], unexpandedOffset, false);
          if (viewChanged) {
            layoutChanged = YES;
            [viewsNeedingRefresh addObject:unexpandedViews[i]];
          }
          unexpandedOffset += (textSize - getTextLayer(unexpandedViews[i]).bounds.size.width);
        }
      } else {
        if (i < expandedViews.count) {
          if (clearTextLayerOverride(expandedViews[i])) {
            layoutChanged = YES;
            [viewsNeedingRefresh addObject:expandedViews[i]];
          }
        }
        if (i < unexpandedViews.count) {
          BOOL viewChanged = clearTextLayerOverride(unexpandedViews[i]);
          viewChanged |= setOffset(unexpandedViews[i], unexpandedOffset, false);
          if (viewChanged) {
            layoutChanged = YES;
            [viewsNeedingRefresh addObject:unexpandedViews[i]];
          }
        }
      }
    }

    for (int i = 0; i < names[monitorIndex].spaces.count; i++) {
      if (i < unexpandedViews.count) {
        if (setOffset(unexpandedViews[i], -unexpandedOffset/2, true)) {
          layoutChanged = YES;
          if (![viewsNeedingRefresh containsObject:unexpandedViews[i]]) {
            [viewsNeedingRefresh addObject:unexpandedViews[i]];
          }
        }
      }
    }

    monitorIndex += 1;

    if (layoutChanged) {
      refreshChangedViews(viewsNeedingRefresh);
    }
    static BOOL dockHookReported = NO;
    if (!dockHookReported) {
      dockHookReported = YES;
      writePluginStatus(YES);
    }
    os_signpost_interval_end(
      log,
      signpostID,
      "ApplyNames",
      "cache_hit=%d changed=%d spaces=%lu refreshed_views=%lu",
      cacheHit,
      layoutChanged,
      (unsigned long)processedSpaceCount,
      (unsigned long)viewsNeedingRefresh.count
    );
  }
}

- (BOOL)sre_isDesktopSwitcherFrame:(CGRect)rect {
  if (rect.origin.x != 0) {
    return false;
  }
  if (self.superlayer.class != [CALayer class]) {
    return false;
  }

  CGDirectDisplayID displayArray[kMaxDisplays];
  uint32_t displayCount;
  CGGetActiveDisplayList(kMaxDisplays, displayArray, &displayCount);

  for (int i = 0; i < displayCount; i++) {
    if (CGDisplayPixelsWide(displayArray[i]) == rect.size.width) {
      return true;
    }
  }

  return false;
}

- (NSString *)sre_displayUUIDForFrame:(CGRect)rect {
  CGDirectDisplayID displayArray[kMaxDisplays];
  uint32_t displayCount;
  CGGetActiveDisplayList(kMaxDisplays, displayArray, &displayCount);

  CGDirectDisplayID matchingScreen = 0;
  for (int i = 0; i < displayCount; i++) {
    if (CGDisplayPixelsWide(displayArray[i]) == rect.size.width) {
      if (matchingScreen != 0) {
        return nil;
      } else {
        matchingScreen = displayArray[i];
      }
    }
  }
  if (matchingScreen == 0) {
    return nil;
  }
  CFUUIDRef screenUuid = CGDisplayCreateUUIDFromDisplayID(matchingScreen);
  if (screenUuid == nil) {
    return nil;
  }
  CFStringRef uuid = CFUUIDCreateString(nil, screenUuid);
  CFRelease(screenUuid);
  return [(__bridge NSString *)uuid autorelease];
}

@end