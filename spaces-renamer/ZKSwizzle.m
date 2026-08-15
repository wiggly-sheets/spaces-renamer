#import "ZKSwizzle.h"
static NSMutableDictionary *classTable;

@interface NSObject (ZKSwizzle)
+ (void)_ZK_unconditionallySwizzle;
+ (BOOL)_ZK_ignoreTypes;
@end

void *ZKIvarPointer(id self, const char *name) {
  Ivar ivar = class_getInstanceVariable(object_getClass(self), name);
  return ivar == NULL ? NULL : (__bridge void *)self + ivar_getOffset(ivar);
}

static SEL destinationSelectorForSelector(SEL cmd, Class dst) {
  return NSSelectorFromString([@"_ZK_old_" stringByAppendingFormat:@"%s_%@", class_getName(dst), NSStringFromSelector(cmd)]);
}

static Class classFromInfo(const char *info) {
  const char *openingBracket = strchr(info, '[');
  if (openingBracket == NULL) {
    [NSException raise:@"Failed to parse info" format:@"Couldn't find swizzle class for info: %s", info];
    return NULL;
  }

  const char *classStart = openingBracket + 1;
  const char *classEnd = strchr(classStart, ' ');
  if (classEnd == NULL) {
    [NSException raise:@"Failed to parse info" format:@"Couldn't find class terminator for info: %s", info];
    return NULL;
  }

  size_t classNameLength = (size_t)(classEnd - classStart);
  if (classNameLength == 0 || classNameLength >= 255) {
    [NSException raise:@"Failed to parse info" format:@"Invalid swizzle class in info: %s", info];
    return NULL;
  }

  char className[255];
  memcpy(className, classStart, classNameLength);
  className[classNameLength] = '\0';
  return objc_getClass(className);
}

ZKIMP ZKOriginalImplementation(id self, SEL sel, const char *info) {
  if (sel == NULL || self == NULL || info == NULL) {
    [NSException raise:@"Invalid Arguments" format:@"One of self: %@, self: %@, or info: %s is NULL", self, NSStringFromSelector(sel), info];
    return NULL;
  }
  
  Class cls = classFromInfo(info);
  Class dest = object_getClass(self);
  
  if (cls == NULL || dest == NULL) {
    [NSException raise:@"Failed obtain class pair" format:@"src: %@ | dst: %@ | sel: %@", NSStringFromClass(cls), NSStringFromClass(dest), NSStringFromSelector(sel)];
    return NULL;
  }
  
  SEL destSel = destinationSelectorForSelector(sel, cls);
  
  Method method =  class_getInstanceMethod(dest, destSel);
  
  if (method == NULL) {
    [NSException raise:@"Failed to retrieve method" format:@"Got null for the source class %@ with selector %@ (%@)", NSStringFromClass(cls), NSStringFromSelector(sel), NSStringFromSelector(destSel)];
    return NULL;
  }
  
  ZKIMP implementation = (ZKIMP)method_getImplementation(method);
  if (implementation == NULL) {
    [NSException raise:@"Failed to get implementation" format:@"The objective-c runtime could not get the implementation for %@ on the class %@. There is no fix for this", NSStringFromClass(cls), NSStringFromSelector(sel)];
  }
  
  return implementation;
}

ZKIMP ZKSuperImplementation(id object, SEL sel, const char *info) {
  if (sel == NULL || object == NULL) {
    [NSException raise:@"Invalid Arguments" format:@"One of self: %@, self: %@ is NULL", object, NSStringFromSelector(sel)];
    return NULL;
  }
  
  Class cls = object_getClass(object);
  if (cls == NULL) {
    [NSException raise:@"Invalid Argument" format:@"Could not obtain class for the passed object"];
    return NULL;
  }
  
  Class sourceClass = classFromInfo(info);
  if (sourceClass != NULL) {
    BOOL isClassMethod = class_isMetaClass(cls);
    NSString *className = classTable[NSStringFromClass(sourceClass)];
    if (className != NULL) {
      cls = NSClassFromString(className);
      if (isClassMethod) {
        cls = object_getClass(cls);
      }
    }
  }
  
  cls = class_getSuperclass(cls);
  
  if (cls == NULL) {
    [NSException raise:@"Invalid Argument" format:@"Could not obtain superclass for the passed object"];
    return NULL;
  }
  
  Method method = class_getInstanceMethod(cls, sel);
  if (method == NULL) {
    [NSException raise:@"Failed to retrieve method" format:@"We could not find the super implementation for the class %@ and selector %@, are you sure it exists?", NSStringFromClass(cls), NSStringFromSelector(sel)];
    return NULL;
  }
  
  ZKIMP implementation = (ZKIMP)method_getImplementation(method);
  if (implementation == NULL) {
    [NSException raise:@"Failed to get implementation" format:@"The objective-c runtime could not get the implementation for %@ on the class %@. There is no fix for this", NSStringFromClass(cls), NSStringFromSelector(sel)];
  }
  
  return implementation;
}

