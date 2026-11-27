// A stand-in for Flutter's own (see ../windows.h).
#ifndef STUB_ENCODABLE_VALUE_H_
#define STUB_ENCODABLE_VALUE_H_
#include <cstdint>
#include <map>
#include <string>
#include <variant>
#include <vector>
namespace flutter {
class EncodableValue;
using EncodableList = std::vector<EncodableValue>;
using EncodableMap = std::map<EncodableValue, EncodableValue>;
using EncodableBase = std::variant<std::monostate, bool, int32_t, int64_t, double, std::string, std::vector<uint8_t>, EncodableList, EncodableMap>;
class EncodableValue : public EncodableBase {
 public:
  using EncodableBase::EncodableBase;
  EncodableValue() = default;
  EncodableValue(const char* s) : EncodableBase(std::string(s)) {}
};
}  // namespace flutter
#endif
