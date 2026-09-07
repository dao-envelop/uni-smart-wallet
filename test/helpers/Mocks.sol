// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @notice Minimal ERC-20 with public mint, for tests that need a token balance.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock ERC-20 with a toggleable fee-on-transfer (basis points), skimmed to a sink on every
/// non-mint/non-burn transfer. `feeBps` starts at 0 (behaves like a plain token) and can be flipped
/// on later to model a "stable" that activates a transfer fee after positions already exist (e.g. a
/// USDT-style configurable fee). Used by the H-2 PoC to show the manager's settle/delivery accounting
/// assumes `received == sent`.
contract MockFeeOnTransferERC20 is ERC20 {
    uint256 public feeBps; // out of 10_000
    address public immutable feeSink;

    constructor() ERC20("FeeOnTransfer", "FOT") {
        feeSink = address(0xF0F0);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    /// @dev Apply the fee only on real transfers (mint `from==0` / burn `to==0` are exempt).
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, feeSink, fee);
    }
}

/// @notice Echoes back the bytes it receives. Used to verify executeEncodedTx round-trip data.
contract Echo {
    function ping(bytes calldata data) external pure returns (bytes calldata) {
        return data;
    }
}

/// @notice Configurable {IPriceOracle} for the operator-guard tests.
/// - `NotEnforced` ⇒ `check` returns false (no fresh reference): operator ops are rejected
///   (`OperatorSwapUnverified`), owner ops still pass.
/// - `Pass` ⇒ `check` returns true (in-bounds reference): operator ops are allowed.
/// - `Revert` ⇒ `check` reverts (out-of-bounds price), like a real oracle rejecting an adverse swap.
/// - `RejectSpot` ⇒ swaps pass, but the `amountIn == 0` spot check reverts {MockSpotChecked}. This is how
///   a test proves the add path really consulted the oracle: `check` is `view`, so the mock cannot count
///   calls, and a mock that ignores its arguments would let the guard be refactored away unnoticed.
contract MockPriceOracle is IPriceOracle {
    enum Mode {
        NotEnforced,
        Pass,
        Revert,
        RejectSpot
    }

    Mode public mode;

    error MockPriceOutOfBounds();
    error MockSpotChecked();

    function setMode(Mode m) external {
        mode = m;
    }

    function check(PoolKey calldata, bool, uint256 amountIn, uint256) external view returns (bool) {
        if (mode == Mode.Revert) revert MockPriceOutOfBounds();
        if (mode == Mode.RejectSpot) {
            if (amountIn == 0) revert MockSpotChecked();
            return true;
        }
        return mode == Mode.Pass;
    }

    /// @dev The add half of the op call is the spot check of the add path, so `RejectSpot` fires there.
    function checkOp(PoolKey calldata, bool, uint256 amountIn, uint256, int24, int24) external view returns (bool) {
        if (mode == Mode.Revert) revert MockPriceOutOfBounds();
        if (mode == Mode.RejectSpot) {
            if (amountIn == 0) revert MockSpotChecked();
            return true;
        }
        return mode == Mode.Pass;
    }
}

/// @notice A no-op hook that only observes the add/remove-liquidity calls, for the
/// {OpenVolatileLPManager} suite. It returns its own selector (so v4 accepts the call) and touches no
/// deltas — deliberately: it proves the manager's ops still work with a hook *in the loop*, without the
/// hook being the thing under test. Counters let a test assert it really was invoked.
///
/// Deployment is not `new MockObserverHook()`: v4 reads a hook's permissions from the low 14 bits of
/// its ADDRESS (`Hooks.sol:15-18`) and `PoolManager.initialize` rejects a non-zero hook with no flags
/// via `isValidHookAddress`. So a test must place the code at an address carrying the flags it
/// implements — see the `vm.etch` in the suite.
contract MockObserverHook is BaseTestHooks {
    uint256 public beforeAddCalls;
    uint256 public beforeRemoveCalls;

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        returns (bytes4)
    {
        ++beforeAddCalls;
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        returns (bytes4)
    {
        ++beforeRemoveCalls;
        return IHooks.beforeRemoveLiquidity.selector;
    }
}

/// @notice A hook that reverts on `beforeRemoveLiquidity` — the "a benign-looking hook can brick
/// `withdrawTo` and trap principal" risk that {OpenVolatileLPManager} documents as accepted. Present so
/// that risk is demonstrated by a passing test rather than asserted in a comment.
contract MockBrickingHook is BaseTestHooks {
    error Bricked();

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert Bricked();
    }
}
