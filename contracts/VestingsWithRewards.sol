// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "hardhat/console.sol";

/**
 * @title ECMcoinVestingWithRewards
 * @notice This contract manages linear token vesting schedules with optional rewards for beneficiaries.
 * @dev Features:
 *   - Linear vesting with optional cliff and revocability
 *   - Configurable reward rate, accruing linearly with vesting progress
 *   - O(1) tracking of total required token balance (vesting + rewards)
 *   - Secure, non-reentrant, and robust against overflows and double-claims
 *   - Owner can revoke, withdraw excess, and query all schedules
 *   - Beneficiaries can claim vested tokens and/or rewards independently or together
 *   - Custom errors for all validation and operational failures
 *   - Designed for use with ERC20 tokens (e.g., ECM token)
 *
 * Security:
 *   - Uses OpenZeppelin Ownable, ReentrancyGuard, SafeERC20, and Math libraries
 *   - All state changes validated and protected against reentrancy
 *   - All critical arithmetic uses checked math and overflow guards
 *   - All user and owner actions revert with custom errors on invalid input or state
 *
 * Intended for DAOs, teams, or projects needing robust, auditable vesting and reward distribution.
 */
contract ECMcoinVestingWithRewards is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Custom errors for input validation
    error ZeroAddress();
    error ZeroAddressBeneficiary();
    error AmountMustBePositive();
    error DurationMustBePositive();
    error DurationMustBeGreaterThanCliff();
    error InsufficientTokens();
    error InvalidRewardRate(); // When reward rate is above maximum

    // Custom errors for vesting operations
    error ScheduleNotFound();
    error ScheduleRevoked();
    error NotRevocable();
    error NotBeneficiaryOrOwner();
    error NoClaimableAmount();
    error NotEnoughWithdrawableFunds();

    // Custom errors for batch operations (not yet implemented, but referenced in test stubs)
    error DuplicateScheduleId();
    error InvalidScheduleId();

    // Custom errors for timing and validation
    error StartTimeMustBeFuture(); // When start time is in the past
    error InsufficientContractBalance(); // When contract has insufficient balance
    error CannotRescueVestingToken(); // When trying to rescue vesting token

    // --- Constants ---
    uint256 public constant REWARD_RATE_PRECISION = 1000; // Precision for reward rate (0.1% increments)
    uint256 public constant MAX_REWARD_RATE = REWARD_RATE_PRECISION; // Maximum allowed reward rate (100%)

    // --- Core state variables ---
    IERC20 private immutable _ecmToken; // The ERC20 token being vested and rewarded
    bytes32[] private vestingSchedulesIds; // List of all vesting schedule IDs (for enumeration)
    uint256 private vestingSchedulesTotalAmount; // Total amount of tokens in all active vesting schedules
    uint256 private rewardObligations; // Total outstanding obligations (vesting + rewards) required to fully fund all schedules

    // --- Vesting schedule data structure ---
    struct VestingSchedule {
        address beneficiary; // Address receiving vested tokens and rewards
        uint256 cliff; // Timestamp when vesting cliff ends (no vesting before this)
        uint256 start; // Vesting start timestamp
        uint256 duration; // Total vesting duration in seconds
        bool revocable; // True if owner can revoke this schedule
        uint256 amountTotal; // Total amount of tokens to be vested
        uint256 released; // Amount of tokens already released to beneficiary
        bool revoked; // True if schedule has been revoked
        uint256 rewardRate; // Reward rate (0.1% precision, e.g. 105 = 10.5%)
    }

    // --- State mappings ---
    mapping(bytes32 => VestingSchedule) private vestingSchedules; // Maps schedule ID to VestingSchedule struct
    mapping(bytes32 => uint256) private totalRewardClaimed; // Maps schedule ID to total rewards claimed so far
    mapping(address => uint256) private holdersVestingCount; // Maps beneficiary address to their number of schedules

    // Events for vesting operations
    event VestingScheduleCreated(
        bytes32 indexed vestingScheduleId,
        address indexed beneficiary,
        uint256 start,
        uint256 cliff,
        uint256 duration,
        bool revocable,
        uint256 amount,
        uint256 rewardRate
    );
    event VestingScheduleRevoked(bytes32 indexed vestingScheduleId);
    event TokensReleased(
        bytes32 indexed vestingScheduleId,
        address indexed beneficiary,
        uint256 amount
    );
    event RewardClaimed(
        bytes32 indexed vestingScheduleId,
        address indexed beneficiary,
        uint256 amount
    );
    event CombinedClaimed(
        bytes32 indexed vestingScheduleId,
        address indexed beneficiary,
        uint256 vestedAmount,
        uint256 rewardAmount
    );
    event Withdraw(address indexed to, uint256 amount);

    modifier onlyIfVestingScheduleExists(bytes32 id) {
        if (vestingSchedules[id].beneficiary == address(0))
            revert ScheduleNotFound();
        _;
    }
    /**
     * @dev Reverts if the vesting schedule does not exist or has been revoked.
     */
    modifier onlyIfVestingScheduleNotRevoked(bytes32 vestingScheduleId) {
        if (vestingSchedules[vestingScheduleId].revoked)
            revert ScheduleRevoked();
        _;
    }

    /**
     * @dev Creates a vesting contract.
     * @param ecmToken_ address of the ECM token contract
     */
    constructor(address ecmToken_) Ownable(msg.sender) {
        if (ecmToken_ == address(0)) revert ZeroAddress();
        _ecmToken = IERC20(ecmToken_);
    }

    /**
     * @dev This function is called for plain Ether transfers, i.e. for every call with empty calldata.
     */
    receive() external payable {}

    /**
     * @dev Fallback function is executed if none of the other functions match the function
     * identifier or no data was provided with the function call.
     */
    fallback() external payable {}

    /**
     * @notice Initializes a new vesting schedule with optional linear rewards for a beneficiary.
     * @dev This function configures both vesting and reward parameters for a new schedule, ensuring robust validation and preventing accidental overwrites.
     * Vesting Details:
     * Tokens vest linearly over the specified _duration, starting after a _cliff period.
     * No tokens are vested or claimable before the cliff ends.
     * Vesting progress is proportional to elapsed time since _start, up to _duration.
     * Reward Details:
     * Rewards accrue linearly in sync with vesting progress.
     * The total possible reward is calculated as _amount * _rewardRate / REWARD_RATE_PRECISION.
     * Rewards are claimable as vesting progresses, but not before the cliff.
     * Security & Validation:
     * Only the contract owner can create schedules.
     * Validates that the start time is in the future, the beneficiary is not the zero address, and all numeric parameters are positive and within bounds.
     * Prevents schedule ID collisions and arithmetic overflows.
     * Updates global accounting for vesting and reward obligations to ensure the contract remains fully funded.
     * @param _beneficiary The address to receive vested tokens and rewards.
     * @param _start The timestamp when vesting begins.
     * @param _cliff The duration (in seconds) before vesting starts (cliff period).
     * @param _duration The total duration (in seconds) over which tokens vest.
     * @param _revocable Whether the owner can revoke this vesting schedule.
     * @param _amount The total number of tokens to be vested.
     * @param _rewardRate The reward rate (0-1000, with 0.1% precision; e.g., 105 = 10.5%).
     */

    function createVestingSchedule(
        address _beneficiary,
        uint256 _start,
        uint256 _cliff,
        uint256 _duration,
        bool _revocable,
        uint256 _amount,
        uint256 _rewardRate
    ) external onlyOwner {
        // --- Validation checks ---
        // Vesting must start in the future
        if (_start < block.timestamp) revert StartTimeMustBeFuture();
        // Beneficiary cannot be zero address
        if (_beneficiary == address(0)) revert ZeroAddressBeneficiary();
        // Duration must be positive
        if (_duration == 0) revert DurationMustBePositive();
        // Amount must be positive
        if (_amount == 0) revert AmountMustBePositive();
        // Duration must be strictly greater than cliff
        if (_duration <= _cliff) revert DurationMustBeGreaterThanCliff();
        // Overflow guard: _start + _duration must not overflow
        if (_start + _duration < _start) revert DurationMustBePositive();
        // Reward rate must not exceed maximum
        if (_rewardRate > MAX_REWARD_RATE) revert InvalidRewardRate();

        // Compute the new vesting schedule ID for this beneficiary
        bytes32 vestingScheduleId = computeNextVestingScheduleIdForHolder(
            _beneficiary
        );
        // Prevent accidental overwrite of an existing schedule
        if (vestingSchedules[vestingScheduleId].beneficiary != address(0))
            revert DuplicateScheduleId();

        // Calculate absolute cliff timestamp
        uint256 cliffAbs = _start + _cliff;

        // Store the new vesting schedule
        vestingSchedules[vestingScheduleId] = VestingSchedule(
            _beneficiary,
            cliffAbs,
            _start,
            _duration,
            _revocable,
            _amount,
            0, // released
            false, // revoked
            _rewardRate
        );

        // Track total vesting amount for all schedules
        vestingSchedulesTotalAmount += _amount;

        // --- Update obligations ---
        // Add both vesting and reward obligations for this schedule
        rewardObligations += _amount;
        rewardObligations += Math.mulDiv(
            _amount,
            _rewardRate,
            REWARD_RATE_PRECISION,
            Math.Rounding.Floor
        );

        // Track schedule IDs and beneficiary count
        vestingSchedulesIds.push(vestingScheduleId);
        holdersVestingCount[_beneficiary] += 1;

        // Initialize reward tracking for this schedule
        totalRewardClaimed[vestingScheduleId] = 0;

        // Emit event for new schedule
        emit VestingScheduleCreated(
            vestingScheduleId,
            _beneficiary,
            _start,
            cliffAbs,
            _duration,
            _revocable,
            _amount,
            _rewardRate
        );
    }

    /**
     * @notice Revokes a vesting schedule, claiming all vested tokens and rewards, and forfeiting the remainder
     * @dev This function:
     * 1. Claims all currently vested tokens and accrued rewards for the beneficiary
     * 2. Forfeits all unvested tokens and unaccrued rewards
     * 3. Updates global accounting (vestingSchedulesTotalAmount and rewardObligations)
     * 4. Marks the schedule as revoked to prevent further claims
     * 
     * Security & Validation:
     * - Only callable by contract owner
     * - Only valid for existing, unrevoked, revocable schedules
     * - Processes any claimable amounts before revocation
     * - Updates all accounting atomically to maintain consistent state
     * 
     * @param vestingScheduleId The unique identifier of the vesting schedule to revoke
     * @dev Emits:
     * - CombinedClaimed event if there are claimable amounts
     * - VestingScheduleRevoked event upon successful revocation
     */
    function revoke(
        bytes32 vestingScheduleId
    )
        external
        onlyOwner
        onlyIfVestingScheduleExists(vestingScheduleId)
        onlyIfVestingScheduleNotRevoked(vestingScheduleId)
    {
        VestingSchedule storage vestingSchedule = vestingSchedules[
            vestingScheduleId
        ];
        if (!vestingSchedule.revocable) revert NotRevocable();

        // Claim any vested and reward tokens (this will update released/claimed and reduce rewardObligations for those portions)
        claimVestedAndRewards(vestingScheduleId);

        // Calculate unreleased vesting and unaccrued reward
        uint256 unreleased = vestingSchedule.amountTotal -
            vestingSchedule.released;
        if (unreleased > 0) {
            vestingSchedulesTotalAmount -= unreleased;
            // Only log if there are unreleased tokens
            rewardObligations -= unreleased;
        }

        // uint256 unaccruedReward = Math.mulDiv(unreleased, vestingSchedule.rewardRate, REWARD_RATE_PRECISION, Math.Rounding.Floor);
        uint256 totalReward = _totalReward(vestingScheduleId);
        uint256 remainingReward = totalReward -
            totalRewardClaimed[vestingScheduleId];
        if (remainingReward > 0) {
            rewardObligations -= remainingReward;
        }

        vestingSchedule.revoked = true;
        emit VestingScheduleRevoked(vestingScheduleId);
    }

    /**
     * @notice Allows the owner to withdraw excess tokens not needed for vesting or rewards
     * @dev This function enables the contract owner to withdraw tokens that exceed the total obligations.
     * 
     * Withdrawal Rules:
     * - Only withdrawable amount = current balance - total obligations (vesting + rewards)
     * - Prevents withdrawing tokens needed for vesting schedules or rewards
     * - Fails if requested amount exceeds withdrawable balance
     * 
     * Security & Validation:
     * - Only callable by contract owner (onlyOwner)
     * - Protected against reentrancy (nonReentrant)
     * - Uses SafeERC20 for token transfers
     * - Reverts if amount exceeds withdrawable balance
     * 
     * @param amount The number of tokens to withdraw
     * @dev Emits:
     * - Withdraw event with recipient address and amount
     */
    function withdraw(uint256 amount) external nonReentrant onlyOwner {
        uint256 withdrawable = getWithdrawableAmount();
        if (withdrawable < amount) revert NotEnoughWithdrawableFunds();
        _ecmToken.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    /**
     * @notice Releases a specific amount of vested tokens to the beneficiary
     * @dev This function allows beneficiaries or the owner to claim tokens that have vested according to the schedule.
     * 
     * Release Mechanics:
     * - Only releases tokens that have actually vested based on time elapsed
     * - Updates vesting accounting (released amount, total vesting amount)
     * - Reduces reward obligations by the released amount
     * - Transfers tokens directly to the beneficiary
     * 
     * Security & Validation:
     * - Protected against reentrancy (nonReentrant)
     * - Only callable by beneficiary or contract owner
     * - Only valid for existing, unrevoked schedules
     * - Amount must be positive and not exceed releasable amount
     * - Updates all accounting atomically before transfer
     * 
     * @param vestingScheduleId The unique identifier of the vesting schedule
     * @param amount The amount of tokens to release (must not exceed releasable amount)
     * @dev Emits:
     * - TokensReleased event with schedule ID, beneficiary, and amount
     */
    function release(
        bytes32 vestingScheduleId,
        uint256 amount
    )
        public
        nonReentrant
        onlyIfVestingScheduleExists(vestingScheduleId)
        onlyIfVestingScheduleNotRevoked(vestingScheduleId)
    {
        VestingSchedule storage vestingSchedule = vestingSchedules[
            vestingScheduleId
        ];
        if (
            !(msg.sender == vestingSchedule.beneficiary ||
                msg.sender == owner())
        ) revert NotBeneficiaryOrOwner();
        uint256 releasable = _computeReleasableAmount(vestingSchedule);
        if (!(releasable >= amount && amount > 0)) revert NoClaimableAmount();
        vestingSchedule.released += amount;
        vestingSchedulesTotalAmount -= amount;
        rewardObligations -= amount; // Reduce only the vesting part
        _ecmToken.safeTransfer(vestingSchedule.beneficiary, amount);
        emit TokensReleased(
            vestingScheduleId,
            vestingSchedule.beneficiary,
            amount
        );
    }

    /**
     * @notice Claims all available vested tokens and accrued rewards in a single transaction
     * @dev This function optimizes the claiming process by combining vested token and reward claims:
     * 
     * Claim Process:
     * 1. Calculates total releasable vested tokens based on elapsed time
     * 2. Computes claimable rewards based on vesting progress
     * 3. Combines both amounts and transfers in a single transaction
     * 4. Updates all relevant accounting (vesting amounts, rewards, obligations)
     * 
     * State Updates:
     * - vestingSchedule.released: Tracks released tokens
     * - vestingSchedulesTotalAmount: Reduces total vesting amount
     * - totalRewardClaimed: Updates claimed rewards for schedule
     * - rewardObligations: Reduces both vesting and reward obligations
     * 
     * Security & Validation:
     * - Protected against reentrancy (nonReentrant)
     * - Only callable by beneficiary or contract owner
     * - Only valid for existing, unrevoked schedules
     * - Verifies contract has sufficient balance
     * - Updates all state before external calls
     * 
     * @param vestingScheduleId The unique identifier of the vesting schedule
     * @dev Emits:
     * - CombinedClaimed event with vested amount and reward amount
     * @dev Note: This is the preferred method for claiming both vested tokens and rewards
     * as it is more gas efficient than separate calls
     */
    function claimVestedAndRewards(
        bytes32 vestingScheduleId
    )
        public
        nonReentrant
        onlyIfVestingScheduleExists(vestingScheduleId)
        onlyIfVestingScheduleNotRevoked(vestingScheduleId)
    {
        VestingSchedule storage vestingSchedule = vestingSchedules[
            vestingScheduleId
        ];
        if (msg.sender != vestingSchedule.beneficiary && msg.sender != owner())
            revert NotBeneficiaryOrOwner();

        // Get releasable vested amount
        uint256 releasableAmount = _computeReleasableAmount(vestingSchedule);

        // Get claimable rewards
        uint256 claimableRewards = computeClaimableReward(vestingScheduleId);

        uint256 totalAmount = releasableAmount + claimableRewards;
        if (_ecmToken.balanceOf(address(this)) < totalAmount)
            revert InsufficientContractBalance();

        // Update states first
        if (releasableAmount > 0) {
            vestingSchedule.released += releasableAmount;
            vestingSchedulesTotalAmount -= releasableAmount;
        }
        if (claimableRewards > 0) {
            totalRewardClaimed[vestingScheduleId] += claimableRewards;
        }
        // Emit event for combined claim
        if (totalAmount > 0) {
            rewardObligations -= totalAmount; // Reduce both vesting and reward parts
            _ecmToken.safeTransfer(vestingSchedule.beneficiary, totalAmount);
            emit CombinedClaimed(
                vestingScheduleId,
                vestingSchedule.beneficiary,
                releasableAmount,
                claimableRewards
            );
        }
    }

    /**
     * @notice Claims only rewards (keeping for backward compatibility)
     * @param vestingScheduleId the vesting schedule identifier
     */
    function claimReward(
        bytes32 vestingScheduleId
    )
        external
        nonReentrant
        onlyIfVestingScheduleExists(vestingScheduleId)
        onlyIfVestingScheduleNotRevoked(vestingScheduleId)
    {
        VestingSchedule storage vestingSchedule = vestingSchedules[
            vestingScheduleId
        ];
        if (msg.sender != vestingSchedule.beneficiary)
            revert NotBeneficiaryOrOwner();
        uint256 claimable = computeClaimableReward(vestingScheduleId);
        if (claimable == 0) revert NoClaimableAmount();
        totalRewardClaimed[vestingScheduleId] += claimable;
        rewardObligations -= claimable;
        _ecmToken.safeTransfer(vestingSchedule.beneficiary, claimable);
        emit RewardClaimed(
            vestingScheduleId,
            vestingSchedule.beneficiary,
            claimable
        );
    }

    /**
     * @notice Computes the claimable reward for a vesting schedule.
     * @param vestingScheduleId the vesting schedule identifier
     * @return The amount of rewards claimable based on linear vesting progress
     */
    /**
     * @notice Computes the currently claimable reward for a vesting schedule.
     * @dev The reward calculation is based on linear vesting progress.
     * Formula: totalRewardAmount = vestingAmount * rewardRate / 100
     *         earnedRewards = totalRewardAmount * timePassed / vestingDuration
     *         claimableRewards = earnedRewards - alreadyClaimedRewards
     * @param vestingScheduleId the vesting schedule identifier
     * @return The amount of rewards currently claimable
     */
    function computeClaimableReward(
        bytes32 vestingScheduleId
    )
        public
        view
        onlyIfVestingScheduleExists(vestingScheduleId)
        onlyIfVestingScheduleNotRevoked(vestingScheduleId)
        returns (uint256)
    {
        VestingSchedule storage vestingSchedule = vestingSchedules[
            vestingScheduleId
        ];
        uint256 currentTime = getCurrentTime();

        // If before cliff or revoked, no rewards
        if ((currentTime < vestingSchedule.cliff) || vestingSchedule.revoked) {
            return 0;
        }

        // Calculate time progress for rewards
        uint256 timeFromStart = currentTime - vestingSchedule.start;
        if (timeFromStart > vestingSchedule.duration) {
            timeFromStart = vestingSchedule.duration;
        }

        // Calculate total rewards based on linear progress with increased precision
        uint256 totalReward = Math.mulDiv(
            vestingSchedule.amountTotal,
            vestingSchedule.rewardRate,
            REWARD_RATE_PRECISION,
            Math.Rounding.Floor
        );

        uint256 earnedRewards = Math.mulDiv(
            totalReward,
            timeFromStart,
            vestingSchedule.duration,
            Math.Rounding.Floor
        );

        // Prevent underflow: if already claimed >= earned, return 0
        uint256 alreadyClaimed = totalRewardClaimed[vestingScheduleId];
        if (earnedRewards <= alreadyClaimed) {
            return 0;
        }
        // Subtract already claimed rewards
        return earnedRewards - alreadyClaimed;
    }

    /**
     * @notice Projects the reward amount that will be claimable at a future timestamp
     * @dev This is a view function that simulates reward calculation at a future time
     * @param vestingScheduleId the vesting schedule identifier
     * @param timestamp the future timestamp to project rewards for
     * @return projectedReward The projected total claimable reward at the given timestamp
     * @return newRewards The new rewards that will be earned between now and the timestamp
     */
    function projectRewardsAtTime(
        bytes32 vestingScheduleId,
        uint256 timestamp
    )
        public
        view
        onlyIfVestingScheduleExists(vestingScheduleId)
        onlyIfVestingScheduleNotRevoked(vestingScheduleId)
        returns (uint256 projectedReward, uint256 newRewards)
    {
        VestingSchedule storage vestingSchedule = vestingSchedules[
            vestingScheduleId
        ];

        // If timestamp is before cliff or schedule is revoked, return 0
        if ((timestamp < vestingSchedule.cliff) || vestingSchedule.revoked) {
            return (0, 0);
        }

        // Calculate time progress for rewards at the projected timestamp
        uint256 timeFromStart = timestamp - vestingSchedule.start;
        if (timeFromStart > vestingSchedule.duration) {
            timeFromStart = vestingSchedule.duration;
        }

        // Calculate total rewards based on linear progress with increased precision (match computeClaimableReward)
        uint256 totalReward = Math.mulDiv(
            vestingSchedule.amountTotal,
            vestingSchedule.rewardRate,
            REWARD_RATE_PRECISION,
            Math.Rounding.Floor
        );
        uint256 projectedEarnedRewards = Math.mulDiv(
            totalReward,
            timeFromStart,
            vestingSchedule.duration,
            Math.Rounding.Floor
        );

        uint256 alreadyClaimed = totalRewardClaimed[vestingScheduleId];
        uint256 currentlyClaimable = computeClaimableReward(vestingScheduleId);

        // Prevent underflow: if already claimed >= projected, return 0
        if (projectedEarnedRewards <= alreadyClaimed) {
            projectedReward = 0;
        } else {
            projectedReward = projectedEarnedRewards - alreadyClaimed;
        }
        // Prevent underflow for newRewards as well
        if (projectedReward <= currentlyClaimable) {
            newRewards = 0;
        } else {
            newRewards = projectedReward - currentlyClaimable;
        }
        return (projectedReward, newRewards);
    }

    function _totalReward(bytes32 id) internal view returns (uint256) {
        VestingSchedule storage s = vestingSchedules[id];
        return
            Math.mulDiv(
                s.amountTotal,
                s.rewardRate,
                REWARD_RATE_PRECISION,
                Math.Rounding.Floor
            );
    }

    function getFundingShortfall() public view returns (uint256) {
        uint256 bal = _ecmToken.balanceOf(address(this));
        return rewardObligations > bal ? (rewardObligations - bal) : 0;
    }

    function getDueNow(
        bytes32 id
    )
        public
        view
        returns (uint256 duePrincipal, uint256 dueRewards, uint256 totalDue)
    {
        VestingSchedule memory s = vestingSchedules[id];
        if (s.beneficiary == address(0) || s.revoked) return (0, 0, 0);
        uint256 releasable = _computeReleasableAmount(s);
        uint256 claimable = computeClaimableReward(id);
        return (releasable, claimable, releasable + claimable);
    }

    /**
     * @dev Returns the number of vesting schedules associated to a beneficiary.
     * @return the number of vesting schedules
     */
    function getVestingSchedulesCountByBeneficiary(
        address _beneficiary
    ) external view returns (uint256) {
        return holdersVestingCount[_beneficiary];
    }

    /**
     * @dev Returns the vesting schedule id at the given index.
     * @return the vesting id
     */
    function getVestingIdAtIndex(
        uint256 index
    ) external view returns (bytes32) {
        if (index >= getVestingSchedulesCount()) revert ScheduleNotFound();
        return vestingSchedulesIds[index];
    }

    /**
     * @notice Returns the vesting schedule information for a given holder and index.
     * @return the vesting schedule structure information
     */
    function getVestingScheduleByAddressAndIndex(
        address holder,
        uint256 index
    ) external view returns (VestingSchedule memory) {
        if (index >= holdersVestingCount[holder]) revert ScheduleNotFound();
        return
            getVestingSchedule(
                computeVestingScheduleIdForAddressAndIndex(holder, index)
            );
    }

    /**
     * @notice Returns the total amount of vesting schedules.
     * @return the total amount of vesting schedules
     */
    function getVestingSchedulesTotalAmount() external view returns (uint256) {
        return vestingSchedulesTotalAmount;
    }

    /**
     * @dev Returns the address of the ERC20 token managed by the vesting contract.
     */
    function getToken() external view returns (address) {
        return address(_ecmToken);
    }

    function getRequiredTokenBalance()
        external
        view
        returns (uint256 requiredTokens)
    {
        return rewardObligations;
    }

    /**
     * @dev Returns the number of vesting schedules managed by this contract.
     * @return the number of vesting schedules
     */
    function getVestingSchedulesCount() public view returns (uint256) {
        return vestingSchedulesIds.length;
    }

    /**
     * @notice Computes the vested amount of tokens for the given vesting schedule identifier.
     * @return the vested amount
     */
    function computeReleasableAmount(
        bytes32 vestingScheduleId
    )
        external
        view
        onlyIfVestingScheduleExists(vestingScheduleId)
        onlyIfVestingScheduleNotRevoked(vestingScheduleId)
        returns (uint256)
    {
        VestingSchedule storage vestingSchedule = vestingSchedules[
            vestingScheduleId
        ];
        return _computeReleasableAmount(vestingSchedule);
    }

    /**
     * @notice Returns the vesting schedule information for a given identifier.
     * @return the vesting schedule structure information
     */
    function getVestingSchedule(
        bytes32 vestingScheduleId
    ) public view returns (VestingSchedule memory) {
        return vestingSchedules[vestingScheduleId];
    }

    /**
     * @dev Returns the amount of tokens that can be withdrawn by the owner.
     * @return the amount of tokens
     */
    function getWithdrawableAmount() public view returns (uint256) {
        uint256 balance = _ecmToken.balanceOf(address(this));
        if (balance < rewardObligations) revert InsufficientContractBalance();
        return balance - rewardObligations;
    }

    /**
     * @dev Computes the next vesting schedule identifier for a given holder address.
     * @param holder The address of the holder
     * @return The next vesting schedule identifier
     */
    function computeNextVestingScheduleIdForHolder(
        address holder
    ) public view returns (bytes32) {
        return
            computeVestingScheduleIdForAddressAndIndex(
                holder,
                holdersVestingCount[holder]
            );
    }

    /**
     * @dev Returns the last vesting schedule for a given holder address.
     */
    function getLastVestingScheduleForHolder(
        address holder
    ) external view returns (VestingSchedule memory) {
        uint256 count = holdersVestingCount[holder];
        if (count == 0) revert ScheduleNotFound();
        return
            vestingSchedules[
                computeVestingScheduleIdForAddressAndIndex(
                    holder,
                    holdersVestingCount[holder] - 1
                )
            ];
    }

    /**
     * @dev Computes the vesting schedule identifier for an address and an index.
     */
    function computeVestingScheduleIdForAddressAndIndex(
        address holder,
        uint256 index
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(holder, index));
    }

    /**
     * @dev Computes the releasable amount of tokens for a vesting schedule.
     * @dev The vesting calculation follows these rules:
     * 1. Before cliff or if revoked: 0 tokens are releasable
     * 2. After full duration: All remaining tokens are releasable
     * 3. Between cliff and full duration: Linear vesting applies
     *
     * Linear Vesting Formula:
     * vestedAmount = totalAmount * timeElapsed / totalDuration
     * releasableAmount = vestedAmount - alreadyReleased
     *
     * @param vestingSchedule The vesting schedule to compute releasable amount for
     * @return The amount of tokens that can be released at the current time:
     * - 0 if before cliff or revoked
     * - (amountTotal - released) if fully vested
     * - Linear proportion if partially vested
     */
    function _computeReleasableAmount(
        VestingSchedule memory vestingSchedule
    ) internal view returns (uint256) {
        uint256 currentTime = getCurrentTime();

        // No tokens are releasable before cliff or if schedule is revoked
        if ((currentTime < vestingSchedule.cliff) || vestingSchedule.revoked) {
            return 0;
        }

        // All remaining tokens are releasable after full duration
        if (currentTime >= vestingSchedule.start + vestingSchedule.duration) {
            return vestingSchedule.amountTotal - vestingSchedule.released;
        }

        // Calculate linearly vested amount between cliff and end
        uint256 timeFromStart = currentTime - vestingSchedule.start;
        uint256 vestedAmount = Math.mulDiv(
            vestingSchedule.amountTotal,
            timeFromStart,
            vestingSchedule.duration,
            Math.Rounding.Floor
        );
        return vestedAmount - vestingSchedule.released;
    }

    /**
     * @dev Returns the current time.
     * @return the current timestamp in seconds.
     */
    function getCurrentTime() internal view virtual returns (uint256) {
        return block.timestamp;
    }
}
