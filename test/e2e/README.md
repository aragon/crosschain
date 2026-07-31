# End-to-end tests

These suites carry a message the whole way: an origin DAO proposal calls
`forwardMessage`, the adapter hands it to CCIP, the peer router delivers it, the
destination adapter authenticates it, and the destination executor runs the
actions.

## Why these exist, given the unit suites

The per-function suites under `test/unit/` test each side against a HAND-BUILT
counterpart: the send tests assert what the adapter handed the router, and the
receive tests feed the controller an envelope the test itself constructed. Both
can pass while the two sides disagree, because nothing forces the bytes and
addresses one side PRODUCES to be the ones the other side ACCEPTS.

They also run against `CrossChainControllerDAOMock`, whose `hasPermission` is a
settable mapping. That proves the controller CALLS the right permission checks,
but never that a real `PermissionManager` grant makes them pass or that a revoke
makes them fail. Every suite here goes through a real OSx `DAO`, except
`CrossChainRoundTrip.t.sol`, which stays on the mock.

## Layout

| File | What it covers |
|---|---|
| `Base.sol` | The two-stack (optionally three-stack) fixture every suite inherits, except `CrossChainRoundTrip.t.sol`, which stands up its own equivalent on the DAO mock |
| `HappyPath.t.sol` | Both directions, multi-action and value-bearing payloads, out-of-order delivery, multi-lane, fees |
| `Authorization.t.sol` | The lane, forward and receive gates against a real `PermissionManager`; a grant/revoke round trip; the pause/unpause split. Not covered here: `updateExecutor`, `updateMinFailedMessageGas`, `cancelMessage`, the upgrade gate; `retryMessage`'s gate is in `RetryAndFailures.t.sol` |
| `RetryAndFailures.t.sol` | Both recovery layers, and the ways a delivered payload can fail short of gas exhaustion (that is `GasLimits.t.sol`); also adapter-rotation and bridge-redelivery replays |
| `FeesAndOps.t.sol` | Native and ERC20 fee lanes, starvation, broken lanes, sweeping |
| `GasLimits.t.sol` | The three gas regimes, and the A/B proof that `minFailedMessageGas` is load-bearing |
| `Reentrancy.t.sol` | What an authenticated payload can and cannot do mid-execution; legitimate multi-hop chaining |
| `ReplayAndIdentity.t.sol` | Transaction identity, and replaying a message where it does not belong — across chains, lanes and controllers |
| `fork/CCIPRealRouter.t.sol` | The stack against REAL production CCIP Router bytecode on mainnet and Base |
| `CrossChainRoundTrip.t.sol` | A round trip against the DAO mock |

## Running

```bash
make test-e2e        # the end-to-end suites
make test-e2e-fork   # needs MAINNET_RPC_URL + BASE_RPC_URL
```

`--match-path 'test/e2e/*.t.sol'` does not exclude `fork/` — the glob crosses
directory separators — so `make test-e2e` and a plain `forge test` both select
the fork suite. It `vm.skip`s every test when the RPC endpoints are absent, which
is why CI is unaffected; with endpoints configured it will reach the network.
Note it falls back to `RPC_URL` when `MAINNET_RPC_URL` is unset.

## How CCIP is simulated

**In-process (default).** `CCIPRelayRouterMock` is a pair of routers modelling
both halves of a lane, asynchronously: `ccipSend` queues, and delivery is a
separate call through `CallWithExactGas` with the gas limit decoded from
`extraArgs` — verbatim what `Router.routeMessage` does. A failed delivery
returns `success = false` and stays queued rather than reverting, which is what
makes CCIP's FAILED-then-manually-executed semantics testable.

Both stacks live in one EVM with `block.chainid` flipped between phases, using
production chain ids and selectors. `block.chainid` is the only per-chain value
these contracts read — it stamps `Transaction.originChainId` on the way out and
backs the `INCORRECT_CHAIN_MISMATCH` guard on the way in — so flipping it makes
those checks real rather than cosmetic.

**Fork.** Two real forks. The origin uses the real `ccipSend`; delivery pranks a
real registered OffRamp, discovered from `Router.getOffRamps()`, into the real
`Router.routeMessage` — `onlyOffRamp`, real exact-gas semantics. That is the
highest fidelity available without the DON.

`test_fork_everyMappedSelectorIsALiveLane` is the reason the fork suite earns
its keep: `CCIPAdapter`'s chain-id/selector table is compiled in and cannot be
fixed without a redeploy, so a wrong entry is only discoverable against a live
Router. Its coverage is **pinned, not floored**: `_MAPPED_CHAIN_COUNT` and the
candidate pair list are hardcoded, so adding or removing a chain fails the test
until both are updated. That is deliberate — it forces a live-lane check on every
table change rather than silently skipping the new entry.

## Reading the tests

`success` returned from the `_deliver*` helpers is the BRIDGE-level outcome, not
the payload's:

- `success == true` with state `Delivered` — the payload failed and was caught.
  Recovery is `retryMessage`, which is permission-gated — though the setup grants
  `RETRY_MESSAGE_PERMISSION` to `ANY_ADDR`, so out of the box anyone can retry.
  These suites narrow it deliberately.
- `success == false` — the delivery itself failed and nothing *new* was stored.
  On a first arrival the state is still `None`; on redelivery of an
  already-recorded message the stored state is unchanged. CCIP leaves the message
  manually executable **by anyone**.
