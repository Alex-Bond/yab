// Page context menus, included by core.mm after the shared wire helpers.
// Chrome builds the menu for the hidden producer window; Yab draws its own
// menu at the page point instead and answers through this continuation.
#include "include/cef_context_menu_handler.h"

struct PageMenu {
  std::string tab;
  NSString* token;
  CefRefPtr<CefRunContextMenuCallback> callback;
  std::set<int> commands;
};
static std::map<std::string, PageMenu> pageMenus;

// chrome/app/chrome_command_ids.h, Chromium 156.0.8078.48.
static const int kExtensionCommandFirst = 49000, kExtensionCommandLast = 49999;
static const int kChromeCommandCopy = 50150, kChromeCommandCut = 50151, kChromeCommandPaste = 50152;
static const int kChromeCommandSelectAll = 50156;

static void CancelPageMenu(const std::string& tab) {
  auto found = pageMenus.find(tab);
  if (found == pageMenus.end()) return;
  auto callback = found->second.callback;
  pageMenus.erase(found);
  callback->Cancel();
}
// Only rows Yab may forward: Chrome's own edit commands it
// offers here, and extension items (chrome.contextMenus) with submenus.
// A DevTools frontend's rows are all its own (Reveal in Sources, Copy selector...).
static NSArray* MenuRows(CefRefPtr<CefMenuModel> model, std::set<int>& commands, bool every = false, int depth = 0) {
  NSMutableArray* rows = [NSMutableArray new];
  if (!model || depth > 3) return rows;
  for (size_t i = 0; i < model->GetCount() && i < 200; i++) {
    int command = model->GetCommandIdAt(i);
    auto type = model->GetTypeAt(i);
    if (type == MENUITEMTYPE_SEPARATOR || !model->IsVisibleAt(i)) continue;
    bool extension = every || (command >= kExtensionCommandFirst && command <= kExtensionCommandLast);
    NSArray* children = type == MENUITEMTYPE_SUBMENU ? MenuRows(model->GetSubMenuAt(i), commands, every, depth + 1) : @[];
    if (!extension && !children.count) {
      if (depth == 0 && (command == kChromeCommandCopy || command == kChromeCommandCut || command == kChromeCommandPaste ||
          command == kChromeCommandSelectAll) && model->IsEnabledAt(i)) commands.insert(command);
      continue;
    }
    if (type != MENUITEMTYPE_SUBMENU) commands.insert(command);
    [rows addObject:@{@"command": @(command), @"label": Str(model->GetLabelAt(i)),
                      @"enabled": @(model->IsEnabledAt(i)), @"checked": @(model->IsCheckedAt(i)),
                      @"extension": @(extension), @"rows": children}];
  }
  return rows;
}
static bool OpenPageMenu(Tab* tab, CefRefPtr<CefFrame> frame, CefRefPtr<CefContextMenuParams> params,
                         CefRefPtr<CefMenuModel> model, CefRefPtr<CefRunContextMenuCallback> callback) {
  if (!tab || tab->closing || tab->internal || !tab->adopted) { callback->Cancel(); return true; }
  CancelPageMenu(tab->id);
  PageMenu menu{tab->id, NSUUID.UUID.UUIDString, callback, {}};
  NSArray* extensions = MenuRows(model, menu.commands, tab->devToolsFrontend);
  std::vector<CefString> suggestions;
  params->GetDictionarySuggestions(suggestions);
  NSMutableArray* words = [NSMutableArray new];
  for (const auto& word : suggestions) if (words.count < 8) [words addObject:Str(word)];
  NSMutableArray* chrome = [NSMutableArray new];
  for (int command : menu.commands) if (command < kExtensionCommandFirst || command > kExtensionCommandLast) [chrome addObject:@(command)];
  int flags = params->GetTypeFlags();
  Event(@"menu.open", tab, @{@"request": menu.token, @"x": @(params->GetXCoord()), @"y": @(params->GetYCoord()),
    @"link": Str(params->GetLinkUrl()), @"unfilteredLink": Str(params->GetUnfilteredLinkUrl()),
    @"source": Str(params->GetSourceUrl()), @"media": @(params->GetMediaType()),
    @"hasImage": @(params->HasImageContents()), @"title": Str(params->GetTitleText()),
    @"selection": Str(params->GetSelectionText()), @"editable": @(params->IsEditable()),
    @"editFlags": @(params->GetEditStateFlags()), @"frame": Str(params->GetFrameUrl()),
    @"page": Str(params->GetPageUrl()), @"mainFrame": @(frame && frame->IsMain()),
    @"typeFlags": @(flags), @"misspelled": Str(params->GetMisspelledWord()),
    @"suggestions": words, @"chrome": chrome, @"extensions": extensions, @"devToolsFrontend": @(tab->devToolsFrontend)});
  pageMenus.emplace(tab->id, std::move(menu));
  return true;
}
class ImageBytes : public CefDownloadImageCallback {
  NSString* request_;
 public:
  explicit ImageBytes(NSString* request) : request_(request) {}
  void OnDownloadImageFinished(const CefString&, int status, CefRefPtr<CefImage> image) override {
    int width = 0, height = 0;
    auto png = image && !image->IsEmpty() ? image->GetAsPNG(1, true, width, height) : nullptr;
    size_t size = png ? png->GetSize() : 0;
    if (!size || size > 48 * 1024 * 1024) { Reply(request_, nil, [NSString stringWithFormat:@"No image (HTTP %d)", status]); return; }
    NSMutableData* data = [NSMutableData dataWithLength:size];
    png->GetData(data.mutableBytes, size, 0);
    Reply(request_, @{@"png": [data base64EncodedStringWithOptions:0], @"width": @(width), @"height": @(height)});
  }
  IMPLEMENT_REFCOUNTING(ImageBytes);
};
static bool ContextMenuRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if ([method isEqual:@"menu.reply"]) {
    auto found = pageMenus.find(tab.id);
    if (found == pageMenus.end() || ![found->second.token isEqual:S(p, @"request")]) {
      Reply(request, nil, @"No matching page menu"); return true;
    }
    NSNumber* command = [p[@"command"] isKindOfClass:NSNumber.class] ? p[@"command"] : nil;
    // Only a row this menu offered can be run. Anything else cancels.
    bool offered = command && found->second.commands.count(command.intValue);
    auto callback = found->second.callback;
    pageMenus.erase(found);
    Reply(request, @{@"ran": @(offered)});
    if (offered) callback->Continue(command.intValue, EVENTFLAG_NONE); else callback->Cancel();
    return true;
  }
  if ([method isEqual:@"page.download"] || [method isEqual:@"page.imageData"]) {
    NSURL* url = [NSURL URLWithString:S(p, @"url")];
    NSString* scheme = url.scheme.lowercaseString;
    if (!url || !([scheme isEqual:@"http"] || [scheme isEqual:@"https"] || [scheme isEqual:@"data"] || [scheme isEqual:@"blob"])) {
      Reply(request, nil, @"A web URL is required"); return true;
    }
    if ([method isEqual:@"page.download"]) {
      // CEF's download handler then asks Yab for the destination as usual.
      tab.browser->GetHost()->StartDownload(Key(S(p, @"url"))); Reply(request); return true;
    }
    tab.browser->GetHost()->DownloadImage(Key(S(p, @"url")), false, 0, false, new ImageBytes(request));
    return true;
  }
  if ([method isEqual:@"page.replaceMisspelling"]) {
    NSString* word = S(p, @"text");
    if (!word.length || word.length > 200) { Reply(request, nil, @"A word is required"); return true; }
    tab.browser->GetHost()->ReplaceMisspelling(Key(word)); Reply(request); return true;
  }
  return false;
}
