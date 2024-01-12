// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import "dss-test/DssTest.sol";

import {MockERC20} from "erc20-helpers/MockERC20.sol";
import {MockERC4626, ERC20} from "solmate/test/utils/mocks/MockERC4626.sol";
import {OracleMock} from "lib/metamorpho/lib/morpho-blue/src/mocks/OracleMock.sol";

import {AllocatorRegistry} from "dss-allocator/AllocatorRegistry.sol";
import {AllocatorRoles} from "dss-allocator/AllocatorRoles.sol";

import {IERC20} from "erc20-helpers/interfaces/IERC20.sol";
import {IERC4626} from "lib/metamorpho/lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IMorpho, Id, MarketParams} from "lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IMetaMorpho} from "lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {IMetaMorphoFactory} from "lib/metamorpho/src/interfaces/IMetaMorphoFactory.sol";

import {UpgradeableProxy} from "upgradeable-proxy/UpgradeableProxy.sol";

import {SparkERC4626Conduit} from "../src/SparkERC4626Conduit.sol";

import {ORACLE_PRICE_SCALE} from "../lib/metamorpho/lib/morpho-blue/src/libraries/ConstantsLib.sol";

import {MarketParamsLib} from "lib/metamorpho/lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

contract SparkLendConduitIntegrationTestBase is DssTest {
    address DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address METAMORPHO_FACTORY = 0xA9c3D3a366466Fa809d1Ae982Fb2c46E5fC41101;

    address BORROWER = makeAddr("borrower");
    address SUPPLIER = makeAddr("supplier");

    address admin = makeAddr("admin");
    address buffer1 = makeAddr("buffer1");
    address buffer2 = makeAddr("buffer2");
    address operator1 = makeAddr("operator1");
    address operator2 = makeAddr("operator2");

    bytes32 constant ILK1 = "ilk1";
    bytes32 constant ILK2 = "ilk2";

    uint256 INIT_MORPHO_BALANCE; // dai.balanceOf(MORPHO)

    AllocatorRegistry registry;
    AllocatorRoles roles;

    IERC20 dai = IERC20(DAI);
    IMorpho morpho = IMorpho(MORPHO);
    OracleMock oracle;
    MarketParams marketParams;

    MockERC20 collateralToken;
    uint256 LLTV = 915000000000000000;
    Id id;

    IMetaMorphoFactory factory = IMetaMorphoFactory(METAMORPHO_FACTORY);
    address vault;

    SparkERC4626Conduit conduit;

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl, 18_970_366);

        // Starting state at block 18_970_366
        INIT_MORPHO_BALANCE = dai.balanceOf(MORPHO);

        collateralToken = new MockERC20("CollateralToken", "CTKN", 18);
        oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);
        marketParams = MarketParams(DAI, address(collateralToken), address(oracle), IRM, LLTV);
        morpho.createMarket(marketParams);
        id = MarketParamsLib.id(marketParams);

        vault = address(factory.createMetaMorpho(address(this), 1 days, DAI, "DAI vault", "MMDAI", hex""));

        IMetaMorpho(vault).submitCap(marketParams, 10e6 ether);
        vm.warp(block.timestamp + 1 days);
        IMetaMorpho(vault).acceptCap(marketParams);

        Id[] memory supplyQueue = new Id[](1);
        supplyQueue[0] = id;
        IMetaMorpho(vault).setSupplyQueue(supplyQueue);

        UpgradeableProxy proxy = new UpgradeableProxy();
        SparkERC4626Conduit impl = new SparkERC4626Conduit();

        proxy.setImplementation(address(impl));

        conduit = SparkERC4626Conduit(address(proxy));

        registry = new AllocatorRegistry();
        roles = new AllocatorRoles();

        conduit.setRoles(address(roles));
        conduit.setRegistry(address(registry));

        registry.file(ILK1, "buffer", buffer1);
        registry.file(ILK2, "buffer", buffer2);

        _setupOperatorRole(ILK1, operator1); // TODO: Change
        _setupOperatorRole(ILK2, operator2);

        // TODO: Use real buffer
        vm.prank(buffer1);
        IERC20(DAI).approve(address(conduit), type(uint256).max);

        vm.prank(buffer2);
        IERC20(DAI).approve(address(conduit), type(uint256).max);

        vm.prank(BORROWER);
        collateralToken.approve(MORPHO, type(uint256).max);

        vm.prank(SUPPLIER);
        IERC20(DAI).approve(MORPHO, type(uint256).max);

        conduit.setVaultAsset(DAI, vault);
        conduit.setAssetEnabled(DAI, true);
    }

    function _setupOperatorRole(bytes32 ilk_, address operator_) internal {
        uint8 ROLE = 0;

        // Ensure address(this) can always set for a new ilk
        roles.setIlkAdmin(ilk_, address(this));

        roles.setUserRole(ilk_, operator_, ROLE, true);

        address conduit_ = address(conduit);

        roles.setRoleAction(ilk_, ROLE, conduit_, conduit.deposit.selector, true);
        roles.setRoleAction(ilk_, ROLE, conduit_, conduit.withdraw.selector, true);
    }

    function _assertInvariants() internal {
        assertEq(conduit.totalShares(DAI), conduit.shares(DAI, ILK1) + conduit.shares(DAI, ILK2), "Invariant A");

        // NOTE: 1 error because 2 ilks, rounding error scales with number of ilks
        assertEq(
            conduit.getTotalDeposits(DAI),
            conduit.getDeposits(DAI, ILK1) + conduit.getDeposits(DAI, ILK2),
            "Invariant B"
        );

        assertApproxEqAbs(conduit.totalShares(DAI), IERC4626(vault).balanceOf(address(conduit)), 2, "Invariant C");

        assertApproxEqAbs(
            conduit.getTotalDeposits(DAI),
            IERC4626(vault).convertToAssets(IERC4626(vault).balanceOf(address(conduit))),
            2,
            "Invariant D"
        );
    }

    function _assertVaultState(uint256 totalAssets, uint256 balance, uint256 totalSupply) internal {
        assertApproxEqAbs(IERC4626(vault).totalAssets(), totalAssets, 1, "vault total assets");
        assertEq(IERC4626(vault).balanceOf(address(conduit)), balance, "vault balance");
        assertEq(IERC4626(vault).totalSupply(), totalSupply, "vault total suply");
    }

    function _assertDaiState(uint256 buffer1Balance, uint256 vaultBalance) internal {
        assertEq(dai.balanceOf(buffer1), buffer1Balance, "buffer1Balance");
        assertEq(dai.balanceOf(MORPHO) + dai.balanceOf(BORROWER), vaultBalance, "vaultBalance");
    }

    function _assertDaiState(uint256 buffer1Balance, uint256 buffer2Balance, uint256 vaultBalance) internal {
        _assertDaiState(buffer1Balance, vaultBalance);
        assertEq(dai.balanceOf(buffer2), buffer2Balance, "buffer2Balance");
    }

    function _assertConduitState(uint256 ilk1Shares, uint256 totalShares) internal {
        assertEq(conduit.shares(DAI, ILK1), ilk1Shares, "ilk1Shares");
        assertEq(conduit.totalShares(DAI), totalShares, "totalShares");
    }

    function _assertConduitState(uint256 ilk1Shares, uint256 ilk2Shares, uint256 totalShares) internal {
        _assertConduitState(ilk1Shares, totalShares);
        assertEq(conduit.shares(DAI, ILK2), ilk2Shares, "ilk2Shares");
    }
}

