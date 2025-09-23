# Integration Guide (Vue 3 + TypeScript + Ethers v6)

## 0) What you’ll build

* **Connect wallet** (MetaMask, WalletConnect)
* **Read schedules** for the connected wallet
* **Show cliff / progress / releasable & rewards due**
* **Claim combined (recommended), claim rewards-only, or release a custom amount**
* **Owner dashboard** (optional): create schedules, revoke, withdraw excess, check solvency

---

## 1) Prereqs

* Vue 3 + Vite (TypeScript)
* Node 18+
* An ERC-20 token already deployed (the “ECM” token)
* The `ECMcoinVestingWithRewards` contract deployed (you’ll need its address)

```bash
npm i ethers@^6 web3modal@^2 @walletconnect/ethereum-provider@^2
```

> If you already have a global wallet solution, you can skip `web3modal` and wire your own provider.

---

## 2) Put the ABI in your frontend

Create `artifacts/contracts/ECMcoinVestingWithRewards/ECMcoinVestingWithRewards.json` with the ABI of your contract (from your build artifacts).
---

## 3) Minimal Web3 bootstrap (ethers v6 + Web3Modal)

Create `src/web3.ts`:

```ts
import { ethers } from "ethers";
import { createWeb3Modal, defaultConfig } from "@web3modal/ethers/react"; // Vue can still use this store-neutral setup

// 1) Your chain & contract addresses
export const CHAIN_ID = 1; // or your testnet id
export const VESTING_ADDRESS = "0xYourVestingContract";
export const ECM_TOKEN_ADDRESS = "0xYourEcmToken";

// 2) RPC(s)
const projectId = "YOUR_WALLETCONNECT_ID";
export const web3Modal = createWeb3Modal({
  ethersConfig: defaultConfig({ metadata: { name: "ECM Vesting DApp", description: "", url: "", icons: [] }}),
  chains: [{ chainId: CHAIN_ID, name: "Ethereum", currency: "ETH", explorerUrl: "https://etherscan.io", rpcUrl: "https://mainnet.infura.io/v3/YOUR_INFURA" }],
  projectId
});

// 3) Helpers
export function getProvider() {
  if (window.ethereum) return new ethers.BrowserProvider(window.ethereum);
  throw new Error("No injected provider found");
}

export async function getSigner() {
  const provider = getProvider();
  return await provider.getSigner();
}

export async function getAccountAddress() {
  const signer = await getSigner();
  return await signer.getAddress();
}
```

---

## 4) Contract factory (typed wrapper)

Create `src/contracts/vesting.ts`:

```ts
import { ethers } from "ethers";
import VestingABI from "@/abi/ECMcoinVestingWithRewards.json";
import { getProvider, getSigner } from "@/web3";
import { VESTING_ADDRESS } from "@/web3";

export function vestingRead() {
  const provider = getProvider();
  return new ethers.Contract(VESTING_ADDRESS, VestingABI, provider);
}

export async function vestingWrite() {
  const signer = await getSigner();
  return new ethers.Contract(VESTING_ADDRESS, VestingABI, signer);
}
```

If you frequently call the ERC-20 token balance/decimals, also add `src/contracts/erc20.ts`.

---

## 5) Vue composables for data

Create `src/composables/useVesting.ts`:

```ts
import { ref, computed } from "vue";
import { ethers } from "ethers";
import { vestingRead, vestingWrite } from "@/contracts/vesting";
import { getAccountAddress } from "@/web3";

export interface VestingSchedule {
  beneficiary: string;
  cliff: bigint;
  start: bigint;
  duration: bigint;
  revocable: boolean;
  amountTotal: bigint;
  released: bigint;
  revoked: boolean;
  rewardRate: bigint;
}

const REWARD_RATE_PRECISION = 1000n;

export function useVesting() {
  const loading = ref(false);
  const schedules = ref<{ id: string; data: VestingSchedule }[]>([]);
  const account = ref<string>("");

  async function loadMySchedules() {
    loading.value = true;
    try {
      account.value = await getAccountAddress();
      const vesting = vestingRead();

      const count: bigint = await vesting.getVestingSchedulesCountByBeneficiary(account.value);
      const items: { id: string; data: VestingSchedule }[] = [];

      for (let i = 0n; i < count; i++) {
        const id = await vesting.computeVestingScheduleIdForAddressAndIndex(account.value, i);
        const data = await vesting.getVestingSchedule(id);
        items.push({ id, data });
      }
      schedules.value = items;
    } finally {
      loading.value = false;
    }
  }

  async function getDueNow(id: string) {
    const vesting = vestingRead();
    const [duePrincipal, dueRewards, totalDue] = await vesting.getDueNow(id);
    return { duePrincipal, dueRewards, totalDue } as {
      duePrincipal: bigint; dueRewards: bigint; totalDue: bigint;
    };
  }

  async function claimCombined(id: string) {
    const vesting = await vestingWrite();
    const tx = await vesting.claimVestedAndRewards(id);
    return await tx.wait();
  }

  async function claimRewardsOnly(id: string) {
    const vesting = await vestingWrite();
    const tx = await vesting.claimReward(id);
    return await tx.wait();
  }

  async function releasePrincipal(id: string, amount: string) {
    const vesting = await vestingWrite();
    const tx = await vesting.release(id, amount); // amount must be in token units (BigInt string)
    return await tx.wait();
  }

  function progressPercent(s: VestingSchedule) {
    const now = BigInt(Math.floor(Date.now()/1000));
    if (s.revoked || now < s.cliff) return 0;
    const end = s.start + s.duration;
    if (now >= end) return 100;
    const elapsed = now - s.start;
    const pct = Number(elapsed * 100n / s.duration);
    return pct;
  }

  function formatAmount(v: bigint, decimals = 18) {
    return Number(ethers.formatUnits(v, decimals));
  }

  return {
    loading, schedules, account,
    loadMySchedules, getDueNow,
    claimCombined, claimRewardsOnly, releasePrincipal,
    progressPercent, formatAmount
  };
}
```

