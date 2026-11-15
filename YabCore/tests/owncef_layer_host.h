#pragma once
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <unistd.h>

// The private hosting primitive stays confined to the native acceptance host.
@interface CALayerHost : CALayer
@property(nonatomic) uint32_t contextId;
@end

// Capture the actual remote pixels with the existing, authorized SCK tool.
// AppKit cacheDisplay cannot see another process's CALayerHost contents.
static NSString* YCWindowPixels(NSWindow* window, NSString* file) {
  NSString* captureFile = [[file stringByDeletingPathExtension]
                            stringByAppendingString:@".capture.png"];
  NSString* script = @"import json, os, sys; from pathlib import Path; "
    "sys.path.insert(0, str(Path.cwd() / 'evals')); "
    "from probe_capture import picture; "
    "print(json.dumps(picture(int(sys.argv[1]), Path(sys.argv[2]), window_id=int(sys.argv[3]))))";
  NSTask* task = [NSTask new];
  task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
  task.arguments = @[@"-c", script, @(getpid()).stringValue, captureFile,
                     @(window.windowNumber).stringValue];
  NSPipe* output = [NSPipe pipe];
  task.standardOutput = output;
  task.standardError = NSFileHandle.fileHandleWithStandardError;
  NSError* error = nil;
  if (![task launchAndReturnError:&error]) return error.localizedDescription;
  __weak NSTask* watched = task;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    if (watched.running) [watched terminate];
  });
  NSData* data = [output.fileHandleForReading readDataToEndOfFile];
  [task waitUntilExit];
  if (task.terminationStatus != 0) {
    return [NSString stringWithFormat:@"SCK capture failed: %d", task.terminationStatus];
  }
  NSDictionary* metadata = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  if (![metadata[@"capture"] isEqual:@"ScreenCaptureKit"])
    return @"Capture did not use ScreenCaptureKit";
  // picture() writes its own metadata JSON. Use a different stem so the
  // protocol client cannot mistake it for the final color-count result.
  NSData* png = [NSData dataWithContentsOfFile:captureFile];
  if (!png || ![png writeToFile:file options:NSDataWritingAtomic error:&error])
    return error.localizedDescription ?: @"Missing SCK pixels";
  return @"ScreenCaptureKit";
}
