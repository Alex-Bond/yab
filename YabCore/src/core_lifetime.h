#pragma once
#include <atomic>
#include <dispatch/dispatch.h>
#include <sys/event.h>
#include <unistd.h>
#include <stdio.h>

namespace yc {
void Shutdown();

// Callable from any thread, any number of times. The orderly close runs on
// the main thread; the backstop guarantees that the helper (and with it every
// GPU, renderer and utility child, which exit when their browser process is
// gone) cannot outlive its client even when the main thread is wedged in a
// nested loop or a stuck browser close. Shutdown() keeps its own 5 s quit and
// 15 s exit fallbacks; this one fires after them.
inline void BeginShutdown(const char* reason) {
  static std::atomic<bool> begun{false};
  if (begun.exchange(true)) return;
  fprintf(stderr, "YabCore: %s, shutting down\n", reason);
  dispatch_async(dispatch_get_main_queue(), ^{ Shutdown(); });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 17 * NSEC_PER_SEC),
                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    fprintf(stderr, "YabCore: shutdown did not finish, exiting\n");
    _exit(4);
  });
}

// Watch the connected client socket off the main thread. The main-thread
// poll also sees EOF, but only while the main run loop services timers.
// EV_EOF on the read filter means the peer closed its end.
inline void WatchPeer(int fd) {
  int queue = kqueue();
  if (queue < 0) return;
  struct kevent change;
  EV_SET(&change, fd, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, nullptr);
  if (kevent(queue, &change, 1, nullptr, 0, nullptr) < 0) { close(queue); return; }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    struct kevent event;
    // Closing fd on the main thread removes the knote; the wait then blocks
    // until the process exits, which shutdown guarantees.
    while (kevent(queue, nullptr, 0, &event, 1, nullptr) == 1)
      if (event.flags & EV_EOF) { BeginShutdown("client socket closed"); break; }
    close(queue);
  });
}

// Register before CefInitialize: the client may exit before it connects or
// before CEF creates its first browser. NOTE_EXIT also covers SIGKILL/crashes.
// The handler runs off the main thread so a wedged main loop cannot hide it.
class OwnerWatch {
 public:
  bool Start() {
    pid_t owner = getppid();
    if (owner <= 1) return false;
    source_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, owner, DISPATCH_PROC_EXIT,
                                     dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (!source_) return false;
    dispatch_source_set_event_handler(source_, ^{ BeginShutdown("owner process exited"); });
    dispatch_resume(source_);
    // Close the registration race when the parent exited just before resume.
    return getppid() == owner;
  }
  ~OwnerWatch() { if (source_) dispatch_source_cancel(source_); }
 private:
  dispatch_source_t source_ = nullptr;
};
}
