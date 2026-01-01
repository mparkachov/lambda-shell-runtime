Describe 'lambda-shell-runtime'
  It 'passes the smoke test'
    When run ./scripts/smoke_test.sh
    The status should be success
    The output should include "aws-cli/"
    The output should include "jq-"
  End
End

Describe 'sam integration'
  sam_missing() { ! command -v sam >/dev/null 2>&1; }
  docker_missing() { ! command -v docker >/dev/null 2>&1; }
  docker_unavailable() { ! docker info >/dev/null 2>&1; }

  Skip if "sam not installed" sam_missing
  Skip if "docker not installed" docker_missing
  Skip if "docker not running" docker_unavailable

  It 'invokes the example handler with SAM'
    When run ./scripts/integration_test.sh
    The status should be success
  End
End
