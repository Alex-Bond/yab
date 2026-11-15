#import <AppKit/AppKit.h>
#include TEST_INPUT_VIEW_HEADER
#include <iostream>

@interface RenderWidgetHostViewCocoa : NSView
@end
@implementation RenderWidgetHostViewCocoa
@end

int main() {
  @autoreleasepool {
    int failed = 0, checks = 0;
    auto check = [&](const char* name, NSView* actual, NSView* expected) {
      ++checks;
      if (actual != expected) { ++failed; std::cerr << "FAIL " << name << '\n'; }
      else std::cout << "PASS " << name << '\n';
    };
    NSString* name = @"RenderWidgetHostViewCocoa";
    NSView* root = [NSView new];
    auto* cached = [RenderWidgetHostViewCocoa new];
    auto* current = [RenderWidgetHostViewCocoa new];
    [root addSubview:cached]; [root addSubview:current];
    cached.hidden = YES;
    check("cached Back selects current view", FindView(root, name), current);
    cached.hidden = NO; current.hidden = YES;
    check("Forward selects newly visible view", FindView(root, name), cached);
    cached.hidden = YES;
    check("no visible target fails closed", FindView(root, name), nil);
    current.hidden = NO;
    NSView* hiddenAncestor = [NSView new]; hiddenAncestor.hidden = YES;
    [cached removeFromSuperview]; [hiddenAncestor addSubview:cached]; cached.hidden = NO;
    [current removeFromSuperview]; [root addSubview:hiddenAncestor]; [root addSubview:current];
    check("hidden subtree cannot own input", FindView(root, name), current);
    check("hidden ancestor also blocks a direct root", FindView(cached, name), nil);
    check("visible matching root is eligible", FindView(current, name), current);
    check("unmatched class has no target", FindView(root, @"MissingInputView"), nil);
    check("nil hierarchy has no target", FindView(nil, name), nil);
    std::cout << checks << " input-view checks, " << failed << " failed\n";
    return failed ? 1 : 0;
  }
}
