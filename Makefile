-include .env
export

.PHONY: test test-e2e test-e2e-fork

test: ## Run the whole suite; the fork tests skip themselves without RPCs
	forge test

test-e2e: ## Run the end-to-end suites; the fork tests skip themselves without RPCs
	forge test --match-path 'test/e2e/*.t.sol'

test-e2e-fork: ## Run the end-to-end suite against real CCIP Routers
	@if [ -z "$$MAINNET_RPC_URL" ] || [ -z "$$BASE_RPC_URL" ]; then \
		echo "MAINNET_RPC_URL and BASE_RPC_URL must be set (in .env or the environment);"; \
		echo "the suite skips every test without them."; \
		exit 1; \
	fi
	forge test --match-path 'test/e2e/fork/*'

predeploy: ## Simulate a protocol deployment
	@echo "Simulating the deployment"
	forge script CreateRepo --rpc-url $(RPC_URL)

deploy: ## Deploy and verify the protocol
	forge script CreateRepo \
	    --rpc-url $(RPC_URL) \
	    --broadcast \
	    --verify \
	    --etherscan-api-key $(ETHERSCAN_API_KEY)

verify: ## Verify all contracts from the last broadcast
	forge script CreateRepo \
	    --rpc-url $(RPC_URL) \
	    --private-key $(PRIVATE_KEY) \
	    --verify \
	    --etherscan-api-key $(ETHERSCAN_API_KEY) \
	    --resume
