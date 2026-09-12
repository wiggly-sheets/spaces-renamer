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

static NSString *const SpacesRenamerPayloadVersion = @SPACES_RENAMER_VERSION;
static NSString *const SpacesRenamerInjectedNotification =
    @"com.wiggly-sheets.SpacesRenamer.Injected";

static void publishSpacesRenamerInjectionStatus(NSString *phase) {
  @autoreleasepool {
    NSDictionary *status = @{
      @"protocolVersion": @"1",
      @"payloadVersion": SpacesRenamerPayloadVersion,
      @"dockPID": @([[NSProcessInfo processInfo] processIdentifier]),
      @"loadedAt": @([[NSDate date] timeIntervalSince1970]),
      @"phase": phase
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

#ifndef SPACES_RENAMER_TESTING
__attribute__((constructor))
#endif
static void reportSpacesRenamerInjection(void) {
  publishSpacesRenamerInjectionStatus(@"loaded");
}

static char OVERRIDDEN_STRING;
static char ORIGINAL_STRING;
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

static NSArray<Monitor *> *monitorNamesFromPropertyLists(
  id namesPropertyList,
  id spacesPropertyList
) {
  if (
    ![namesPropertyList isKindOfClass:[NSDictionary class]]
    || ![spacesPropertyList isKindOfClass:[NSDictionary class]]
  ) {
    return @[];
  }

  id names = [namesPropertyList objectForKey:@"spaces_renaming"];
  id monitors = [spacesPropertyList objectForKey:@"Monitors"];
  if (
    ![names isKindOfClass:[NSDictionary class]]
    || ![monitors isKindOfClass:[NSArray class]]
  ) {
    return @[];
  }

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
      NSMutableDictionary *parsedSpace = [@{
        @"selected": @([uuid isEqualToString:selected]),
        @"name": name ?: @""
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

  id dictOfNames = [NSDictionary dictionaryWithContentsOfFile:customNamesPlist];
  id spacesCustom = [NSDictionary dictionaryWithContentsOfFile:listOfSpacesPlist];
  NSArray<Monitor *> *newNames = monitorNamesFromPropertyLists(
    dictOfNames,
    spacesCustom
  );

  [cachedMonitors release];
  cachedMonitors = [newNames copy];
  [cachedNamesModificationDate release];
  cachedNamesModificationDate = [namesModificationDate copy];
  [cachedSpacesModificationDate release];
  cachedSpacesModificationDate = [spacesModificationDate copy];
  plistCacheInitialized = YES;
  return cachedMonitors;
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
    static dispatch_once_t hookVerifiedOnce;
    dispatch_once(&hookVerifiedOnce, ^{
      publishSpacesRenamerInjectionStatus(@"active");
    });
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
