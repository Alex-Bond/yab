// Executes the production registry with a deterministic CEF UI task queue.
#import <Foundation/Foundation.h>
#include <cassert>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>
#include "include/cef_task.h"
static std::vector<std::unique_ptr<CefTask>> tasks;
static bool acceptsTasks = true;
bool CefPostTask(int thread, CefTask* task) {
  assert(thread == TID_UI);
  std::unique_ptr<CefTask> owned(task);
  if (!acceptsTasks) return false;
  tasks.push_back(std::move(owned)); return true;
}
struct Tab { std::string id = "a", profile = "test"; bool closing = false; uint64_t documentGeneration = 0; };
static std::map<std::string, Tab> tabs;
static bool IsReadTab(Tab*) { return false; }
static std::string Key(NSString* s) { return s ? s.UTF8String : ""; }
static NSString* S(NSDictionary* p, NSString* key) { return p[key]; }
static int opens = 0, closed = 0, errors = 0;
static void Event(NSString* kind, Tab*, NSDictionary*) {
  if ([kind isEqual:@"question.open"]) ++opens;
  if ([kind isEqual:@"question.closed"]) ++closed;
}
static void Reply(NSString*, id = nil, NSString* error = nil) { if (error) ++errors; }
#ifndef QUESTION_REGISTRY
#define QUESTION_REGISTRY "../src/page_questions.inc"
#endif
#include QUESTION_REGISTRY
static void drain() {
  while (!tasks.empty()) {
    auto task = std::move(tasks.front()); tasks.erase(tasks.begin()); task->Execute();
  }
}
int main() { @autoreleasepool {
  tabs["a"] = Tab{}; tabs["b"] = Tab{}; tabs["b"].id = "b";
  Tab& a = tabs.at("a"); Tab& b = tabs.at("b");
  int replies = 0;
  auto add = [&](Tab& tab, uint64_t prompt, bool native = true) {
    AskQuestion(&tab, @"location", @{}, [&](NSDictionary*) { ++replies; }, prompt, native);
    for (const auto& [token, q] : pageQuestions) if (q.tab == tab.id && q.prompt == prompt) return token;
    abort();
  };
  auto reply = [&](Tab& tab, const std::string& token) {
    return QuestionRequest(tab, @"question.reply", @{@"request": @(token.c_str()), @"allow": @YES}, @"reply");
  };
  auto token = add(a, 1);
  reply(b, token); assert(errors == 1 && replies == 0); // Original tab only.
  reply(a, token); assert(replies == 0 && pageQuestions.size() == 1);
  reply(a, token); assert(errors == 2 && tasks.size() == 1); // Queued duplicate.
  drain(); assert(replies == 1 && pageQuestions.empty());
  reply(a, token); assert(errors == 3); drain(); assert(replies == 1);
  token = add(a, 2); reply(a, token);
  CancelQuestions(a.id); drain(); assert(replies == 1); // Queued close/navigation.
  add(a, 3); CancelQuestions(a.id); assert(replies == 1); // Native owner cancels.
  add(a, 0, false); CancelQuestions(a.id); assert(replies == 2); // Auth/media still cancel.
  token = add(a, 6); reply(a, token);
  auto sibling = add(a, 7); auto other = add(b, 6);
  DismissPermission(&a, 6); drain();
  assert(replies == 2 && closed == 1 && pageQuestions.size() == 2);
  reply(a, token); assert(errors == 4);
  reply(a, sibling); reply(b, other); drain(); assert(replies == 4);
  token = add(a, 4); acceptsTasks = false; reply(a, token);
  assert(errors == 5 && pageQuestions.empty()); acceptsTasks = true;
  token = add(a, 10); reply(a, token); a.closing = true;
  drain(); assert(replies == 4); a.closing = false;
  // The general generation also changes on attempted/provisional navigation.
  // Only native dismissal/committed-page cancellation withdraws this prompt.
  token = add(a, 11); reply(a, token); ++a.documentGeneration;
  drain(); assert(replies == 5);
  // Continue can synchronously reenter native dismissal/teardown: registry is
  // already consumed, and a newly opened unrelated prompt survives that reply.
  AskQuestion(&a, @"location", @{}, [&](NSDictionary*) {
    assert(pageQuestions.empty()); ++replies; CancelQuestions(a.id); add(b, 9);
  }, 5, true);
  token = pageQuestions.begin()->first; reply(a, token); drain();
  assert(replies == 6 && pageQuestions.size() == 1);
  CancelQuestions(b.id); assert(pageQuestions.empty());
  printf("PASS page question registry: deferred, duplicate, cancellation, queue failure, reentry\n");
} }
