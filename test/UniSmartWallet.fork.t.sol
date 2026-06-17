// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {UniSmartWallet} from "../src/UniSmartWallet.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {WalletPositionDescriptor} from "../src/WalletPositionDescriptor.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork tests against the live Base V4 PoolManager. Verifies that the
/// settle/take/unlock plumbing works against the production PoolManager (not the
/// in-test deploy used by the unit suites). Env-gated: skips cleanly if BASE_RPC
/// is unset so CI without secrets stays green.
///
/// Run:
///   BASE_RPC=https://... [BASE_FORK_BLOCK=...] \
///     forge test --match-path test/UniSmartWallet.fork.t.sol -vvv
contract UniSmartWalletForkTest is Test {
    using StateLibrary for IPoolManager;
    using stdJson for string;

    string internal constant JSON_PREFIX = "data:application/json;base64,";

    // Base mainnet V4 deployment (chainId 8453) per script/chain_params.json.
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    // Canonical Base tokens.
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // We initialize a fresh hookless pool with a less-common fee tier so this
    // test doesn't depend on the existing pool state on the fork. The wallet
    // is the sole LP for this pool → all swap fees accrue to it.
    uint24 internal constant FEE = 100; // 0.01%
    int24 internal constant SPACING = 1;

    UniSmartWallet internal wallet;
    PoolSwapTest internal swapRouter;
    PoolKey internal key;
    Currency internal currency0;
    Currency internal currency1;

    address internal trader = address(0xCAFE);

    bool internal forkActive;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC unset; skipping fork tests");
            return;
        }

        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
        forkActive = true;

        // Sort token addresses into (currency0, currency1).
        (currency0, currency1) =
            WETH < USDC ? (Currency.wrap(WETH), Currency.wrap(USDC)) : (Currency.wrap(USDC), Currency.wrap(WETH));

        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))
        });

        // Initialize a fresh pool at tick 0 if it doesn't already exist on the fork.
        (uint160 sp,,,) = POOL_MANAGER.getSlot0(key.toId());
        if (sp == 0) {
            POOL_MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(0));
        }

        swapRouter = new PoolSwapTest(POOL_MANAGER);

        // Deploy wallet — singleton NFT mints to msg.sender (this test contract).
        wallet = new UniSmartWallet(POOL_MANAGER);

        // Fund the wallet generously.
        deal(WETH, address(wallet), 100 ether);
        deal(USDC, address(wallet), 1_000_000e6);

        // Fund the trader and give the swap router unlimited approvals.
        deal(WETH, trader, 100 ether);
        deal(USDC, trader, 1_000_000e6);
        vm.startPrank(trader);
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ────────── helpers ──────────

    function _open(bytes32 salt, uint128 liquidity) internal {
        wallet.openPosition(
            key, -SPACING * 100, SPACING * 100, liquidity, salt, 0, type(uint128).max, type(uint128).max
        );
    }

    function _swapThroughRange(bool zeroForOne, int256 amountSpecified) internal {
        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _balOf(Currency c) internal view returns (uint256) {
        return IERC20(Currency.unwrap(c)).balanceOf(address(wallet));
    }

    // ────────── tests ──────────

    function test_fork_lifecycle_baseWethUsdc() public {
        if (!forkActive) return;

        bytes32 salt = bytes32(uint256(1));
        _open(salt, 1e15);

        uint256 bal0Before = _balOf(currency0);
        uint256 bal1Before = _balOf(currency1);

        _swapThroughRange(true, -1e12);
        _swapThroughRange(false, -1e12);

        wallet.closePosition(salt);

        assertEq(wallet.openPositionCount(), 0);
        assertEq(wallet.positionOf(salt).liquidity, 0);
        assertGt(_balOf(currency0), bal0Before, "fees0 should land in wallet");
        assertGt(_balOf(currency1), bal1Before, "fees1 should land in wallet");
    }

    function test_fork_pokeRoundtrip() public {
        if (!forkActive) return;

        bytes32 salt = bytes32(uint256(2));
        _open(salt, 1e15);
        uint128 liqBefore = wallet.positionOf(salt).liquidity;

        _swapThroughRange(true, -1e12);
        _swapThroughRange(false, -1e12);

        // pokePosition must not revert and must leave principal untouched.
        // Fee-accrual correctness is v4-core's responsibility, validated in
        // test_pokePosition_collectsFeesOnly under controlled in-test conditions;
        // here we only verify the live PoolManager accepts the unlock/take flow
        // with liquidityDelta == 0 (the structural difference vs close/decrease).
        wallet.pokePosition(salt);

        assertEq(wallet.positionOf(salt).liquidity, liqBefore, "principal must stay");
        assertEq(wallet.openPositionCount(), 1, "registry entry must stay");
    }

    function test_fork_decreasePartial() public {
        if (!forkActive) return;

        bytes32 salt = bytes32(uint256(3));
        _open(salt, 1e15);

        _swapThroughRange(true, -1e12);

        wallet.decreasePosition(salt, 5e14);

        V4PositionManager.Position memory p = wallet.positionOf(salt);
        assertEq(p.liquidity, 5e14);
        assertEq(wallet.openPositionCount(), 1, "decrease should not remove the entry");
    }

    /// @notice On-chain `tokenURI` against the live PoolManager: two real positions + accrued fees,
    /// ffi-decoded and checked against on-chain state.
    function test_fork_tokenURI_withPositions() public {
        if (!forkActive) return;

        WalletPositionDescriptor descriptor = new WalletPositionDescriptor();
        wallet.setPositionDescriptor(address(descriptor)); // msg.sender == this == NFT owner

        _open(bytes32(uint256(10)), 1e15);
        _open(bytes32(uint256(11)), 1e15);
        _swapThroughRange(true, -1e12);
        _swapThroughRange(false, -1e12);

        string memory uri = wallet.tokenURI(1);
        string memory json = _decodeJson(uri);

        assertEq(json.readString(".name"), "Envelop UniSmartWallet #1", "name");
        assertEq(json.readString(".attributes[0].value"), "2", "two open positions");
        assertEq(
            json.readString(".positions[0].currency0"), Strings.toHexString(Currency.unwrap(currency0)), "currency0"
        );
        assertGt(vm.parseUint(json.readString(".positions[0].fees0")), 0, "fees0 after swaps");
        // second position is rendered too
        assertEq(json.readString(".positions[1].liquidity"), "1000000000000000", "pos1 liquidity");
    }

    function _decodeJson(string memory dataUri) internal returns (string memory) {
        bytes memory sb = bytes(dataUri);
        bytes memory pb = bytes(JSON_PREFIX);
        bytes memory out = new bytes(sb.length - pb.length);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = sb[pb.length + i];
        }
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat("printf '%s' '", string(out), "' | base64 -d");
        return string(vm.ffi(cmd));
    }
}
