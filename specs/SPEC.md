### Architecture

The architecture is deliberately flexible: adapters are swappable, because the
`CrossChainController` is the single entry point for both sending and receiving messages,
and it is where all configuration lives. Adapters hold no routing state of their own -
swapping in a new bridge means deploying an adapter and updating the controller's config.

Routing works off a per-destination config. When the controller is asked to forward a
message, it is given a `destinationId` which is the standard chain id always. The config stored under that id holds two
addresses:

- `localAdapter` - the adapter on this chain that the controller hands the message to.
- `remoteAdapter` - the address on the destination chain that the message is addressed
  to.

On the destination chain, the arriving message is delivered to that remote adapter, which
in turn forwards it to the `CrossChainController` there. The controller is therefore both
ends of every route: the sender's entry point and the receiver's final destination.

### Permissions

Only one adapter is configured per destination chain id at any given time, so that single
bridge is a single point of failure. This demands care when assigning permissions.

**The threat.** Normally L1 governance is what updates the L2 controller's configuration,
and those updates travel over the bridge. If the bridge is compromised - say the L2
`CCIPRouter` - the attacker can inject an arbitrary message and shape it so the L2
`CrossChainController` believes it originated from legitimate L1 governance. The
controller cannot tell the difference: it trusts the bridge to have authenticated the
sender. An attacker with that capability could, for example, rewrite sensitive
configuration on the L2 controller.

**What makes it exploitable.** The controller routes every inbound payload to its
configured `Executor` for final execution. So whatever permissions that executor holds are
effectively reachable by anyone who controls the bridge. If the executor can call the
controller's own sensitive functions, a compromised bridge inherits that power.

This is precisely why the executor is kept separate from the L2 DAO. Pointing the
controller's `executor` at the L2 DAO and granting that DAO sensitive permissions on the
controller reproduces the same exposure - the identity of the executor is irrelevant, only
its permissions matter.

**Recommended configuration.** Set the controller's `executor` to a dedicated
`Executor`, and grant that executor **no permissions on the `CrossChainController`
itself**. Sensitive configuration is then changed only by the L2 DAO acting directly, off
the cross-chain path - so a compromised bridge cannot reach it.

**The alternative.** If you consider bridge compromise a negligible risk, you can avoid having a dedicated `Executor`, but instead set `executor = dao` on the controller and give those sensitive permissions to the DAO. 

> Note that `DAO` is still required on both chains due to the fact that `CrossChainController` is an OSx plugin.

> These options are not mutually exclusive: the L2 controller's sensitive functions can be
> made callable by both the `Executor` (over the cross-chain path) and the L2 DAO. That
> keeps L1 governance in control by default while leaving the L2 DAO able to act
> immediately when speed matters - at the cost of accepting the bridge-compromise exposure
> described above.

### The Diagram

```mermaid
%%{init: {"themeVariables": {"fontSize": "18px"}}}%%
flowchart TB
  subgraph L1
    DAO[DAO]
    CCC1[CrossChainController]
    ADP1[CCIPAdapter]
    ROUTER1[CCIPRouter L1]
  end

  CCIP{{CCIP Network / DON}}

  subgraph L2
    ROUTER2[CCIPRouter L2]
    ADP2[CCIPAdapter L2]
    CCC2[CrossChainController]
    DAO2["DAO L2<br/>-<br/>updateConfig<br/>pause / unpause<br/>upgradeTo<br/>cancelMessage<br/>retryMessage<br/>sweep<br/>updateExecutor<br/>updateRetryCutoff"]
    EXEC[Executor]
  end

  DAO -->|1 . forwardMessage| CCC1
  CCC1 -.->|2 . sendMessage<br/>DELEGATECALL| ADP1
  ADP1 -->|3 . ccipSend| ROUTER1
  ROUTER1 -->|4| CCIP
  CCIP -->|5| ROUTER2
  ROUTER2 -->|6 . ccipReceive| ADP2
  ADP2 -->|7 . receiveMessage| CCC2
  CCC2 -->|8 . execute| EXEC
  DAO2 -.->|admin| CCC2
```

