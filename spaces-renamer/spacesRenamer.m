//
//  spaces-renamer.m
//  spaces-renamer
//
//  Created by Alex Beals
//  Copyright 2017 Alex Beals.
//

@import Foundation;
@import CoreText;
#import "ZKSwizzle.h"
#import <QuartzCore/QuartzCore.h>
#import <Cocoa/Cocoa.h>
#import <os/signpost.h>
#import <unistd.h>

static NSString *const SpacesRenamerPayloadVersion = @"1";
static NSString *const SpacesRenamerInjectedNotification =
    @"com.wiggly-sheets.SpacesRenamer.Injected";

__attribute__((constructor))
static void reportSpacesRenamerInjection(void) {
  @autoreleasepool {
    NSDictionary *status = @{
      @"protocolVersion": @"1",
      @"payloadVersion": SpacesRenamerPayloadVersion,
      @"dockPID": @([[NSProcessInfo processInfo] processIdentifier]),
      @"loadedAt": @([[NSDate date] timeIntervalSince1970])
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:status options:0 error:nil];
    NSString *path = [NSString stringWithFormat:
        @"/tmp/spaces-renamer-injection-%u.json", getuid()];
    [data writeToFile:path options:NSDataWritingAtomic error:nil];
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:SpacesRenamerInjectedNotification
                      object:nil
                    userInfo:status
          deliverImmediately:YES];
  }
}

static char OVERRIDDEN_STRING;
static char OVERRIDDEN_WIDTH;
static char OFFSET;
static char NEW_X;
static char TYPE;
static char CACHED_TEXT_LAYER;
static char OBSERVING_PROPERTIES_CHANGED;

#define customNamesPlist [@"~/Library/Containers/com.alexbeals.spacesrenamer/com.alexbeals.spacesrenamer.plist" stringByExpandingTildeInPath]
#define listOfSpacesPlist [@"~/Library/Containers/com.alexbeals.spacesrenamer/com.alexbeals.spacesrenamer.currentspaces.plist" stringByExpandingTildeInPath]

@class Monitor;
static NSArray<Monitor *> *cachedMonitors;
static NSDate *cachedNamesModificationDate;
static NSDate *cachedSpacesModificationDate;
static BOOL plistCacheInitialized = NO;

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

// Maximum online or active displays.
//
// SpacesRenamer uses the core graphics API to get online/active
// displays by calling CGGetActiveDisplayList() and CGGetOnlineDisplayList(),
// this definition is the count that will be used when calling those functions.
//
// If you have more than 12 monitors, this tweak can't help you with organization, good luck.
#define kMaxDisplays 12

int monitorIndex = 0;

@interface ECMaterialLayer : CALayer
@end

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

// Refresh only the Space-label subtree whose associated layout values changed.
// The old implementation walked almost the entire Mission Control layer tree.
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

