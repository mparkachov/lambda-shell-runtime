Describe 'unit tests'
  It 'reports init error for missing handler script'
    When run ./scripts/test-unit.sh missing-handler-file
    The status should be success
  End

  It 'reports init error for missing handler function'
    When run ./scripts/test-unit.sh missing-handler-function
    The status should be success
  End

  It 'reports init error for unreadable handler file'
    When run ./scripts/test-unit.sh unreadable-handler
    The status should be success
  End

  It 'reports invocation error for non-zero exit'
    When run ./scripts/test-unit.sh handler-exit
    The status should be success
  End

  It 'reports invocation error with stderr stackTrace'
    When run ./scripts/test-unit.sh handler-exit-stderr
    The status should be success
  End

  It 'escapes error payloads with control characters'
    When run ./scripts/test-unit.sh handler-exit-escape
    The status should be success
  End

  It 'exits when response POST fails'
    When run ./scripts/test-unit.sh response-post-failure
    The status should be success
  End

  It 'exits when error POST fails'
    When run ./scripts/test-unit.sh error-post-failure
    The status should be success
  End

  It 'handles large payloads'
    When run ./scripts/test-unit.sh large-payload
    The status should be success
  End

  It 'cleans invocation env vars between invocations'
    When run ./scripts/test-unit.sh env-var-cleanup
    The status should be success
  End
End

Describe 'response streaming'
  It 'streams response when response mode is streaming'
    When run ./scripts/test-unit.sh streaming-response
    The status should be success
  End
End
