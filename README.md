# ECMcoinVestingWithRewards — README

A robust, production-grade ERC-20 vesting contract with **linear vesting**, **optional cliffs**, **owner-controlled revocation**, and a **linear rewards** mechanism that accrues alongside vesting. Designed for DAOs, teams, and token issuers who need **auditable**, **fully funded**, and **gas-efficient** distribution schedules.

---

## Table of contents

* [Key features](#key-features)
* [Concepts & math](#concepts--math)
* [Contract addresses & tokens](#contract-addresses--tokens)
* [Installation & build](#installation--build)
* [Deployment](#deployment)
* [Funding the contract](#funding-the-contract)
* [Creating schedules](#creating-schedules)
* [Claiming (beneficiaries)](#claiming-beneficiaries)
* [Owner operations](#owner-operations)
* [View & helper functions](#view--helper-functions)
* [Events](#events)
* [Custom errors](#custom-errors)
* [Access control & security](#access-control--security)
* [Lifecycle examples](#lifecycle-examples)
* [Testing ideas](#testing-ideas)
* [Gas & design notes](#gas--design-notes)
* [FAQ](#faq)
* [License](#license)

---

## Key features

* **Linear vesting** with customizable:

  * `start` (future timestamp),
  * `cliff` (seconds from `start`),
  * `duration` (seconds),
  * `revocable` flag,
  * `amountTotal`.

* **Linear rewards** tied to vesting progress:
  Rewards accrue in sync with vesting using `rewardRate` in **0.1% precision** (`REWARD_RATE_PRECISION = 1000`, so `105` = 10.5%). Max = 100% of principal.

* **O(1) solvency tracking** via `rewardObligations`:
  A single number that always equals **principal remaining + rewards remaining** across all active schedules. The owner can **safely withdraw** only the over-collateral.

* **Safe by default**:

  * OpenZeppelin `Ownable`, `ReentrancyGuard`, `SafeERC20`, `Math`.
  * Custom errors (lower gas + clear failure reasons).
  * All state validated; reentrancy-safe claims & withdrawals.

* **Great DX**:

  * Query due amounts now (`getDueNow`) and funding shortfall (`getFundingShortfall`).
  * Enumerate schedules; compute schedule IDs deterministically.

---

## Concepts & math

### Vesting

* Nothing vests **before the cliff** (`currentTime < cliff ⇒ 0`).
* After `start + duration`, **all remaining** principal vests.
* In between, vested principal grows linearly:

  ```
  vested = amountTotal * (currentTime - start) / duration
  releasable = vested - released
  ```

### Rewards

* Max rewards for a schedule:

  ```
  totalReward = amountTotal * rewardRate / REWARD_RATE_PRECISION
  ```
* Accrual is linear with vesting progress (same time scale):

  ```
  earnedRewards = totalReward * (min(currentTime, start+duration) - start) / duration
  claimableRewards = max(0, earnedRewards - totalRewardClaimed[id])
  ```

### Solvency (funding)

* `rewardObligations` tracks **everything the contract still owes** (unreleased principal + unclaimed rewards).
* When a schedule is created:

  ```
  rewardObligations += amountTotal
  rewardObligations += totalReward
  ```
* When tokens are released or rewards claimed, obligations decrease by the amount paid.
* Revocation:

  * Calls `claimVestedAndRewards()` first (pays anything already due),
  * Then subtracts **unreleased principal** and **unaccrued rewards** from obligations, and marks the schedule revoked.

---

## Contract addresses & tokens

* This contract manages **one ERC-20 token** provided at construction:

  ```solidity
  constructor(address ecmToken_) Ownable(msg.sender)
  ```
* `_ecmToken` is immutable. You **cannot** change it later.

---

## Installation & build

```bash
# Install dependencies
npm install

# Install OZ if not already present
npm install @openzeppelin/contracts

# Compile with Hardhat
npx hardhat compile

# Run tests (add your test files under test/)
npx hardhat test
```

---

## Deployment

Example Hardhat deployment script:

```ts
// scripts/deploy.ts
import { ethers } from "hardhat";

async function main() {
  const TOKEN = "0xYourERC20TokenAddress"; // ECM token address

  const Vesting = await ethers.getContractFactory("ECMcoinVestingWithRewards");
  const vesting = await Vesting.deploy(TOKEN);
  await vesting.waitForDeployment();

  console.log("ECMcoinVestingWithRewards deployed at:", await vesting.getAddress());
}

main().catch((e) => { console.error(e); process.exit(1); });
```

Run:

```bash
npx hardhat run scripts/deploy.ts --network <your-network>
```

---

## Funding the contract

Before creating schedules, **fund the contract** with enough tokens to cover the resulting obligations.

* Compute **required** balance at any time:

  ```solidity
  getRequiredTokenBalance()  // == rewardObligations
  getFundingShortfall()      // == max(0, rewardObligations - tokenBalance)
  ```
* Fund by transferring tokens to the contract:

  ```bash
  # using a script or console:
  await token.transfer(vestingAddress, amount)
  ```

> If underfunded, claim calls will revert with `InsufficientContractBalance`.

---

## Creating schedules

Only the **owner** can create a schedule:

```solidity
function createVestingSchedule(
  address _beneficiary,
  uint256 _start,
  uint256 _cliff,      // seconds from start
  uint256 _duration,   // total seconds
  bool    _revocable,
  uint256 _amount,     // principal tokens to vest
  uint256 _rewardRate  // 0..1000 (0.1% steps), e.g., 105 = 10.5%
) external onlyOwner;
```

**Validation**

* `_start` must be **in the future**.
* `_duration > 0` and `_duration > _cliff`.
* `_amount > 0`.
* `_rewardRate ≤ MAX_REWARD_RATE (= 1000)`.
* Schedule ID must be **unused** (contract auto-computes it).

**Schedule ID**

* Deterministic per holder + index:

  ```
  id = keccak256(abi.encodePacked(beneficiary, holdersVestingCount[beneficiary]))
  ```
* Use `computeNextVestingScheduleIdForHolder(holder)` to preview next ID.

**Example (Hardhat console)**

```js
const now = (await ethers.provider.getBlock("latest")).timestamp;
const start = now + 3600;       // starts in 1 hour
const cliff = 30 * 24 * 3600;   // 30 days
const duration = 180 * 24 * 3600; // 6 months
const amount = ethers.parseUnits("1000000", 18);
const rewardRate = 100;         // 10.0%

await vesting.createVestingSchedule(
  "0xBeneficiary",
  start, cliff, duration,
  true,     // revocable
  amount,
  rewardRate
);
```

---

## Claiming (beneficiaries)

Beneficiaries (or owner on their behalf) have two main paths:

### 1) Claim both vested principal and rewards (recommended)

```solidity
function claimVestedAndRewards(bytes32 vestingScheduleId) public;
```

* Combines vested principal **and** claimable rewards in one transfer.
* Updates all state **before** external calls (safe).
* Emits `CombinedClaimed`.

### 2) Claim only rewards

```solidity
function claimReward(bytes32 vestingScheduleId) external;
```

* Beneficiary-only path (owner cannot call this on behalf).
* Emits `RewardClaimed`.

### 3) Claim only principal (custom amount)

```solidity
function release(bytes32 vestingScheduleId, uint256 amount) public;
```

* Beneficiary or owner can release a **subset** of the releasable principal.

> All three methods are `nonReentrant` and validate schedule existence and non-revoked status.

---

## Owner operations

* **Revoke a schedule** (if revocable):

  ```solidity
  revoke(bytes32 vestingScheduleId)
  ```

  Steps:

  1. Pays out anything currently due (principal + rewards),
  2. Forfeits unvested principal and unaccrued rewards,
  3. Updates global accounting,
  4. Marks schedule `revoked`.

* **Withdraw excess tokens** (over-collateral only):

  ```solidity
  withdraw(uint256 amount)
  ```

  * Withdrawable = `tokenBalance - rewardObligations`.
  * Reverts if trying to withdraw needed funds.

---

## View & helper functions

* **Per-schedule**

  * `getVestingSchedule(bytes32 id) → VestingSchedule`
  * `computeReleasableAmount(bytes32 id) → uint256`
  * `computeClaimableReward(bytes32 id) → uint256`
  * `projectRewardsAtTime(bytes32 id, uint256 ts) → (projected, newRewards)`
  * `getDueNow(bytes32 id) → (duePrincipal, dueRewards, totalDue)`

* **Global / accounting**

  * `getRequiredTokenBalance() → uint256` (== `rewardObligations`)
  * `getFundingShortfall() → uint256`
  * `getWithdrawableAmount() → uint256`

* **Enumeration & IDs**

  * `getVestingSchedulesCount() → uint256`
  * `getVestingSchedulesTotalAmount() → uint256`
  * `getVestingSchedulesCountByBeneficiary(address) → uint256`
  * `getVestingIdAtIndex(uint256) → bytes32`
  * `getVestingScheduleByAddressAndIndex(address holder, uint256 index) → VestingSchedule`
  * `computeVestingScheduleIdForAddressAndIndex(address holder, uint256 index) → bytes32`
  * `computeNextVestingScheduleIdForHolder(address holder) → bytes32`
  * `getLastVestingScheduleForHolder(address) → VestingSchedule`

---

## Events

| Event                    | When                       | Params                                                                   |
| ------------------------ | -------------------------- | ------------------------------------------------------------------------ |
| `VestingScheduleCreated` | On create                  | `id, beneficiary, start, cliff, duration, revocable, amount, rewardRate` |
| `VestingScheduleRevoked` | On revoke                  | `id`                                                                     |
| `TokensReleased`         | On `release`               | `id, beneficiary, amount`                                                |
| `RewardClaimed`          | On `claimReward`           | `id, beneficiary, amount`                                                |
| `CombinedClaimed`        | On `claimVestedAndRewards` | `id, beneficiary, vestedAmount, rewardAmount`                            |
| `Withdraw`               | On owner withdraw          | `to, amount`                                                             |

---

## Custom errors

Clear, gas-efficient reverts:

* **Input validation**: `ZeroAddress`, `ZeroAddressBeneficiary`, `AmountMustBePositive`, `DurationMustBePositive`, `DurationMustBeGreaterThanCliff`, `InvalidRewardRate`, `StartTimeMustBeFuture`
* **Solvency / balances**: `InsufficientTokens` *(reserved)*, `InsufficientContractBalance`, `NotEnoughWithdrawableFunds`
* **Schedule state**: `ScheduleNotFound`, `ScheduleRevoked`, `NotRevocable`, `DuplicateScheduleId`, `InvalidScheduleId`
* **Permissions**: `NotBeneficiaryOrOwner`
* **Operations**: `NoClaimableAmount`, `CannotRescueVestingToken` *(reserved)*

---

## Access control & security

* **Owner**:

  * `createVestingSchedule`, `revoke`, `withdraw`, and can also call `release`/`claimVestedAndRewards` on behalf of beneficiaries.
* **Beneficiary**:

  * May call `release`, `claimVestedAndRewards`, `claimReward` (rewards-only path is beneficiary-only).
* **Security design**:

  * All transfers use `SafeERC20`.
  * All external-facing state-changing claim paths are `nonReentrant`.
  * Accounting updated **before** transfers.
  * Schedule creation requires **future** `start` and strict param checks.
  * Global solvency via `rewardObligations` avoids accidental underfunding on owner withdrawals.

---

## Lifecycle examples

### A) Create → Fund → Claim

1. **Fund** (recommended to slightly over-fund):

   * Transfer `amountTotal + totalReward` (and a buffer) to the contract.

2. **Create** a schedule with:

   * `start = now + 1 day`, `cliff = 30 days`, `duration = 180 days`, `rewardRate = 150 (15%)`.

3. **Before cliff**:

   * `computeReleasableAmount = 0`, `computeClaimableReward = 0`.

4. **During vesting**:

   * `release(id, amount)` or `claimVestedAndRewards(id)` to pull vested principal (and/or rewards).

5. **After full duration**:

   * One last `claimVestedAndRewards(id)` releases everything left (principal + any unclaimed rewards).

### B) Revocation (owner)

* If `revocable` is true:

  * Call `revoke(id)`.
  * Contract first pays what’s due (vested + rewards so far), then forfeits the rest and updates obligations.

---

## Testing ideas

* **Happy paths**: create → mid-vesting claims → final claim.
* **Cliff boundary**: just before / at / after `cliff`.
* **Revocation**: 0% vested, 50% vested, 100% vested scenarios.
* **Under/over-funding**: ensure claim reverts on shortfall; owner can withdraw only over-collateral.
* **Multiple schedules per beneficiary**: enumeration, ID collisions prevented.
* **RewardRate edge cases**: 0%, 100% (max).
* **Time travel**: use Hardhat to advance time and confirm linearity.

---

## Gas & design notes

* **O(1) global solvency**: `rewardObligations` avoids iterating schedules to decide withdrawable amounts.
* **Custom errors** reduce gas over revert strings.
* **Math.mulDiv** with `Rounding.Floor` provides precise, overflow-safe arithmetic.
* Reward & vesting calculations share the **same linear time base**, which is intuitive and easy to reason about.

---

## FAQ

**Q: Can I create multiple schedules for the same beneficiary?**
Yes. IDs are `keccak256(beneficiary, index)`. Use enumeration helpers to manage them.

**Q: Can the owner claim on behalf of a beneficiary?**
Yes for combined (`claimVestedAndRewards`) and principal (`release`). **Rewards-only** (`claimReward`) is beneficiary-only.

**Q: What happens if the contract is underfunded?**
Claim functions revert with `InsufficientContractBalance`. Top up the contract or avoid creating schedules without funding first.

**Q: Can I change the reward rate after creation?**
No. Schedules are immutable except revocation (if flagged).

**Q: Does the contract accept ETH?**
A `receive()`/`fallback()` exists to safely accept ETH, but ETH is **not** used in any accounting. Only the ERC-20 token matters.

---

## License

SPDX-License-Identifier: **MIT**

---

### Appendix: Quick reference (common calls)

```solidity
// Preview next ID for a user
bytes32 nextId = vesting.computeNextVestingScheduleIdForHolder(user);

// View how much is due right now
(uint256 principal, uint256 reward, uint256 total) = vesting.getDueNow(id);

// Claim both principal+rewards (beneficiary or owner)
vesting.claimVestedAndRewards(id);

// Claim rewards only (beneficiary only)
vesting.claimReward(id);

// Release a custom principal amount (beneficiary or owner)
vesting.release(id, amount);

// Revoke (owner, only if revocable=true)
vesting.revoke(id);

// Withdraw excess tokens (owner-only)
vesting.withdraw(amount);

// Check solvency
uint256 required = vesting.getRequiredTokenBalance();
uint256 shortfall = vesting.getFundingShortfall();
uint256 withdrawable = vesting.getWithdrawableAmount();
```
