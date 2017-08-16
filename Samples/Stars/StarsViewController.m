#import "StarsViewController.h"

#import "StarsRenderer.h"

@implementation StarsViewController

- (instancetype)init {
  return [super initWithRenderer:[[StarsRenderer alloc] init]];
}

- (BOOL)isModal {
  // Return YES since we are the topmost fullscreen view controller.
  return YES;
}

- (void)didTapBackButton {
  // User pressed the back button. Pop this view controller.
  NSLog(@"User pressed back button");
}

@end
