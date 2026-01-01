# TODO

## Missing runtime behavior
- Propagate invocation metadata from Runtime API headers (request ID, deadline, invoked function ARN, trace ID).
- Surface client context and Cognito identity when provided by Lambda.
- Include richer error reporting fields (error type and diagnostic details) in invocation error responses.
- Implement response streaming if required by your use cases.

## Integration testing
- Add SAM-based integration tests that package the layer and invoke the example handler.
- Add error-path tests (missing handler, non-zero exit, invalid executable).
- Optionally add LocalStack tests for end-to-end Lambda + AWS service calls if needed.