### Functions

#### `CrossChainController`

The message paths that move messages forward (`forwardMessage`, `receiveMessage`,
`retryMessage`) are all `whenNotPaused`. `cancelMessage` and the admin paths
deliberately are not, so an incident can be recovered from while the system is paused
(see the `pause()` row for why cancelling stays available).

| Function | Access | What it does |
|---|---|---|
| `forwardMessage(dstChainId, gasLimit, message)` | `FORWARD_MESSAGE_PERMISSION` | Outbound entry point. Builds a `Transaction` with the next nonce, ABI-encodes it, and `delegatecall`s the local adapter's `sendMessage`. The `delegatecall` is what makes the adapter code run **as the controller**: the bridge fee is paid straight from the controller's own balance so adapters never custody funds, and the bridge attributes the message to the controller's address rather than the adapter's - which is why the far side trusts the remote *controller* as sender, and why an adapter may be swapped without changing who the destination trusts. Returns `txId`. |
| `quoteFee(dstChainId, gasLimit, message)` | view | Quotes the exact bytes `forwardMessage` would send, returning `(feeToken, fee, available)` - the last being this contract's current balance of that token. Use it to check funding before sending. |
| `receiveMessage(messageId, encodedTx, originChainId)` | `onlyLocalAdapter(originChainId)` | Inbound entry point. Decodes the transaction, re-verifies both chain ids against the payload, rejects replays. Success → `Executed`; revert → `Delivered` and retryable. Never reverts on a bad payload. |
| `executeActions(txId, payload)` | self only | Decodes `Action[]` and calls the executor. External purely so `receiveMessage` can wrap it in `try/catch`; decoding lives here so malformed payloads are captured rather than bouncing the bridge delivery. |
| `retryMessage(encodedTx)` | `RETRY_MESSAGE_PERMISSION` | Re-runs a `Delivered` message. Does **not** catch - if it fails again the whole call reverts and the message stays `Delivered`, so it can be retried later. |
| `cancelMessage(encodedTx)` | `CANCEL_MESSAGE_PERMISSION` | Burns a `Delivered` message. The `txId` moves to `Cancelled` and never back to `None`, so it can never be re-delivered or retried. |
| `updateConfig(chainIds, configs)` | `MANAGE_CONTROLLER_CONFIG_PERMISSION` | Sets or clears lanes, keyed by **remote** chain id. A lane must be fully set or fully cleared; chain id `0` is rejected as it marks "unset". All-or-nothing because the two halves serve opposite directions and a half-set lane is broken either way: `localAdapter` alone can send but authenticates nothing inbound, `remoteAdapter` alone accepts inbound but cannot send. Requiring both keeps "is this lane configured?" a single unambiguous fact. Clearing both is likewise the only clean way to retire a lane: it shuts the route down in both directions at once, so no outbound message can be sent to a chain that is no longer trusted and no inbound message from it is still accepted. |
| `updateExecutor(executor)` | `MANAGE_CONTROLLER_CONFIG_PERMISSION` | Repoints the controller at a different execution target. Must have code. The call validates **only** that the target has code - it cannot check that the new executor actually authorizes the controller to call `execute`. Repointing to a target that does not is the easiest way to silently brick the receive path; see the executor runbook below. |
| `updateRetryCutoff(originChainId, cutoff)` | `MANAGE_CONTROLLER_CONFIG_PERMISSION` | Blocks every `Delivered` message from `originChainId` that arrived at or before `cutoff` from ever being retried. Does in one call what `cancelMessage` does one message at a time. The cutoff must be strictly increasing and cannot be set past `block.timestamp`, so it is aimed at messages that have already arrived - it cannot pre-emptively block messages that arrive with a later timestamp. One edge exists: the blocking check is inclusive (`bridgedAt <= cutoff`), so a message delivered in the same second as a `cutoff = block.timestamp` update also falls under it, even though it arrived after the update. The error direction is conservative (a fresh failed message becomes non-retryable, and can only be blocked, never executed, by this), and the decommissioning runbook clears the lane before setting the cutoff, so no such delivery can slip in between. To stop in-flight messages, call `updateConfig` to clear the lane's adapters: with no `localAdapter` registered for that chain id, `receiveMessage` no longer authenticates the incoming call and the message is rejected on arrival. |
| `pause()` / `unpause()` | `PAUSE_PERMISSION` / `UNPAUSE_PERMISSION` | Halts and resumes the three message paths that move messages forward: `forwardMessage`, `receiveMessage` and `retryMessage`. The two directions carry **separate permissions**: a guardian can be trusted to freeze without being trusted to reopen, so a compromised guardian key cannot unpause mid-incident while a malicious message is still pending - the setup grants the guardian `PAUSE_PERMISSION` only, and `UNPAUSE_PERMISSION` stays with the DAO. `cancelMessage` is deliberately **not** gated - pausing exists to stop bad messages from executing, and cancelling is how you stop a pending one for good. If it were gated, the only way to cancel a pending message would be to unpause first, which reopens the paths you just closed. |
| `sweep(token, to, amount)` | `SWEEP_PERMISSION` | Moves pre-funded fee assets out, typically back to the DAO. `address(0)` means native currency. |

