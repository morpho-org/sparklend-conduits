// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import { IERC4626 }  from 'forge-std/interfaces/IERC4626.sol';
import { SafeERC20 } from 'erc20-helpers/SafeERC20.sol';

import { UpgradeableProxied } from 'upgradeable-proxy/UpgradeableProxied.sol';

import { ISparkERC4626Conduit } from './interfaces/ISparkERC4626Conduit.sol';

interface RolesLike {
    function canCall(bytes32, address, address, bytes4) external view returns (bool);
}

interface RegistryLike {
    function buffers(bytes32 ilk) external view returns (address buffer);
}

contract SparkERC4626Conduit is UpgradeableProxied, ISparkERC4626Conduit {

    using SafeERC20  for address;

    /**********************************************************************************************/
    /*** Storage                                                                                ***/
    /**********************************************************************************************/

    address public override roles;
    address public override registry;

    // TODO: renaming?
    mapping(address => address) public assetToVault;

    mapping(address => bool) public override enabled;

    mapping(address => uint256) public override totalShares;

    mapping(address => mapping(bytes32 => uint256)) public override shares;

    /**********************************************************************************************/
    /*** Modifiers                                                                              ***/
    /**********************************************************************************************/

    modifier auth() {
        require(wards[msg.sender] == 1, "SparkERC4626Conduit/not-authorized");
        _;
    }

    modifier ilkAuth(bytes32 ilk) {
        require(
            RolesLike(roles).canCall(ilk, msg.sender, address(this), msg.sig),
            "SparkERC4626Conduit/ilk-not-authorized"
        );
        _;
    }

    /**********************************************************************************************/
    /*** Admin Functions                                                                        ***/
    /**********************************************************************************************/

    function setRoles(address _roles) external override auth {
        roles = _roles;

        emit SetRoles(_roles);
    }

    function setRegistry(address _registry) external override auth {
        registry = _registry;

        emit SetRegistry(_registry);
    }

    function setAssetEnabled(address asset, bool enabled_) external override auth {
        enabled[asset] = enabled_;
        asset.safeApprove(assetToVault[asset], enabled_ ? type(uint256).max : 0);

        emit SetAssetEnabled(asset, enabled_);
    }

    // TODO: add to interface
    // Note: when changing the vault, the asset is disabled by default.
    // Note: make sure to withdraw all funds before changing the vault.
    function setVaultAsset(address asset, address vault) external auth {
        // Disable the asset if the vault is unset
        // TODO: confirm this is the desired behavior
        // TODO: can create weird behavior
        if (assetToVault[asset] != vault) enabled[asset] = false;

        assetToVault[asset] = vault;

        emit SetVaultAsset(asset, vault);
    }

    /**********************************************************************************************/
    /*** Operator Functions                                                                     ***/
    /**********************************************************************************************/

    function deposit(bytes32 ilk, address asset, uint256 amount) external override ilkAuth(ilk) {
        require(enabled[asset], "SparkERC4626Conduit/asset-disabled");

        address source = RegistryLike(registry).buffers(ilk);

        require(source != address(0), "SparkERC4626Conduit/no-buffer-registered");

        // Convert asset amount to shares
        uint256 newShares = _convertToShares(asset, amount);

        shares[asset][ilk] += newShares;
        totalShares[asset] += newShares;

        asset.safeTransferFrom(source, address(this), amount);
        IERC4626(assetToVault[asset]).deposit(amount, address(this));

        emit Deposit(ilk, asset, source, amount);
    }

    function withdraw(bytes32 ilk, address asset, uint256 maxAmount)
        external override ilkAuth(ilk) returns (uint256 amount)
    {
        // Constrain the amount that can be withdrawn by the max amount
        amount = _min(maxAmount, maxWithdraw(ilk, asset));

        // Convert the amount to withdraw to shares
        // TODO: check if we still need to round up
        uint256 withdrawalShares = _min(shares[asset][ilk], _convertToShares(asset, amount));

        // Reduce share accounting by the amount withdrawn
        shares[asset][ilk] -= withdrawalShares;
        totalShares[asset] -= withdrawalShares;

        address destination = RegistryLike(registry).buffers(ilk);

        require(destination != address(0), "SparkERC4626Conduit/no-buffer-registered");

        IERC4626(assetToVault[asset]).withdraw(amount, destination, address(this));

        emit Withdraw(ilk, asset, destination, amount);
    }

    /**********************************************************************************************/
    /*** View Functions                                                                         ***/
    /**********************************************************************************************/

    function maxDeposit(bytes32, address asset) public view override returns (uint256 maxDeposit_) {
        return enabled[asset] ? IERC4626(assetToVault[asset]).maxDeposit() : 0;
    }

    function maxWithdraw(bytes32 ilk, address asset)
        public view override returns (uint256 maxWithdraw_)
    {
        return _min(_convertToAssets(asset, shares[asset][ilk]), getAvailableLiquidity(asset));
    }

    function getTotalDeposits(address asset) external view override returns (uint256) {
        return _convertToAssets(asset, totalShares[asset]);
    }

    function getDeposits(address asset, bytes32 ilk) external view override returns (uint256) {
        return _convertToAssets(asset, shares[asset][ilk]);
    }

    function getAvailableLiquidity(address asset) public view override returns (uint256) {
        return IERC4626(assetToVault[asset]).maxWithdraw();
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _convertToAssets(address asset, uint256 amount) internal view returns (uint256) {
        return IERC4626(assetToVault[asset]).convertToAssets(amount);
    }

    function _convertToShares(address asset, uint256 amount) internal view returns (uint256) {
        return IERC4626(assetToVault[asset]).convertToShares(amount);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
