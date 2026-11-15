// Production shared-budget lifetime tests. No CEF/PDF native acceptance claim.
#include "original_pdf_budget.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <thread>
#include <vector>
using yc::OriginalPDFBudget;
static int checks=0;
static void Require(bool ok,const char* label) {
  if(!ok){std::fprintf(stderr,"FAIL: %s\n",label);std::exit(1);}++checks;
}
int main() {
  {
    OriginalPDFBudget budget;auto logical=budget.Acquire("original-tab");
    auto native_callback=logical;logical.reset();
    Require(!budget.Acquire("original-tab"),"logical cancel cannot free native callback credit");
    native_callback.reset();Require(bool(budget.Acquire("original-tab")),"actual native callback retirement releases credit");
  }
  {
    OriginalPDFBudget budget;auto logical=budget.Acquire("original-tab");
    auto queued_ui=logical,writer=logical,file=logical;logical.reset();
    Require(!budget.Acquire("original-tab"),"queued UI/writer/file own retired credit");
    queued_ui.reset();writer.reset();Require(!budget.Acquire("original-tab"),"FD owner still holds retired credit");
    file.reset();Require(bool(budget.Acquire("original-tab")),"all resource owners really retired");
  }
  {
    OriginalPDFBudget budget;std::vector<std::shared_ptr<OriginalPDFBudget::Credit>> pending;
    for(int i=0;i<8;++i)pending.push_back(budget.Acquire(std::to_string(i)));
    Require(bool(pending.back()),"eight original work items admitted");
    Require(!budget.Acquire("ninth"),"retired-but-pending callback/writer global maximum eight");
    for(int i=0;i<200;++i)Require(!budget.Acquire("ninth"),"cancel/retry cannot grow unknown memory budget");
    pending[0].reset();Require(bool(budget.Acquire("ninth")),"only actual retirement restores global room");
    Require(!budget.Acquire("1"),"another original tab credit unaffected");
  }
  {
    auto budget=std::make_unique<OriginalPDFBudget>();auto credit=budget->Acquire("original");
    budget.reset();std::thread writer([credit=std::move(credit)]() mutable {credit.reset();});writer.join();
    Require(true,"credit safely outlives logical budget wrapper on writer thread");
  }
  {
    OriginalPDFBudget budget;std::vector<std::shared_ptr<OriginalPDFBudget::Credit>> credits(32);
    std::vector<std::thread> threads;
    for(size_t i=0;i<credits.size();++i)threads.emplace_back([&,i]{credits[i]=budget.Acquire("same-original");});
    for(auto& thread:threads)thread.join();size_t admitted=0;for(auto& credit:credits)admitted+=bool(credit);
    Require(admitted==1,"thread-safe per-original owner acquisition");credits.clear();
    Require(bool(budget.Acquire("same-original")),"concurrent owners all released exactly once");
  }
  {
    OriginalPDFBudget budget(1);auto credit=budget.Acquire("original");
    int descriptor=open("/dev/null",O_RDONLY|O_CLOEXEC);Require(descriptor>=0,"owned descriptor opened");
    Require(credit->CloseDescriptor(descriptor)&&descriptor==-1,"original descriptor closes exactly once");
    Require(credit->CloseDescriptor(descriptor),"closed descriptor cannot be signalled or retried");
    credit.reset();Require(bool(budget.Acquire("next")),"known close restores capacity");
  }
  {
    OriginalPDFBudget budget(1);auto credit=budget.Acquire("original");
    int descriptor=open("/dev/null",O_RDONLY|O_CLOEXEC);Require(descriptor>=0,"owned failure fixture opened");
    Require(::close(descriptor)==0,"fixture retires only its own descriptor");
    Require(!credit->CloseDescriptor(descriptor)&&descriptor==-1,"close error poisons without retry");
    credit.reset();Require(!budget.Acquire("original")&&!budget.Acquire("next"),"unknown close never refunds owner or global capacity");
  }
  {
    OriginalPDFBudget budget(1);auto credit=budget.Acquire("original");
    credit->Poison();credit.reset();
    Require(!budget.Acquire("next"),"unknown named resource cannot buy another slot");
  }
  {
    OriginalPDFBudget budget(0);Require(!budget.Acquire("original"),"zero capacity denies");
    OriginalPDFBudget normal;Require(!normal.Acquire(""),"missing original owner denies");
  }
  std::printf("QA_CHECK_RESULT {\"passed\":true,\"checks\":%d,\"scope\":\"production shared budget lifetime only, no CEF/native PDF proof\"}\n",checks);
}
