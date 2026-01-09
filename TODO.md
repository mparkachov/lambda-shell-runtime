# TODO

## Runtime parity

## Documentation / usability
- Document handler execution modes clearly (sourced POSIX `sh` for `function.handler`; bash requires executable handler).
- Document or provide a tiny helper for computing remaining time from `LAMBDA_RUNTIME_DEADLINE_MS` (context parity).

## Testing
- Add tests for large payload handling and env var cleanup between invocations.
- Optionally add LocalStack tests for end-to-end Lambda + AWS service calls.
