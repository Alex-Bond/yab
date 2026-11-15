#pragma once
#import <Foundation/Foundation.h>
#ifndef YABCORE_ORIGINAL_CALLER_ACCEPTED_VERSION
#define YABCORE_ORIGINAL_CALLER_ACCEPTED_VERSION 0
#endif
namespace yc::original_caller {
// Optional original-parent proof. No failure changes ordinary source62 routes.
// Explicit observation is diagnostic only; compiled accepted policy still0.
void CaptureBeforeCEF(int inherited_socket, bool diagnostic_observation = false, bool deadline_gate = false);
void ConnectionAccepted(int owned_socket);
void ConnectionDropped();
void Hello(NSDictionary* parameters);
bool Ready();
NSDictionary* DiagnosticReceipt(NSString* actual_factory_owner, NSString* actual_group_connection);
NSDictionary* Receipt(NSString* actual_factory_owner, NSString* actual_group_connection);
}
