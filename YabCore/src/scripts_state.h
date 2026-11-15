// Page script state belongs to a tab, never to the page-controlled payload.
struct ScriptContext {
  NSString* token;
  NSString* session;
  NSString* frame;
  NSString* world;
  NSString* origin;
  int id;
  bool isDefault;
  NSString* nativeDocument = @"";
};
struct ScriptState {
  NSString* mainFrame = @"";
  std::map<std::string, NSDictionary*> frames;
  std::map<std::string, std::string> parents;
  std::vector<std::string> frameOrder;
  NSArray* definitions = @[];
  NSDictionary* relays = @{};
  std::map<std::string, ScriptContext> contexts;
  std::set<std::string> sessions;
  std::map<std::string, std::vector<NSString*>> identifiers;
  // Per session: a release of the "console" object group in flight (1), and
  // another owed after it (2). See ConsoleRelease in scripts.inc.
  std::map<std::string, int> consoleRelease;
  bool applying = false;
  // A blank document was loaded to bring up the agent of an unnavigated tab.
  bool blankFirst = false;
  // The scheme and ground the app last asked for (scripts.appearance).
  NSDictionary* appearance = nil;
  // Shield's document-start stylesheets (shield.inc): what the document on
  // its way should get, and what the agent holds.
  NSString* shieldURL = nil;
  bool shieldWantGeneric = false, shieldHasGeneric = false, shieldBusy = false;
  const void* shieldEngine = nullptr;
  NSString* shieldWantOwn = nil, *shieldHasOwn = nil;
  NSString* shieldGenericScript = nil, *shieldOwnScript = nil;
};
