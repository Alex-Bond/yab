// Extension commands (manifest "commands") in Chromium tabs.
//
// Chrome's CommandService keeps every command's key in the profile's
// "extensions.commands" preference: "mac:Command+Shift+X" ->
// {extension, command_name, global}. That is the exact key, where
// developerPrivate's command rows give only the text Chrome shows for it
// (⇧⌘X). extension.list carries it on each row's commands, for Yab's key map
// and Settings › Shortcuts; extension.command writes it back as
// chrome://extensions/shortcuts does. A pressed key reaches Chrome as
// extension.action.open (an action command) or extension.command.run.

// extension id -> command name -> {shortcut, global}, this platform's only.
static NSDictionary* ExtensionCommandKeys(Tab& tab) {
  NSMutableDictionary* out = [NSMutableDictionary new];
  if (!tab.browser) return out;
  auto value = tab.browser->GetHost()->GetRequestContext()->GetPreference("extensions.commands");
  if (!value || value->GetType() != VTYPE_DICTIONARY) return out;
  auto all = value->GetDictionary();
  CefDictionaryValue::KeyList keys;
  if (!all || !all->GetKeys(keys)) return out;
  for (auto& key : keys) {
    std::string name = key.ToString();
    if (name.rfind("mac:", 0) != 0 || all->GetType(key) != VTYPE_DICTIONARY) continue;
    auto entry = all->GetDictionary(key);
    NSString* extension = Str(entry->GetString("extension")), *command = Str(entry->GetString("command_name"));
    if (!ExtensionValidID(extension) || !command.length || command.length > 256) continue;
    // "mac:Shortcut", or "mac:MediaKey:<extension>" for a media key.
    NSString* shortcut = [@(name.substr(4).c_str()) componentsSeparatedByString:@":"].firstObject;
    bool global = entry->HasKey("global") && entry->GetType("global") == VTYPE_BOOL && entry->GetBool("global");
    NSMutableDictionary* commands = out[extension];
    if (!commands) { commands = [NSMutableDictionary new]; out[extension] = commands; }
    commands[command] = @{@"shortcut": shortcut ?: @"", @"global": @(global)};
  }
  return out;
}

// extension.list's rows, each command with its key ("" for none).
static id ExtensionRowsWithCommandKeys(id rows, NSDictionary* keys) {
  if (![rows isKindOfClass:NSArray.class]) return rows;
  NSMutableArray* out = [NSMutableArray new];
  for (id row in (NSArray*)rows) {
    if (![row isKindOfClass:NSDictionary.class] || ![row[@"commands"] isKindOfClass:NSArray.class]) { [out addObject:row]; continue; }
    NSDictionary* own = [keys[row[@"id"]] isKindOfClass:NSDictionary.class] ? keys[row[@"id"]] : @{};
    NSMutableArray* commands = [NSMutableArray new];
    for (id command in (NSArray*)row[@"commands"]) {
      if (![command isKindOfClass:NSDictionary.class] || ![command[@"name"] isKindOfClass:NSString.class]) continue;
      NSMutableDictionary* entry = [command mutableCopy];
      NSDictionary* bound = own[command[@"name"]];
      entry[@"shortcut"] = bound[@"shortcut"] ?: @"";
      if (bound) entry[@"global"] = bound[@"global"];
      [commands addObject:entry];
    }
    NSMutableDictionary* copy = [row mutableCopy];
    copy[@"commands"] = commands;
    [out addObject:copy];
  }
  return out;
}
