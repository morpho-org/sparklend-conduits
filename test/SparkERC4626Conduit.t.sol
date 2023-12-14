// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import 'dss-test/DssTest.sol';

import { MockERC20 } from 'erc20-helpers/MockERC20.sol';

import { UpgradeableProxy } from 'upgradeable-proxy/UpgradeableProxy.sol';

import { SparkERC4626Conduit } from '../src/SparkERC4626Conduit.sol';

import { RolesMock, RegistryMock } from "./mocks/Mocks.sol";

import { MockERC4626, ERC20 } from 'solmate/test/utils/mocks/MockERC4626.sol';


// TODO: Add multiple buffers when multi ilk is used

contract SparkERC4626ConduitTestBase is DssTest {

    uint256 constant RBPS             = RAY / 10_000;
    uint256 constant WBPS             = WAD / 10_000;
    uint256 constant SECONDS_PER_YEAR = 365 days;

    bytes32 constant ILK  = 'some-ilk';
    bytes32 constant ILK2 = 'some-ilk2';

    address buffer = makeAddr("buffer");

    RolesMock    roles;
    RegistryMock registry;
    MockERC20    token;
    MockERC4626  vault;

    SparkERC4626Conduit conduit;

    event Deposit(bytes32 indexed ilk, address indexed asset, address origin, uint256 amount);
    event Withdraw(bytes32 indexed ilk, address indexed asset, address destination, uint256 amount);
    event SetRoles(address roles);
    event SetRegistry(address registry);
    event SetAssetEnabled(address indexed asset, bool enabled);

    function setUp() public virtual {
        roles    = new RolesMock();
        registry = new RegistryMock();

        registry.setBuffer(buffer); // TODO: Update this, make buffer per ilk

        token = new MockERC20('Token', 'TKN', 18);
        vault = new MockERC4626(ERC20(address(token)), 'Vault', 'VAULT');

        UpgradeableProxy proxy = new UpgradeableProxy();
        SparkERC4626Conduit impl  = new SparkERC4626Conduit();

        proxy.setImplementation(address(impl));

        conduit = SparkERC4626Conduit(address(proxy));

        conduit.setRoles(address(roles));
        conduit.setRegistry(address(registry));
        conduit.setVaultAsset(address(vault), address(token));
        conduit.setAssetEnabled(address(token), true);

        vm.prank(buffer);
        token.approve(address(conduit), type(uint256).max);

        // Set default liquidity index to be greater than 1:1
        // 100 / 125% = 80 shares for 100 asset deposit
        // TODO: update
        // token.transfer(125_00 * RBPS);
    }

    function _assertVaultState(
        uint256 totalAssets,
        uint256 balance,
        uint256 totalSupply
    ) internal {
        assertEq(vault.totalAssets(),                     totalAssets);
        assertEq(vault.balanceOf(address(conduit)),       balance);
        assertEq(vault.totalSupply(),                     totalSupply);
    }

    function _assertTokenState(uint256 bufferBalance, uint256 vaultBalance) internal {
        assertEq(token.balanceOf(buffer),          bufferBalance);
        assertEq(token.balanceOf(address(vault)), vaultBalance);
    }

}

contract SparkERC4626ConduitConstructorTests is SparkERC4626ConduitTestBase {

    function test_constructor() public {
        assertEq(conduit.wards(address(this)), 1);
    }

}

contract SparkERC4626ConduitModifierTests is SparkERC4626ConduitTestBase {

    function test_authModifiers() public {
        UpgradeableProxy(address(conduit)).deny(address(this));

        checkModifier(address(conduit), "SparkERC4626Conduit/not-authorized", [
            SparkERC4626Conduit.setRoles.selector,
            SparkERC4626Conduit.setRegistry.selector,
            SparkERC4626Conduit.setVaultAsset.selector,
            SparkERC4626Conduit.setAssetEnabled.selector
        ]);
    }

    function test_ilkAuthModifiers() public {
        roles.setCanCall(false);

        checkModifier(address(conduit), "SparkERC4626Conduit/ilk-not-authorized", [
            SparkERC4626Conduit.deposit.selector,
            SparkERC4626Conduit.withdraw.selector
        ]);
    }

}

