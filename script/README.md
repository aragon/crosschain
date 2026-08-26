# Cross-chain deploy kit

Gives a hub DAO **you create** the whole cross-chain stack — the controller on
the hub and on N satellite chains, satellite DAOs, the chain id registries, the CCIP adapters and the
routing — in two calls. It will not finish a deployment that leaves a DAO
nobody can act as, and it will not start one against a hub DAO it cannot act
as.

## The shape of a deployment

```solidity
contract Deploy is CrossChainDeploy {
    function _loadTopology() internal override {
        _loadTopologyFromJson(vm.envString("DEPLOY_CONFIG"));   // or fill the fields yourself
    }

    function run() public {
        initCrosschain(vm.envOr("PRIVATE_KEY", uint256(0)));

        // 1. Yours: create the hub DAO — on the fork initCrosschain() left
        //    selected, with the deployer holding EXECUTE on it. A bare
        //    DAOFactory.createDao with no plugins is the simplest way to get
        //    both.
        _broadcast();
        hub.dao = address(myCreateDao());
        vm.stopBroadcast();

        // 2. The kit: the hub controller prepared, every satellite built end
        //    to end, then the prepared install applied onto YOUR dao and the
        //    hub's lanes wired.
        setUpCrosschain();
        installCrosschain();

        // 3. Yours again: hub governance, with the stack's final controller,
        //    executor and adapter addresses in view.
        _broadcast();
        (address plugin,) = _installPlugin(hub, myVotingRepo, myTag, myInstallData());
        vm.stopBroadcast();
        _addGovernor(hub, plugin);          // the kit verifies this can execute

        // 4. The last act of the deployer's authority: prove the declared
        //    governors can act, then revoke the deployer's own EXECUTE.
        _handOverHub();
    }

    // satellites: omit for the multisig default, or override _configureSatellite(i)
}
```

Available between and after the two kit calls: `_installPlugin`, `_publishRepo`,
`_grantExecute`, `_revokeExecute`, `_grantRoot`, `_revokeRoot`, `_addGovernor`,
`_installMultisigGovernance` if you want the kit's multisig on the hub too, and
`_handOverHub` for the final revoke.

A hook or script section that grants `EXECUTE` to a temporary helper **must
revoke it**. Nothing else will: `_assertGovernable` proves the declared
governors *can* act, never that nothing else can, and the handovers only take
the permission back from the deployer. Alchemix's Factory is the worked
example — granted, called, revoked, all before the kit is called.

`_addGovernor` takes plural declarations, and should. Real governance is often
several contracts — two staged processors plus an emergency Safe, say. A single
declaration aimed at the Safe would pass the check while a processor's grant had
silently failed, leaving a DAO that looks governed and cannot pass a proposal.

## What you owe the kit

The kit used to create every DAO itself, which made "the deployer can act as
this DAO" structural. On the hub that guarantee is gone, so it is **checked** —
at the top of `setUpCrosschain()`, again at `installCrosschain()` — and a
consumer owes the kit exactly this:

1. **Create the hub DAO after `initCrosschain()`**, on the fork it leaves
   selected. A DAO created anywhere else is a DAO on the wrong chain, and the
   kit refuses it as codeless.
2. **Hold `EXECUTE` on it** as the deployer, until `installCrosschain()` has
   run. `DAOFactory.createDao` with an empty plugin list grants the caller
   exactly this.
3. **The DAO must hold `ROOT` on itself.** The kit installs by executing
   grants AS the DAO, which OSx gates on ROOT. `DAOFactory` DAOs always
   qualify; anything hand-rolled is checked rather than trusted.
4. **Call the kit before revoking anything.** Both entry points re-check; a
   revoked deployer is refused in a sentence rather than deep inside
   `DAO.execute`.
5. **Revoke afterwards with `_handOverHub()`** — not bare-handed. It proves the
   declared governors can act first, which is the difference between a
   handover and a frozen DAO.

## What runs