#### `IBaseAdapter` / `BaseAdapter`

The contract every transport must satisfy. The split in execution context is the key
detail: `sendMessage` is reached only by `delegatecall` from the controller, so it runs
against the controller's storage and balance, while the receive path runs as the adapter
itself so it can read its own trusted-remote map.

| Function | Access | What it does |
|---|---|---|
| `sendMessage(receiver, dstChainId, gasLimit, message)` | `onlyDelegatecallFromController` | Sends over the bridge. Because it is delegatecalled, the fee comes from the **controller's** balance and the bridge attributes the message to the **controller's** address. Returns `(messageId, fee)`. |
| `toNativeChainId(chainId)` / `fromNativeChainId(chainId)` | view | Translates between standard EVM chain ids and the bridge's own encoding. Both **must revert** on unmapped ids - returning `0` would silently address the wrong lane. |
| `_forwardMessage(messageId, payload, originChainId)` | internal | Hands an authenticated inbound message to the controller via a plain `CALL`. Guarded by an `address(this) == _selfAddress` check, so it can never run under `delegatecall`. |

#### `Executor`

| Function | Access | What it does |
|---|---|---|
| `execute(callId, actions, allowFailureMap)` | `onlyOwner` | Runs the action batch. The OSx commons `Executor` is permissionless by design; this variant gates it behind `Ownable` so it can be deployed standalone with the controller as owner. All other behaviour - bounds check, failure map, reentrancy guard, `Executed` event - is unchanged. |
| `receive()` | - | Accepts plain ETH transfers so the executor can be pre-funded for value-bearing actions (see below). The commons `Executor` has no payable path, so without this the contract could not be topped up at all. |

> The controller always calls `execute` with an `allowFailureMap` of `0`, so every action
> in an inbound payload must succeed or the whole batch is captured as `Delivered` for
> retry.

**Value-bearing actions.** The messaging layer moves instructions, never funds: only the
encoded `Action[]` bytes cross the bridge, and the entire receive path - the adapter's
bridge callback, `receiveMessage`, `executeActions`, `execute` - is non-payable. An
action may still target a payable function with `value > 0`: `payable` only governs
whether a call can *carry* `msg.value`, not whether a contract can *spend* what it
already holds, so the executor pays `action.value` out of its own balance at execution
time. This is why `receive()` exists - the executor is topped up in advance and the cross-chain action spends from that
balance. Funding is a separate, prior operation; it is never part of the message. If the
balance is short, the action fails, the zero `allowFailureMap` reverts the whole batch,
and the message is captured as `Delivered` - fund the executor and `retryMessage`.

