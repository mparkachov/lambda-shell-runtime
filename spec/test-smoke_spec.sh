Describe 'lambda-shell-runtime'
  It 'passes the smoke test'
    When run ./scripts/test-smoke.sh
    The status should be success
    The output should include "aws-cli/"
    The output should include "jq-"
  End
End
