// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IVault} from "@symbiotic/interfaces/vault/IVault.sol";
import {IBaseDelegator} from "@symbiotic/interfaces/delegator/IBaseDelegator.sol";
import {IRegistry} from "@symbiotic/interfaces/common/IRegistry.sol";
import {IEntity} from "@symbiotic/interfaces/common/IEntity.sol";
import {IVetoSlasher} from "@symbiotic/interfaces/slasher/IVetoSlasher.sol";
import {Subnetwork} from "@symbiotic/contracts/libraries/Subnetwork.sol";
import {ISlasher} from "@symbiotic/interfaces/slasher/ISlasher.sol";
import {IOperatorSpecificDelegator} from "@symbiotic/interfaces/delegator/IOperatorSpecificDelegator.sol";

import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StakePowerManager} from "./extendable/StakePowerManager.sol";
import {CaptureTimestampManager} from "./extendable/CaptureTimestampManager.sol";

import {NetworkStorage} from "./storages/NetworkStorage.sol";
import {SlashingWindowStorage} from "./storages/SlashingWindowStorage.sol";

import {PauseableEnumerableSet} from "../libraries/PauseableEnumerableSet.sol";

/**
 * @title VaultManager
 * @notice Abstract contract for managing vaults and their relationships with operators and subnetworks
 * @dev Extends BaseManager and provides functionality for registering, pausing, and managing vaults
 */
