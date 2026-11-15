# Upstream reference test suite

These Qt tests are retained as upstream reference and are not built by the
current native application. For the active tests, see
[the native verification instructions](../native/README.md#verification).
The commands below describe the historical upstream build only.

To run tests, add `-DTESTING=ON` argument when invoking cmake, then build the app as usual. \
After building, run `cmake --build <build> --target check` where `<build>` is your cmake build directory.
