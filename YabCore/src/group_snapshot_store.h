#pragma once
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace yc::group_snapshot {
constexpr size_t kMaximum = 16 * 1024 * 1024;
constexpr size_t kChunk = 196608;

// Credits belong to actual work/resources, not to discovery-map membership.
// Entry, accepted native callback, buffer, writer, file and reader share one.
class Budget {
  struct State { std::mutex lock; std::set<const void*> groups; };
  std::shared_ptr<State> state_ = std::make_shared<State>();
 public:
  class Credit {
    friend class Budget;
    std::shared_ptr<State> state_;
    const void* group_;
    std::atomic<bool> poisoned_{false};
    Credit(std::shared_ptr<State> state, const void* group) : state_(std::move(state)), group_(group) {}
   public:
    Credit(const Credit&) = delete;
    Credit& operator=(const Credit&) = delete;
    void Poison() { poisoned_.store(true); }
    ~Credit() {
      std::lock_guard<std::mutex> hold(state_->lock);
      // An uncertain FD close never refunds capacity. At most two poisoned
      // keys remain until process exit; there is no eviction/retry bypass.
      if (!poisoned_.load()) state_->groups.erase(group_);
    }
  };
  std::shared_ptr<Credit> Acquire(const void* original_group) {
    std::lock_guard<std::mutex> hold(state_->lock);
    if (!original_group || state_->groups.size() >= 2 || state_->groups.count(original_group)) return {};
    state_->groups.insert(original_group);
    return std::shared_ptr<Credit>(new Credit(state_, original_group));
  }
  size_t Used() const {
    std::lock_guard<std::mutex> hold(state_->lock); return state_->groups.size();
  }
};

class FD {
  int value_ = -1;
  std::shared_ptr<Budget::Credit> credit_;
 public:
  FD(int value, std::shared_ptr<Budget::Credit> credit) : value_(value), credit_(std::move(credit)) {}
  FD(const FD&) = delete;
  FD& operator=(const FD&) = delete;
  ~FD() { Close(); }
  int Get() const { return value_; }
  bool Close() {
    if (value_ < 0) return true;
    int original = value_; value_ = -1;
    // Never retry close on a potentially reused descriptor after EINTR.
    if (close(original) != 0) { credit_->Poison(); return false; }
    return true;
  }
};

class ImmutableFile {
  std::shared_ptr<FD> read_;
  std::shared_ptr<Budget::Credit> credit_;
  size_t size_;
  ImmutableFile(std::shared_ptr<FD> read, std::shared_ptr<Budget::Credit> credit, size_t size)
      : read_(std::move(read)), credit_(std::move(credit)), size_(size) {}
 public:
  // Input is an independent byte buffer, never a CEF dictionary/reference.
  // Open a separate read-only descriptor before unlink, then write only to the
  // private writer. Once published, no writable descriptor or API survives.
  static std::shared_ptr<ImmutableFile> Freeze(const std::string& bytes, const std::string& temporary_directory,
      const std::shared_ptr<Budget::Credit>& credit, const std::atomic<bool>& retired) {
    if (!credit || bytes.empty() || bytes.size() > kMaximum || retired.load()) return {};
    std::string name; int raw = -1;
    for (int attempt = 0; attempt < 4; ++attempt) {
      unsigned char nonce[16]; arc4random_buf(nonce, sizeof(nonce));
      name = temporary_directory + "/yab-native-snapshot-";
      const char* hex = "0123456789abcdef";
      for (auto byte : nonce) { name.push_back(hex[byte >> 4]); name.push_back(hex[byte & 15]); }
      raw = open(name.c_str(), O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
      if (raw >= 0 || errno != EEXIST) break;
    }
    if (raw < 0) return {};
    FD writer(raw, credit);
    bool private_file = fchmod(raw, 0600) == 0 && fcntl(raw, F_SETFD, FD_CLOEXEC) == 0;
    struct stat before{};
    private_file &= fstat(raw, &before) == 0 && S_ISREG(before.st_mode) && before.st_uid == getuid() &&
                    (before.st_mode & 0777) == 0600 && before.st_nlink == 1;
    int readonly = private_file ? open(name.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW) : -1;
    auto read = readonly >= 0 ? std::make_shared<FD>(readonly, credit) : nullptr;
    struct stat same{};
    private_file &= readonly >= 0 && fstat(readonly, &same) == 0 && before.st_dev == same.st_dev && before.st_ino == same.st_ino;
    // No source payload is written while any name exists.
    const bool unlinked = unlink(name.c_str()) == 0;
    if (!unlinked) credit->Poison(); // Unknown named resource cannot buy another slot.
    struct stat anonymous{};
    if (!private_file || !unlinked || fstat(raw, &anonymous) != 0 || anonymous.st_nlink != 0) return {};
    size_t offset = 0;
    while (offset < bytes.size()) {
      if (retired.load()) return {};
      const size_t remaining = bytes.size() - offset;
      const size_t count = remaining < kChunk ? remaining : kChunk;
      ssize_t written = write(raw, bytes.data() + offset, count);
      if (written < 0 && errno == EINTR) continue;
      if (written <= 0) return {};
      offset += static_cast<size_t>(written);
    }
    struct stat finished{};
    if (retired.load() || fsync(raw) != 0 || fstat(raw, &finished) != 0 ||
        finished.st_size != static_cast<off_t>(bytes.size()) || !writer.Close()) return {};
    return std::shared_ptr<ImmutableFile>(new ImmutableFile(std::move(read), credit, bytes.size()));
  }
  bool Read(size_t offset, size_t length, std::string& bytes, const std::atomic<bool>& retired) const {
    if (retired.load() || offset >= size_ || !length || length > kChunk || length > size_ - offset) return false;
    bytes.resize(length); size_t done = 0;
    while (done < length) {
      if (retired.load()) { bytes.clear(); return false; }
      ssize_t count = pread(read_->Get(), bytes.data() + done, length - done, static_cast<off_t>(offset + done));
      if (count < 0 && errno == EINTR) continue;
      if (count <= 0) { bytes.clear(); return false; }
      done += static_cast<size_t>(count);
    }
    return true;
  }
};
} // namespace yc::group_snapshot
