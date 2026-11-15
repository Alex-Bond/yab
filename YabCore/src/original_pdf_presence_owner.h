#ifndef YABCORE_ORIGINAL_PDF_PRESENCE_OWNER_H_
#define YABCORE_ORIGINAL_PDF_PRESENCE_OWNER_H_
#include <cstdint>
#include <string>
namespace yc {
// Value-only scope captured from the original helper/browser and native primary
// document. generation is the frozen V2 admission stamp. The mutable CDP context
// generation may advance while this exact native document remains unchanged.
struct OriginalPDFPresenceIdentity {
  std::string tab,profile,document,frame;
  uint64_t connection=0,generation=0;
  int browser=0;
  uintptr_t browserIdentity=0;
  bool MatchesNativeDocument(const std::string& candidateDocument,
                             const std::string& candidateFrame) const {
    return !document.empty()&&!frame.empty()&&document==candidateDocument&&frame==candidateFrame;
  }
  bool MatchesNativeOwner(const OriginalPDFPresenceIdentity& current) const {
    return connection&&connection==current.connection&&browser>0&&browser==current.browser&&
        browserIdentity&&browserIdentity==current.browserIdentity&&!tab.empty()&&tab==current.tab&&
        !profile.empty()&&profile==current.profile&&MatchesNativeDocument(current.document,current.frame);
  }
};
}
#endif
