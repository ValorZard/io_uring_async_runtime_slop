# Third-Party Notices

## AHT

The HTTP/1.1 and WebSocket protocol implementation in this repository is
informed by [AHT](https://github.com/ovenpasta/aht), by ovenpasta (Aldo
Nicolas Bruno). In particular, its documented HTTP framing rules, chunked
decoder error handling, and WebSocket frame validation informed the
independent, fixed-capacity Ada/SPARK implementation under `src/http/` and
`src/ws/`.

AHT is licensed under the Apache License, Version 2.0. Its source and full
license text are available at https://github.com/ovenpasta/aht.