# Cross-chain deploy kit

Stands up a fresh OSx DAO with the cross-chain controller on one hub chain and N
satellite chains, in a single run. It will not finish a deployment that leaves a
DAO nobody can act as.

## The common case: no Solidity

A DAO governed by a multisig on every chain needs a config file and nothing else.

```bash
DEPLOY_CONFIG=deploy/my-dao.json \
  forge script StandardDeploy --broadcast --account <keystore>
```

```jsonc
{
  "hub": {
    "chainId": 1,
    "rpc": "mainnet",                    // a foundry.toml alias or a URL
    "daoFactory": "0x…", "psp": "0x…", "pluginRepoFactory": "0x…",
    "crossChainRepo": "0x…",             // the CrossChainController PluginRepo
    "multisigRepo": "0x…",               // only if you use the default governance
    "ccipRouter": "0x…", "ccipFeeToken": "",   // empty = the chain's native currency
    "dao": { "subdomain": "my-dao", "metadata": "ipfs://…" },
    "governance": { "members": ["0x…", "0x…"], "minApprovals": 2 }
  },
  "satelliteCount": 1,
  "satellites": [ { /* same shape */ } ],
  "minFailedMessageGas": 45000
}
```

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
`_grantRoot`, `_revokeRoot`, `_addGovernor`, and `_installMultisigGovernance` if
you want the default on the hub too.

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
| every DAO ends governable | the controller grants `MANAGE_CONTROLLER_CONFIG`, `CANCEL_MESSAGE`, `SWEEP`, `PAUSE`, `UNPAUSE` and `UPGRADE_PLUGIN` to the DAO **and nobody else**. A DAO nothing can act as means a wrong lane, a stranded message and an upstream security fix are permanently out of reach |
| the executor is never the DAO | otherwise any inbound message clearing the adapter executes with full DAO authority |
| no controller holds a permission on its DAO | same, checked from the other side |
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
2. `--account <keystore>` or `--ledger`
3. `--private-key 0x…` on the command line

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
