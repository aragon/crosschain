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
| [CrossChainController.sol](../src/CrossChainController.sol) | 235 | Core plugin. Owns the send path (`forwardMessage`), the receive path (`receiveMessage`), retry/cancel, fee pre-funding and `sweep`, pausing, per-chain lane config, and UUPS upgradeability inherited from OSx `PluginUUPSUpgradeable` - the `_authorizeUpgrade` hook itself lives in that out-of-scope base. | Receives from registered local adapters only; executes arbitrary `Action[]` on the executor. |
| [adapters/CCIP/CCIPAdapter.sol](../src/adapters/CCIP/CCIPAdapter.sol) | 99 | Chainlink CCIP bridge adapter. Send path runs under `delegatecall` from the controller; receive path (`ccipReceive`) runs as the adapter under a `CALL` from the CCIP router. | Accepts inbound messages from the CCIP router; validates the trusted remote. |
| [adapters/BaseAdapter.sol](../src/adapters/BaseAdapter.sol) | 57 | Shared adapter logic: the `CROSS_CHAIN_CONTROLLER` and `CHAIN_ID_REGISTRY` bindings, the chain-id mappers that resolve through that registry and revert on its `0`, the trusted-remote map, the `onlyDelegatecallFromController` send-context check, and the `address(this) != _selfAddress` receive-context check. | Enforces the send/receive execution-context split - but only on `sendMessage` and `_forwardMessage`; `quoteFee`, the chain-id mappers, `trustedRemote` and `supportsInterface` carry no context guard. Both mappers make an external call into the bound registry, which is a trust dependency of this contract. |
| [CrossChainControllerSetup.sol](../src/CrossChainControllerSetup.sol) | 115 | OSx `PluginUpgradeableSetup` for build 1. Deploys the UUPS proxy, optionally deploys a dedicated `Executor` and transfers its ownership to the plugin, and builds the grant/revoke permission set. | Builds the grant set at install and the revoke set at uninstall - deliberately not a mirror: a guardian's `PAUSE_PERMISSION` survives uninstall, and `EXECUTE_PERMISSION` on the DAO is always revoked whether or not it was granted. |
| [Executor.sol](../src/Executor.sol) | 12 | `Ownable` variant of the OSx commons `Executor`, so `execute` is restricted to its owning controller rather than permissionless. Holds and forwards native value. | The account inbound payloads execute as while it is the configured executor; `updateExecutor` can repoint at any time. |
| [lib/Transaction.sol](../src/lib/Transaction.sol) | 33 | The `Transaction` envelope, `TransactionState`, and the encode/decode/`id` helpers. The txId derived here is the replay- and identity-key on the DESTINATION side; `forwardMessage` stores no per-message record, only a monotonic nonce. | Defines what the destination authenticates against. |
| [ICrossChainController.sol](../src/ICrossChainController.sol) | 37 | External interface and every event the plugin declares (`MessageForwarded`, `MessageReceived`, `MessageExecutionFailed`, `MinFailedMessageGasUpdated`, …). Inherited `Paused`/`Upgraded`/`Initialized` are emitted but not redeclared here. | Integration and off-chain-indexer surface. |
| [adapters/IBaseAdapter.sol](../src/adapters/IBaseAdapter.sol) | 13 | Adapter interface. Its NatSpec carries the `MUST` requirements every future adapter has to satisfy (revert on unmapped chain ids; enforce the `delegatecall` context; fee paid from the controller's balance). | The contract that third-party adapters will be written against. |
| [lib/Errors.sol](../src/lib/Errors.sol) | 25 | Every custom error declared by this system. In-scope code also reverts with OSx errors (`InvalidUpdatePath`, `TooManyActions`/`ActionFailed`/`ReentrantCall` via `Executor`, and `DaoUnauthorized` via the registry's `auth` modifier). | None (declarations only). |
| [lib/Permissions.sol](../src/lib/Permissions.sol) | 12 | The eight plugin permission ids, `MANAGE_CHAIN_ID_REGISTRY_PERMISSION_ID`, plus the DAO's `EXECUTE_PERMISSION_ID`. | Ids must match what the setup grants and what `auth(...)` checks. Three exceptions: `UPGRADE_PLUGIN_PERMISSION_ID` is enforced by the inherited hook against its own identically-valued constant; `EXECUTE_PERMISSION_ID` is granted on the DAO, never checked on the plugin; and `MANAGE_CHAIN_ID_REGISTRY_PERMISSION_ID` is granted by no setup at all - deployment tooling or the DAO grants it per registry - and is checked on the `ChainIdRegistry`, never on the plugin. |
| [registry/ChainIdRegistry.sol](../src/registry/ChainIdRegistry.sol) | 28 | The runtime-updatable chain id translation table an adapter is bound to, one per adapter protocol. `DaoAuthorizable`, gated on `MANAGE_CHAIN_ID_REGISTRY_PERMISSION`. Writes both directions together and clears the stale reverse entry on a repoint. | **A trust dependency of every adapter pointing at it.** The permission holder can repoint a live lane at a different bridge-native chain in one call, sending messages to the wrong chain; the binding is constructor-only, so an adapter cannot be moved off a compromised registry. |
| [registry/IChainIdRegistry.sol](../src/registry/IChainIdRegistry.sol) | 5 | Registry interface and the `ChainIdPairSet` event. Documents that both directions answer `0` for an unmapped id, and that turning that into a revert is `BaseAdapter`'s job. | The surface adapters and off-chain indexers read. |

¹ Lines of code excluding blanks, comments, `pragma` and `import`.

## Reference

[SPEC.md](./SPEC.md) describes the intended protocol behaviour and
should be read as the specification the implementation is audited against.

[test/e2e/README.md](../test/e2e/README.md) documents the end-to-end suites,
which carry a message through both stacks against a real OSx `DAO` (except
`CrossChainRoundTrip.t.sol`, which uses the DAO mock) and, in the fork suite,
against production CCIP Router bytecode. They are out of scope themselves, but
are the most direct executable statement of intended behaviour.