abstract contract VaultManager is NetworkStorage, SlashingWindowStorage, CaptureTimestampManager, StakePowerManager {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableMap for EnumerableMap.AddressToAddressMap;
    using PauseableEnumerableSet for PauseableEnumerableSet.AddressSet;
    using PauseableEnumerableSet for PauseableEnumerableSet.Uint160Set;
    using Subnetwork for address;
    using Math for uint256;

    error NotVault();
    error VaultNotInitialized();
    error VaultAlreadyRegistered();
    error VaultEpochTooShort();
    error UnknownSlasherType();
    error NonVetoSlasher();
    error NotOperatorSpecificVault();

    /// @custom:storage-location erc7201:symbiotic.storage.VaultManager
    struct VaultManagerStorage {
        address _vaultRegistry;
        PauseableEnumerableSet.Uint160Set _subnetworks;
        PauseableEnumerableSet.AddressSet _sharedVaults;
        mapping(address => PauseableEnumerableSet.AddressSet) _operatorVaults;
        EnumerableMap.AddressToAddressMap _vaultOperator;
    }

    event InstantSlash(address vault, bytes32 subnetwork, uint256 amount);
    event VetoSlash(address vault, bytes32 subnetwork, uint256 index);

    enum SlasherType {
        INSTANT, // Instant slasher type
        VETO // Veto slasher type

    }

    enum DelegatorType {
        NETWORK_RESTAKE,
        FULL_RESTAKE,
        OPERATOR_SPECIFIC,
        OPERATOR_NETWORK_SPECIFIC
    }

    /**
     * @notice Structure to store slashing parameters
     * @param epochStartTs The epoch start timestamp
     * @param vault The vault address
     * @param operator The operator address
     * @param slashPercentage The percentage to slash
     * @param subnetwork The subnetwork identifier
     */
    struct SlashParams {
        uint48 epochStartTs;
        address vault;
        address operator;
        uint256 slashPercentage;
        bytes32 subnetwork;
    }

    // keccak256(abi.encode(uint256(keccak256("symbiotic.storage.VaultManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VaultManagerStorageLocation =
        0x485f0695561726d087d0cb5cf546efed37ef61dfced21455f1ba7eb5e5b3db00;

    uint256 public constant PARTS_PER_BILLION = 1_000_000_000;

    /**
     * @notice Internal helper to access the VaultManager storage struct
     * @dev Uses assembly to load storage location from a constant slot
     * @return $ Storage pointer to the VaultManagerStorage struct
     */
    function _getVaultManagerStorage() internal pure returns (VaultManagerStorage storage $) {
        assembly {
            $.slot := VaultManagerStorageLocation
        }
    }

    uint96 internal constant DEFAULT_SUBNETWORK = 0;

    /**
     * @notice Initializes the VaultManager with required parameters
     * @param vaultRegistry The address of the vault registry contract
     */
    function __VaultManager_init_private(
        address vaultRegistry
    ) internal onlyInitializing {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._vaultRegistry = vaultRegistry;
        _registerSubnetwork(DEFAULT_SUBNETWORK);
    }

    /**
     * @notice Gets the address of the vault registry contract
     * @return The vault registry contract address
     */
    function _VAULT_REGISTRY() internal view returns (address) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._vaultRegistry;
    }

    /**
     * @notice Gets the total number of shared vaults
     * @return uint256 The count of shared vaults
     */
    function _sharedVaultsLength() internal view returns (uint256) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._sharedVaults.length();
    }

    /**
     * @notice Gets the vault information at a specific index
     * @param pos The index position to query
     * @return address The vault address
     * @return uint48 The time when the vault was enabled
     * @return uint48 The time when the vault was disabled
     */
    function _sharedVaultWithTimesAt(
        uint256 pos
    ) internal view returns (address, uint48, uint48) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._sharedVaults.at(pos);
    }

    /**
     * @notice Gets all currently active shared vaults
     * @return address[] Array of active shared vault addresses
     */
    function _activeSharedVaults() internal view returns (address[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._sharedVaults.getActive(getCaptureTimestamp());
    }

    /**
     * @notice Gets all shared vaults that were active at a specific timestamp
     * @param timestamp The timestamp to check
     * @return address[] Array of shared vault addresses that were active at the timestamp
     */
    function _activeSharedVaultsAt(
        uint48 timestamp
    ) internal view returns (address[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._sharedVaults.getActive(timestamp);
    }

    /**
     * @notice Gets the number of vaults associated with an operator
     * @param operator The operator address to query
     * @return uint256 The count of vaults for the operator
     */
    function _operatorVaultsLength(
        address operator
    ) internal view returns (uint256) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._operatorVaults[operator].length();
    }

    /**
     * @notice Gets the vault information at a specific index for an operator
     * @param operator The operator address
     * @param pos The index position to query
     * @return address The vault address
     * @return uint48 The time when the vault was enabled
     * @return uint48 The time when the vault was disabled
     */
    function _operatorVaultWithTimesAt(address operator, uint256 pos) internal view returns (address, uint48, uint48) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._operatorVaults[operator].at(pos);
    }

    /**
     * @notice Gets all currently active vaults for a specific operator
     * @param operator The operator address
     * @return address[] Array of active vault addresses
     */
    function _activeOperatorVaults(
        address operator
    ) internal view returns (address[] memory) {
        return _activeOperatorVaultsAt(getCaptureTimestamp(), operator);
    }

    /**
     * @notice Gets all currently active vaults for a specific operator at a specific timestamp
     * @param timestamp The timestamp to check
     * @param operator The operator address
     * @return address[] Array of active vault addresses
     */
    function _activeOperatorVaultsAt(uint48 timestamp, address operator) internal view returns (address[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._operatorVaults[operator].getActive(timestamp);
    }

    /**
     * @notice Gets all currently active vaults across all operators
     * @return address[] Array of all active vault addresses
     */
    function _activeVaults() internal view returns (address[] memory) {
        return _activeVaultsAt(getCaptureTimestamp());
    }

    /**
     * @notice Gets all vaults that were active at a specific timestamp
     * @param timestamp The timestamp to check
     * @return address[] Array of vault addresses that were active at the timestamp
     */
    function _activeVaultsAt(
        uint48 timestamp
    ) internal view returns (address[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        address[] memory activeSharedVaults_ = $._sharedVaults.getActive(timestamp);
        uint256 len = activeSharedVaults_.length;
        uint256 operatorVaultsLen = $._vaultOperator.length();
        address[] memory vaults = new address[](len + operatorVaultsLen);

        for (uint256 i; i < len; ++i) {
            vaults[i] = activeSharedVaults_[i];
        }

        for (uint256 i; i < operatorVaultsLen; ++i) {
            (address vault, address operator) = $._vaultOperator.at(i);
            if ($._operatorVaults[operator].wasActiveAt(timestamp, vault)) {
                vaults[len++] = vault;
            }
        }

        assembly {
            mstore(vaults, len)
        }

        return vaults;
    }

    /**
     * @notice Gets all currently active vaults for a specific operator
     * @param operator The operator address
     * @return address[] Array of active vault addresses for the operator
     */
    function _activeVaults(
        address operator
    ) internal view returns (address[] memory) {
        return _activeVaultsAt(getCaptureTimestamp(), operator);
    }

    /**
     * @notice Gets all vaults that were active for an operator at a specific timestamp
     * @param timestamp The timestamp to check
     * @param operator The operator address
     * @return address[] Array of vault addresses that were active at the timestamp
     */
    function _activeVaultsAt(uint48 timestamp, address operator) internal view returns (address[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        address[] memory activeSharedVaults_ = $._sharedVaults.getActive(timestamp);
        address[] memory activeOperatorVaults_ = $._operatorVaults[operator].getActive(timestamp);

        uint256 activeSharedVaultsLen = activeSharedVaults_.length;
        uint256 activeOperatorVaultsLen = activeOperatorVaults_.length;
        address[] memory vaults = new address[](activeSharedVaultsLen + activeOperatorVaultsLen);
        for (uint256 i; i < activeSharedVaultsLen; ++i) {
            vaults[i] = activeSharedVaults_[i];
        }
        for (uint256 i; i < activeOperatorVaultsLen; ++i) {
            vaults[activeSharedVaultsLen + i] = activeOperatorVaults_[i];
        }

        return vaults;
    }

    /**
     * @notice Checks if a vault was active at a specific timestamp
     * @param timestamp The timestamp to check
     * @param operator The operator address
     * @param vault The vault address
     * @return bool True if the vault was active at the timestamp
     */
    function _vaultWasActiveAt(uint48 timestamp, address operator, address vault) internal view returns (bool) {
        return _sharedVaultWasActiveAt(timestamp, vault) || _operatorVaultWasActiveAt(timestamp, operator, vault);
    }

    /**
     * @notice Checks if a shared vault was active at a specific timestamp
     * @param timestamp The timestamp to check
     * @param vault The vault address
     * @return bool True if the shared vault was active at the timestamp
     */
    function _sharedVaultWasActiveAt(uint48 timestamp, address vault) internal view returns (bool) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._sharedVaults.wasActiveAt(timestamp, vault);
    }

    /**
     * @notice Checks if an operator vault was active at a specific timestamp
     * @param timestamp The timestamp to check
     * @param operator The operator address
     * @param vault The vault address
     * @return bool True if the operator vault was active at the timestamp
     */
    function _operatorVaultWasActiveAt(
        uint48 timestamp,
        address operator,
        address vault
    ) internal view returns (bool) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._operatorVaults[operator].wasActiveAt(timestamp, vault);
    }

    /**
     * @notice Gets the stake amount for an operator in a vault and subnetwork at a specific timestamp
     * @param timestamp The timestamp to check
     * @param operator The operator address
     * @param vault The vault address
     * @return uint256 The stake amount at the timestamp
     */
    function _getOperatorStakeAt(uint48 timestamp, address operator, address vault) private view returns (uint256) {
        bytes32 subnetworkId = _NETWORK().subnetwork(0);
        return IBaseDelegator(IVault(vault).delegator()).stakeAt(subnetworkId, operator, timestamp, "");
    }

    /**
     * @notice Gets the power amount for an operator in a vault
     * @param operator The operator address
     * @param vault The vault address
     * @return uint256 The power amount
     */
    function _getOperatorPower(address operator, address vault) internal view returns (uint256) {
        return _getOperatorPowerAt(getCaptureTimestamp(), operator, vault);
    }

    /**
     * @notice Gets the power amount for an operator in a vault at a specific timestamp
     * @param timestamp The timestamp to check
     * @param operator The operator address
     * @param vault The vault address
     * @return uint256 The power amount at the timestamp
     */
    function _getOperatorPowerAt(uint48 timestamp, address operator, address vault) internal view returns (uint256) {
        uint256 stake = _getOperatorStakeAt(timestamp, operator, vault);
        return stakeToPower(vault, stake);
    }

    /**
     * @notice Gets the total power amount for an operator across all vaults
     * @param operator The operator address
     * @return power The total power amount
     */
    function _getOperatorPower(
        address operator
    ) internal view returns (uint256 power) {
        return _getOperatorPowerAt(getCaptureTimestamp(), operator);
    }

    /**
     * @notice Gets the total power amount for an operator across all vaults at a specific timestamp
     * @param timestamp The timestamp to check
     * @param operator The operator address
     * @return power The total power amount at the timestamp
     */
    function _getOperatorPowerAt(uint48 timestamp, address operator) internal view returns (uint256 power) {
        address[] memory vaults = _activeVaultsAt(timestamp, operator);

        return _getOperatorPowerAt(timestamp, operator, vaults);
    }

    /**
     * @notice Gets the total power amount for an operator across all vaults
     * @param operator The operator address
     * @param vaults The list of vault addresses
     * @return power The total power amount
     */
    function _getOperatorPower(address operator, address[] memory vaults) internal view returns (uint256 power) {
        return _getOperatorPowerAt(getCaptureTimestamp(), operator, vaults);
    }

    /**
     * @notice Gets the total power amount for an operator across all vaults at a specific timestamp
     * @param timestamp The timestamp to check
     * @param operator The operator address
     * @param vaults The list of vault addresses
     * @return power The total power amount at the timestamp
     */
    function _getOperatorPowerAt(
        uint48 timestamp,
        address operator,
        address[] memory vaults
    ) internal view returns (uint256 power) {
        for (uint256 i; i < vaults.length; ++i) {
            address vault = vaults[i];
            power += _getOperatorPowerAt(timestamp, operator, vault);
        }

        return power;
    }

    /**
     * @notice Calculates the total power for a list of operators
     * @param operators Array of operator addresses
     * @return power The total power amount
     */
    function _totalPower(
        address[] memory operators
    ) internal view returns (uint256 power) {
        for (uint256 i; i < operators.length; ++i) {
            power += _getOperatorPower(operators[i]);
        }

        return power;
    }

    /**
     * @notice Registers a new subnetwork
     * @param subnetwork The subnetwork identifier to register
     */
    function _registerSubnetwork(
        uint96 subnetwork
    ) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._subnetworks.register(_now(), uint160(subnetwork));
    }

    /**
     * @notice Registers a new shared vault
     * @param vault The vault address to register
     */
    function _registerSharedVault(
        address vault
    ) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        _validateVault(vault);
        $._sharedVaults.register(_now(), vault);
    }

    /**
     * @notice Registers a new operator vault
     * @param operator The operator address
     * @param vault The vault address to register
     */
    function _registerOperatorVault(address operator, address vault) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        _validateVault(vault);
        _validateOperatorVault(operator, vault);

        $._operatorVaults[operator].register(_now(), vault);
        $._vaultOperator.set(vault, operator);
    }

    /**
     * @notice Pauses a shared vault
     * @param vault The vault address to pause
     */
    function _pauseSharedVault(
        address vault
    ) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._sharedVaults.pause(_now(), vault);
    }

    /**
     * @notice Unpauses a shared vault
     * @param vault The vault address to unpause
     */
    function _unpauseSharedVault(
        address vault
    ) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._sharedVaults.unpause(_now(), _SLASHING_WINDOW(), vault);
    }

    /**
     * @notice Pauses an operator vault
     * @param operator The operator address
     * @param vault The vault address to pause
     */
    function _pauseOperatorVault(address operator, address vault) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._operatorVaults[operator].pause(_now(), vault);
    }

    /**
     * @notice Unpauses an operator vault
     * @param operator The operator address
     * @param vault The vault address to unpause
     */
    function _unpauseOperatorVault(address operator, address vault) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._operatorVaults[operator].unpause(_now(), _SLASHING_WINDOW(), vault);
    }

    /**
     * @notice Unregisters a shared vault
     * @param vault The vault address to unregister
     */
    function _unregisterSharedVault(
        address vault
    ) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._sharedVaults.unregister(_now(), _SLASHING_WINDOW(), vault);
    }

    /**
     * @notice Unregisters an operator vault
     * @param operator The operator address
     * @param vault The vault address to unregister
     */
    function _unregisterOperatorVault(address operator, address vault) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._operatorVaults[operator].unregister(_now(), _SLASHING_WINDOW(), vault);
        $._vaultOperator.remove(vault);
    }

    /**
     * @notice Slashes a vault based on provided conditions
     * @param epochStartTs The epoch start timestamp
     * @param operator The operator address
     * @param percentage The percentage to slash (in parts per billion)
     * @dev emit VaultManager.InstantSlash or VaultManager.VetoSlash based on slasher type
     */
    function _slash(uint48 epochStartTs, address operator, uint256 percentage) internal {
        SlashParams memory params;
        params.epochStartTs = epochStartTs;
        params.operator = operator;
        params.slashPercentage = percentage;
        // Tanssi will use only one subnetwork so we only check the first
        params.subnetwork = _NETWORK().subnetwork(0);

        address[] memory vaults = _activeVaultsAt(epochStartTs, operator);
        // simple pro-rata slasher
        uint256 vaultsLength = vaults.length;
        for (uint256 i; i < vaultsLength;) {
            _processVaultSlashing(vaults[i], params);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Get vault stake and calculate slashing amount.
     * @param vault The vault address to calculate its stake
     * @param params Struct containing slashing parameters
     */
    function _processVaultSlashing(address vault, SlashParams memory params) private {
        uint256 vaultStake = IBaseDelegator(IVault(vault).delegator()).stakeAt(
            params.subnetwork, params.operator, params.epochStartTs, new bytes(0)
        );
        // Slash percentage is already in parts per billion
        // so we need to divide by a billion
        uint256 slashAmount = params.slashPercentage.mulDiv(vaultStake, PARTS_PER_BILLION);

        _slashVault(params.epochStartTs, vault, params.subnetwork, params.operator, slashAmount);
    }

    /**
     * @dev Slashes a vault's stake for a specific operator. Middleware SDK already provides _slashVault function but  custom version is needed to avoid revert in specific scenarios for the gateway message passing.
     * @param timestamp Time at which the epoch started
     * @param vault Address of the vault to slash
     * @param subnetwork Subnetwork identifier
     * @param operator Address of the operator being slashed
     * @param amount Amount to slash
     */
    function _slashVault(
        uint48 timestamp,
        address vault,
        bytes32 subnetwork,
        address operator,
        uint256 amount
    ) private {
        address slasher = IVault(vault).slasher();

        if (slasher == address(0) || amount == 0) {
            return;
        }
        uint256 slasherType = IEntity(slasher).TYPE();

        uint256 response;
        if (slasherType == uint256(SlasherType.INSTANT)) {
            response = ISlasher(slasher).slash(subnetwork, operator, amount, timestamp, new bytes(0));
            emit VaultManager.InstantSlash(vault, subnetwork, response);
        } else if (slasherType == uint256(SlasherType.VETO)) {
            response = IVetoSlasher(slasher).requestSlash(subnetwork, operator, amount, timestamp, new bytes(0));
            emit VaultManager.VetoSlash(vault, subnetwork, response);
        } else {
            revert VaultManager.UnknownSlasherType();
        }
    }

    /**
     * @notice Executes a veto-based slash for a vault
     * @param vault The vault address
     * @param slashIndex The index of the slash to execute
     * @param hints Additional data for the veto slasher
     * @return slashedAmount The amount that was slashed
     */
    function _executeSlash(
        address vault,
        uint256 slashIndex,
        bytes memory hints
    ) internal returns (uint256 slashedAmount) {
        address slasher = IVault(vault).slasher();
        uint64 slasherType = IEntity(slasher).TYPE();
        if (slasherType != uint64(SlasherType.VETO)) {
            revert NonVetoSlasher();
        }

        return IVetoSlasher(slasher).executeSlash(slashIndex, hints);
    }

    /**
     * @notice Validates if a vault is properly initialized and registered
     * @param vault The vault address to validate
     */
    function _validateVault(
        address vault
    ) private view {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        if (!IRegistry(_VAULT_REGISTRY()).isEntity(vault)) {
            revert NotVault();
        }

        if (!IVault(vault).isInitialized()) {
            revert VaultNotInitialized();
        }

        if ($._vaultOperator.contains(vault) || $._sharedVaults.contains(vault)) {
            revert VaultAlreadyRegistered();
        }

        uint48 vaultEpoch = IVault(vault).epochDuration();

        address slasher = IVault(vault).slasher();
        if (slasher != address(0)) {
            uint64 slasherType = IEntity(slasher).TYPE();
            if (slasherType == uint64(SlasherType.VETO)) {
                vaultEpoch -= IVetoSlasher(slasher).vetoDuration();
            } else if (slasherType > uint64(SlasherType.VETO)) {
                revert UnknownSlasherType();
            }
        }

        if (vaultEpoch < _SLASHING_WINDOW()) {
            revert VaultEpochTooShort();
        }
    }

    function _validateOperatorVault(address operator, address vault) internal view {
        address delegator = IVault(vault).delegator();
        uint64 delegatorType = IEntity(delegator).TYPE();
        if (
            (
                delegatorType != uint64(DelegatorType.OPERATOR_SPECIFIC)
                    && delegatorType != uint64(DelegatorType.OPERATOR_NETWORK_SPECIFIC)
            ) || IOperatorSpecificDelegator(delegator).operator() != operator
        ) {
            revert NotOperatorSpecificVault();
        }
    }
}