contract SparkLendConduitDepositIntegrationTests is SparkLendConduitIntegrationTestBase {
    function test_deposit_insufficientBalanceBoundary() external {
        deal(DAI, buffer1, 100 ether);

        vm.startPrank(operator1);
        vm.expectRevert("SafeERC20/transfer-from-failed");
        conduit.deposit(ILK1, DAI, 100 ether + 1);

        conduit.deposit(ILK1, DAI, 100 ether);
    }

    function test_deposit_zeroAddressBuffer() external {
        deal(DAI, buffer1, 100 ether);

        registry.file(ILK1, "buffer", address(0));

        vm.prank(operator1);
        vm.expectRevert("SparkERC4626Conduit/no-buffer-registered");
        conduit.deposit(ILK1, DAI, 100 ether);

        registry.file(ILK1, "buffer", buffer1);

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 100 ether);
    }

    function test_deposit_ilkNotRegistered() external {
        bytes32 ILK3 = "ilk3";
        address operator3 = makeAddr("operator3");
        address buffer3 = makeAddr("buffer3");

        vm.prank(buffer3);
        IERC20(DAI).approve(address(conduit), type(uint256).max);

        _setupOperatorRole(ILK3, operator3);

        deal(DAI, buffer3, 100 ether);

        // Same error, but because buffer was never initialized to begin with
        vm.prank(operator3);
        vm.expectRevert("SparkERC4626Conduit/no-buffer-registered");
        conduit.deposit(ILK3, DAI, 100 ether);

        registry.file(ILK3, "buffer", buffer3);

        vm.prank(operator3);
        conduit.deposit(ILK3, DAI, 100 ether);
    }

    function test_deposit_singleIlk_valueAccrual() external {
        deal(DAI, buffer1, 100 ether);

        _assertInvariants();

        _assertDaiState({buffer1Balance: 100 ether, vaultBalance: INIT_MORPHO_BALANCE});

        _assertVaultState({totalAssets: 0, balance: 0, totalSupply: 0});

        _assertConduitState({ilk1Shares: 0, totalShares: 0});

        uint256 expectedIlk1shares = IERC4626(vault).convertToShares(100 ether);

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 100 ether);

        _assertInvariants();

        _assertDaiState({buffer1Balance: 0, vaultBalance: INIT_MORPHO_BALANCE + 100 ether});

        _assertVaultState({totalAssets: 100 ether, balance: expectedIlk1shares, totalSupply: expectedIlk1shares});

        _assertConduitState({ilk1Shares: expectedIlk1shares, totalShares: expectedIlk1shares});

        // Borrow to accrue interest
        deal(address(collateralToken), BORROWER, 100 ether);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(marketParams, 100 ether, BORROWER, hex"");
        morpho.borrow(marketParams, 50 ether, 0, BORROWER, BORROWER);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        uint256 expectedSupplyBalance = MorphoBalancesLib.expectedSupplyAssets(morpho, marketParams, address(vault));

        _assertInvariants();

        _assertVaultState({
            totalAssets: expectedSupplyBalance,
            balance: expectedIlk1shares,
            totalSupply: expectedIlk1shares
        });
    }

    function test_deposit_multiIlk_valueAccrual() external {
        deal(DAI, buffer1, 100 ether);
        deal(DAI, buffer2, 50 ether);

        _assertInvariants();

        _assertDaiState({buffer1Balance: 100 ether, buffer2Balance: 50 ether, vaultBalance: INIT_MORPHO_BALANCE});

        _assertVaultState({totalAssets: 0, balance: 0, totalSupply: 0});

        _assertConduitState({ilk1Shares: 0, ilk2Shares: 0, totalShares: 0});

        uint256 expectedIlk1shares = IERC4626(vault).convertToShares(100 ether);

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 100 ether);

        // Borrow to accrue interest
        deal(address(collateralToken), BORROWER, 100 ether);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(marketParams, 100 ether, BORROWER, hex"");
        morpho.borrow(marketParams, 50 ether, 0, BORROWER, BORROWER);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        _assertInvariants();

        uint256 expectedSupplyBalance = MorphoBalancesLib.expectedSupplyAssets(morpho, marketParams, address(vault));

        _assertDaiState({buffer1Balance: 0, buffer2Balance: 50 ether, vaultBalance: INIT_MORPHO_BALANCE + 100 ether});

        _assertVaultState({
            totalAssets: expectedSupplyBalance,
            balance: expectedIlk1shares,
            totalSupply: expectedIlk1shares
        });

        _assertConduitState({ilk1Shares: expectedIlk1shares, totalShares: expectedIlk1shares});

        uint256 expectedIlk2shares = IERC4626(vault).convertToShares(50 ether);

        vm.prank(operator2);
        conduit.deposit(ILK2, DAI, 50 ether);

        _assertInvariants();

        _assertDaiState({buffer1Balance: 0, buffer2Balance: 0, vaultBalance: INIT_MORPHO_BALANCE + 150 ether});

        _assertVaultState({
            totalAssets: expectedSupplyBalance + 50 ether,
            balance: expectedIlk1shares + expectedIlk2shares,
            totalSupply: expectedIlk1shares + expectedIlk2shares
        });

        _assertConduitState({
            ilk1Shares: expectedIlk1shares,
            ilk2Shares: expectedIlk2shares,
            totalShares: expectedIlk1shares + expectedIlk2shares
        });
    }
}

