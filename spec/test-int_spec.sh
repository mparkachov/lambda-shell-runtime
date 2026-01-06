Describe 'integration tests'
  sam_missing() { ! command -v sam >/dev/null 2>&1; }
  docker_missing() { ! command -v docker >/dev/null 2>&1; }
  docker_unavailable() { ! docker info >/dev/null 2>&1; }

  Skip if "sam not installed" sam_missing
  Skip if "docker not installed" docker_missing
  Skip if "docker not running" docker_unavailable

  It 'invokes the example handler with SAM'
    When run ./scripts/test-int.sh standard
    The status should be success
  End

  It 'streams response with curl-minimal'
    When run ./scripts/test-int.sh streaming
    The status should be success
  End
End
