#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static NSString *const SpacesRenamerInjectionMachService =
    @"com.wiggly-sheets.SpacesRenamer.InjectionHelper";
static NSString *const SpacesRenamerInjectionProtocolVersion = @"1";

@protocol SpacesRenamerInjectionXPC

- (void)pingWithReply:(void (^)(NSString *protocolVersion,
                                NSString *helperVersion))reply;
- (void)injectWithReply:(void (^)(BOOL succeeded,
                                  NSString *message,
                                  NSNumber * _Nullable dockPID))reply;

@end

NS_ASSUME_NONNULL_END
