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
makes them fail. Everything here goes through a real OSx `DAO`.

## Layout

| File | What it covers |
|---|---|
| `Base.sol` | The two-stack (optionally three-stack) fixture every suite inherits |
| `HappyPath.t.sol` | Both directions, multi-action and value-bearing payloads, out-of-order delivery, multi-lane, fees |
| `Authorization.t.sol` | Every gate, against a real `PermissionManager`; grant/revoke round trips; the pause/unpause split |
| `RetryAndFailures.t.sol` | Both recovery layers, and every way a delivered payload can fail |
| `FeesAndOps.t.sol` | Native and ERC20 fee lanes, starvation, broken lanes, sweeping |
| `GasLimits.t.sol` | The three gas regimes, and the A/B proof that `minFailedMessageGas` is load-bearing |
| `Reentrancy.t.sol` | What an authenticated payload can and cannot do mid-execution; legitimate multi-hop chaining |
| `ReplayAndIdentity.t.sol` | Transaction identity, and every way a message might be replayed where it does not belong |
| `fork/CCIPRealRouter.t.sol` | The stack against REAL production CCIP Router bytecode on mainnet and Base |
| `CrossChainRoundTrip.t.sol` | A round trip against the DAO mock |

## Running

```bash
make test-e2e        # in-process, no RPC needed
make test-e2e-fork   # needs MAINNET_RPC_URL + BASE_RPC_URL
```

The fork suite `vm.skip`s every test when the RPC endpoints are absent, so a
plain `forge test` (and CI) is unaffected by it.

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
Router. It is written as a sweep over candidate chain ids rather than a
hardcoded list, so it keeps covering the whole table as chains are added to or
removed from `ChainIds`.

## Reading the tests

`success` returned from the `_deliver*` helpers is the BRIDGE-level outcome, not
the payload's:

- `success == true` with state `Delivered` — the payload failed and was caught.
  Recovery is `retryMessage`, which is **permissioned**.
- `success == false` with state `None` — the delivery itself failed and nothing
  was stored. CCIP leaves the message manually executable **by anyone**.
