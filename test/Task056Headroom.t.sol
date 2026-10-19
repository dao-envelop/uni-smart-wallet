// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {FactoryHelper} from "./helpers/FactoryHelper.sol";
import {Echo} from "./helpers/Mocks.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {SingletonNFTOwned} from "../src/abstract/SingletonNFTOwned.sol";
import {IWalletDescriptor} from "../src/interfaces/IWalletDescriptor.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract RevertingDescriptor is IWalletDescriptor {
    error Boom();

    function tokenURI(address, uint256) external pure returns (string memory) {
        revert Boom();
    }
}

contract GasBurningDescriptor is IWalletDescriptor {
    function tokenURI(address, uint256) external view returns (string memory) {
        while (gasleft() > 0) {}
        return "unreachable";
    }
}

contract FixedDescriptor is IWalletDescriptor {
    function tokenURI(address, uint256) external pure returns (string memory) {
        return "data:application/json;base64,e30=";
    }
}

contract CustomRevert {
    error Custom(uint256 x);

    function fail() external pure {
        revert Custom(42);
    }
}

/// @notice task_056: the EIP-170 savings changed *where* some checks run and how a few helpers are built,
/// never what a caller sees. These pin the observable behaviour of every rewritten path.
contract Task056HeadroomTest is StableLPTestBase {
    // ────────── tokenURI survives a broken descriptor ──────────

    function test_tokenURI_revertingDescriptor_returnsEmpty() public {
        address d = address(new RevertingDescriptor());
        vm.prank(owner);
        mgr.setPositionDescriptor(d);
        assertEq(mgr.tokenURI(1), "", "a reverting descriptor degrades to the no-descriptor answer");
    }

    function test_tokenURI_gasBurningDescriptor_returnsEmpty() public {
        address d = address(new GasBurningDescriptor());
        vm.prank(owner);
        mgr.setPositionDescriptor(d);
        assertEq(mgr.tokenURI{gas: 5_000_000}(1), "", "out-of-gas in the renderer is caught too");
    }

    function test_tokenURI_workingDescriptor_passesThrough() public {
        address d = address(new FixedDescriptor());
        vm.prank(owner);
        mgr.setPositionDescriptor(d);
        assertEq(mgr.tokenURI(1), "data:application/json;base64,e30=");
    }

    function test_tokenURI_nonexistentToken_stillReverts() public {
        vm.expectRevert();
        mgr.tokenURI(2);
    }

    // ────────── name() without the byte loop ──────────

    function test_name_full32Bytes() public {
        bytes32 full = bytes32("Envelop StableLP Vault v2 Alpha!"); // 32 chars, no terminator
        StableLPManager.InitParams memory p = _initParams(owner);
        p.name = full;
        StableLPManager m = FactoryHelper.cloneStable(factory, address(impl), p);
        assertEq(m.name(), "Envelop StableLP Vault v2 Alpha!");
    }

    /// @dev Bytes after the first zero are dropped and must not leak into the ABI padding.
    function test_name_stopsAtFirstZero_paddingClean() public {
        bytes32 n = bytes32(bytes("Ab")) | bytes32(uint256(0xff)); // "Ab", zeros, then garbage in the last byte
        StableLPManager.InitParams memory p = _initParams(owner);
        p.name = n;
        StableLPManager m = FactoryHelper.cloneStable(factory, address(impl), p);
        assertEq(m.name(), "Ab");
        (bool ok, bytes memory raw) = address(m).staticcall(abi.encodeWithSignature("name()"));
        assertTrue(ok);
        assertEq(raw, abi.encode("Ab"), "raw return is canonically padded");
    }

    // ────────── executeEncodedTxBatch on a raw call ──────────

    function test_batch_bubblesCalleeRevert() public {
        address t = address(new CustomRevert());
        address[] memory targets = new address[](1);
        targets[0] = t;
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeCall(CustomRevert.fail, ());
        vm.expectRevert(abi.encodeWithSelector(CustomRevert.Custom.selector, 42));
        vm.prank(owner);
        mgr.executeEncodedTxBatch(targets, values, datas);
    }

    function test_batch_returnsResultsAndSendsNative() public {
        vm.deal(address(mgr), 1 ether);
        Echo e = new Echo();
        address[] memory targets = new address[](2);
        targets[0] = address(e);
        targets[1] = address(0xBEEF);
        uint256[] memory values = new uint256[](2);
        values[1] = 0.25 ether;
        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeCall(Echo.ping, (hex"c0ffee"));
        vm.prank(owner);
        bytes[] memory res = mgr.executeEncodedTxBatch(targets, values, datas);
        assertEq(abi.decode(res[0], (bytes)), hex"c0ffee", "call result returned");
        assertEq(res[1].length, 0, "plain native send returns nothing");
        assertEq(address(0xBEEF).balance, 0.25 ether);
    }

    function test_batch_failedNativeSend_reverts() public {
        address[] memory targets = new address[](1);
        targets[0] = address(new CustomRevert()); // no receive/fallback
        uint256[] memory values = new uint256[](1);
        values[0] = 1;
        vm.deal(address(mgr), 1);
        bytes[] memory datas = new bytes[](1);
        vm.expectRevert();
        vm.prank(owner);
        mgr.executeEncodedTxBatch(targets, values, datas);
    }

    // ────────── validation moved inside the unlock keeps its errors ──────────

    function test_allocate_unknownPool_stillUnknownPool() public {
        BaseLPManager.AllocLeg[] memory legs = _allocateParams(FUND);
        PoolId ghost = PoolId.wrap(bytes32(uint256(0xdead)));
        legs[1].poolId = ghost;
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.UnknownPool.selector, ghost));
        vm.prank(owner);
        mgr.allocate(legs);
    }

    function test_allocateFrom_unknownPool_stillUnknownPool() public {
        BaseLPManager.AllocLeg[] memory legs = _allocateParams(FUND);
        PoolId ghost = PoolId.wrap(bytes32(uint256(0xdead)));
        legs[0].poolId = ghost;
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.UnknownPool.selector, ghost));
        vm.prank(owner);
        mgr.allocateFrom(USDT, FUND, legs);
    }

    function test_reinvest_unknownPool_stillUnknownPool() public {
        BaseLPManager.AllocLeg memory leg = _allocateParams(FUND)[0];
        PoolId ghost = PoolId.wrap(bytes32(uint256(0xdead)));
        leg.poolId = ghost;
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.UnknownPool.selector, ghost));
        vm.prank(owner);
        mgr.reinvest(leg);
    }

    function test_stableOps_strangerStillNotAuthorizedFirst() public {
        BaseLPManager.AllocLeg[] memory none = new BaseLPManager.AllocLeg[](0);
        vm.expectRevert(SingletonNFTOwned.NotAuthorized.selector);
        mgr.allocate(none);
        vm.expectRevert(SingletonNFTOwned.NotAuthorized.selector);
        mgr.allocateFrom(Currency.wrap(address(0xdead)), 0, none);
    }

    function test_withdrawTo_unknownAndOverPull_sameErrors() public {
        vm.prank(owner);
        mgr.allocate(_allocateParams(FUND));
        bytes32 salt = _saltFor(0);
        uint128 have = mgr.positionOf(salt).liquidity;

        BaseLPManager.WithdrawSwap[] memory swaps = new BaseLPManager.WithdrawSwap[](0);
        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](1);

        pulls[0] = BaseLPManager.WithdrawStep({salt: bytes32(uint256(7)), liquidityToPull: 0});
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.UnknownPosition.selector, bytes32(uint256(7))));
        vm.prank(owner);
        mgr.withdrawTo(BaseLPManager.WithdrawToParams(address(0xBEEF), USDT, 1, pulls, swaps));

        pulls[0] = BaseLPManager.WithdrawStep({salt: salt, liquidityToPull: have + 1});
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.DeltaExceedsLiquidity.selector, have + 1, have));
        vm.prank(owner);
        mgr.withdrawTo(BaseLPManager.WithdrawToParams(address(0xBEEF), USDT, 1, pulls, swaps));
    }

    // ────────── Volatile: auth still precedes every other check ──────────

    function _volatile() internal returns (VolatileLPManager v) {
        VolatileLPManager vImpl = new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
        v = VolatileLPManager(payable(Clones.clone(address(vImpl))));
        PoolKey[] memory cfgs = new PoolKey[](1);
        cfgs[0] = poolKeys[0];
        v.initialize(
            VolatileLPManager.InitParams({
                owner: owner, name: "", descriptor: address(0), oracle: address(0), pools: cfgs
            })
        );
    }

    function test_volatile_strangerGetsNotAuthorized_beforeAnyValidation() public {
        VolatileLPManager v = _volatile();
        VolatileLPManager.VolatileAllocLeg[] memory none = new VolatileLPManager.VolatileAllocLeg[](0);
        VolatileLPManager.RecenterParams memory rp;
        rp.salt = bytes32(uint256(99)); // not open
        VolatileLPManager.VolatileAllocLeg memory add;

        vm.expectRevert(SingletonNFTOwned.NotAuthorized.selector);
        v.allocate(none);
        vm.expectRevert(SingletonNFTOwned.NotAuthorized.selector);
        v.recenter(rp);
        vm.expectRevert(SingletonNFTOwned.NotAuthorized.selector);
        v.moveLiquidity(bytes32(uint256(99)), 0, add);
    }

    function test_volatile_ownerErrorsUnchanged() public {
        VolatileLPManager v = _volatile();
        VolatileLPManager.VolatileAllocLeg[] memory none = new VolatileLPManager.VolatileAllocLeg[](0);
        VolatileLPManager.RecenterParams memory rp;
        rp.salt = bytes32(uint256(99));
        VolatileLPManager.VolatileAllocLeg memory add;

        vm.startPrank(owner);
        vm.expectRevert(BaseLPManager.NoLegs.selector);
        v.allocate(none);
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.UnknownPosition.selector, rp.salt));
        v.recenter(rp);
        vm.expectRevert(V4PositionManager.ZeroLiquidity.selector);
        v.moveLiquidity(bytes32(uint256(99)), 0, add);
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.UnknownPosition.selector, bytes32(uint256(99))));
        v.moveLiquidity(bytes32(uint256(99)), 1, add);
        vm.stopPrank();
    }
}
