default: help

import 'lib/just-foundry/justfile'

DEPLOY_SCRIPT := "script/CreateRepo.sol:CreateRepo"

# End-to-end suites (test/e2e/*.t.sol). Fork tests are included and self-skip
# when MAINNET_RPC_URL / BASE_RPC_URL are unset.
[group('test')]
test-e2e *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }} && env_load
    FORGE=$(just resolve-forge) || exit 1
    BUILD_PARAMS=$(just resolve-build-params) || exit 1
    ETHERSCAN_API_KEY="" $FORGE test $BUILD_PARAMS -vvv \
        --match-path 'test/e2e/*.t.sol' {{ args }}

# End-to-end fork suite against real CCIP routers. Requires BOTH
# MAINNET_RPC_URL and BASE_RPC_URL — the suite forks two chains in the same
# process, so a single RPC won't do. Shadows the inherited `test-fork`.
[group('test')]
test-fork *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }} && env_load
    if [ -z "${MAINNET_RPC_URL:-}" ] || [ -z "${BASE_RPC_URL:-}" ]; then
        echo "MAINNET_RPC_URL and BASE_RPC_URL must be set (in .env or the environment);"
        echo "the suite skips every test without them."
        exit 1
    fi
    FORGE=$(just resolve-forge) || exit 1
    BUILD_PARAMS=$(just resolve-build-params) || exit 1
    $FORGE test $BUILD_PARAMS -vvv \
        --match-path 'test/e2e/fork/*' {{ args }}
