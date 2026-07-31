-include .env
export

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
