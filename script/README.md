# Cross-chain deploy kit

Stands up a fresh OSx DAO with the cross-chain controller on one hub chain and N
satellite chains, in a single run. It will not finish a deployment that leaves a
DAO nobody can act as.

## The config

There is no zero-code entry point any more — the hub DAO is yours to create, so
there is always a script to write (see below). The kit's own JSON loader,
`_loadTopologyFromJson`, is still offered for the topology:

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
    "dao": { "subdomain": "my-dao", "metadata": "ipfs://…" },
    "governance": { "members": ["0x…", "0x…"], "minApprovals": 2 }
  },
  "satelliteCount": 1,
  "satellites": [ { /* same shape */ } ],
  "minFailedMessageGas": 45000
}
```

**Every key above is required on every chain, including the ones you do not use.**
The loader reads scalars one path at a time and does not probe for absence, so a
missing key fails with `path ".hub.multisigRepo" must return exactly one JSON
value` rather than defaulting. Write the zero address for `multisigRepo` and
`ccipFeeToken` when they do not apply, and give every chain a `governance` block
even where a hook installs something else — the roster is read before the hook
runs. All of these fail loudly before anything is broadcast.

Add a read grant for wherever you keep it — `fs_permissions` is per-project and
does not travel with this submodule:

```toml
fs_permissions = [{ access = "read", path = "./deploy" }]
```

## Anything else: one hook

```solidity
contract Deploy is CrossChainDeploy {
    function _loadTopology() internal override {
        _loadTopologyFromJson(vm.envString("DEPLOY_CONFIG"));   // or fill the fields yourself
    }

    function _configureHub() internal override {
        PluginRepo repo = PluginRepo(myVotingRepo);
        (address plugin,) = _installPlugin(hub, repo, repo.latestTag(), myInstallData());
        _addGovernor(hub, plugin);        // the kit verifies this can execute
    }

    // satellites: omit for the multisig default, or override _configureSatellite(i)
}
```

Available inside a hook: `_installPlugin`, `_publishRepo`, `_grantExecute`,
`_revokeExecute`, `_grantRoot`, `_revokeRoot`, `_addGovernor`, and
`_installMultisigGovernance` if you want the default on the hub too.

A hook that grants `EXECUTE` to a temporary helper **must revoke it**. Nothing
else will: `_assertGovernable` proves the declared governors *can* act, never
that nothing else can, and the handover only takes the permission back from the
deployer. Alchemix's Factory is the worked example — granted, called, revoked,
all before the hook returns.

DAO creation is not among them, deliberately. The kit has already created every
DAO by the time a hook runs, which is what makes "the deployer can act as this
DAO" structural rather than something you have to arrange.

`_addGovernor` takes plural declarations, and should. Real governance is often
several contracts — two staged processors plus an emergency Safe, say. A single
declaration aimed at the Safe would pass the check while a processor's grant had
silently failed, leaving a DAO that looks governed and cannot pass a proposal.

## What runs

| | | |
|---|---|---|
| 1 | forks | one per chain, chain id asserted after every switch |
| 2 | DAOs | plugin-less, so `DAOFactory` grants the deployer `EXECUTE` |
| 3 | controllers | one sweep, dedicated `Executor`, one pinned build |
| 4 | adapters + routing | hub-and-spoke, both directions |
| 5 | governance | your hook |
| 6 | handover | the deployer's `EXECUTE` revoked everywhere |

Governance is installed second to last, not first. Nothing earlier needs it — the
controller grants its permissions to the DAO, not to the governor — and a late
hook sees final controller, executor and adapter addresses, so it can grant
against them.

## What you cannot switch off

A hook may choose *how* something is done. It may never choose *whether* a safety
property holds. These live in non-virtual code:

| invariant | the failure it prevents |
|---|---|
| the signing account is the one that gets revoked | forge only fills the script sender from `--private-key`; under `--account`/`--ledger` it stays at its own default while a different wallet signs. The kit refuses to guess, then reads the `EXECUTE` grant back off each DAO before continuing. Guessing wrong means the handover revokes an address that holds nothing and the real signer keeps unconditional `EXECUTE` on every DAO, permanently |
| every DAO ends governable | the controller grants `MANAGE_CONTROLLER_CONFIG`, `CANCEL_MESSAGE`, `SWEEP`, `PAUSE`, `UNPAUSE`, `FORWARD_MESSAGE` and `UPGRADE_PLUGIN` to the DAO **and nobody else**. A DAO nothing can act as means a wrong lane, a stranded message, an unsendable veto and an upstream security fix are all permanently out of reach |
| a declared governor is neither `address(0)` nor the deployer | OSx reports a grant against the zero address, and the deployer's `EXECUTE` is revoked by the very next phase — either would let the governability proof pass on a DAO that ends up frozen |
| no roster entry is `address(0)` | `Addresslist` counts a zero toward the threshold without adding a signer, so `2`-of-`["0xAlice", "0x0"]` installs cleanly, reads as governed, and can never reach quorum |
| the executor is never the DAO | otherwise any inbound message clearing the adapter executes with full DAO authority |
| no controller holds a permission on its DAO | same, from the other side. Prevented by construction rather than checked: the setup is given `address(0)` for the executor slot, which is what makes it mint a dedicated one |
| every adapter trusts the remote CONTROLLER | read back off both adapters after routing. `trustedRemote` is constructor-only with no setter, so a lane wired to a DAO, or to the remote adapter instead of its controller, deploys quietly and then reverts every inbound message — and repair needs new adapters on both chains after the deployer's authority is gone |
| every adapter can map the chain ids it serves | asked of the deployed bytecode, not of the two hand-maintained lists that decide which adapter class to construct. A chain absent from the table gets an adapter that reverts `UNKNOWN_CHAIN_ID` on every send |
| the PSP never keeps `ROOT` | it needs `ROOT` for one transaction; longer is a second unconditional authority |
| every fork is the chain config claims | an adapter's trusted remote is fixed at construction, so a wrong RPC is permanent |
| adapters only after every controller exists | an adapter names the controller on the other side |
| one controller build across the deployment | each chain's repo has its own history; asking each for "latest" splits builds across a lane |
| `minFailedMessageGas != 0` | a zero reserve lets an out-of-gas payload revert delivery, leaving the message unreachable by both retry and cancel |

## Testing your deployment

Inherit `CrossChainDeployConformance` and point it at your own run:

```solidity
kit.selectHub();
assertConformant(kit.hubCfg(), PSP, deployer);
assertLaneWired(hub.controller, satelliteChainId, hub.adapter, satellite.adapter);
```

## Two things that will bite

**Signing.** Three ways in, in precedence order:

1. `PRIVATE_KEY` in the environment
2. `--account <keystore>` or `--ledger` — **also pass `--sender <that wallet's address>`**
3. `--private-key 0x…` on the command line