contract SparkERC4626ConduitDepositTests is SparkERC4626ConduitTestBase {

    function setUp() public override {
        super.setUp();
        token.mint(buffer, 100 ether);
    }

    function test_deposit_revert_notEnabled() public {
        conduit.setAssetEnabled(address(token), false);
        vm.expectRevert("SparkERC4626Conduit/asset-disabled");
        conduit.deposit(ILK, address(token), 100 ether);
    }

    function test_deposit() public {
        _assertTokenState({
            bufferBalance: 100 ether,
            vaultBalance: 0
        });

        _assertVaultState({
            totalAssets:       0,
            balance:           0,
            totalSupply:       0
        });

        assertEq(conduit.shares(address(token), ILK), 0);
        assertEq(conduit.totalShares(address(token)), 0);

        vm.expectEmit();
        emit Deposit(ILK, address(token), buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);

        _assertTokenState({
            bufferBalance: 0,
            vaultBalance: 100 ether
        });

        _assertVaultState({
            totalAssets:       100 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);
    }

    function test_deposit_multiIlk_increasingIndex() public {
        _assertTokenState({
            bufferBalance: 100 ether,
            vaultBalance: 0
        });

        _assertVaultState({
            totalAssets:       0,
            balance:           0,
            totalSupply:       0
        });

        assertEq(conduit.shares(address(token), ILK), 0);
        assertEq(conduit.totalShares(address(token)), 0);

        vm.expectEmit();
        emit Deposit(ILK, address(token), buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);

        _assertTokenState({
            bufferBalance: 0,
            vaultBalance: 100 ether
        });

        _assertVaultState({
            totalAssets:       100 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        // pool.setLiquidityIndex(160_00 * RBPS);  // 50 / 160% = 31.25 shares for 50 asset deposit

        token.mint(buffer, 50 ether);  // For second deposit

        vm.expectEmit();
        emit Deposit(ILK2, address(token), buffer, 50 ether);
        conduit.deposit(ILK2, address(token), 50 ether);

        _assertTokenState({
            bufferBalance: 0,
            vaultBalance: 150 ether
        });

        _assertVaultState({
            totalAssets:       111.25 ether, // 80 + 31.25
            balance:           178 ether,  // 80 * 1.6 + 50 = 178
            totalSupply:       178 ether
        });

        assertEq(conduit.shares(address(token), ILK),  80 ether);
        assertEq(conduit.shares(address(token), ILK2), 31.25 ether);
        assertEq(conduit.totalShares(address(token)),  111.25 ether);
    }

}

contract SparkERC4626ConduitWithdrawTests is SparkERC4626ConduitTestBase {

    function setUp() public override {
        super.setUp();
        token.mint(buffer, 100 ether);

        conduit.deposit(ILK, address(token), 100 ether);
    }

    // Assert that one wei can't be withdrawn without burning one share
    function test_withdraw_sharesRounding() public {
        _assertTokenState({
            bufferBalance: 0,
            vaultBalance: 100 ether
        });

        _assertVaultState({
            totalAssets:       100 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 1);
        assertEq(conduit.withdraw(ILK, address(token), 1), 1);

        _assertTokenState({
            bufferBalance: 1,
            vaultBalance: 100 ether - 1
        });

        // NOTE: SparkERC4626 state doesn't have rounding logic, just conduit state.
        _assertVaultState({
            totalAssets:       100 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether - 1);
        assertEq(conduit.totalShares(address(token)), 80 ether - 1);
    }

    function test_withdraw_singleIlk_exactPartialWithdraw() public {
        _assertTokenState({
            bufferBalance: 0,
            vaultBalance: 100 ether
        });

        _assertVaultState({
            totalAssets:       100 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 40 ether);
        assertEq(conduit.withdraw(ILK, address(token), 40 ether), 40 ether);

        _assertTokenState({
            bufferBalance: 40 ether,
            vaultBalance: 60 ether
        });

        _assertVaultState({
            totalAssets:       48 ether,
            balance:           60 ether,
            totalSupply:       60 ether
        });

        assertEq(conduit.shares(address(token), ILK), 48 ether);
        assertEq(conduit.totalShares(address(token)), 48 ether);
    }

    function test_withdraw_singleIlk_maxUint() public {
        _assertTokenState({
            bufferBalance: 0,
            vaultBalance: 100 ether
        });

        _assertVaultState({
            totalAssets:       100 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 100 ether);
        assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 100 ether);

        _assertTokenState({
            bufferBalance: 100 ether,
            vaultBalance: 0
        });

        _assertVaultState({
            totalAssets:       0,
            balance:           0,
            totalSupply:       0
        });

        assertEq(conduit.shares(address(token), ILK), 0);
        assertEq(conduit.totalShares(address(token)), 0);
    }

    function test_withdraw_multiIlk_exactPartialWithdraw() public {
        token.mint(buffer, 50 ether);
        conduit.deposit(ILK2, address(token), 50 ether);

        _assertTokenState({
            bufferBalance: 0,
            vaultBalance: 150 ether
        });

        _assertVaultState({
            totalAssets:       120 ether,
            balance:           150 ether,
            totalSupply:       150 ether
        });

        assertEq(conduit.shares(address(token), ILK),  80 ether);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  120 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 50 ether);
        assertEq(conduit.withdraw(ILK, address(token), 50 ether), 50 ether);

        _assertTokenState({
            bufferBalance: 50 ether,
            vaultBalance: 100 ether
        });

        _assertVaultState({
            totalAssets:       100 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK),  40 ether);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  80 ether);
    }

    // TODO: Partial liquidity
    function test_withdraw_multiIlk_maxUint() public {
        token.mint(buffer, 50 ether);
        conduit.deposit(ILK2, address(token), 50 ether);

        _assertTokenState({
            bufferBalance: 0,
            vaultBalance: 150 ether
        });

        _assertVaultState({
            totalAssets:       120 ether,
            balance:           150 ether,
            totalSupply:       150 ether
        });

        assertEq(conduit.shares(address(token), ILK),  80 ether);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  120 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 100 ether);
        assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 100 ether);

        _assertTokenState({
            bufferBalance: 100 ether,
            vaultBalance: 50 ether
        });

        _assertVaultState({
            totalAssets:       40 ether,
            balance:           50 ether,
            totalSupply:       50 ether
        });

        assertEq(conduit.shares(address(token), ILK),  0);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  40 ether);
    }

    function test_withdraw_singleIlk_maxUint_partialLiquidity() public {
        deal(address(token), address(vault), 40 ether);

        _assertTokenState({
            bufferBalance: 0,
            vaultBalance: 40 ether
        });

        _assertVaultState({
            totalAssets:       100 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 40 ether);
        assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 40 ether);

        _assertTokenState({
            bufferBalance: 40 ether,
            vaultBalance: 0
        });

        _assertVaultState({
            totalAssets:       48 ether,
            balance:           60 ether,
            totalSupply:       60 ether
        });

        assertEq(conduit.shares(address(token), ILK), 48 ether);
        assertEq(conduit.totalShares(address(token)), 48 ether);
    }

    // function test_withdraw_multiIlk_increasingIndex() public {
    //     token.mint(buffer, 50 ether);
    //     conduit.deposit(ILK2, address(token), 50 ether);

    //     _assertTokenState({
    //         bufferBalance: 0,
    //         vaultBalance: 150 ether
    //     });

    //     _assertVaultState({
    //         scaledBalance:     120 ether,
    //         scaledTotalSupply: 120 ether,
    //         balance:           150 ether,
    //         totalSupply:       150 ether
    //     });

    //     assertEq(conduit.shares(address(token), ILK),  80 ether);
    //     assertEq(conduit.shares(address(token), ILK2), 40 ether);
    //     assertEq(conduit.totalShares(address(token)),  120 ether);

    //     // type(uint256).max yields the same underlying funds because of same index
    //     vm.expectEmit();
    //     emit Withdraw(ILK, address(token), buffer, 100 ether);
    //     assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 100 ether);

    //     _assertTokenState({
    //         bufferBalance: 100 ether,
    //         vaultBalance: 50 ether
    //     });

    //     _assertVaultState({
    //         scaledBalance:     40 ether,
    //         scaledTotalSupply: 40 ether,
    //         balance:           50 ether,
    //         totalSupply:       50 ether
    //     });

    //     assertEq(conduit.shares(address(token), ILK),  0);
    //     assertEq(conduit.shares(address(token), ILK2), 40 ether);
    //     assertEq(conduit.totalShares(address(token)),  40 ether);

    //     // This mimics interest being earned in the pool. However since the liquidity hasn't
    //     // changed, ilk2 will not be able to withdraw the full amount of funds they are entitled to.
    //     // This means that they will instead just burn less shares in order to get their initial
    //     // deposit back.
    //     pool.setLiquidityIndex(160_00 * RBPS);  // 100 / 160% = 62.5 shares for 100 asset deposit

    //     assertEq(conduit.withdraw(ILK2, address(token), type(uint256).max), 50 ether);

    //     _assertTokenState({
    //         bufferBalance: 150 ether,
    //         vaultBalance: 0
    //     });

    //     _assertVaultState({
    //         scaledBalance:     8.75 ether,  // 40 - (50 / 1.6) = 8.75
    //         scaledTotalSupply: 8.75 ether,
    //         balance:           14 ether,    // Interest earned by ilk2
    //         totalSupply:       14 ether
    //     });

    //     assertEq(conduit.shares(address(token), ILK),  0);
    //     assertEq(conduit.shares(address(token), ILK2), 8.75 ether);
    //     assertEq(conduit.totalShares(address(token)),  8.75 ether);
    // }

    // function test_withdraw_multiIlk_decreasingIndex() public {
    //     token.mint(buffer, 50 ether);
    //     conduit.deposit(ILK2, address(token), 50 ether);

    //     _assertTokenState({
    //         bufferBalance: 0,
    //         vaultBalance: 150 ether
    //     });

    //     _assertVaultState({
    //         scaledBalance:     120 ether,
    //         scaledTotalSupply: 120 ether,
    //         balance:           150 ether,
    //         totalSupply:       150 ether
    //     });

    //     assertEq(conduit.shares(address(token), ILK),  80 ether);
    //     assertEq(conduit.shares(address(token), ILK2), 40 ether);
    //     assertEq(conduit.totalShares(address(token)),  120 ether);

    //     // type(uint256).max yields the same underlying funds because of same index
    //     vm.expectEmit();
    //     emit Withdraw(ILK, address(token), buffer, 100 ether);
    //     assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 100 ether);

    //     _assertTokenState({
    //         bufferBalance: 100 ether,
    //         vaultBalance: 50 ether
    //     });

    //     _assertVaultState({
    //         scaledBalance:     40 ether,
    //         scaledTotalSupply: 40 ether,
    //         balance:           50 ether,
    //         totalSupply:       50 ether
    //     });

    //     assertEq(conduit.shares(address(token), ILK),  0);
    //     assertEq(conduit.shares(address(token), ILK2), 40 ether);
    //     assertEq(conduit.totalShares(address(token)),  40 ether);

    //     // This mimics a loss in the pool. Since the liquidity hasn't changed, this means that the
    //     // 40 shares that ilk2 has will not be able to withdraw the full amount of funds they
    //     // originally deposited.
    //     pool.setLiquidityIndex(80_00 * RBPS);  // 100 / 80% = 125 shares for 100 asset deposit

    //     assertEq(conduit.withdraw(ILK2, address(token), type(uint256).max), 32 ether);

    //     _assertTokenState({
    //         bufferBalance: 132 ether,
    //         vaultBalance: 18 ether
    //     });

    //     _assertVaultState({
    //         totalAssets:       0,
    //         balance:           0,
    //         totalSupply:       0
    //     });

    //     assertEq(conduit.shares(address(token), ILK),  0);
    //     assertEq(conduit.shares(address(token), ILK2), 0);
    //     assertEq(conduit.totalShares(address(token)),  0);
    // }

}

contract SparkERC4626ConduitMaxViewFunctionTests is SparkERC4626ConduitTestBase {

    function test_maxDeposit() public {
        assertEq(conduit.maxDeposit(ILK, address(token)), type(uint256).max);
    }

    function test_maxDeposit_unsupportedAsset() public {
        assertEq(conduit.maxDeposit(ILK, makeAddr("some-addr")), 0);
    }

    function test_maxWithdraw() public {
        assertEq(conduit.maxWithdraw(ILK, address(token)), 0);

        token.mint(buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);

        assertEq(conduit.maxWithdraw(ILK, address(token)), 100 ether);

        deal(address(vault), address(conduit), 40 ether);

        assertEq(conduit.maxWithdraw(ILK, address(token)), 40 ether);
    }

}

contract SparkERC4626ConduitGetTotalDepositsTests is SparkERC4626ConduitTestBase {

    // function test_getTotalDeposits() external {
    //     token.mint(buffer, 100 ether);
    //     conduit.deposit(ILK, address(token), 100 ether);

    //     assertEq(conduit.getTotalDeposits(address(token)), 100 ether);

    //     pool.setLiquidityIndex(160_00 * RBPS);

    //     // 100 @ 1.25 = 80, 80 @ 1.6 = 128
    //     assertEq(conduit.getTotalDeposits(address(token)), 128 ether);
    // }

    // function testFuzz_getTotalDeposits(
    //     uint256 index1,
    //     uint256 index2,
    //     uint256 depositAmount
    // )
    //     external
    // {
    //     index1        = bound(index1,        1 * RBPS, 500_00 * RBPS);
    //     index2        = bound(index2,        1 * RBPS, 500_00 * RBPS);
    //     depositAmount = bound(depositAmount, 0,        1e32);

    //     pool.setLiquidityIndex(index1);

    //     token.mint(buffer, depositAmount);
    //     conduit.deposit(ILK, address(token), depositAmount);

    //     assertApproxEqAbs(conduit.getTotalDeposits(address(token)), depositAmount, 10);

    //     pool.setLiquidityIndex(index2);

    //     uint256 expectedDeposit = depositAmount * 1e27 / index1 * index2 / 1e27;

    //     assertApproxEqAbs(conduit.getTotalDeposits(address(token)), expectedDeposit, 10);
    // }

}

contract SparkERC4626ConduitGetDepositsTests is SparkERC4626ConduitTestBase {

    // function test_getDeposits() external {
    //     token.mint(buffer, 100 ether);
    //     conduit.deposit(ILK, address(token), 100 ether);

    //     assertEq(conduit.getDeposits(address(token), ILK), 100 ether);

    //     pool.setLiquidityIndex(160_00 * RBPS);

    //     // 100 @ 1.25 = 80, 80 @ 1.6 = 128
    //     assertEq(conduit.getDeposits(address(token), ILK), 128 ether);
    // }

    // function testFuzz_getDeposits(
    //     uint256 index1,
    //     uint256 index2,
    //     uint256 depositAmount
    // )
    //     external
    // {
    //     index1        = bound(index1,        1 * RBPS, 500_00 * RBPS);
    //     index2        = bound(index2,        1 * RBPS, 500_00 * RBPS);
    //     depositAmount = bound(depositAmount, 0,        1e32);

    //     pool.setLiquidityIndex(index1);

    //     token.mint(buffer, depositAmount);
    //     conduit.deposit(ILK, address(token), depositAmount);

    //     assertApproxEqAbs(conduit.getDeposits(address(token), ILK), depositAmount, 10);

    //     pool.setLiquidityIndex(index2);

    //     uint256 expectedDeposit = depositAmount * 1e27 / index1 * index2 / 1e27;

    //     assertApproxEqAbs(conduit.getDeposits(address(token), ILK), expectedDeposit, 10);
    // }

}

contract SparkERC4626ConduitGetAvailableLiquidityTests is SparkERC4626ConduitTestBase {

    function test_getAvailableLiquidity() external {
        assertEq(conduit.getAvailableLiquidity(address(token)), 0);

        deal(address(token), address(vault), 100 ether);

        assertEq(conduit.getAvailableLiquidity(address(token)), 100 ether);
    }

    function testFuzz_getAvailableLiquidity(uint256 dealAmount) external {
        assertEq(conduit.getAvailableLiquidity(address(token)), 0);

        deal(address(token), address(vault), dealAmount);

        assertEq(conduit.getAvailableLiquidity(address(token)), dealAmount);
    }

}

contract SparkERC4626ConduitAdminSetterTests is SparkERC4626ConduitTestBase {

    address SET_ADDRESS = makeAddr("set-address");

    function test_setRoles() public {
        assertEq(conduit.roles(), address(roles));

        vm.expectEmit();
        emit SetRoles(SET_ADDRESS);
        conduit.setRoles(SET_ADDRESS);

        assertEq(conduit.roles(), SET_ADDRESS);
    }

    function test_setRegistry() public {
        assertEq(conduit.registry(), address(registry));

        vm.expectEmit();
        emit SetRegistry(SET_ADDRESS);
        conduit.setRegistry(SET_ADDRESS);

        assertEq(conduit.registry(), SET_ADDRESS);
    }

    // function test_setAssetEnabled() public {
    //     // Starting state
    //     conduit.setAssetEnabled(address(token), false);

    //     assertEq(conduit.enabled(address(token)), false);

    //     assertEq(token.allowance(address(conduit), address(pool)), 0);

    //     vm.expectEmit();
    //     emit SetAssetEnabled(address(token), true);
    //     conduit.setAssetEnabled(address(token), true);

    //     assertEq(conduit.enabled(address(token)), true);

    //     assertEq(token.allowance(address(conduit), address(pool)), type(uint256).max);

    //     vm.expectEmit();
    //     emit SetAssetEnabled(address(token), false);
    //     conduit.setAssetEnabled(address(token), false);

    //     assertEq(conduit.enabled(address(token)), false);

    //     assertEq(token.allowance(address(conduit), address(pool)), 0);
    // }

}