### Deployment

From the Aragon OSx point of view, `CrossChainController` is a **plugin** (see the [plugin docs](https://docs.aragon.org/osx-contracts/1.x/core/plugins/)). Every plugin installation goes through the singleton `PluginSetupProcessor`, which requires the plugin to have its own `PluginRepo` - the registry that holds all of its published versions. A DAO installs a specific version by pointing at that repo.

A `PluginRepo` does not hold the plugin code itself. It holds a `PluginSetup` per version - here `CrossChainControllerSetup` - which acts as the plugin's installer: it deploys the plugin instance and declares the permissions the DAO must grant or revoke. Keeping the setup separate lets every version ship its own installation logic, which matters because these steps are rarely trivial.

Steps to install: Let's assume L1 is mainnet and L2 is base.

Both controllers must exist before either adapter can be deployed: an adapter takes
its trusted remote in the constructor and has no setter, and that trusted remote is
the *other* chain's controller.

1. Install `CrossChainController` on L1. (CCC_L1)
2. Install `CrossChainController` on L2. (CCC_L2)
3. On L1, deploy `CCIPAdapter` (ADAPTER_L1) with:
   - `_crosschainController` = **CCC_L1** - the LOCAL controller. The send path is
     `delegatecall`ed from it, and `onlyDelegatecallFromController` compares
     `address(this)` against this value, so a remote address here makes every send
     revert with `SEND_PATH_NOT_DELEGATECALLED`.
   - `_ccipRouter` = the CCIP Router on L1.
   - `_feeToken` = the fee token, or `address(0)` for native.
   - `_trustedRemoteConfigs` = `[{ standardChainId: <L2 chain id>, trustedRemote: CCC_L2 }]`
     - the remote **controller**, never the remote adapter: the send path is a
     `delegatecall`, so the bridge attributes inbound messages to the controller.
4. On L2, deploy `CCIPAdapter` (ADAPTER_L2) with the mirror image:
   `_crosschainController` = **CCC_L2**, `_ccipRouter` = the CCIP Router on L2,
   `_feeToken` as above, and
   `_trustedRemoteConfigs` = `[{ standardChainId: <L1 chain id>, trustedRemote: CCC_L1 }]`.
5. On L1, call `updateConfig` on CCC_L1 with `_chainIds = [<L2 chain id>]` and
   `_configs = [{ localAdapter: ADAPTER_L1, remoteAdapter: ADAPTER_L2 }]`.
6. On L2, call `updateConfig` on CCC_L2 with `_chainIds = [<L1 chain id>]` and
   `_configs = [{ localAdapter: ADAPTER_L2, remoteAdapter: ADAPTER_L1 }]`.

Note the asymmetry in what each side stores: `updateConfig` records the remote
**adapter** (the bridge-level receiver), while the adapter constructor records the
remote **controller** (the authenticated sender). Swapping them is the most common
wiring mistake - inbound messages are then rejected with `REMOTE_NOT_TRUSTED`.

### Decommissioning a chain (runbook)

Clearing a lane does **not** block that chain's delivered backlog. `updateConfig` and
`updateRetryCutoff` guard two different doors, and retiring a chain requires closing
both:

- `updateConfig` (clear) guards **arrival**: with no `localAdapter` registered,
  `receiveMessage` no longer authenticates the incoming call, so both in-flight and
  future messages from that chain are rejected on delivery.
- `updateRetryCutoff` guards the **backlog**: `retryMessage` never checks whether the
  lane still exists, so any message from that chain already sitting in `Delivered`
  remains retryable after the lane is cleared. Since every delivered message has
  `bridgedAt <= block.timestamp`, a cutoff of `block.timestamp` always covers the
  entire existing backlog in one call.

To stop trusting a chain, do both in one proposal:

1. `updateConfig([chainId], [all-zero ChainConfig])` - no further messages from that
   chain arrive.
2. `updateRetryCutoff(chainId, block.timestamp)` - nothing it already delivered can
   ever be retried.

Doing only step 1 leaves the delivered backlog executable by any
`RETRY_MESSAGE_PERMISSION` holder; doing only step 2 leaves the door open for new
deliveries.

### Repointing the executor (runbook)

When calling `updateExecutor`, make sure the new executor **already allows the
controller to call `execute` on it** at the moment of the switch. `updateExecutor`
itself only checks that the target has code; it cannot verify authorization, because
every `IExecutor` implementation gates `execute` its own way:

- `executor = dao` - `DAO.execute` requires the caller to hold `EXECUTE_PERMISSION`
  on the DAO. The setup grants this to the controller only at install time, and only
  when it was *installed* with `executor = dao`. Switching to the DAO later does
  **not** grant it.
- dedicated `Executor` - `execute` is `onlyOwner`. The setup wires ownership only for
  the executor it deploys itself. A new `Executor` deployed later is owned by its
  deployer until someone calls `transferOwnership(controller)`.

**Why this bricks the receive path.** The misconfiguring proposal itself succeeds -
the target has code, `ExecutorUpdated` is emitted, nothing looks wrong. But from that
moment every inbound message reaches `IExecutor(executor).execute(...)` and reverts
(`Unauthorized` / not-owner). The revert is swallowed by `receiveMessage`'s
`try/catch`, so each message quietly lands as `Delivered` instead of executing. 
Recovery needs a second governance round-trip (grant the
permission / transfer ownership) plus a `retryMessage` per stuck message; if the
controller sits on a chain whose only governance path is the cross-chain lane that
was just broken, that round-trip may not even be possible over the lane itself.

An `updateExecutor` proposal must therefore bundle, in this order:

1. The authorization on the new executor - grant the controller
   `EXECUTE_PERMISSION` on the DAO when repointing to the DAO, or
   `transferOwnership(controller)` when repointing to a dedicated `Executor`.
2. The `updateExecutor` call itself.
3. Optionally, revoke the controller's authorization on the *old* executor
   (revoke `EXECUTE_PERMISSION` / transfer the old `Executor`'s ownership away), so
   the abandoned target does not keep a live execution path.

### Uninstallation

Uninstalling the plugin revokes permissions - nothing more. `prepareUninstallation`
returns the revoke list, but a setup contract cannot call into the plugin, so the
controller's own state survives uninstallation untouched: `chainToAdapter` keeps its
lanes, and `receiveMessage` is not gated by a DAO permission - it is guarded only by
that lane config. The result is that an "uninstalled" controller **keeps accepting
inbound messages** from its configured remote chains and keeps executing them on its
executor.

Whether that is dangerous depends on the executor. When `executor = dao`, the
uninstall revokes the controller's `EXECUTE_PERMISSION` on the DAO, so inbound
messages can no longer do anything. But with a dedicated `Executor`, any permissions
the DAO granted that executor on *other* contracts remain reachable: remote
governance - or a compromised bridge - retains exactly that power after the plugin is
"gone".

An uninstall proposal must therefore not consist of the uninstallation alone. Bundle,
in this order:

1. `updateConfig` clearing **every** configured lane (all-zero `ChainConfig` per
   chain id) - shuts the route down in both directions; inbound messages fail
   authentication on arrival. Per the decommissioning runbook above, pair each
   cleared lane with `updateRetryCutoff(chainId, block.timestamp)`: the uninstall
   only revokes the permissions the setup granted, so a `RETRY_MESSAGE_PERMISSION`
   holder the DAO added separately could otherwise still execute the delivered
   backlog.
2. Optionally `pause()` - belt-and-braces freeze of the message paths; there is no
   reason to leave an abandoned controller unpaused.
3. `sweep` of any pre-funded fee assets back to the DAO.
4. Revoke any permissions the DAO granted the dedicated `Executor` elsewhere.
5. The uninstallation itself.

Steps 1-3 require the permissions being revoked in step 5, so they cannot be done
afterwards - a controller uninstalled first can never be cleaned up.