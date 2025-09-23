import { expect } from "chai";
import hre, { ethers } from "hardhat";
import { parseEther, ZeroAddress } from "ethers";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("TokenVesting", function () {
  let Token: any;
  let testToken: any;
  let owner: any;
  let addr1: any;
  let addr2: any;
  let addrs: any;
  let ECMcoinVestingWithRewards: any;


  describe("ECMcoinVestingWithRewards - Deployment & Initialization", function () {

    beforeEach(async function () {
      await hre.network.provider.send("hardhat_reset");
      [owner, addr1, addr2, ...addrs] = await ethers.getSigners();
      Token = await ethers.getContractFactory("MockERC20");
      ECMcoinVestingWithRewards = await ethers.getContractFactory("ECMcoinVestingWithRewards");
      testToken = await Token.deploy("Test Token", "TT", parseEther("1000000"));
    });

    it("Should revert if ECM token address is zero", async function () {
      await expect(ECMcoinVestingWithRewards.deploy(ZeroAddress)).to.be.revertedWithCustomError(
        ECMcoinVestingWithRewards, "ZeroAddress"
      );
    });

    it("Should initialize with correct token address", async function () {
      const vesting = await ECMcoinVestingWithRewards.deploy(testToken.target);
      expect(await vesting.getToken()).to.equal(testToken.target);
    });
  });

  describe("ECMcoinVestingWithRewards - Vesting Schedule Creation", function () {
    let vesting: any;
    const rewardRate = 100; // 10%
    const cliff = 60 * 60 * 24 * 30; // 1 month
    const duration = 60 * 60 * 24 * 180; // 6 months
    const amount = parseEther("1000");
    beforeEach(async function () {
      await hre.network.provider.send("hardhat_reset");
      [owner, addr1, addr2, ...addrs] = await ethers.getSigners();
      Token = await ethers.getContractFactory("MockERC20");
      ECMcoinVestingWithRewards = await ethers.getContractFactory("ECMcoinVestingWithRewards");
      testToken = await Token.deploy("Test Token", "TT", parseEther("1000000"));
      vesting = await ECMcoinVestingWithRewards.deploy(testToken.target);
    });

    it("Should create a vesting schedule with valid parameters", async function () {
      await testToken.transfer(vesting.target, amount);
      await expect(
        vesting.createVestingSchedule(
          addr1.address,
          Math.floor(Date.now() / 1000) + 100,
          cliff,
          duration,
          true,
          amount,
          rewardRate
        )
      ).to.emit(vesting, "VestingScheduleCreated");
    });

    it("Should revert if beneficiary is zero address", async function () {
      await testToken.transfer(vesting.target, amount);
      await expect(
        vesting.createVestingSchedule(
          ethers.ZeroAddress,
          Math.floor(Date.now() / 1000) + 100,
          cliff,
          duration,
          true,
          amount,
          rewardRate
        )
      ).to.be.revertedWithCustomError(vesting, "ZeroAddressBeneficiary");
    });

    it("Should revert if amount is zero", async function () {
      await testToken.transfer(vesting.target, amount);
      await expect(
        vesting.createVestingSchedule(
          addr1.address,
          Math.floor(Date.now() / 1000) + 100,
          cliff,
          duration,
          true,
          0,
          rewardRate
        )
      ).to.be.revertedWithCustomError(vesting, "AmountMustBePositive");
    });

    it("Should revert if duration is zero", async function () {
      await testToken.transfer(vesting.target, amount);
      await expect(
        vesting.createVestingSchedule(
          addr1.address,
          Math.floor(Date.now() / 1000) + 100,
          cliff,
          0,
          true,
          amount,
          rewardRate
        )
      ).to.be.revertedWithCustomError(vesting, "DurationMustBePositive");
    });

    it("Should revert if duration <= cliff", async function () {
      await testToken.transfer(vesting.target, amount);
      await expect(
        vesting.createVestingSchedule(
          addr1.address,
          Math.floor(Date.now() / 1000) + 100,
          cliff,
          cliff,
          true,
          amount,
          rewardRate
        )
      ).to.be.revertedWithCustomError(vesting, "DurationMustBeGreaterThanCliff");
      await expect(
        vesting.createVestingSchedule(
          addr1.address,
          Math.floor(Date.now() / 1000) + 100,
          cliff,
          cliff - 1,
          true,
          amount,
          rewardRate
        )
      ).to.be.revertedWithCustomError(vesting, "DurationMustBeGreaterThanCliff");
    });

    it("Should revert if reward rate > MAX_REWARD_RATE", async function () {
      await testToken.transfer(vesting.target, amount);
      const overMaxRewardRate = 1001; // MAX_REWARD_RATE is 1000
      await expect(
        vesting.createVestingSchedule(
          addr1.address,
          Math.floor(Date.now() / 1000) + 100,
          cliff,
          duration,
          true,
          amount,
          overMaxRewardRate
        )
      ).to.be.revertedWithCustomError(vesting, "InvalidRewardRate");
    });
  });

  describe("ECMcoinVestingWithRewards - Vesting Schedule State", function () {
    let vesting: any;
    const rewardRate = 100; // 10%
    const cliff = 60 * 60 * 24 * 30; // 1 month
    const duration = 60 * 60 * 24 * 180; // 6 months
    const amount = parseEther("1000");
    let vestingScheduleId: any;
    beforeEach(async function () {
      await hre.network.provider.send("hardhat_reset");
      [owner, addr1, addr2, ...addrs] = await ethers.getSigners();
      Token = await ethers.getContractFactory("MockERC20");
      ECMcoinVestingWithRewards = await ethers.getContractFactory("ECMcoinVestingWithRewards");
      testToken = await Token.deploy("Test Token", "TT", parseEther("1000000"));
      vesting = await ECMcoinVestingWithRewards.deploy(testToken.target);
      await testToken.transfer(vesting.target, amount);
      const start = Math.floor(Date.now() / 1000) + 100;
      await vesting.createVestingSchedule(
        addr1.address,
        start,
        cliff,
        duration,
        true,
        amount,
        rewardRate
      );
      vestingScheduleId = await vesting.computeVestingScheduleIdForAddressAndIndex(addr1.address, 0);
    });

    it("Should return correct vesting schedule info", async function () {
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      expect(schedule.beneficiary).to.equal(addr1.address);
      expect(schedule.amountTotal).to.equal(amount);
      expect(schedule.cliff).to.equal((await vesting.getVestingSchedule(vestingScheduleId)).cliff);
      expect(schedule.duration).to.equal(duration);
      expect(schedule.rewardRate).to.equal(rewardRate);
    });

    it("Should return correct vesting schedule count by beneficiary", async function () {
      const count = await vesting.getVestingSchedulesCountByBeneficiary(addr1.address);
      expect(count).to.equal(1);
    });

    it("Should return correct vesting schedule id at index", async function () {
      const id = await vesting.getVestingIdAtIndex(0);
      expect(id).to.equal(vestingScheduleId);
    });
  });

  describe("ECMcoinVestingWithRewards - Vesting Progress & Release", function () {
    let vesting: any;
    const rewardRate = 100; // 10%
    const cliff = 60 * 60 * 24 * 30; // 1 month
    const duration = 60 * 60 * 24 * 180; // 6 months
    const amount = parseEther("1000");
    let vestingScheduleId: any;
    beforeEach(async function () {
      await hre.network.provider.send("hardhat_reset");
      [owner, addr1, addr2, ...addrs] = await ethers.getSigners();
      Token = await ethers.getContractFactory("MockERC20");
      ECMcoinVestingWithRewards = await ethers.getContractFactory("ECMcoinVestingWithRewards");
      testToken = await Token.deploy("Test Token", "TT", parseEther("1000000"));
      vesting = await ECMcoinVestingWithRewards.deploy(testToken.target);
      await testToken.transfer(vesting.target, amount);
      const start = Math.floor(Date.now() / 1000) + 10;
      await vesting.createVestingSchedule(
        addr1.address,
        start,
        cliff,
        duration,
        true,
        amount,
        rewardRate
      );
      vestingScheduleId = await vesting.computeVestingScheduleIdForAddressAndIndex(addr1.address, 0);
    });

    it("Should not release tokens before cliff", async function () {
      // Move to just before cliff
      await time.increaseTo((await vesting.getVestingSchedule(vestingScheduleId)).cliff - BigInt(10));
      await expect(
        vesting.connect(addr1).release(vestingScheduleId, parseEther("1"))
      ).to.be.revertedWithCustomError(vesting, "NoClaimableAmount");
    });

    it("Should release correct amount after cliff and during vesting", async function () {
      // Move to halfway through vesting
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      const halfTime = schedule.start + schedule.duration / BigInt(2);
      await time.increaseTo(halfTime);
      const releasable = await vesting.computeReleasableAmount(vestingScheduleId);
      expect(releasable).to.be.closeTo(parseEther("500"), parseEther("1"));
      await expect(
        vesting.connect(addr1).release(vestingScheduleId, parseEther("100"))
      ).to.emit(vesting, "TokensReleased").withArgs(vestingScheduleId, addr1.address, parseEther("100"));
      const afterRelease = await vesting.getVestingSchedule(vestingScheduleId);
      expect(afterRelease.released).to.equal(parseEther("100"));
    });

    it("Should release all tokens after full duration", async function () {
      // Move to after full vesting
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      const endTime = schedule.start + schedule.duration + BigInt(1);
      await time.increaseTo(endTime);
      const releasable = await vesting.computeReleasableAmount(vestingScheduleId);
      expect(releasable).to.equal(amount);
      await expect(
        vesting.connect(addr1).release(vestingScheduleId, amount)
      ).to.emit(vesting, "TokensReleased").withArgs(vestingScheduleId, addr1.address, amount);
      const afterRelease = await vesting.getVestingSchedule(vestingScheduleId);
      expect(afterRelease.released).to.equal(amount);
    });

    it("Should revert if non-beneficiary/non-owner tries to release", async function () {
      // Move to after cliff
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      await time.increaseTo(schedule.cliff + BigInt(1));
      await expect(
        vesting.connect(addr2).release(vestingScheduleId, parseEther("1"))
      ).to.be.revertedWithCustomError(vesting, "NotBeneficiaryOrOwner");
    });

    it("Should revert if trying to release more than vested", async function () {
      // Move to after cliff
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      await time.increaseTo(schedule.cliff + BigInt(1));
      const releasable = await vesting.computeReleasableAmount(vestingScheduleId);
      await expect(
        vesting.connect(addr1).release(vestingScheduleId, releasable + parseEther("1"))
      ).to.be.revertedWithCustomError(vesting, "NoClaimableAmount");
    });
  });

  describe("ECMcoinVestingWithRewards - Reward Accrual & Claiming", function () {
    let vesting: any;
    const rewardRate = 100; // 10%
    const cliff = 60 * 60 * 24 * 30; // 1 month
    const duration = 60 * 60 * 24 * 180; // 6 months
    const amount = parseEther("1000");
    let vestingScheduleId: any;
    beforeEach(async function () {
      await hre.network.provider.send("hardhat_reset");
      [owner, addr1, addr2, ...addrs] = await ethers.getSigners();
      Token = await ethers.getContractFactory("MockERC20");
      ECMcoinVestingWithRewards = await ethers.getContractFactory("ECMcoinVestingWithRewards");
      testToken = await Token.deploy("Test Token", "TT", parseEther("1000000"));
      vesting = await ECMcoinVestingWithRewards.deploy(testToken.target);
      await testToken.transfer(vesting.target, amount);
      const start = Math.floor(Date.now() / 1000) + 10;
      await vesting.createVestingSchedule(
        addr1.address,
        start,
        cliff,
        duration,
        true,
        amount,
        rewardRate
      );
      vestingScheduleId = await vesting.computeVestingScheduleIdForAddressAndIndex(addr1.address, 0);
    });

    it("Should accrue rewards linearly with vesting progress", async function () {
      // Move to halfway through vesting
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      const halfTime = schedule.start + schedule.duration / BigInt(2);
      await time.increaseTo(halfTime);
      const claimable = await vesting.computeClaimableReward(vestingScheduleId);
      // 10% of 1000 = 100, half vested = 50
      expect(claimable).to.be.closeTo(parseEther("50"), parseEther("1"));
    });

    it("Should allow beneficiary to claim rewards", async function () {
      // Move to halfway through vesting
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      const halfTime = schedule.start + schedule.duration / BigInt(2);
      await time.increaseTo(halfTime);
      const claimable = await vesting.computeClaimableReward(vestingScheduleId);
      await expect(
        vesting.connect(addr1).claimReward(vestingScheduleId)
      ).to.emit(vesting, "RewardClaimed");
    });

    it("Should revert if non-beneficiary tries to claim rewards", async function () {
      // Move to halfway through vesting
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      const halfTime = schedule.start + schedule.duration / BigInt(2);
      await time.increaseTo(halfTime);
      await expect(
        vesting.connect(addr2).claimReward(vestingScheduleId)
      ).to.be.revertedWithCustomError(vesting, "NotBeneficiaryOrOwner");
    });

    it("Should revert if no rewards to claim", async function () {
      // Just after creation, before cliff
      await expect(
        vesting.connect(addr1).claimReward(vestingScheduleId)
      ).to.be.revertedWithCustomError(vesting, "NoClaimableAmount");
    });

    it("Should not underflow on reward claim (returns 0 if already claimed all)", async function () {
      // Move to end of vesting
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      const endTime = schedule.start + schedule.duration + BigInt(1);
      await time.increaseTo(endTime);
      await vesting.connect(addr1).claimReward(vestingScheduleId);
      // Try to claim again after all claimed
      const claimable = await vesting.computeClaimableReward(vestingScheduleId);
      expect(claimable).to.equal(0);
      await expect(
        vesting.connect(addr1).claimReward(vestingScheduleId)
      ).to.be.revertedWithCustomError(vesting, "NoClaimableAmount");
    });

  });

  describe("Combined Claim (Vested + Rewards)", function () {
    let vesting: any;
    const rewardRate = 100; // 10%
    const cliff = 60 * 60 * 24 * 30; // 1 month
    const duration = 60 * 60 * 24 * 180; // 6 months
    const amount = parseEther("1000");
    let vestingScheduleId: any;
    beforeEach(async function () {
      await hre.network.provider.send("hardhat_reset");
      [owner, addr1, addr2, ...addrs] = await ethers.getSigners();
      Token = await ethers.getContractFactory("MockERC20");
      ECMcoinVestingWithRewards = await ethers.getContractFactory("ECMcoinVestingWithRewards");
      testToken = await Token.deploy("Test Token", "TT", parseEther("1000000"));
      vesting = await ECMcoinVestingWithRewards.deploy(testToken.target);
      await testToken.transfer(vesting.target, amount);
      const start = Math.floor(Date.now() / 1000) + 10;
      await vesting.createVestingSchedule(
        addr1.address,
        start,
        cliff,
        duration,
        true,
        amount,
        rewardRate
      );
      vestingScheduleId = await vesting.computeVestingScheduleIdForAddressAndIndex(addr1.address, 0);
    });

    it("Should allow beneficiary to claim both vested and rewards in one call", async function () {
      // Move to halfway through vesting
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      const halfTime = schedule.start + schedule.duration / BigInt(2);
      await time.increaseTo(halfTime);
      const releasable = await vesting.computeReleasableAmount(vestingScheduleId);
      const claimableReward = await vesting.computeClaimableReward(vestingScheduleId);
      const beforeBalance = await testToken.balanceOf(addr1.address);
      await expect(
        vesting.connect(addr1).claimVestedAndRewards(vestingScheduleId)
      ).to.emit(vesting, "CombinedClaimed")
      const afterBalance = await testToken.balanceOf(addr1.address);
      // Should receive both vested and reward tokens
      expect(afterBalance - beforeBalance).to.be.closeTo(releasable + claimableReward, parseEther("1"));
    });
  });

  describe("ECMcoinVestingWithRewards - Revocation", function () {
    let vesting: any;
    let Token: any;
    let testToken: any;
    let owner: any;
    let addr1: any;
    let addr2: any;
    let addrs: any;
    let ECMcoinVestingWithRewards: any;
    const rewardRate = 100; // 10%
    const cliff = 60 * 60 * 24 * 30; // 1 month
    const duration = 60 * 60 * 24 * 180; // 6 months
    const amount = parseEther("1000");
    let vestingScheduleId: any;
    beforeEach(async function () {
      await hre.network.provider.send("hardhat_reset");
      [owner, addr1, addr2, ...addrs] = await ethers.getSigners();
      Token = await ethers.getContractFactory("MockERC20");
      ECMcoinVestingWithRewards = await ethers.getContractFactory("ECMcoinVestingWithRewards");
      testToken = await Token.deploy("Test Token", "TT", parseEther("1000000"));
      vesting = await ECMcoinVestingWithRewards.deploy(testToken.target);
      await testToken.transfer(vesting.target, amount);
      const start = Math.floor(Date.now() / 1000) + 10;
      await vesting.createVestingSchedule(
        addr1.address,
        start,
        cliff,
        duration,
        true, // revocable
        amount,
        rewardRate
      );
      vestingScheduleId = await vesting.computeVestingScheduleIdForAddressAndIndex(addr1.address, 0);
    });

    it("Should allow owner to revoke revocable schedule", async function () {
      await expect(
        vesting.connect(owner).revoke(vestingScheduleId)
      ).to.emit(vesting, "VestingScheduleRevoked");
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      expect(schedule.revoked).to.equal(true);
    });

    it("Should release vested tokens on revoke", async function () {
      // Move to halfway through vesting
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      const halfTime = schedule.start + schedule.duration / BigInt(2);
      await time.increaseTo(halfTime);
      const releasable = await vesting.computeReleasableAmount(vestingScheduleId);
      const claimableReward = await vesting.computeClaimableReward(vestingScheduleId);
      const beforeBalance = await testToken.balanceOf(addr1.address);
      await expect(
        vesting.connect(owner).revoke(vestingScheduleId)
      ).to.emit(vesting, "VestingScheduleRevoked");
      const afterBalance = await testToken.balanceOf(addr1.address);
      expect(afterBalance - beforeBalance).to.be.closeTo(releasable + claimableReward, parseEther("1"));
    });

    it("Should revert if non-owner tries to revoke", async function () {
      await expect(
        vesting.connect(addr1).revoke(vestingScheduleId)
      ).to.be.revertedWithCustomError(vesting, "OwnableUnauthorizedAccount");
    });

    it("Should revert if schedule is not revocable", async function () {
      // Create a non-revocable schedule
      const start = Math.floor(Date.now() / 1000) + 10;
      await testToken.transfer(vesting.target, amount);
      await vesting.createVestingSchedule(
        addr2.address,
        start,
        cliff,
        duration,
        false, // not revocable
        amount,
        rewardRate
      );
      const nonRevocableId = await vesting.computeVestingScheduleIdForAddressAndIndex(addr2.address, 0);
      await expect(
        vesting.connect(owner).revoke(nonRevocableId)
      ).to.be.revertedWithCustomError(vesting, "NotRevocable");
    });
  });

  describe("ECMcoinVestingWithRewards - Withdrawals", function () {
    let vesting: any;
    let ECMcoinVestingWithRewards: any;
    const rewardRate = 100; // 10%
    const cliff = 60 * 60 * 24 * 30; // 1 month
    const duration = 60 * 60 * 24 * 180; // 6 months
    const amount = parseEther("1000");
    beforeEach(async function () {
      await hre.network.provider.send("hardhat_reset");
      [owner, addr1, addr2, ...addrs] = await ethers.getSigners();
      Token = await ethers.getContractFactory("MockERC20");
      ECMcoinVestingWithRewards = await ethers.getContractFactory("ECMcoinVestingWithRewards");
      testToken = await Token.deploy("Test Token", "TT", parseEther("1000000"));
      vesting = await ECMcoinVestingWithRewards.deploy(testToken.target);
      // Fund contract with more than needed for vesting
      await testToken.transfer(vesting.target, amount * 2n);
      const start = Math.floor(Date.now() / 1000) + 10;
      await vesting.createVestingSchedule(
        addr1.address,
        start,
        cliff,
        duration,
        true,
        amount,
        rewardRate
      );
    });

    it("Should allow owner to withdraw excess tokens", async function () {
      const beforeOwner = await testToken.balanceOf(owner.address);
      const withdrawable = await vesting.getWithdrawableAmount();
      await expect(
        vesting.connect(owner).withdraw(withdrawable)
      ).to.emit(vesting, "Withdraw").withArgs(owner.address, withdrawable);
      const afterOwner = await testToken.balanceOf(owner.address);
      expect(afterOwner - beforeOwner).to.equal(withdrawable);
    });

    it("Should revert if non-owner tries to withdraw", async function () {
      const withdrawable = await vesting.getWithdrawableAmount();
      await expect(
        vesting.connect(addr1).withdraw(withdrawable)
      ).to.be.revertedWithCustomError(vesting, "OwnableUnauthorizedAccount");
    });

    it("Should revert if withdrawing more than available", async function () {
      const withdrawable = await vesting.getWithdrawableAmount();
      await expect(
        vesting.connect(owner).withdraw(withdrawable + parseEther("1"))
      ).to.be.revertedWithCustomError(vesting, "NotEnoughWithdrawableFunds");
    });
  });

  describe("ECMcoinVestingWithRewards - Projections", function () {
    let vesting: any;
    let ECMcoinVestingWithRewards: any;
    const rewardRate = 100; // 10%
    const cliff = 60 * 60 * 24 * 30; // 1 month
    const duration = 60 * 60 * 24 * 180; // 6 months
    const amount = parseEther("1000");
    let vestingScheduleId: any;
    beforeEach(async function () {
      await hre.network.provider.send("hardhat_reset");
      [owner, addr1, , ...addrs] = await ethers.getSigners();
      Token = await ethers.getContractFactory("MockERC20");
      ECMcoinVestingWithRewards = await ethers.getContractFactory("ECMcoinVestingWithRewards");
      testToken = await Token.deploy("Test Token", "TT", parseEther("1000000"));
      vesting = await ECMcoinVestingWithRewards.deploy(testToken.target);
      await testToken.transfer(vesting.target, amount);
      const start = Math.floor(Date.now() / 1000) + 10;
      await vesting.createVestingSchedule(
        addr1.address,
        start,
        cliff,
        duration,
        true,
        amount,
        rewardRate
      );
      vestingScheduleId = await vesting.computeVestingScheduleIdForAddressAndIndex(addr1.address, 0);
    });

    it("Should project rewards at future timestamp with correct precision", async function () {
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      // Project to 75% of vesting duration
      const futureTime = schedule.start + (schedule.duration * 3n) / 4n;
      const [projectedReward, newRewards] = await vesting.projectRewardsAtTime(vestingScheduleId, futureTime);
      // 10% of 1000 = 100, 75% vested = 75
      expect(projectedReward).to.be.closeTo(parseEther("75"), parseEther("1"));
      expect(newRewards).to.be.closeTo(parseEther("75"), parseEther("1"));
    });

    it("Should return 0 for projections before cliff", async function () {
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      const beforeCliff = schedule.cliff - 1n;
      const [projectedReward, newRewards] = await vesting.projectRewardsAtTime(vestingScheduleId, beforeCliff);
      expect(projectedReward).to.equal(0);
      expect(newRewards).to.equal(0);
    });

    it("Should return 0 for projections after all claimed", async function () {
      // Move to end and claim all rewards
      const schedule = await vesting.getVestingSchedule(vestingScheduleId);
      const endTime = schedule.start + schedule.duration + 1n;
      await time.increaseTo(endTime);
      await vesting.connect(addr1).claimReward(vestingScheduleId);
      // Project to after end
      const [projectedReward, newRewards] = await vesting.projectRewardsAtTime(vestingScheduleId, endTime + 100n);
      expect(projectedReward).to.equal(0);
      expect(newRewards).to.equal(0);
    });
  });

  describe("ECMcoinVestingWithRewards - Required Token Total", function () {
    let vesting: any;
    const rewardRate1 = 100; // 10%
    const rewardRate2 = 200; // 20%
    const cliff = 60 * 60 * 24 * 30; // 1 month
    const duration = 60 * 60 * 24 * 180; // 6 months
    const amount1 = parseEther("1000");
    const amount2 = parseEther("500");
    let vestingScheduleId1: any;
    let vestingScheduleId2: any;
    beforeEach(async function () {
      await hre.network.provider.send("hardhat_reset");
      [owner, addr1, addr2, ...addrs] = await ethers.getSigners();
      Token = await ethers.getContractFactory("MockERC20");
      ECMcoinVestingWithRewards = await ethers.getContractFactory("ECMcoinVestingWithRewards");
      testToken = await Token.deploy("Test Token", "TT", parseEther("1000000"));
      vesting = await ECMcoinVestingWithRewards.deploy(testToken.target);
    });

    it("Should reflect correct requiredTokenTotal after single schedule creation", async function () {
      const expected = amount1 + (amount1 * BigInt(rewardRate1)) / 1000n;
      await testToken.transfer(vesting.target, expected);
      await vesting.createVestingSchedule(
        addr1.address,
        Math.floor(Date.now() / 1000) + 100,
        cliff,
        duration,
        true,
        amount1,
        rewardRate1
      );
      const required = await vesting.getRequiredTokenBalance();
      expect(required).to.equal(expected);
    });

    it("Should reflect correct requiredTokenTotal after multiple schedule creations", async function () {
      const expected1 = amount1 + (amount1 * BigInt(rewardRate1)) / 1000n;
      const expected2 = amount2 + (amount2 * BigInt(rewardRate2)) / 1000n;
      await testToken.transfer(vesting.target, expected1 + expected2);
      await vesting.createVestingSchedule(
        addr1.address,
        Math.floor(Date.now() / 1000) + 100,
        cliff,
        duration,
        true,
        amount1,
        rewardRate1
      );
      await vesting.createVestingSchedule(
        addr2.address,
        Math.floor(Date.now() / 1000) + 200,
        cliff,
        duration,
        true,
        amount2,
        rewardRate2
      );
      const required = await vesting.getRequiredTokenBalance();
      expect(required).to.equal(expected1 + expected2);
    });

    it("Should decrement requiredTokenTotal correctly after revocation", async function () {
      const expected = amount1 + (amount1 * BigInt(rewardRate1)) / 1000n;
      await testToken.transfer(vesting.target, expected);
      await vesting.createVestingSchedule(
        addr1.address,
        Math.floor(Date.now() / 1000) + 100,
        cliff,
        duration,
        true,
        amount1,
        rewardRate1
      );
      vestingScheduleId1 = await vesting.computeVestingScheduleIdForAddressAndIndex(addr1.address, 0);
      // Move to 0% vested (before cliff)
      await vesting.connect(owner).revoke(vestingScheduleId1);
      const required = await vesting.getRequiredTokenBalance();
      expect(required).to.equal(0);
    });

    it("Should decrement requiredTokenTotal proportionally after partial vesting and revocation", async function () {
      const expected = amount1 + (amount1 * BigInt(rewardRate1)) / 1000n;
      await testToken.transfer(vesting.target, expected);
      await vesting.createVestingSchedule(
        addr1.address,
        Math.floor(Date.now() / 1000) + 10,
        cliff,
        duration,
        true,
        amount1,
        rewardRate1
      );
      vestingScheduleId1 = await vesting.computeVestingScheduleIdForAddressAndIndex(addr1.address, 0);
      // Move to halfway through vesting
      const schedule = await vesting.getVestingSchedule(vestingScheduleId1);
      const halfTime = schedule.start + schedule.duration / BigInt(2);
      await time.increaseTo(halfTime);
      // Release half
      const releasable = await vesting.computeReleasableAmount(vestingScheduleId1);
      await vesting.connect(addr1).release(vestingScheduleId1, releasable);
      // Now revoke (should only remove unvested + unaccrued reward)
      await vesting.connect(owner).revoke(vestingScheduleId1);
      // After revocation, requiredTokenTotal should be exactly the released + reward for released portion
      // // Calculate expected: released + reward on released
      const released = releasable;
      const rewardOnReleased = (released * BigInt(rewardRate1)) / 1000n;
      const required = await vesting.getRequiredTokenBalance();
      expect(required).to.equal(0n); // Should be very close to 0
    });
  });

});