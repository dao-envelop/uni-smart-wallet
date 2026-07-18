// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LPManagerFactory} from "../../src/LPManagerFactory.sol";
import {StableLPManager} from "../../src/StableLPManager.sol";
import {VolatileLPManager} from "../../src/VolatileLPManager.sol";

/// @notice Test-only helpers for the universal {LPManagerFactory}: build a factory with a single
/// blessed implementation and clone a manager through it with the product-specific init calldata.
/// Kept as a library so both `is Test` and `is StableLPTestBase` suites can reuse it (the `new`
/// deployment is inlined into the caller).
library FactoryHelper {
    /// @dev A factory owned by `owner_` whose allowlist holds exactly `impl`.
    function single(address owner_, address impl) internal returns (LPManagerFactory f) {
        address[] memory impls = new address[](1);
        impls[0] = impl;
        f = new LPManagerFactory(owner_, impls);
    }

    /// @dev Clone a StableLPManager through `f`, forwarding the typed `initialize(p)` as raw calldata.
    function cloneStable(LPManagerFactory f, address impl, StableLPManager.InitParams memory p)
        internal
        returns (StableLPManager)
    {
        return StableLPManager(payable(f.createManager(impl, p.owner, abi.encodeCall(StableLPManager.initialize, (p)))));
    }

    /// @dev Clone a VolatileLPManager through `f`, forwarding the typed `initialize(p)` as raw calldata.
    function cloneVolatile(LPManagerFactory f, address impl, VolatileLPManager.InitParams memory p)
        internal
        returns (VolatileLPManager)
    {
        return VolatileLPManager(
            payable(f.createManager(impl, p.owner, abi.encodeCall(VolatileLPManager.initialize, (p))))
        );
    }
}
