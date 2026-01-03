# TODO

## Missing runtime behavior
- Enrich invocation error payloads beyond the current exit-status message (for example `stackTrace` or captured stderr) if desired.
- Decide how to handle failed POSTs to the Runtime API (response/error) instead of silently ignoring curl failures.
- Implement response streaming if required by your use cases.

## Integration testing
- Optionally add LocalStack tests for end-to-end Lambda + AWS service calls if needed.
