#define SPACES_RENAMER_TESTING 1
#define ZKSWIZZLE_DEFS 1

static unsigned long originalImplementationCallCount;
static void recordOriginalImplementationCall(void);

#define ZKSwizzleInterface(CLASS_NAME, TARGET_CLASS, SUPERCLASS) \
  @interface CLASS_NAME : SUPERCLASS \
  @end
#define ZKOrig(TYPE, ...) recordOriginalImplementationCall()

@import QuartzCore;

@interface ECTextLayer : CATextLayer
@end

@implementation ECTextLayer
@end

#import "../spacesRenamer.m"

static void recordOriginalImplementationCall(void) {
  originalImplementationCallCount += 1;
}

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static CALayer *makeSpaceLabelView(ECTextLayer **textLayerResult) {
  CALayer *view = [CALayer layer];
  CALayer *textContainer = [CALayer layer];
  ECTextLayer *textLayer = [ECTextLayer layer];
  textLayer.string = @"Desktop 1";
  [textContainer addSublayer:textLayer];
  [view addSublayer:textContainer];
  *textLayerResult = textLayer;
  return view;
}

static void testRemovingNameRestoresDefaultLabel(void) {
  ECTextLayer *textLayer = nil;
  CALayer *view = makeSpaceLabelView(&textLayer);

  require(overrideTextLayer(view, @"Code", 92, @"expanded"),
          @"applying a Space name should change the label");
  require([textLayer.string isEqual:@"Code"],
          @"the custom Space name should be visible");

  textLayer.string = @"Desktop 2";
  enforceTextLayerOverride(textLayer);
  require([textLayer.string isEqual:@"Code"],
          @"Dock refreshes should not displace an active custom name");

  require(clearTextLayerOverride(view),
          @"removing a Space name should clear its override");
  require([textLayer.string isEqual:@"Desktop 2"],
          @"the latest normal macOS label should be restored");
  require(objc_getAssociatedObject(textLayer, &OVERRIDDEN_STRING) == nil,
          @"KVO must not retain the stale custom string");
  require(objc_getAssociatedObject(textLayer, &OVERRIDDEN_WIDTH) == nil,
          @"the custom width should be cleared");
  require(objc_getAssociatedObject(textLayer.superlayer, &TYPE) == nil,
          @"the custom layout type should be cleared");
}

static void testKVOTracksDockLabelAndForwardsUnknownContexts(void) {
  _SRECTextLayer *textLayer = [_SRECTextLayer layer];
  textLayer.string = @"Desktop 1";
  assign(textLayer, &OVERRIDDEN_STRING, @"Code");

  textLayer.string = @"Desktop 2";
  [textLayer observeValueForKeyPath:@"propertiesChanged"
                           ofObject:textLayer
                             change:@{}
                            context:&OBSERVING_PROPERTIES_CHANGED];
  require([textLayer.string isEqual:@"Code"],
          @"the active custom name should survive Dock label refreshes");
  require([objc_getAssociatedObject(textLayer, &ORIGINAL_STRING)
              isEqual:@"Desktop 2"],
          @"the latest Dock label should be retained for later restoration");

  NSUInteger callsBefore = originalImplementationCallCount;
  char unrelatedContext;
  [textLayer observeValueForKeyPath:@"foreign"
                           ofObject:textLayer
                             change:@{}
                            context:&unrelatedContext];
  require(originalImplementationCallCount == callsBefore + 1,
          @"unknown KVO contexts should be forwarded to Dock's implementation");
}

static NSDictionary *validNamesPropertyList(void) {
  return @{ @"spaces_renaming": @{ @"space-1": @"Code" } };
}

static NSDictionary *validSpacesPropertyList(void) {
  return @{
    @"Monitors": @[
      @{
        @"Display Identifier": @"display-1",
        @"Current Space": @{ @"uuid": @"space-1" },
        @"Spaces": @[ @{ @"uuid": @"space-1" } ]
      }
    ]
  };
}

static void requireMalformedPropertyListFailsSafe(id names, id spaces,
                                                  NSString *scenario) {
  @try {
    require(monitorNamesFromPropertyLists(names, spaces).count == 0, scenario);
  } @catch (id exception) {
    require(NO, [NSString stringWithFormat:@"%@ threw %@", scenario, exception]);
  }
}

static void testPropertyListValidation(void) {
  NSArray<Monitor *> *monitors = monitorNamesFromPropertyLists(
    validNamesPropertyList(),
    validSpacesPropertyList()
  );
  require(monitors.count == 1, @"a valid monitor should be parsed");
  require([monitors[0].spaces[0][@"name"] isEqual:@"Code"],
          @"a valid Space name should be preserved");

  requireMalformedPropertyListFailsSafe(
    @{ @"spaces_renaming": @[] },
    validSpacesPropertyList(),
    @"an array in place of the names dictionary should fail safe"
  );
  requireMalformedPropertyListFailsSafe(
    validNamesPropertyList(),
    @{ @"Monitors": [NSNull null] },
    @"NSNull in place of the monitor array should fail safe"
  );
  requireMalformedPropertyListFailsSafe(
    validNamesPropertyList(),
    @{ @"Monitors": @[ @[] ] },
    @"an array in place of a monitor dictionary should fail safe"
  );
  requireMalformedPropertyListFailsSafe(
    validNamesPropertyList(),
    @{
      @"Monitors": @[
        @{
          @"Current Space": @{ @"uuid": @"space-1" },
          @"Spaces": @[ [NSNull null] ]
        }
      ]
    },
    @"NSNull in place of a Space dictionary should fail safe"
  );
  requireMalformedPropertyListFailsSafe(
    @{ @"spaces_renaming": @{ @"space-1": @42 } },
    validSpacesPropertyList(),
    @"a non-string Space name should fail safe"
  );
}

int main(void) {
  @autoreleasepool {
    testRemovingNameRestoresDefaultLabel();
    testKVOTracksDockLabelAndForwardsUnknownContexts();
    testPropertyListValidation();
    NSLog(@"PASS: Dock hook safety regressions");
  }
  return 0;
}
