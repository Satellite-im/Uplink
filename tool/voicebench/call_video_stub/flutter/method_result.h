#ifndef STUB_METHOD_RESULT_H_
#define STUB_METHOD_RESULT_H_
namespace flutter {
template <typename T>
class MethodResult {
 public:
  virtual ~MethodResult() {}
  virtual void Success(const T& value) = 0;
  virtual void NotImplemented() = 0;
};
}  // namespace flutter
#endif