That `--sender` is not optional, and the kit will stop without it. Forge only
populates the script's own sender from `--private-key`; with `--account` or
`--ledger` it stays at foundry's default `0x1804c8AB…` while an entirely
different wallet signs every transaction. A kit that believed the default would
create DAOs owned by the real signer and then revoke `EXECUTE` from an address
that never had it — silently, with a success message — leaving the signing EOA
in permanent unconditional control of every DAO in the topology.

A keystore or hardware wallet is the better habit — a plaintext key in the
environment is readable by anything running as you, and leaves no record of which
key signed. But CI usually has a secret rather than a keystore, and refusing that
only pushes people to `--private-key`, where the key is visible in `ps` to every
user on the box.

The sharp edge is the precedence: a stale `PRIVATE_KEY` in your shell silently
beats `--account`. The kit cannot see which flags forge got, so it prints the
resolved signer and its source before broadcasting anything. Read that line.

**A failed run is repeated, not resumed.** `forge script --resume` replays from
`broadcast/`; otherwise start over. Starting over abandons the DAOs the failed
run created — and their **ENS subdomains, which are claimed once per registrar
and never released**. Bump `dao.subdomain` before re-running or `createDao`
reverts `AlreadyRegistered`.

## Out of scope

The kit creates every DAO, which is what makes "the deployer can act as this DAO"
structural rather than something a consumer has to arrange. So it cannot deploy
onto an **existing, already-governed** hub DAO: there is no bootstrap `EXECUTE`
to use, and every phase would have to emit governance actions for a vote instead
of executing them. That is a different tool.