> Notes
> • All numeric onchain values are `bigint`. Keep everything as `bigint` internally; only format for display.
> • `releasePrincipal` expects **token units** (`parseUnits` in the caller).

---

## 6) Example Vue component

`src/components/MyVesting.vue`:

```vue
<script setup lang="ts">
import { onMounted, ref } from "vue";
import { useVesting } from "@/composables/useVesting";
import { ethers } from "ethers";

const {
  loading, schedules, loadMySchedules, getDueNow,
  claimCombined, claimRewardsOnly, releasePrincipal,
  progressPercent, formatAmount
} = useVesting();

const DECIMALS = 18;
const selectedId = ref<string>("");
const customRelease = ref<string>("");

onMounted(loadMySchedules);

async function claimAll(id: string) {
  await claimCombined(id);
  await loadMySchedules();
}

async function claimRewards(id: string) {
  await claimRewardsOnly(id);
  await loadMySchedules();
}

async function releaseSome(id: string) {
  const amount = ethers.parseUnits(customRelease.value || "0", DECIMALS);
  await releasePrincipal(id, amount.toString());
  customRelease.value = "";
  await loadMySchedules();
}
</script>

<template>
  <div>
    <h2>My Vesting Schedules</h2>
    <div v-if="loading">Loading…</div>
    <div v-else-if="!schedules.length">No schedules found.</div>

    <div v-for="s in schedules" :key="s.id" class="card">
      <h3># {{ s.id }}</h3>
      <p>Beneficiary: {{ s.data.beneficiary }}</p>
      <p>Start: {{ Number(s.data.start) }} | Cliff: {{ Number(s.data.cliff) }}</p>
      <p>Duration (s): {{ Number(s.data.duration) }}</p>
      <p>Revocable: {{ s.data.revocable ? "Yes" : "No" }}</p>
      <p>Revoked: {{ s.data.revoked ? "Yes" : "No" }}</p>
      <p>AmountTotal: {{ formatAmount(s.data.amountTotal, DECIMALS) }}</p>
      <p>Released: {{ formatAmount(s.data.released, DECIMALS) }}</p>

      <progress :value="progressPercent(s.data)" max="100"></progress>
      <small>{{ progressPercent(s.data) }}%</small>

      <div class="actions">
        <button @click="claimAll(s.id)" :disabled="s.data.revoked">Claim Combined</button>
        <button @click="claimRewards(s.id)" :disabled="s.data.revoked">Claim Rewards Only</button>
      </div>

      <div class="release">
        <input v-model="customRelease" placeholder="Amount (e.g. 123.45)" />
        <button @click="releaseSome(s.id)" :disabled="s.data.revoked">Release Principal</button>
      </div>

      <AsyncDue :id="s.id" :decimals="DECIMALS" :format="formatAmount" :getDueNow="getDueNow" />
    </div>
  </div>
</template>

<style scoped>
.card { border: 1px solid #e5e7eb; border-radius: 12px; padding: 16px; margin-bottom: 16px; }
.actions button { margin-right: 8px; }
.release { margin-top: 8px; }
</style>
```

`src/components/AsyncDue.vue`:

