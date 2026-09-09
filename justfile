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

# Deploy the full CCIP lane on Arbitrum Sepolia + Base Sepolia in one run.
# `script/testnet/Test_Deploy.s.sol` forks both chains internally, so this
# bypasses the active just-foundry network. Needs ARBITRUM_SEPOLIA_RPC,
# BASE_SEPOLIA_RPC and DEPLOYER_KEY in `.env`. Contracts are not verified —
# use `forge verify-contract` per chain if you need it.
[group('script')]
deploy-testnet *args:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f .env ] && set -a && source .env && set +a
    for v in DEPLOYER_KEY ARBITRUM_SEPOLIA_RPC BASE_SEPOLIA_RPC; do
        if [ -z "${!v:-}" ]; then
            echo "$v must be set (in .env or the environment)."
            exit 1
        fi
    done
    source {{ JUST_LIB }}
    mkdir -p logs
    LOG="logs/Test_Deploy-$(date +%y-%m-%d-%H-%M).log"
    CMD=(forge script script/testnet/Test_Deploy.s.sol:Test_Deploy \
        --sig "run()" --broadcast --multi -vvv {{ args }})
    run_logged "$LOG" "${CMD[@]}"
    echo "Log: $LOG"
