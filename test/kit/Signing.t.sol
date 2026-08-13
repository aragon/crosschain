// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { CrossChainDeploy } from "../../script/CrossChainDeploy.sol";

/// @notice Records the address that actually called it.
/// @dev The only way to observe the broadcaster. `msg.sender` inside a script's
///      own frame is the entry-point caller; the sender `vm.startBroadcast`
///      installs is visible only to a CALLEE. Comparing the two is the whole
///      point of this suite.
contract Echo {
    address public lastCaller;

    function ping() external {
        lastCaller = msg.sender;
    }
}

contract SigningProbe is CrossChainDeploy {
    function _loadTopology() internal override { }
    function _configureHub() internal override { }

    /// @dev The production path: no key, so forge's resolved sender signs.
    function probeForgeResolved() external {
        deployerKey = 0;
        _broadcast();
        vm.stopBroadcast();
    }

    function probeExplicitKey(uint256 _key) external {
        deployerKey = _key;
        _broadcast();
        vm.stopBroadcast();
    }

    function resolveWith(uint256 _key) external returns (address) {
        deployerKey = _key;
        return _resolveDeployer();
    }

    function foundryDefaultSender() external pure returns (address) {
        return FOUNDRY_DEFAULT_SENDER;
    }

    /// @dev Resolves the deployer, then broadcasts a real call and reports who
    ///      the callee saw. If those two differ, the handover revokes the wrong
    ///      account.
    function resolvedVersusActual(uint256 _key, Echo _echo) external returns (address resolved, address actual) {
        deployerKey = _key;
        resolved = _resolveDeployer();

        _broadcast();
        _echo.ping();
        vm.stopBroadcast();

        actual = _echo.lastCaller();
    }
}

/// @notice Both signing paths, and the seam a fork suite cannot reach.
/// @dev A fork suite always supplies a real key -- it needs a specific funded
///      address and must stay off `vm.setEnv`, which is process-global and races
///      concurrent tests. So the zero-key path, which is the one production
///      uses, is only reachable here.
contract SigningTest is Test {
    SigningProbe internal probe;
    Echo internal echo;

    function setUp() public {
        probe = new SigningProbe();
        echo = new Echo();
    }

    /// @notice `vm.startBroadcast(0)` reverts "private key cannot be 0", so a
    ///         zero key must branch to the no-argument form rather than being
    ///         passed through.
    function test_zeroKeyUsesForgeResolvedSender() public {
        probe.probeForgeResolved();
    }

    function test_explicitKeyBroadcastsWithIt() public {
        probe.probeExplicitKey(uint256(keccak256("signer")));
    }

    function test_explicitKeyResolvesThatKeysAddress() public {
        uint256 key = uint256(keccak256("signer"));
        assertEq(probe.resolveWith(key), vm.addr(key), "an explicit key addresses itself");
    }

    // -------------------------------------------------------------------------
    // The property that actually matters
    // -------------------------------------------------------------------------

    /// @notice The resolved deployer must be the account that really sends.
    /// @dev This is the assertion the suite was missing. It used to check
    ///      `_resolveDeployer() == address(this)` -- true by construction,
    ///      because a test calls the probe directly, and therefore true no
    ///      matter how badly the resolution was broken. It pinned the bug in
    ///      place rather than catching it.
    ///
    ///      Resolution only matters relative to who signs, so compare against a
    ///      callee's `msg.sender` under a live broadcast instead of against a
    ///      constant.
    function test_explicitKey_resolvedDeployerIsTheAccountThatSends() public {
        uint256 key = uint256(keccak256("signer"));
        (address resolved, address actual) = probe.resolvedVersusActual(key, echo);
        assertEq(resolved, actual, "resolved deployer is not the account that broadcast");
        assertEq(actual, vm.addr(key), "broadcast did not use the supplied key");
    }

    /// @notice With no key and no `--sender`, forge leaves the script sender at
    ///         its own default while a keystore or ledger wallet does the
    ///         signing. Guessing there is how an EOA keeps `EXECUTE` on every
    ///         DAO forever, so the kit must refuse instead.
    function test_zeroKeyRefusesForgesDefaultSender() public {
        vm.prank(probe.foundryDefaultSender());
        vm.expectRevert(
            bytes(
                "cannot resolve the signing address: under --account/--ledger forge leaves the script sender at its default, so the handover would revoke EXECUTE from the wrong account and the real signer would keep it. Pass --sender <the signing address> too, or set PRIVATE_KEY."
            )
        );
        probe.resolveWith(0);
    }

    /// @notice An explicit `--sender` is the documented repair, so it must work.
    function test_zeroKeyAcceptsAnExplicitSender() public {
        address operator = makeAddr("operator");
        vm.prank(operator);
        assertEq(probe.resolveWith(0), operator, "--sender should resolve to itself");
    }

    /// @notice Pins the constant to forge's own definition.
    /// @dev A hardcoded address that drifts from what forge actually uses would
    ///      silently disarm the guard above -- the check would compare against a
    ///      value nothing ever equals and pass every time.
    function test_foundryDefaultSenderMatchesItsDerivation() public view {
        assertEq(
            probe.foundryDefaultSender(),
            address(uint160(uint256(keccak256("foundry default caller")))),
            "FOUNDRY_DEFAULT_SENDER no longer matches forge's derivation"
        );
    }
}
