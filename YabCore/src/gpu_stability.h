#pragma once
#include <string>

namespace yabcore {
// #1056 reaches GetMinBufferSizes() on a Dawn error pipeline with validation
// skipped. Keep Graphite and its Metal compositor; validate before SetPipeline
// touches pipeline state. Dawn processes disabled toggles after enabled toggles,
// so this also overrides Chromium's default Graphite skip_validation toggle.
// This is a mitigation, not a repair of the pipeline compilation failure.
template <typename Command>
void ApplyGpuStabilityPolicy(Command& command) {
  std::string disabled = command.GetSwitchValue("disable-dawn-features").ToString();
  const std::string toggle = "skip_validation";
  bool found = false;
  for (size_t start = 0; start < disabled.size();) {
    const size_t end = disabled.find(',', start);
    if (disabled.substr(start, end == std::string::npos ? end : end - start) == toggle)
      found = true;
    if (end == std::string::npos) break;
    start = end + 1;
  }
  if (!found) {
    if (!disabled.empty() && disabled.back() != ',') disabled += ',';
    disabled += toggle;
    command.AppendSwitchWithValue("disable-dawn-features", disabled);
  }
}
}  // namespace yabcore
