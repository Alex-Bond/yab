#include <limits.h>
// Native history entry IDs stay scoped to the browser that supplied them.
static bool HistoryRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if ([method isEqual:@"history.read"]) {
    CDP(tab, @"Page.getNavigationHistory", @{}, [request](NSDictionary* result, NSString* error) {
      Reply(request, result, error);
    });
    return true;
  }
  if (![method isEqual:@"history.go"]) return false;
  NSNumber* entry = p[@"entry"];
  if (![entry isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)entry) == CFBooleanGetTypeID() || entry.doubleValue < 1 ||
      entry.doubleValue > INT_MAX || entry.doubleValue != entry.intValue) {
    Reply(request, nil, @"A native history entry ID is required"); return true;
  }
  auto id = tab.id;
  CDP(tab, @"Page.getNavigationHistory", @{}, [id, request, entry](NSDictionary* result, NSString* error) {
    if (error) { Reply(request, nil, error); return; }
    auto current = tabs.find(id);
    if (current == tabs.end() || current->second.closing) { Reply(request, nil, @"Tab closed"); return; }
    bool exists = false;
    for (NSDictionary* row in result[@"entries"]) if ([row[@"id"] isEqual:entry]) { exists = true; break; }
    // A menu can outlive a replaced history list. Never substitute a URL load
    // or use an index from a different list when its native entry has gone.
    if (!exists) { Reply(request, @{@"navigated": @NO}); return; }
    CDP(current->second, @"Page.navigateToHistoryEntry", @{@"entryId": entry},
      [request](NSDictionary* result, NSString* error) { Reply(request, result, error); });
  });
  return true;
}
