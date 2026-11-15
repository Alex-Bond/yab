#pragma once
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <libproc.h>
#include <unistd.h>

namespace yc {
// Only paths and process identity, never page URLs or command payloads.
inline void TraceLaunch(NSString* root, NSString* event, NSString* target = nil) {
  if (!root.length) return;
  char executable[PROC_PIDPATHINFO_MAXSIZE] = {};
  proc_pidpath(getpid(), executable, sizeof(executable));
  NSMutableDictionary* row = [@{@"event": event, @"time": @(NSDate.date.timeIntervalSince1970),
    @"pid": @(getpid()), @"ppid": @(getppid()), @"bundle": NSBundle.mainBundle.bundlePath ?: @"",
    @"executable": NSBundle.mainBundle.executablePath ?: @"", @"kernelExecutable": @(executable)} mutableCopy];
  if (target) row[@"target"] = target;
  NSString* clone = [[[NSTemporaryDirectory() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"X"]
    stringByAppendingPathComponent:[(NSBundle.mainBundle.bundleIdentifier ?: @"") stringByAppendingString:@".code_sign_clone"]];
  row[@"cloneRoot"] = clone;
  NSData* encoded = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
  if (!encoded) return;
  NSMutableData* line = [encoded mutableCopy]; [line appendBytes:"\n" length:1];
  NSString* file = [[root stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"launches.jsonl"];
  int fd = open(file.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  if (fd < 0) return;
  write(fd, line.bytes, line.length); close(fd);
}
}