contract SparkLendConduitWithdrawIntegrationTests is SparkLendConduitIntegrationTestBase {
    function test_withdraw_noBufferRegistered() external {
        deal(DAI, buffer1, 100 ether);

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 100 ether);

        registry.file(ILK1, "buffer", address(0));

        vm.prank(operator1);
        vm.expectRevert("SparkERC4626Conduit/no-buffer-registered");
        conduit.withdraw(ILK1, DAI, 100 ether);

        registry.file(ILK1, "buffer", buffer1);

        vm.prank(operator1);
        conduit.withdraw(ILK1, DAI, 100 ether);
    }

    function test_withdraw_singleIlk_valueAccrual() external {
        deal(DAI, buffer1, 100 ether);

        uint256 expectedIlk1shares = IERC4626(vault).convertToShares(100 ether);

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 100 ether);

        _assertInvariants();

        _assertDaiState({buffer1Balance: 0, vaultBalance: INIT_MORPHO_BALANCE + 100 ether});

        _assertVaultState({totalAssets: 100 ether, balance: expectedIlk1shares, totalSupply: expectedIlk1shares});

        _assertConduitState({ilk1Shares: expectedIlk1shares, totalShares: expectedIlk1shares});

        // Borrow to accrue interest
        deal(address(collateralToken), BORROWER, 100 ether);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(marketParams, 100 ether, BORROWER, hex"");
        morpho.borrow(marketParams, 50 ether, 0, BORROWER, BORROWER);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        _assertInvariants();

        uint256 expectedSupplyBalance = MorphoBalancesLib.expectedSupplyAssets(morpho, marketParams, address(vault));

        _assertVaultState({
            totalAssets: expectedSupplyBalance,
            balance: expectedIlk1shares,
            totalSupply: expectedIlk1shares
        });

        // Provide liquidity to allow withdraw
        deal(DAI, SUPPLIER, expectedSupplyBalance);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, expectedSupplyBalance, 0, SUPPLIER, hex"");

        vm.prank(operator1);
        uint256 amountWithdrawn = conduit.withdraw(ILK1, DAI, expectedSupplyBalance);

        // Slightly less funds received than withdrawn, causing dust of 1 in accounting, because of the utilization of assets (and not shares) to withdraw max.
        assertApproxEqAbs(amountWithdrawn, expectedSupplyBalance, 1);
        assertLe(amountWithdrawn, expectedSupplyBalance);

        _assertInvariants();

        _assertDaiState({
            buffer1Balance: amountWithdrawn,
            vaultBalance: INIT_MORPHO_BALANCE + 100 ether + expectedSupplyBalance - amountWithdrawn
        });

        _assertVaultState({totalAssets: 0, balance: 0, totalSupply: 0});

        _assertConduitState({ilk1Shares: 0, totalShares: 0});
    }

    function test_withdraw_multiIlk_valueAccrual() external {
        // Intentionally using same values for both ilks to show differences in interest accrual
        deal(DAI, buffer1, 100 ether);
        deal(DAI, buffer2, 100 ether);

        uint256 expectedIlk1shares = IERC4626(vault).convertToShares(100 ether);

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 100 ether);

        // Borrow to accrue interest
        deal(address(collateralToken), BORROWER, 100 ether);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(marketParams, 100 ether, BORROWER, hex"");
        morpho.borrow(marketParams, 50 ether, 0, BORROWER, BORROWER);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        uint256 expectedIlk2shares = IERC4626(vault).convertToShares(100 ether);

        vm.prank(operator2);
        conduit.deposit(ILK2, DAI, 100 ether);

        // Warp time to show interest accrual for both ilks
        vm.warp(block.timestamp + 10 days);

        _assertInvariants();

        _assertDaiState({
            buffer1Balance: 0,
            buffer2Balance: 0,
            vaultBalance: INIT_MORPHO_BALANCE + 100 ether + 100 ether
        });

        uint256 expectedSupplyBalance = MorphoBalancesLib.expectedSupplyAssets(morpho, marketParams, address(vault));

        _assertVaultState({
            totalAssets: expectedSupplyBalance,
            balance: expectedIlk1shares + expectedIlk2shares,
            totalSupply: expectedIlk1shares + expectedIlk2shares
        });

        _assertConduitState({
            ilk1Shares: expectedIlk1shares,
            ilk2Shares: expectedIlk2shares,
            totalShares: expectedIlk1shares + expectedIlk2shares
        });

        uint256 expectedIlk1Value = IERC4626(vault).convertToAssets(expectedIlk1shares);
        vm.prank(operator1);
        uint256 amountWithdrawn1 = conduit.withdraw(ILK1, DAI, expectedIlk1Value);

        // Slightly less funds received than withdrawn, causing dust of 1 in accounting, because of the utilization of assets (and not shares) to withdraw max.
        assertApproxEqAbs(amountWithdrawn1, expectedIlk1Value, 1);
        assertLe(amountWithdrawn1, expectedIlk1Value);

        _assertInvariants();

        uint256 combinedDeposits = 100 ether + 100 ether;

        _assertDaiState({
            buffer1Balance: amountWithdrawn1,
            buffer2Balance: 0,
            vaultBalance: INIT_MORPHO_BALANCE + combinedDeposits - amountWithdrawn1
        });

        _assertVaultState({
            totalAssets: expectedSupplyBalance - amountWithdrawn1,
            balance: expectedIlk2shares,
            totalSupply: expectedIlk2shares
        });

        _assertConduitState({ilk1Shares: 0, ilk2Shares: expectedIlk2shares, totalShares: expectedIlk2shares});

        vm.warp(block.timestamp + 1 days);

        uint256 expectedIlk2Value = IERC4626(vault).convertToAssets(expectedIlk2shares);

        // Provide liquidity to allow withdraw
        deal(DAI, SUPPLIER, expectedIlk2Value);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, expectedIlk2Value, 0, SUPPLIER, hex"");

        vm.prank(operator2);
        uint256 amountWithdrawn2 = conduit.withdraw(ILK2, DAI, expectedIlk2Value);

        // Slightly less funds received than withdrawn, causing dust of 1 in accounting, because of the utilization of assets (and not shares) to withdraw max.
        assertApproxEqAbs(amountWithdrawn2, expectedIlk2Value, 1);
        assertLe(amountWithdrawn2, expectedIlk2Value);

        _assertInvariants();

        _assertDaiState({
            buffer1Balance: amountWithdrawn1,
            buffer2Balance: amountWithdrawn2,
            vaultBalance: INIT_MORPHO_BALANCE + combinedDeposits + expectedIlk2Value - amountWithdrawn1 - amountWithdrawn2
        });

        expectedSupplyBalance = MorphoBalancesLib.expectedSupplyAssets(morpho, marketParams, address(vault));

        // Dust of 1 left after withdrawal
        _assertVaultState({totalAssets: expectedSupplyBalance, balance: 0, totalSupply: 0});

        _assertConduitState({ilk1Shares: 0, ilk2Shares: 0, totalShares: 0});
    }
}
