// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CCIPAdapterBase } from "./Base.t.sol";
import { CCIPAdapter } from "@src/adapters/CCIP/CCIPAdapter.sol";
import { BaseAdapter } from "@src/adapters/BaseAdapter.sol";
import { Errors } from "@src/lib/Errors.sol";

contract CCIPAdapterConstructorTest is CCIPAdapterBase {
    /// @dev Redeclared from `BaseAdapter` so `vm.expectEmit` can emit it.
    event TrustedRemoteSet(uint256 indexed chainId, address trustedRemote);

    function test_revertsIfControllerIsZeroAddress() public {
        // `BaseAdapter`'s check, hit before any CCIP-specific validation.
        vm.expectRevert(Errors.ZERO_ADDRESS.selector);
        new CCIPAdapter(address(0), address(router), address(0), new BaseAdapter.TrustedRemoteConfig[](0));
    }

    function test_revertsIfTrustedRemoteConfigHasZeroChainId() public {
        BaseAdapter.TrustedRemoteConfig[] memory configs = new BaseAdapter.TrustedRemoteConfig[](1);
        configs[0] = BaseAdapter.TrustedRemoteConfig({ standardChainId: 0, trustedRemote: remoteController });

        vm.expectRevert(Errors.INVALID_CHAIN_ID.selector);
        new CCIPAdapter(address(controller), address(router), address(0), configs);
    }

    /// @dev The config loop is exercised with 0 or 1 entries everywhere else;
    ///      a multi-entry config must wire every lane and emit once per entry
    ///      (`TrustedRemoteSet` is asserted nowhere else in the suite).
    function test_multiEntryConfigWiresEveryLaneAndEmitsPerEntry() public {
        address baseRemoteController = makeAddr("baseRemoteController");

        BaseAdapter.TrustedRemoteConfig[] memory configs = new BaseAdapter.TrustedRemoteConfig[](2);
        configs[0] =
            BaseAdapter.TrustedRemoteConfig({ standardChainId: CHAIN_ETH_MAINNET, trustedRemote: remoteController });
        configs[1] =
            BaseAdapter.TrustedRemoteConfig({ standardChainId: CHAIN_BASE, trustedRemote: baseRemoteController });

        vm.expectEmit(true, true, true, true);
        emit TrustedRemoteSet(CHAIN_ETH_MAINNET, remoteController);
        vm.expectEmit(true, true, true, true);
        emit TrustedRemoteSet(CHAIN_BASE, baseRemoteController);

        CCIPAdapter multiAdapter = new CCIPAdapter(address(controller), address(router), address(0), configs);

        assertEq(multiAdapter.trustedRemote(CHAIN_ETH_MAINNET), remoteController);
        assertEq(multiAdapter.trustedRemote(CHAIN_BASE), baseRemoteController);
    }

    /// @dev A zero trusted remote is accepted-and-inert, not rejected: the
    ///      receive path's zero-sender short-circuit keeps it safe (pinned in
    ///      the ccipReceive suite).
    function test_acceptsZeroTrustedRemoteAsInert() public {
        BaseAdapter.TrustedRemoteConfig[] memory configs = new BaseAdapter.TrustedRemoteConfig[](1);
        configs[0] = BaseAdapter.TrustedRemoteConfig({ standardChainId: CHAIN_BASE, trustedRemote: address(0) });

        CCIPAdapter zeroRemoteAdapter = new CCIPAdapter(address(controller), address(router), address(0), configs);

        assertEq(zeroRemoteAdapter.trustedRemote(CHAIN_BASE), address(0));
    }

    function test_revertsIfRouterIsZeroAddress() public {
        vm.expectRevert(Errors.ZERO_ADDRESS.selector);
        new CCIPAdapter(address(controller), address(0), address(0), new BaseAdapter.TrustedRemoteConfig[](0));
    }

    function test_revertsIfFeeTokenIsSpecified_ButIsEOA() public {
        address feeToken = makeAddr("FEE_TOKEN");

        vm.expectRevert(abi.encodeWithSelector(Errors.HAS_NO_CODE.selector, feeToken));
        new CCIPAdapter(address(controller), makeAddr("Adapter"), feeToken, new BaseAdapter.TrustedRemoteConfig[](0));
    }

    function test_wiresUpConfiguredTrustedRemoteControllerAndSelector() public view {
        assertEq(adapter.trustedRemote(CHAIN_ETH_MAINNET), remoteController);
        assertEq(adapter.toNativeChainId(CHAIN_ETH_MAINNET), uint256(SEL_ETH_MAINNET));
    }
}