| | `setUpCrosschain()` | |
|---|---|---|
| 1 | preconditions | the four obligations above, plus a non-empty topology, checked BEFORE anything irreversible |
| 2 | hub controller | prepared through the PSP — permissionless, so satellite adapters can bake its address in |
| 3 | satellite DAOs | plugin-less, so `DAOFactory` grants the deployer `EXECUTE` |
| 4 | satellite controllers | one sweep, dedicated `Executor`, one build pinned on the hub |
| 5 | chain id registries, adapters + satellite routing | one registry per chain, owned by that chain's DAO and seeded with the lanes it resolves; then hub-and-spoke adapters, trusted remotes verified on both sides |
| 6 | satellite governance | the multisig default, or your hook — see [Satellite governance](#satellite-governance) |
| 7 | satellite handover | the deployer's `EXECUTE` revoked on every DAO the kit created |

| | `installCrosschain()` | |
|---|---|---|
| 1 | preconditions | re-checked; a second install refused by name |
| 2 | apply | the prepared install lands on YOUR dao: three actions through `DAO.execute`, `ROOT` lent to the PSP for one transaction |
| 3 | hub routing | every lane written, then read back off the controller |

Hub governance runs after both, not first. Nothing earlier needs it — the
controller grants its permissions to the DAO, not to the governor — and a late
install sees final controller, executor and adapter addresses, so it can grant
against them.

## What you cannot switch off

A hook may choose *how* something is done. It may never choose *whether* a safety
property holds. These live in non-virtual code:

| invariant | the failure it prevents |
|---|---|
| the signing account is the one that acts and gets revoked | forge only fills the script sender from `--private-key`; under `--account`/`--ledger` it stays at its own default while a different wallet signs. The kit refuses to guess, then reads the `EXECUTE` grant back off each DAO before continuing. Guessing wrong means the handover revokes an address that holds nothing and the real signer keeps unconditional `EXECUTE`, permanently |
| the hub DAO is actionable before anything burns | `setUpCrosschain()` hands satellites to their governance and claims ENS subdomains, which are never released. A typo'd `hub.dao` discovered at install time would come after all of that is unrecoverable |
| every **satellite** ends governable | the controller grants `MANAGE_CONTROLLER_CONFIG`, `CANCEL_MESSAGE`, `SWEEP`, `PAUSE`, `UNPAUSE`, `FORWARD_MESSAGE` and `UPGRADE_PLUGIN` to the DAO **and nobody else**. A DAO nothing can act as means a wrong lane, a stranded message, an unsendable veto and an upstream security fix are all permanently out of reach |
| the deployer's `EXECUTE` is revoked on every DAO **the kit created** | the deploying key must not keep unconditional authority over a live satellite. **The kit never revokes on the hub** — that authority is the consumer's working capital for governance still to come, and taking it is the consumer's own last step, via `_handOverHub()`, which runs the same governability proof the satellite handover does |
| a declared governor is neither `address(0)` nor the deployer | OSx reports a grant against the zero address, and the deployer's `EXECUTE` is destined for revocation — either would let the governability proof pass on a DAO that ends up frozen |
| no roster entry is `address(0)` | `Addresslist` counts a zero toward the threshold without adding a signer, so `2`-of-`["0xAlice", "0x0"]` installs cleanly, reads as governed, and can never reach quorum |
| the executor is never the DAO | otherwise any inbound message clearing the adapter executes with full DAO authority |
| no controller holds a permission on its DAO | same, from the other side. Prevented by construction rather than checked: the setup is given `address(0)` for the executor slot, which is what makes it mint a dedicated one |
| every adapter trusts the remote CONTROLLER | read back off both adapters after deployment. `trustedRemote` is constructor-only with no setter, so a lane wired to a DAO, or to the remote adapter instead of its controller, deploys quietly and then reverts every inbound message — and repair needs new adapters on both chains |
| every adapter can map the chain ids it serves | asked of the registry the deployed adapter is actually bound to, not of the config that was meant to seed it. A missing selector, or a pair written to the wrong chain's registry, gets an adapter that reverts `UNKNOWN_CHAIN_ID` on every send over that lane. This proves a lane resolves, **not** that it resolves to the right chain — a wrong but non-zero selector passes |
| every DAO can manage its own chain id registry | the registry is granted to the DAO, never to the deploying key. Without the grant, adding a chain later means replacing adapters on both sides; with it granted to the deployer instead, the handover would leave behind an authority that can repoint a live lane |
| the hub's lanes are read back after routing | `_routeHub` writes controller storage; the check reads `chainToAdapter` back rather than trusting the write, because adapter-side reads say nothing about what the controller learned |
| the PSP never keeps `ROOT` | it needs `ROOT` for one transaction; longer is a second unconditional authority |
| every fork is the chain config claims | an adapter's trusted remote is fixed at construction, so a wrong RPC is permanent |
| adapters only after every controller exists | an adapter names the controller on the other side |
| registries before adapters | an adapter takes its registry as a constructor argument and has no setter |
| one controller build across the deployment | resolved as "latest" on the hub — always the first prepare — then demanded everywhere; asking each chain's repo independently splits builds across a lane |
| `minFailedMessageGas != 0`, checked at prepare | the value is baked into the proxy's `initialize` when it is prepared; a zero reserve lets an out-of-gas payload revert delivery, leaving the message unreachable by both retry and cancel |

## Satellite governance

The default installs an Aragon Multisig on every satellite: it reads that
chain's `governance.members` and `governance.minApprovals`, installs from
`multisigRepo`, grants the plugin `EXECUTE` on the satellite DAO, and declares it
as the governor. An empty roster, a `minApprovals` of zero or above the roster
size, and any `address(0)` entry are all refused.

### A Safe instead

`_configureSatellite` is the hook. Override it, grant `EXECUTE` to the Safe, and
declare it:

```solidity
/// @dev One Safe per satellite chain, deployed and configured beforehand.
function _safeFor(uint256 _chainId) internal view returns (address);

function _configureSatellite(uint256 _i) internal override {
    address safe = _safeFor(satellites[_i].chainId);
    require(safe.code.length > 0, "no Safe at that address on this chain");

    _broadcast();
    _grantExecute(satellites[_i], safe);
    vm.stopBroadcast();

    _addGovernor(satellites[_i], safe);
}
```

Four things to get right:

1. **The Safe must already exist on that satellite chain, at that address.** The
   kit deploys DAOs, controllers and adapters, not Safes. Deploying through the
   same factory and salt on every chain lands on one address, but check
   `.code.length` on the fork rather than assuming — the hook runs with the
   satellite's fork already selected, so a plain `.code.length` reads the right
   chain.
2. **The grant must be unconditional.** `_assertGovernable` probes with empty
   calldata, so a `grantWithCondition` reads as absent and the run stops.
3. **Still give the chain a `governance` block.** The loader reads the roster
   before any hook runs. `multisigRepo` may be the zero address.
4. **Do not call `_select` yourself**, and do wrap `_grantExecute` in a
   broadcast — it acts as the DAO, so without one nothing is sent.

The kit still runs `_assertGovernable` immediately after your hook and again
inside `_revokeDeployer` just before the handover, so a Safe that cannot act
stops the run rather than stranding the chain. What it cannot check is whether
the Safe's threshold is reachable: it proves the address holds `EXECUTE`, not
that its owners can produce a signature. The roster guard covers that for the
multisig default; with a Safe, the owner set and threshold are yours to verify.

## The config

The kit's JSON loader, `_loadTopologyFromJson`, is offered for the topology —
or override `_loadTopology` and fill the same fields from config you already
have:

```jsonc
{
  "hub": {
    "chainId": 1,
    "rpc": "mainnet",                    // a foundry.toml alias or a URL
    "daoFactory": "0x…", "psp": "0x…", "pluginRepoFactory": "0x…",
    "crossChainRepo": "0x…",             // the CrossChainController PluginRepo
    "multisigRepo": "0x…",               // the zero address if you override _configureSatellite
    "ccipRouter": "0x…",
    "ccipFeeToken": "0x0000000000000000000000000000000000000000",  // zero = native currency
    "ccipChainSelector": 5009297550715157269,   // CCIP's own id for THIS chain
    "dao": { "subdomain": "my-dao", "metadata": "ipfs://…" },
    "governance": { "members": ["0x…", "0x…"], "minApprovals": 2 }
  },
  "satelliteCount": 1,
  "satellites": [ { /* same shape */ } ],
  "minFailedMessageGas": 45000
}
```

`ccipChainSelector` is CCIP's own id for the chain the block describes, not for
its counterpart. The kit seeds each chain's `ChainIdRegistry` with the selectors
of the chains it talks to, reading them from the other blocks — so the hub's
selector ends up in every satellite's registry, and vice versa.

Transcribe it from Chainlink's
[`chain-selectors` registry](https://github.com/smartcontractkit/chain-selectors/blob/main/selectors.yml);
`test/fixtures/chains.json` in this repo carries pre-verified values for 18 chains,
and the mainnet ones are cross-checked against a live Router by
`test_fork_everyMappedSelectorIsALiveLane`. Two transcription traps: selectors
exceed 2^53, so any JavaScript-based config tooling will silently mangle them
(`5009297550715157269` becomes `…157000`) — write them as a quoted string if
anything but `forge` touches your JSON; and the field is `ccipChainSelector` here
but `ccipSelector` in `chains.json`, so do not copy the key along with the value.

**Double-check the value, because the kit cannot.** Omit it and the loader stops
at `path ".hub.ccipChainSelector" must return exactly one JSON value`; write `0`
and `_requireChain` stops at `ccipChainSelector missing`; write something wider
than a `uint64` and it stops there too. All three are pre-flight, before anything
is broadcast. But a **wrong yet plausible** selector is not caught by anything:
`_requireMapsChain` proves a lane RESOLVES, never that it resolves to the right
chain. A typo naming another real chain deploys, hands over, and then sends
governance payloads to that chain — fee spent, message lost, no revert. Before
the registry this was impossible because the table was audited bytecode; it is
the price of making the table configurable. The repair is the same trade in the
other direction: one `setChainIdPair` through governance, rather than a
replacement adapter on both sides.

**Every key above is required on every chain, including the ones you do not use.**
The loader reads scalars one path at a time and does not probe for absence, so a
missing key fails with `path ".hub.multisigRepo" must return exactly one JSON
value` rather than defaulting. Write the zero address for `multisigRepo` and
`ccipFeeToken` when they do not apply, and give every chain a `governance` block
even where a hook installs something else — the roster is read before the hook
runs. All of these fail loudly before anything is broadcast. There is no
`hub.dao` key and never can be: the hub DAO does not exist yet when the topology
is read.

Add a read grant for wherever you keep it — `fs_permissions` is per-project and
does not travel with this submodule:

```toml
fs_permissions = [{ access = "read", path = "./deploy" }]
```

## Testing your deployment

Inherit `CrossChainDeployConformance` and point it at your own run:

```solidity
kit.selectHub();
assertHubConformant(hubDeployed, PSP);
assertLaneWired(hub.controller, satelliteChainId, hub.adapter, satellite.adapter);

kit.selectSatellite(0);
assertSatelliteConformant(satDeployed, PSP, deployer);
```

`assertHubConformant` deliberately asserts neither deployer-revoked nor
governability — those became the consumer's promises when hub governance left
the kit, so assert them in your own suite, after your `_handOverHub()`.

## Two things that will bite

**Signing.** Three ways in, in precedence order:

1. `PRIVATE_KEY` in the environment — pass `vm.envOr("PRIVATE_KEY", uint256(0))`
   to `initCrosschain`
2. `--account <keystore>` or `--ledger` — **also pass `--sender <that wallet's
   address>`**
3. `--private-key 0x…` on the command line

That `--sender` is not optional, and the kit will stop without it. Forge only
populates the script's own sender from `--private-key`; with `--account` or
`--ledger` it stays at foundry's default `0x1804c8AB…` while an entirely
different wallet signs every transaction. A kit that believed the default would
create DAOs owned by the real signer and then revoke `EXECUTE` from an address
that never had it — silently, with a success message — leaving the signing EOA
in permanent unconditional control of every satellite.

A keystore or hardware wallet is the better habit — a plaintext key in the
environment is readable by anything running as you, and leaves no record of which
key signed. But CI usually has a secret rather than a keystore, and refusing that
only pushes people to `--private-key`, where the key is visible in `ps` to every
user on the box.

The sharp edge is the precedence: a stale `PRIVATE_KEY` in your shell silently
beats `--account`. The kit cannot see which flags forge got, so it prints the
resolved signer and its source before broadcasting anything. Read that line.

**First, the case that almost certainly applies to you: nothing was broadcast.**
Both kit calls run inside ONE `forge script` invocation, and forge pre-simulates
every recorded transaction on every chain against real chain state *before*
sending anything on any chain, aborting the whole multi-chain run on the first
revert. So a **deterministic** failure — a bad config value, a `require` on a
JSON number, a precondition — leaves **zero transactions on every chain**, no
subdomain burned and nothing to recover. Fix the input and run again. Verified on
two anvils with a positive control; the run that reverts leaves `A=0 B=0`, the
same run without the revert leaves `A=1 B=1`.

Recovery below is for the narrow case the pre-flight cannot catch: chain state
that diverges *between* pre-flight and mining.

**A dead process between the two calls is NOT "just re-run the script".** The
prepared install lives in script storage and the kit writes no files, so a fresh
process knows nothing of it — re-invoking re-runs `setUpCrosschain()` from zero,
silently preparing a second controller and redeploying every satellite,
subdomain burn included. (In-process, a reverted `installCrosschain()` IS
harmless: the kit passes `allowFailureMap = 0`, so the failed apply is atomic on
chain and the pending prepare survives — the same call can be retried before the
process exits.) The real recovery paths, in order of preference:

1. **`forge script --resume`** — the apply calldata is already in `broadcast/`,
   and replaying it is exactly the retry the atomic revert made safe.

   **`--multi` is required and is easy to omit.** The kit broadcasts to more than
   one chain, so the artifact lives under `broadcast/multi/`, and a resume
   without `--multi` looks for a single-chain artifact and reports nothing to
   resume. You also still need the signer flags — `--resume` replays recorded
   calldata, it does not remember who signed:

   ```bash
   forge script script/Deploy.s.sol --resume --multi --private-key $PRIVATE_KEY
   ```

2. **A manual apply** built from the PSP's `InstallationPrepared` event: the
   plugin and version tag are in the event, `executor` is readable off the
   prepared proxy, and the permission set is deterministic in `(dao, plugin)`.

   Two steps are easy to miss, and the apply reverts without them. **The DAO must
   hold `ROOT` on itself and must grant `ROOT` to the PSP for the duration of the
   call** — `applyInstallation` writes permissions, which OSx gates on `ROOT`, and
   the kit's own `_applyController` bundles grant-PSP / apply / revoke-PSP into a
   single `DAO.execute` for exactly this reason. Rebuild that three-action bundle,
   do not call `applyInstallation` bare.

   Note also that an abandoned prepare **never expires**: `validatePreparedSetupId`
   only compares block numbers within its own `(dao, plugin)` pair, so an old
   prepare stays applicable indefinitely. If you prepared twice, be certain which
   one you are applying.

3. **A full restart with fresh subdomains.** ENS subdomains are claimed once per
   registrar and never released, so the failed run's DAOs and their names are
   abandoned, not reused — bump `dao.subdomain` or `createDao` reverts
   `AlreadyRegistered`.

The same subdomain rule applies to a failure inside `setUpCrosschain()` itself:
a re-run does not resume, it redeploys.

## Out of scope

The kit no longer refuses an existing hub DAO — it refuses one **it cannot act
as**. What it still cannot do is deploy onto a hub DAO whose `EXECUTE` is
already locked behind live governance: every phase executes as the DAO through
the deployer's grant, and emitting proposals for a vote instead is a different
tool.

One consequence of taking the DAO as an input is a check the kit cannot make:
OSx has no enumerable registry of installed plugins, so the kit cannot detect a
DAO that already carries *some other* `CrossChainController` from an earlier
life. It refuses to install the SAME prepared controller twice, but "this DAO
already has one of these under a different address" is undecidable on chain —
that is a consumer obligation, not a kit check.
