#pragma once
#include <memory>
class CefTask {
 public:
  virtual ~CefTask() = default;
  virtual void Execute() = 0;
};
#define IMPLEMENT_REFCOUNTING(Type)
constexpr int TID_UI = 0;
bool CefPostTask(int, CefTask*);
