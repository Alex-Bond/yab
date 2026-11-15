#include "gpu_stability.h"
#include <cassert>
#include <map>
#include <string>
struct Value {
  std::string value;
  std::string ToString() const { return value; }
};
struct Command {
  std::map<std::string, std::string> switches;
  Value GetSwitchValue(const char* name) const {
    auto i = switches.find(name);
    return {i == switches.end() ? "" : i->second};
  }
  void AppendSwitchWithValue(const char* name, const std::string& value) {
    switches[name] = value;
  }
};
int main() {
  for (const std::string existing : {"", "other", "skip_validation", "other,skip_validation",
                                     "skip_validation,other", "other,", "skip_validation_extra"}) {
    Command command;
    command.switches = {{"enable-features", "SkiaGraphite,OtherFeature"},
                        {"disable-features", "HardwareMediaKeyHandling"},
                        {"enable-dawn-features", "skip_validation,other"},
                        {"use-angle", "metal"}, {"enable-skia-graphite", ""}};
    if (!existing.empty()) command.switches["disable-dawn-features"] = existing;
    auto untouched = command.switches;
    untouched.erase("disable-dawn-features");
    yabcore::ApplyGpuStabilityPolicy(command);
    const auto value = command.switches.at("disable-dawn-features");
    const bool already = existing == "skip_validation" || existing == "other,skip_validation" ||
                         existing == "skip_validation,other";
    assert(value == (already ? existing : existing +
           (existing.empty() || existing.back() == ',' ? "" : ",") + "skip_validation"));
    auto once = command.switches;
    yabcore::ApplyGpuStabilityPolicy(command);
    assert(once == command.switches);
    command.switches.erase("disable-dawn-features");
    assert(untouched == command.switches);
  }
}
