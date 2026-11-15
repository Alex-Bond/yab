#include "core.h"
#include "core_lifetime.h"
#include "original_caller.h"
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
namespace yc {
bool Transport::Start(NSString* path) {
  // The caller supplies a new socket inside an owner-only directory. Never
  // unlink an existing endpoint, which may belong to a live helper.
  struct stat st;
  NSString* parent = path.stringByDeletingLastPathComponent;
  if (lstat(parent.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) ||
      st.st_uid != getuid() || (st.st_mode & 077) != 0) return false;
  sockaddr_un addr = {}; addr.sun_family = AF_UNIX;
  if (path.length == 0 || strlen(path.fileSystemRepresentation) >= sizeof(addr.sun_path)) return false;
  strlcpy(addr.sun_path, path.fileSystemRepresentation, sizeof(addr.sun_path));
  listener_ = socket(AF_UNIX, SOCK_STREAM, 0);
  if (listener_ < 0) return false;
  fcntl(listener_, F_SETFL, O_NONBLOCK); fcntl(listener_, F_SETFD, FD_CLOEXEC);
  if (bind(listener_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr))) {
    close(listener_); listener_ = -1; return false;
  }
  path_ = path;
  if (chmod(path.fileSystemRepresentation, 0600) || listen(listener_, 1)) { Close(); return false; }
  return true;
}
void Transport::Drop() {
  if (peer_ < 0) return;
  original_caller::ConnectionDropped();
  close(peer_); peer_ = -1;
  [input_ setLength:0]; [output_ setLength:0];
  if (onDisconnect) onDisconnect();
}
void Transport::Close() {
  Drop();
  if (listener_ >= 0) { close(listener_); listener_ = -1; }
  if (path_) { unlink(path_.fileSystemRepresentation); path_ = nil; }
}
void Transport::Send(NSDictionary* value) {
  if (peer_ < 0) return;
  NSError* error = nil;
  NSData* data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:&error];
  if (!data || data.length > kMaxMessage || output_.length + data.length > kMaxQueued) {
    fprintf(stderr, "YabCore transport send rejected: json=%s bytes=%lu queued=%lu\n",
      error ? error.localizedDescription.UTF8String : "valid", (unsigned long)data.length, (unsigned long)output_.length);
    Drop(); return;
  }
  [output_ appendData:data]; [output_ appendBytes:"\n" length:1];
}
void Transport::Poll() {
  int fd = accept(listener_, nullptr, nullptr);
  if (fd >= 0) {
    uid_t uid; gid_t gid;
    if (peer_ >= 0 || getpeereid(fd, &uid, &gid) || uid != getuid()) close(fd);
    else {
      peer_ = fd; fcntl(fd, F_SETFL, O_NONBLOCK); fcntl(fd, F_SETFD, FD_CLOEXEC);
      int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
      original_caller::ConnectionAccepted(fd);
      WatchPeer(fd);
    }
  }
  if (peer_ < 0) return;
  char buffer[16384];
  // Bound UI-thread work per tick so input cannot starve Chromium.
  for (int i = 0; i < 16 && peer_ >= 0; ++i) {
    ssize_t n = read(peer_, buffer, sizeof(buffer));
    if (n == 0) { Drop(); break; }
    if (n < 0) { if (errno != EAGAIN && errno != EINTR) Drop(); break; }
    [input_ appendBytes:buffer length:n];
    if (input_.length > kMaxQueued) { Drop(); break; }
  }
  for (int i = 0; i < 64 && peer_ >= 0; ++i) {
    const void* end = memchr(input_.bytes, '\n', input_.length);
    if (!end) break;
    NSUInteger n = static_cast<const char*>(end) - static_cast<const char*>(input_.bytes);
    if (n > kMaxMessage) { Drop(); break; }
    NSData* line = [input_ subdataWithRange:NSMakeRange(0, n)];
    [input_ replaceBytesInRange:NSMakeRange(0, n + 1) withBytes:nullptr length:0];
    id object = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class]) { Drop(); break; }
    if (onRequest) onRequest(object);
  }
  if (peer_ >= 0 && input_.length > kMaxMessage && !memchr(input_.bytes, '\n', input_.length)) Drop();
  if (peer_ >= 0 && output_.length) {
    ssize_t n = write(peer_, output_.bytes, MIN(output_.length, 256 * 1024));
    if (n > 0) [output_ replaceBytesInRange:NSMakeRange(0, n) withBytes:nullptr length:0];
    else if (n < 0 && errno != EAGAIN && errno != EINTR) Drop();
  }
}
}
