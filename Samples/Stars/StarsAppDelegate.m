#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support. Compile with -fobjc-arc"
#endif

#import "StarsAppDelegate.h"

#import "StarsViewController.h"

@implementation StarsAppDelegate

#pragma mark - UIApplicationDelegate overrides

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
  self.window.rootViewController = [[StarsViewController alloc] init];
  [self.window makeKeyAndVisible];
  return YES;
}

@end
