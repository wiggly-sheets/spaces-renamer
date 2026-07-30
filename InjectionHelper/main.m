#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <libproc.h>
#import <sys/types.h>
#import <unistd.h>
#import "../Shared/SpacesRenamerInjectionXPC.h"

static NSString *const kInstallDirectory =
    @"/Library/PrivilegedHelperTools/com.wiggly-sheets.SpacesRenamer.Injection";
static NSString *const kExpectedClientRequirement =
    @"identifier \"com.wiggly-sheets.SpacesRenamer\"";

@interface InjectionService : NSObject <SpacesRenamerInjectionXPC>
@end

@implementation InjectionService

- (void)pingWithReply:(void (^)(NSString *, NSString *))reply {
  reply(SpacesRenamerInjectionProtocolVersion, @"1");
}

- (void)injectWithReply:(void (^)(BOOL, NSString *, NSNumber *))reply {
  NSXPCConnection *connection = [NSXPCConnection currentConnection];
  uid_t callerUID = connection.effectiveUserIdentifier;
  if (callerUID == 0 || callerUID == (uid_t)-1) {
    reply(NO, @"Refusing an invalid caller user.", nil);
    return;
  }

  pid_t dockPID = [self dockPIDForUser:callerUID];
  if (dockPID <= 0) {
    reply(NO, @"Could not find Dock for the current user.", nil);
    return;
  }

  NSString *injector = [kInstallDirectory stringByAppendingPathComponent:@"dylinject"];
  NSString *payload = [kInstallDirectory stringByAppendingPathComponent:@"spaces-renamer.dylib"];
  if (![[NSFileManager defaultManager] isExecutableFileAtPath:injector] ||
      ![[NSFileManager defaultManager] isReadableFileAtPath:payload]) {
    reply(NO, @"The installed injector or payload is missing.", @(dockPID));
    return;
  }

  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
  task.arguments = @[
    @"asuser", [NSString stringWithFormat:@"%u", callerUID],
    injector, @"com.apple.dock", payload
  ];
  NSPipe *output = [NSPipe pipe];
  task.standardOutput = output;
  task.standardError = output;

  NSError *launchError = nil;
  if (![task launchAndReturnError:&launchError]) {
    reply(NO, launchError.localizedDescription, @(dockPID));
    return;
  }
  [task waitUntilExit];

  NSData *data = [[output fileHandleForReading] readDataToEndOfFile];
  NSString *details = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  details = [details stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (task.terminationStatus != 0) {
    NSString *message = details.length > 0
        ? details
        : [NSString stringWithFormat:@"Injector exited with status %d.",
                                           task.terminationStatus];
    reply(NO, message, @(dockPID));
    return;
  }

  reply(YES, details.length > 0 ? details : @"Injection requested.", @(dockPID));
}

- (pid_t)dockPIDForUser:(uid_t)uid {
  for (NSRunningApplication *application in
       [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"]) {
    pid_t pid = application.processIdentifier;
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) ==
          sizeof(info) &&
        info.pbi_uid == uid) {
      return pid;
    }
  }
  return 0;
}

@end

@interface InjectionListenerDelegate : NSObject <NSXPCListenerDelegate>
@property(nonatomic, strong) InjectionService *service;
@end

@implementation InjectionListenerDelegate

- (instancetype)init {
  self = [super init];
  if (self) {
    _service = [[InjectionService alloc] init];
  }
  return self;
}

- (BOOL)listener:(NSXPCListener *)listener
    shouldAcceptNewConnection:(NSXPCConnection *)connection {
  @try {
    [connection setCodeSigningRequirement:kExpectedClientRequirement];
  } @catch (NSException *exception) {
    return NO;
  }
  connection.exportedInterface =
      [NSXPCInterface interfaceWithProtocol:@protocol(SpacesRenamerInjectionXPC)];
  connection.exportedObject = self.service;
  [connection activate];
  return YES;
}

@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    InjectionListenerDelegate *delegate = [[InjectionListenerDelegate alloc] init];
    NSXPCListener *listener = [[NSXPCListener alloc]
        initWithMachServiceName:SpacesRenamerInjectionMachService];
    listener.delegate = delegate;
    [listener resume];
    [[NSRunLoop currentRunLoop] run];
  }
  return 0;
}