static BOOL enumerateMethods(Class, Class);
BOOL _ZKSwizzle(Class src, Class dest) {
  if (dest == NULL)
    return NO;
  
  NSString *destName = NSStringFromClass(dest);
  if (!destName) {
    return NO;
  }
  
  if (!classTable) {
    classTable = [[NSMutableDictionary alloc] init];
  }
  
  if ([classTable objectForKey:NSStringFromClass(src)]) {
    [NSException raise:@"Invalid Argument"
                format:@"This source class (%@) was already swizzled with another, (%@)", NSStringFromClass(src), classTable[NSStringFromClass(src)]];
    return NO;
  }
  
  BOOL success = enumerateMethods(dest, src);
  success     &= enumerateMethods(object_getClass(dest), object_getClass(src));
  
  [classTable setObject:destName forKey:NSStringFromClass(src)];
  return success;
}

BOOL _ZKSwizzleClass(Class cls) {
  return _ZKSwizzle(cls, [cls superclass]);
}

static BOOL classIgnoresTypes(Class cls) {
  if (!class_isMetaClass(cls)) {
    cls = object_getClass(cls);
  }
  
  if (class_respondsToSelector(cls, @selector(_ZK_ignoreTypes))) {
    id instance = class_createInstance(cls, 0);
    BOOL ignoresTypes = [instance _ZK_ignoreTypes];
    [instance release];
    return ignoresTypes;
  }
  
  return NO;
}

static BOOL enumerateMethods(Class destination, Class source) {    
#if OBJC_API_VERSION < 2
  [NSException raise:@"Unsupported feature" format:@"ZKSwizzle is only available in objc 2.0"];
  return NO;
  
#else
  
  unsigned int methodCount;
  Method *methodList = class_copyMethodList(source, &methodCount);
  BOOL success = YES;
  BOOL ignoreTypes = classIgnoresTypes(source);
  
  for (int i = 0; i < methodCount; i++) {
    Method method = methodList[i];
    SEL selector  = method_getName(method);
    NSString *methodName = NSStringFromSelector(selector);
    
    if (sel_isEqual(selector, @selector(_ZK_unconditionallySwizzle)) ||
        sel_isEqual(selector, @selector(_ZK_ignoreTypes))) {
      continue;
    }
    
    if (class_respondsToSelector(destination, selector)) {
      Method originalMethod = class_getInstanceMethod(destination, selector);
      
      const char *originalType = method_getTypeEncoding(originalMethod);
      const char *newType = method_getTypeEncoding(method);
      if (strcmp(originalType, newType) != 0 && !ignoreTypes) {
        NSLog(@"ZKSwizzle: incompatible type encoding for %@. (expected %s, got %s)", methodName, originalType, newType);
        success = NO;
        continue;
      }
      
      class_addMethod(destination, selector, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod));
      
      SEL destSel = destinationSelectorForSelector(selector, source);
      if (!class_addMethod(destination, destSel, method_getImplementation(method), method_getTypeEncoding(originalMethod))) {
        NSLog(@"ZKSwizzle: failed to add method %@ onto class %@ with selector %@", NSStringFromSelector(selector), NSStringFromClass(source), NSStringFromSelector(destSel));
        success = NO;
        continue;
      }
      
      method_exchangeImplementations(class_getInstanceMethod(destination, selector), class_getInstanceMethod(destination, destSel));
    } else {
      success &= class_addMethod(destination, selector, method_getImplementation(method), method_getTypeEncoding(method));
    }
  }
  
  unsigned int propertyCount;
  objc_property_t *propertyList = class_copyPropertyList(source, &propertyCount);
  for (int i = 0; i < propertyCount; i++) {
    objc_property_t property = propertyList[i];
    const char *name = property_getName(property);
    unsigned int attributeCount;
    objc_property_attribute_t *attributes = property_copyAttributeList(property, &attributeCount);
    
    if (class_getProperty(destination, name) == NULL) {
      class_addProperty(destination, name, attributes, attributeCount);
    } else {
      class_replaceProperty(destination, name, attributes, attributeCount);
    }
    
    free(attributes);
  }
  
  free(propertyList);
  free(methodList);
  return success;
#endif
}

static NSMutableDictionary *groups = nil;
void _$ZKRegisterInterface(Class cls, const char *groupName) {
  if (!groups)
    groups = [[NSMutableDictionary dictionary] retain];
  
  NSString *groupString = @(groupName);
  NSMutableArray *groupList = groups[groupString];
  if (!groupList) {
    groupList = [NSMutableArray array];
    groups[groupString] = groupList;
  }
  
  [groupList addObject:NSStringFromClass(cls)];
}

BOOL _ZKSwizzleGroup(const char *groupName) {
  NSArray *groupList = groups[@(groupName)];
  if (!groupList) {
    [NSException raise:@"Invalid Argument" format:@"ZKSwizzle: There is no group by the name of %s", groupName];
    return NO;
  }
  
  BOOL success = YES;
  for (NSString *className in groupList) {
    Class cls = NSClassFromString(className);
    if (cls == NULL)
      continue;
    
    if (class_respondsToSelector(object_getClass(cls), @selector(_ZK_unconditionallySwizzle))) {
      [cls _ZK_unconditionallySwizzle];
    } else {
      success = NO;
    }
  }
  
  return success;
}