```vue
<script setup lang="ts">
import { onMounted, ref, watch } from "vue";

const props = defineProps<{
  id: string;
  decimals: number;
  format: (v: bigint, d?: number) => number;
  getDueNow: (id: string) => Promise<{ duePrincipal: bigint; dueRewards: bigint; totalDue: bigint }>;
}>();

const duePrincipal = ref<bigint>(0n);
const dueRewards = ref<bigint>(0n);
const totalDue = ref<bigint>(0n);
const loading = ref(false);

async function load() {
  loading.value = true;
  try {
    const res = await props.getDueNow(props.id);
    duePrincipal.value = res.duePrincipal;
    dueRewards.value = res.dueRewards;
    totalDue.value = res.totalDue;
  } finally {
    loading.value = false;
  }
}
onMounted(load);
watch(() => props.id, load);
</script>

<template>
  <div>
    <div v-if="loading">Fetching due amounts…</div>
    <div v-else>
      <p>Due Principal: {{ format(duePrincipal, decimals) }}</p>
      <p>Due Rewards: {{ format(dueRewards, decimals) }}</p>
      <p>Total Due: {{ format(totalDue, decimals) }}</p>
    </div>
  </div>
</template>
```

---

## 7) Owner dashboard hooks (optional)

Create `src/composables/useOwner.ts` (only visible if `account == owner()`):

```ts
import { vestingRead, vestingWrite } from "@/contracts/vesting";
import { ethers } from "ethers";

export function useOwner() {
  async function createSchedule(params: {
    beneficiary: string;
    start: number;    // seconds
    cliff: number;    // seconds from start
    duration: number; // seconds
    revocable: boolean;
    amount: string;   // human string, convert to units before call
    rewardRate: number; // 0..1000
    decimals?: number;
  }) {
    const v = await vestingWrite();
    const amountUnits = ethers.parseUnits(params.amount, params.decimals ?? 18);
    const tx = await v.createVestingSchedule(
      params.beneficiary,
      BigInt(params.start),
      BigInt(params.cliff),
      BigInt(params.duration),
      params.revocable,
      amountUnits,
      BigInt(params.rewardRate)
    );
    return await tx.wait();
  }

  async function revoke(id: string) {
    const v = await vestingWrite();
    const tx = await v.revoke(id);
    return await tx.wait();
  }

  async function withdraw(amountHuman: string, decimals = 18) {
    const v = await vestingWrite();
    const amt = ethers.parseUnits(amountHuman, decimals);
    const tx = await v.withdraw(amt);
    return await tx.wait();
  }

  async function requiredBalance() {
    const v = vestingRead();
    return await v.getRequiredTokenBalance();
  }

  async function shortfall() {
    const v = vestingRead();
    return await v.getFundingShortfall();
  }

  return { createSchedule, revoke, withdraw, requiredBalance, shortfall };
}
```

> Before creating schedules, remind the owner UI to:
>
> 1. **Fund** the vesting contract with `amountTotal + totalReward` per schedule (or the sum across schedules);
> 2. Check `getFundingShortfall()`;
> 3. If shortfall > 0, block “Create” and show a warning.

---

## 8) Error handling (map your custom errors)

Your contract uses **custom errors** (e.g., `StartTimeMustBeFuture()`, `NoClaimableAmount()`). Ethers v6 will surface these via `errorName`/`reason` when the node supports rich errors.

Create `src/lib/tx.ts`:

```ts
export function parseTxError(e: any): string {
  // Ethers v6 error objects often contain a 'shortMessage' and 'info' with errorName
  const name =
    e?.info?.error?.message
      ?.match(/errorName":"([^"]+)"/)?.[1] ||
    e?.shortMessage ||
    e?.message;

  const known: Record<string,string> = {
    StartTimeMustBeFuture: "Start time must be in the future.",
    ZeroAddressBeneficiary: "Beneficiary address cannot be zero.",
    DurationMustBePositive: "Duration must be positive.",
    DurationMustBeGreaterThanCliff: "Duration must be greater than the cliff.",
    AmountMustBePositive: "Amount must be > 0.",
    InvalidRewardRate: "Reward rate exceeds maximum (100%).",
    ScheduleNotFound: "Vesting schedule was not found.",
    ScheduleRevoked: "This schedule has been revoked.",
    NotRevocable: "This schedule is not revocable.",
    NotBeneficiaryOrOwner: "Only the beneficiary or owner may perform this action.",
    NoClaimableAmount: "Nothing claimable yet.",
    InsufficientContractBalance: "Contract underfunded — please contact the project.",
    NotEnoughWithdrawableFunds: "Not enough excess funds to withdraw."
  };

  for (const key of Object.keys(known)) {
    if (String(name).includes(key)) return known[key];
  }
  return "Transaction failed. Please try again.";
}
```

Wrap every write:

```ts
try {
  await claimCombined(id);
} catch (e) {
  toast.error(parseTxError(e));
}
```

---

## 9) UI/UX patterns that help

