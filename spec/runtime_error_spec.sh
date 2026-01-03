Describe 'runtime error paths'
  It 'reports init error for missing handler script'
    When run ./scripts/runtime_error_test.sh missing-handler-file
    The status should be success
  End

  It 'reports init error for missing handler function'
    When run ./scripts/runtime_error_test.sh missing-handler-function
    The status should be success
  End

  It 'reports init error for unreadable handler file'
    When run ./scripts/runtime_error_test.sh unreadable-handler
    The status should be success
  End

  It 'reports invocation error for non-zero exit'
    When run ./scripts/runtime_error_test.sh handler-exit
    The status should be success
  End
End
