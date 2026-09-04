# Seastar Echo

This is the Seastar member of the Ada, Tokio, and Seastar echo comparison.
Every peer uses fixed 32-byte `PING`, `PONG`, and `BYE ` frames, so clients and
servers can be freely mixed.

## Build

```sh
cmake -S bench/seastar_echo -B bench/seastar_echo/build -DCMAKE_BUILD_TYPE=Release
cmake --build bench/seastar_echo/build -j
ctest --test-dir bench/seastar_echo/build --output-on-failure
```

CMake obtains Seastar `seastar-25.05.0` through `FetchContent`; its system
build prerequisites are resolved by Seastar's CMake configuration. The build
produces `seastar_echo_server`, `seastar_echo_client`, and `protocol_check`.

The protocol test always runs. When the default Ada binaries in `bin/` and the
Tokio release binaries are present, CTest also runs every client against every
server implementation. Override any peer location with the corresponding
`IOUR_ADA_ECHO_*` or `IOUR_TOKIO_ECHO_*` CMake cache variable.

## Run

```sh
bench/seastar_echo/build/seastar_echo_server 9099 100
bench/seastar_echo/build/seastar_echo_client 127.0.0.1 9099 100 8
```

`IOUR_BENCH_CPUS=1,2` supplies Seastar's `--cpuset` and `--smp` settings.
Use `SEASTAR_EXTRA_ARGS` for additional Seastar options, for example
`--reactor-backend=io_uring --memory=2G`.