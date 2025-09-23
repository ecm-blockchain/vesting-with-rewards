import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { parseEther } from "ethers";

const ECMcoinVesting_Module = buildModule("ECMCoinVesting_Module", (m) => {
  // ECM token address parameter
  const ecmToken = m.getParameter("ecmToken", "0x4C324169890F42c905f3b8f740DBBe7C4E5e55C0");
  // Deploy ECMcoinVesting with LP and reward token addresses
  const ecmcoinVestingWithRewards = m.contract("ECMcoinVesting", [ecmToken]);

  return { ecmcoinVestingWithRewards };
});

export default ECMcoinVesting_Module;