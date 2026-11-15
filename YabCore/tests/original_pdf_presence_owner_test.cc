// Exercises the production scope used before native callback and queued delivery.
// No SDK getter/CEF runtime acceptance claim.
#include "original_pdf_presence_owner.h"
#include <cstdio>
#include <cstdlib>
#include <limits>
using yc::OriginalPDFPresenceIdentity;
static int checks=0;
static void Require(bool value,const char* message) {
  if(!value){std::fprintf(stderr,"FAIL: %s\n",message);std::exit(1);}++checks;
}
int main() {
  OriginalPDFPresenceIdentity admitted;
  admitted.tab="original-tab";admitted.profile="original-profile";
  admitted.connection=7;admitted.generation=11;admitted.browser=3;
  admitted.browserIdentity=0x1234;admitted.document="native-document-A";admitted.frame="native-frame-A";
  auto current=admitted;
  Require(admitted.MatchesNativeOwner(current),"original native owner admitted");
  ++current.generation;
  Require(admitted.MatchesNativeOwner(current),"late executionContextsCleared after LoadEnd preserves original native owner");
  Require(admitted.generation==11,"late CDP clear does not mutate V2 observe ACK mapping");
  current.generation=std::numeric_limits<uint64_t>::max();
  Require(admitted.MatchesNativeOwner(current),"CDP context generation is not native document authority");
  current=admitted;current.document="native-document-B";
  Require(!admitted.MatchesNativeOwner(current),"same frame and correlation stamp cannot authorize replacement document");
  Require(admitted.MatchesNativeDocument(admitted.document,admitted.frame),"old metadata still looks internally matching");
  Require(!admitted.MatchesNativeOwner(current),"queued old metadata is rejected after native document replacement");
  current=admitted;current.frame="native-frame-B";
  Require(!admitted.MatchesNativeOwner(current),"frame replacement fails even with unchanged document string");
  current=admitted;++current.browserIdentity;
  Require(!admitted.MatchesNativeOwner(current),"reused native browser ID is not original browser object");
  current=admitted;++current.connection;
  Require(!admitted.MatchesNativeOwner(current),"replacement helper connection cannot inherit old observer");
  current=admitted;current.profile="foreign-profile";
  Require(!admitted.MatchesNativeOwner(current),"same browser number cannot cross original profile");
  current=admitted;current.tab="foreign-tab";
  Require(!admitted.MatchesNativeOwner(current),"same native document cannot cross original tab");
  current=admitted;current.document.clear();
  Require(!admitted.MatchesNativeOwner(current),"unknown native identity is not a same-document clear");
  Require(!admitted.MatchesNativeDocument("native-document-B",admitted.frame),"foreign native metadata root document rejected");
  Require(!admitted.MatchesNativeDocument(admitted.document,"native-frame-B"),"foreign native metadata root frame rejected");
  OriginalPDFPresenceIdentity unknown;
  Require(!unknown.MatchesNativeOwner(unknown),"empty identity cannot authorize itself");
  std::printf("Original PDF presence owner: %d checks PASS\n",checks);
}
