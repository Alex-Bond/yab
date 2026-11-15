// Agent security inventories are complete or fail. Snapshot discovery keeps
// its smaller, intentionally lossy limits in scripts.inc.
struct AgentInventory {
  std::set<std::string> sessions;
  std::vector<NSString*> targets;
  NSMutableDictionary* frames = [NSMutableDictionary new];
  NSMutableDictionary* parents = [NSMutableDictionary new];
  NSString* root = nil;
  size_t nodes = 0;
};
static bool AgentTree(const std::shared_ptr<AgentInventory>& inventory, NSDictionary* tree,
                      NSString* parent, int depth) {
  if (![tree isKindOfClass:NSDictionary.class] || depth >= 32 || ++inventory->nodes > 256) return false;
  NSDictionary* frame = tree[@"frame"];
  NSString* frameID = S(frame, @"id");
  if (!frameID.length) return false;
  NSDictionary* old = inventory->frames[frameID];
  if (old && ![S(old, @"url") isEqual:S(frame, @"url")]) return false;
  inventory->frames[frameID] = frame;
  // The root of an out-of-process frame's own tree has no parent in that
  // tree; Chromium names it in the frame's parentId.
  NSString* link = parent.length ? parent : S(frame, @"parentId");
  if (link.length) {
    NSString* oldParent = inventory->parents[frameID];
    if (oldParent && ![oldParent isEqual:link]) return false;
    inventory->parents[frameID] = link;
  }
  id children = tree[@"childFrames"];
  if (children && ![children isKindOfClass:NSArray.class]) return false;
  for (NSDictionary* child in children) if (!AgentTree(inventory, child, frameID, depth + 1)) return false;
  return true;
}
static void AgentCollect(std::string tabID, std::shared_ptr<AgentInventory> inventory,
                         size_t index, Completion done) {
  auto current = tabs.find(tabID);
  if (current == tabs.end() || current->second.closing || current->second.scripts.sessions != inventory->sessions) {
    done(nil, @"Agent frame inventory changed"); return;
  }
  if (index < inventory->targets.size()) {
    NSString* session = inventory->targets[index];
    CDP(current->second, @"Page.getFrameTree", @{}, [tabID, inventory, index, done](NSDictionary* result, NSString* error) {
      NSDictionary* tree = result[@"frameTree"];
      if (error || !AgentTree(inventory, tree, nil, 0)) { done(nil, error ?: @"Incomplete agent frame inventory"); return; }
      if (index == 0) inventory->root = S(tree[@"frame"], @"id");
      AgentCollect(tabID, inventory, index + 1, done);
    }, session);
    return;
  }
  Tab& tab = current->second;
  if (![inventory->root isEqual:tab.scripts.mainFrame]) { done(nil, @"Agent document changed"); return; }
  NSMutableArray* frames = [NSMutableArray new];
  for (NSString* frameID in inventory->frames) {
    // Every observed frame must be rooted in the current page. Disconnected
    // targets, cycles and missing parent links are never treated as safe.
    NSString* ancestor = frameID;
    std::set<std::string> visited;
    while (![ancestor isEqual:inventory->root]) {
      if (!ancestor.length || !visited.insert(Key(ancestor)).second || visited.size() >= 32) {
        done(nil, @"Incomplete agent frame ancestry"); return;
      }
      ancestor = inventory->parents[ancestor];
    }
    const ScriptContext* match = nullptr;
    for (const auto& [token, context] : tab.scripts.contexts) {
      if (!context.isDefault || ![context.frame isEqual:frameID]) continue;
      if (match) { done(nil, @"Ambiguous agent frame context"); return; }
      match = &context;
    }
    if (!match) { done(nil, @"Agent frame context unavailable"); return; }
    NSMutableDictionary* value = [ScriptFrame(tab, *match) mutableCopy];
    value[@"url"] = S(inventory->frames[frameID], @"url");
    [frames addObject:value];
  }
  if (!frames.count || frames.count > 256) { done(nil, @"Incomplete agent frame inventory"); return; }
  done(@{@"frames": frames}, nil);
}
static bool AgentRequest(Tab& tab, NSString* method, NSString* request) {
  if (![method isEqual:@"agents.frames"]) return false;
  auto inventory = std::make_shared<AgentInventory>();
  inventory->sessions = tab.scripts.sessions;
  inventory->targets.push_back(@"");
  for (const auto& session : inventory->sessions) inventory->targets.push_back(@(session.c_str()));
  AgentCollect(tab.id, inventory, 0, [request](NSDictionary* result, NSString* error) { Reply(request, result, error); });
  return true;
}
