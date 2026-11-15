// Shared native-work credit, independent of logical RPC/stream map membership.
#ifndef YABCORE_ORIGINAL_PDF_BUDGET_H_
#define YABCORE_ORIGINAL_PDF_BUDGET_H_
#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <unistd.h>
namespace yc {
class OriginalPDFBudget {
  struct State {
    std::mutex mutex;
    size_t used = 0;
    const size_t limit;
    std::map<std::string,size_t> owners;
    explicit State(size_t limit):limit(limit) {}
  };
 public:
  class Credit {
    friend class OriginalPDFBudget;
    const std::shared_ptr<State> state_;
    const std::string owner_;
    std::atomic<bool> poisoned_{false};
    Credit(std::shared_ptr<State> state,std::string owner):state_(std::move(state)),owner_(std::move(owner)) {}
   public:
    Credit(const Credit&)=delete;Credit& operator=(const Credit&)=delete;
    void Poison() { poisoned_.store(true); }
    bool CloseDescriptor(int& descriptor) {
      const int original=std::exchange(descriptor,-1);
      if(original<0)return true;
      if(::close(original)==0)return true;
      // No retry against a potentially reused descriptor after ambiguous close.
      Poison();return false;
    }
    ~Credit() {
      if(poisoned_.load())return;
      std::lock_guard<std::mutex> lock(state_->mutex);
      auto it=state_->owners.find(owner_);
      if(it!=state_->owners.end()&&it->second==1&&state_->used) {
        state_->owners.erase(it);--state_->used;
      }
    }
  };
  explicit OriginalPDFBudget(size_t limit=8):state_(std::make_shared<State>(limit)) {}
  std::shared_ptr<Credit> Acquire(std::string original_owner) {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if(original_owner.empty()||state_->used>=state_->limit||state_->owners.count(original_owner))return {};
    auto credit=std::shared_ptr<Credit>(new Credit(state_,original_owner));
    state_->owners.emplace(std::move(original_owner),1);++state_->used;return credit;
  }
 private:
  const std::shared_ptr<State> state_;
};
}  // namespace yc
#endif