// Helper method
static void assign(id a, void *key, id assigned) {
  objc_setAssociatedObject(a, key, assigned, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL assignIfChanged(id object, void *key, id value) {
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

// Gets the ECTextLayer child from a starting view
// Good for when you don't care whether it's selected or not
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

// Given a view, sets the OFFSET variable for the text layer's parent, and siblings
// if 'modify' is TRUE, it will add the OFFSET variables, otherwise it will overwrite it
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

// Finds the text layer, and sets the overridden string and width properties
// to the text layer, its parent, and its siblings.
// Additionally sets the type for determining centering behavior
static BOOL overrideTextLayer(CALayer *view, NSString *newString, double width, NSString *type) {
  CATextLayer *textLayer = getTextLayer(view);
  BOOL changed = NO;

  if (textLayer != nil) {
    if (![textLayer.string isEqual:newString]) {
      textLayer.string = newString;
      changed = YES;
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
  }
  return changed;
}

// Gets the text area, and renders how large it would be with the new dimensions
// Uses this for calculating how far they should be offset by
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

    // Works around bug where CTFramesetterSuggestFrameSizeWithConstraints returns 0 for
    // strings entirely composed of whitespace
    double width = getTextSizeHelper(textLayer, [string stringByAppendingString:@".."])
      - getTextSizeHelper(textLayer, @".");
    [widthCache setObject:@(width) forKey:cacheKey];
    return width;
  }
  return -1;
}

// The highlighted space has 2 sublayers, while as a normal space only has 1
static int getSelected(NSArray<CALayer *> *views) {
  for (NSUInteger index = 0; index < views.count; index++) {
    if (views[index].sublayers.count > 1) {
      return (int)index;
    }
  }
  return -1;
}

/*
 1. Load the customNamesPlist for named spaces
 2. Load the listOfSpacesPlist to get the current list of spaces
 3. Crosslist and return the custom names for each plist, and whether it's selected
 */
static NSDate *modificationDate(NSString *path) {
  NSDictionary *attributes = [[NSFileManager defaultManager]
    attributesOfItemAtPath:path
    error:nil
  ];
  return attributes[NSFileModificationDate];
}

static BOOL nullableObjectsEqual(id left, id right) {
  return left == right || (left != nil && [left isEqual:right]);
}

static NSArray<Monitor *> *getNamesFromPlist(BOOL *cacheHit) {
  NSDate *namesModificationDate = modificationDate(customNamesPlist);
  NSDate *spacesModificationDate = modificationDate(listOfSpacesPlist);
  if (
    plistCacheInitialized
    && nullableObjectsEqual(namesModificationDate, cachedNamesModificationDate)
    && nullableObjectsEqual(spacesModificationDate, cachedSpacesModificationDate)
  ) {
    if (cacheHit != NULL) {
      *cacheHit = YES;
    }
    return cachedMonitors ?: @[];
  }

  if (cacheHit != NULL) {
    *cacheHit = NO;
  }
  os_signpost_event_emit(
    performanceLog(),
    OS_SIGNPOST_ID_EXCLUSIVE,
    "ReloadPlists"
  );

  NSDictionary *dictOfNames = [NSDictionary dictionaryWithContentsOfFile:customNamesPlist];
  NSDictionary *spacesCustom = [NSDictionary dictionaryWithContentsOfFile:listOfSpacesPlist];
  NSDictionary *dict = [dictOfNames valueForKey:@"spaces_renaming"];
  NSArray *listOfMonitors = [spacesCustom valueForKeyPath:@"Monitors"];

  NSMutableArray<Monitor *> *newNames = [NSMutableArray
    arrayWithCapacity:listOfMonitors.count
  ];

  for (int i = 0; i < listOfMonitors.count; i++) {
    NSArray *listOfSpaces = [listOfMonitors[i] valueForKeyPath:@"Spaces"];
    NSString *selected = [listOfMonitors[i] valueForKeyPath:@"Current Space.uuid"];
    Monitor *monitor = [[[Monitor alloc] init] autorelease];
    monitor.displayUUID = [listOfMonitors[i] valueForKeyPath:@"Display Identifier"];

    NSMutableArray *spaceNames = [NSMutableArray arrayWithCapacity:listOfSpaces.count];
    for (int j = 0; j < listOfSpaces.count; j++) {
      NSString *uuid = listOfSpaces[j][@"uuid"];
      id name = [dict objectForKey:uuid];
      NSMutableDictionary *screenDict = [NSMutableDictionary dictionary];
      screenDict[@"selected"] = @([uuid isEqualToString:selected]);
      if (name != nil) {
        screenDict[@"name"] = name;
      } else {
        screenDict[@"name"] = @"";
      }
      [spaceNames addObject:screenDict];
    }
    monitor.spaces = spaceNames;
    [newNames addObject:monitor];
  }

  [cachedMonitors release];
  cachedMonitors = [newNames copy];
  [cachedNamesModificationDate release];
  cachedNamesModificationDate = [namesModificationDate copy];
  [cachedSpacesModificationDate release];
  cachedSpacesModificationDate = [spacesModificationDate copy];
  plistCacheInitialized = YES;
  return cachedMonitors;
}

ZKSwizzleInterface(_SRCALayer, CALayer, CALayer);
@implementation _SRCALayer
- (void)setFrame:(CGRect)arg1 {
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
      // Always just center in the parent view
      arg1.origin.x = self.superlayer.frame.size.width / 2 - arg1.size.width / 2;
    } else {
      id possibleOffset = objc_getAssociatedObject(self.sublayers[textIndex], &OFFSET);
      id newX = objc_getAssociatedObject(self, &NEW_X);
      // Only change the offsets once
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
    return;
  }
  id overridden = objc_getAssociatedObject(self, &OVERRIDDEN_STRING);
  if ([overridden isKindOfClass:[NSString class]] && ![self.string isEqualToString:overridden]) {
    self.string = overridden;
  }
}

- (id)propertiesChanged {
  return nil;
}

+(NSSet *)keyPathsForValuesAffectingPropertiesChanged {
  return [NSSet setWithObjects:@"string", nil];
}

@end

ZKSwizzleInterface(_SRECMaterialLayer, ECMaterialLayer, CALayer);
@implementation _SRECMaterialLayer
- (void)setFrame:(CGRect)arg1 {
  // Almost surely the desktop switcher
  if ([self probablyDesktopSwitcher:arg1]) {
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
      ZKOrig(void, arg1);
      return;
    }
    NSArray<CALayer *> *unexpandedViews = switcherContainer.sublayers[0].sublayers;
    NSArray<CALayer *> *expandedViews = switcherContainer.sublayers[1].sublayers;

    int numMonitors = MAX((int)unexpandedViews.count, (int)expandedViews.count);

    // Get which of the spaces in the current dock is selected
    int selected = getSelected((!unexpandedViews || !unexpandedViews.count) ? expandedViews : unexpandedViews);

    os_log_t log = performanceLog();
    os_signpost_id_t signpostID = os_signpost_id_generate(log);
    os_signpost_interval_begin(log, signpostID, "ApplyNames");

    // Get all of the names
    BOOL cacheHit = NO;
    NSArray<Monitor *> *names = getNamesFromPlist(&cacheHit);
    if (names.count == 0) {
      os_signpost_interval_end(
        log,
        signpostID,
        "ApplyNames",
        "cache_hit=%d changed=0 spaces=0",
        cacheHit
      );
      ZKOrig(void, arg1);
      return;
    }

    // Take a best guess at which monitor it is
    int matchingMonitor = -1;
    int matchingMonitorCount = 0;
    for (int i = 0; i < names.count; i++) {
      if (
          names[i].spaces.count == numMonitors && // Same number of monitors
          selected >= 0 &&
          selected < names[i].spaces.count &&
          [names[i].spaces[selected][@"selected"] boolValue] // Same index is selected
          ) {
        matchingMonitor = i;
        matchingMonitorCount += 1;
      }
    }
    // If only one monitor, good to go
    // If more than one monitor, but the sizes are different we can usually identify it
    // Otherwise just go with the same cycling as it appears to have been last time it was good to go
    if (matchingMonitorCount == 1) {
      monitorIndex = matchingMonitor;
    } else {
      // If the size of the bar only matches one of the monitors, then use that one
      NSString *displayUUID = [self getDisplayUUID:arg1];
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
      // It's overridden
      if (name != nil && ![name isEqualToString:@""]) {
        // Expanded
        if (i < expandedViews.count) {
          double textSize = getTextSize(expandedViews[i], name);
          // Don't have the expanded view string overlap other ones
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
        // Unexpanded
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
        if (i < unexpandedViews.count) {
          if (setOffset(unexpandedViews[i], unexpandedOffset, false)) {
            layoutChanged = YES;
            [viewsNeedingRefresh addObject:unexpandedViews[i]];
          }
        }
      }
    }

    // Make sure that it's centered in the bar when unexpanded
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

    // Apply frame overrides only to label subtrees whose associated values changed.
    if (layoutChanged) {
      refreshChangedViews(viewsNeedingRefresh);
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
  ZKOrig(void, arg1);
}

// (40 height unexpanded, 146 expanded), if it's relevant later
- (BOOL)probablyDesktopSwitcher:(CGRect)rect {
  // Must start at origin
  if (rect.origin.x != 0) {
    return false;
  }
  // Is a child of CALayer
  if (self.superlayer.class != [CALayer class]) {
    return false;
  }

  // Get all of the monitors
  CGDirectDisplayID displayArray[kMaxDisplays];
  uint32_t displayCount;
  CGGetActiveDisplayList(kMaxDisplays, displayArray, &displayCount);

  // Is the width of the full screen (one of them)
  for (int i = 0; i < displayCount; i++) {
    if (CGDisplayPixelsWide(displayArray[i]) == rect.size.width) {
      return true;
    }
  }

  // Default to false
  return false;
}

// This checks the same monitors we already fetched in
// probablyDesktopSwitcher, but this is only fallback code if both
// screens have the same number of spaces and the same ones selected
// which is unlikely. Therefore it's better to eat that rare double
// cost than fetch the UUID when it's not needed.
- (NSString *)getDisplayUUID:(CGRect)rect {
  // Get all of the monitors
  CGDirectDisplayID displayArray[kMaxDisplays];
  uint32_t displayCount;
  CGGetActiveDisplayList(kMaxDisplays, displayArray, &displayCount);

  // This is only evaluated after probablyDesktopSwitcher is truthy
  // so one of them is guaranteed to match. We only want ONE to match
  // to feel confident using this signal though. So if we've already
  // matched we just return nil
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
  // Go from the CGDirectDisplayID to the Display Identifier using private APIs
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

// ===============
// DEBUG FUNCTIONS
// ===============
//- (void)printLayer:(CALayer *)layer {
//  [self recursivePrint:layer withPrefix:@""];
//}
//
//- (void)recursivePrint:(CALayer *)layer withPrefix:(NSString *)prefix {
//  NSLog(@"spaces-renamer: %@%@", prefix, layer);
//  for (int i = 0; i < layer.sublayers.count; i++) {
//    [self recursivePrint:layer.sublayers[i] withPrefix:[NSString stringWithFormat:@"  %@", prefix]];
//  }
//}

@end
