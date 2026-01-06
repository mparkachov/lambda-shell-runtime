# TODO

## Runtime parity
- Implement response streaming when `Lambda-Runtime-Function-Response-Mode: streaming` is advertised (API path + streaming POST + tests).
- Avoid ARG_MAX and trailing-newline loss in `function.handler` mode by passing the event via stdin or a temp file (optionally export a `LAMBDA_RUNTIME_EVENT_FILE`).
- Isolate handler shell options/env from the runtime loop (e.g., restore `set -e/-u` and `IFS` after sourcing) so handler scripts cannot mutate runtime behavior.

## Error and payload fidelity
- Use robust JSON escaping for error payloads (tabs/newlines/control chars) and add regression tests.
- Validate Runtime API HTTP status codes for `next`, `response`, and `error`; improve diagnostics and decide on retry/backoff behavior.

## Documentation / usability
- Document handler execution modes clearly (sourced POSIX `sh` for `function.handler`; bash requires executable handler).
- Document or provide a tiny helper for computing remaining time from `LAMBDA_RUNTIME_DEADLINE_MS` (context parity).

## Testing
- Add tests for large payload handling and env var cleanup between invocations.
- Optionally add LocalStack tests for end-to-end Lambda + AWS service calls.