* **Countdown to cliff**: display `max(0, cliff - now)` with a ticking timer.
* **Linear progress bar**: `elapsed / duration` (clamped to 0..1).
* **Disable** claim buttons if:

  * schedule is revoked,
  * `getDueNow().totalDue == 0`,
  * or `computeClaimableReward == 0` for rewards-only path.
* **Decimals**: pull token `decimals()` from `getToken()` address (ERC-20) and cache.
* **Gas estimation**: show pre-estimated gas; catch & show revert reasons from estimation too.

---

## 10) Edge cases you should cover

* **Before cliff**: both principal and rewards are 0.
* **Exactly at end**: `releasable == amountTotal - released`; `claimableRewards == totalReward - claimed`.
* **Revoked schedules**: should read fine but **block claims**; label them clearly.
* **Underfunded contract**: claims revert with `InsufficientContractBalance`. Surface an actionable message.
* **Multiple schedules**: Iterate by index for the connected beneficiary as shown.

---

## 11) Owner-only visibility

Add a simple check:

```ts
import vestingAbi from "@/abi/ECMcoinVestingWithRewards.json";
import { vestingRead } from "@/contracts/vesting";
import { getAccountAddress } from "@/web3";

export async function isOwner(): Promise<boolean> {
  const v = vestingRead() as any;
  const owner = await v.owner();
  const me = await getAccountAddress();
  return owner.toLowerCase() === me.toLowerCase();
}
```

Then conditionally render the **Admin** panel.

---

## 12) Creating IDs client-side

You often need to derive an ID without extra reads:

```ts
const id = await vestingRead().computeVestingScheduleIdForAddressAndIndex(beneficiary, index);
// index runs from 0 .. getVestingSchedulesCountByBeneficiary(beneficiary)-1
```

> For *next* ID preview, you can call `computeNextVestingScheduleIdForHolder(holder)` onchain if you export it to the ABI (it’s `public view` in your contract), or derive it as `keccak256(abi.encodePacked(holder, count))` if needed on backend scripts. Frontend can rely on the onchain helper.

---

## 13) Project rewards UI (nice touch)

Offer a projection slider (“What if I claim on *this date*?”):

```ts
const futureTs = Math.floor(Date.now()/1000) + 30*86400; // +30 days
const [projected, delta] = await vestingRead().projectRewardsAtTime(id, futureTs);
// Show projected total claimable and new rewards between now and that date
```

---

## 14) Security & production checklists

* Always **read** fresh state after a tx confirmation (do not assume local math).
* Do not store private keys client-side. Use injected providers only.
* Handle **chain mismatch** (prompt user to switch network).
* Gracefully handle **reorgs** (only show success after 1 confirmation, or configurable).
* Prefer **claimVestedAndRewards** to reduce user clicks/gas.

---

## 15) Testnet smoke plan (manual QA)

| Scenario           | Steps                                              | Expected                                      |
| ------------------ | -------------------------------------------------- | --------------------------------------------- |
| Before cliff       | Create schedule; connect as beneficiary; try claim | Revert with `NoClaimableAmount`               |
| Mid-vesting        | Fast-forward chain time; claim combined            | Token transfer = duePrincipal+dueRewards      |
| Rewards-only       | Fast-forward; `claimReward`                        | Only rewards paid; principal untouched        |
| Release custom     | Fast-forward; release half the releasable          | Correct delta in `released` / balances        |
| Revocation         | As owner, `revoke` mid-vesting                     | Pays due; marks revoked; blocks future claims |
| Underfunded        | Drain owner excess; attempt claim                  | Revert `InsufficientContractBalance`          |
| Multiple schedules | Create 2+; iterate UI                              | All IDs/schedules load correctly              |

---

## 16) Owner “Create Schedule” form (constraints you must enforce)

* `start` > `now`
* `duration` > 0
* `duration` > `cliff`
* `amount` > 0
* `rewardRate` ∈ \[0, 1000] (== 0% .. 100.0%)
* **Funding**: block submission if `getFundingShortfall()` would become positive after creation (pre-compute required funds client-side or show a “Make sure contract is funded” banner).

**Client-side pre-compute (optional):**

```
totalReward = amount * rewardRate / 1000
obligationIncrease = amount + totalReward
```

Compare `currentTokenBalance - currentRewardObligations` with `obligationIncrease`.

---

## 17) Timezones & formatting

* All contract times are **unix seconds (UTC)**. Format them with `new Date(Number(ts)*1000).toLocaleString()`.
* Persist raw `bigint` in state; only format for views.

---

## 18) Minimal styles

Keep gas & state visible, disable buttons on pending, show toasts for errors, and include a small “Help” section explaining **cliff**, **duration**, **rewards**, and **revocation**.

---