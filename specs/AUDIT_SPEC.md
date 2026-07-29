# Audit Scope

This document lists the contracts submitted for audit. Everything under `src/`
is in scope; `test/`, `script/` and `lib/` (dependencies) are out of scope
except where noted as a reference for intended behaviour.

The system is an Aragon OSx plugin that lets a DAO send and receive
cross-chain messages. A `CrossChainController` on the origin chain encodes an
`Action[]` payload into a `Transaction`, hands it to a bridge adapter, and a
`CrossChainController` on the destination chain authenticates the delivery and
executes the actions through an `Executor`.

## Files in scope

| File | LOC¹ | Role | Trust boundary |
| --- | ---: | --- | --- |
| [CrossChainController.sol](./CrossChainController.sol) | 269 | Core plugin. Owns the send path (`forwardMessage`), the receive path (`receiveMessage`), retry/cancel, fee pre-funding and `sweep`, pausing, per-chain lane config, retry cutoffs, and the UUPS upgrade hook. | Receives from registered local adapters only; executes arbitrary `Action[]` on the executor. |
| [adapters/CCIP/CCIPAdapter.sol](./adapters/CCIP/CCIPAdapter.sol) | 159 | Chainlink CCIP bridge adapter. Send path runs under `delegatecall` from the controller; receive path (`ccipReceive`) runs as the adapter under a `CALL` from the CCIP router. | Accepts inbound messages from the CCIP router; validates the trusted remote. |
| [adapters/BaseAdapter.sol](./adapters/BaseAdapter.sol) | 45 | Shared adapter logic: the `CROSS_CHAIN_CONTROLLER` binding, the trusted-remote map, the `onlyDelegatecallFromController` send-context check, and the `address(this) != _selfAddress` receive-context check. | Enforces the send/receive execution-context split that the whole adapter design rests on. |
| [CrossChainControllerSetup.sol](./CrossChainControllerSetup.sol) | 117 | OSx `PluginUpgradeableSetup` for build 1. Deploys the UUPS proxy, optionally deploys a dedicated `Executor` and transfers its ownership to the plugin, and builds the grant/revoke permission set. | Determines the plugin's entire permission surface at install and uninstall time. |
| [Executor.sol](./Executor.sol) | 16 | `Ownable` variant of the OSx commons `Executor`, so `execute` is restricted to its owning controller rather than permissionless. Holds and forwards native value. | The account that inbound payloads actually execute as. |
| [lib/Transaction.sol](./lib/Transaction.sol) | 34 | The `Transaction` envelope, `TransactionState`/`TransactionRecord`, and the encode/decode/`id` helpers. The txId derived here is the replay- and identity-key for every message. | Defines what the destination authenticates against. |
| [ICrossChainController.sol](./ICrossChainController.sol) | 39 | External interface and the full event set (`MessageForwarded`, `MessageReceived`, `MessageExecutionFailed`, `MinFailedMessageGasUpdated`, …). | Integration and off-chain-indexer surface. |
| [adapters/IBaseAdapter.sol](./adapters/IBaseAdapter.sol) | 14 | Adapter interface. Its NatSpec carries the `MUST` requirements every future adapter has to satisfy (revert on unmapped chain ids; enforce the `delegatecall` context; fee paid from the controller's balance). | The contract that third-party adapters will be written against. |
| [lib/Errors.sol](./lib/Errors.sol) | 28 | Every custom error used across the system. | None (declarations only). |
| [lib/Permissions.sol](./lib/Permissions.sol) | 12 | The eight plugin permission ids plus the DAO's `EXECUTE_PERMISSION_ID`. | Ids must match what the setup grants and what `auth(...)` checks. |
| [lib/ChainIds.sol](./lib/ChainIds.sol) | 13 | Standard EVM chain id constants used by the adapters. | None (constants only). |

## Reference

`specs/SPEC.md` describes the intended protocol behaviour in full and should be
read as the specification the implementation is audited against.
