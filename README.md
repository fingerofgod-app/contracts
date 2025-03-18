# 🐉 FingerOfGod: Smiting the Boundaries of DeFi on Sonic

FingerOfGod is a next-generation DeFi protocol on the Sonic blockchain. Inspired by the successes of Snake.finance and HandOfGod, it introduces pegged tokens (fogHOG and fogSNAKE) and a governance token (FOG), enabling users to earn rewards via Genesis Pools, yield farming, and an elastic supply mechanism. The protocol aims to maintain a balanced and sustainable ecosystem through a combination of on-chain governance and automated treasury functions.

## Open-Source & Licensing Philosophy

At FingerOfGod, we proudly release our code as open source—available for everyone to review, use, and build upon. Our implementation of the “harvest on Sonic” feature is based on common DeFi practices and open standards, ensuring that innovation in this space remains accessible and collaborative.

We strongly believe that the open-source ethos is key to advancing the DeFi ecosystem. While Snake Finance has claimed that our code uses their licensed implementation, it’s important to note that the specific harvest mechanism we employ is a widely adopted practice in the community. Our approach is built on transparent, community-driven standards—not proprietary restrictions.

We remain committed to delivering an open, free, and innovative protocol for everyone. We invite you to review our code on GitHub, contribute, and join us in building a more accessible DeFi future.

## Smart Contract Addresses

| Contract                  | Source File                                                                                                                                                              | Address                                      |
|---------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------|
| **fHOG**                  | [contracts/token/FogElasticToken.sol](https://github.com/fingerofgod-app/contracts/blob/main/contracts/token/FogElasticToken.sol)                                          | [0xafde634d6f38fc59cf94fb9e24a91e31ee6aa5e0](https://sonicscan.org/address/0xafde634d6f38fc59cf94fb9e24a91e31ee6aa5e0)  |
| **fSNAKE**                | [contracts/token/FogElasticToken.sol](https://github.com/fingerofgod-app/contracts/blob/main/contracts/token/FogElasticToken.sol)                                          | [0x11F5cd8aE75c2f498DE4b874058c489AE473E488](https://sonicscan.org/address/0x11F5cd8aE75c2f498DE4b874058c489AE473E488)  |
| **FOG**                   | [contracts/token/FOG.sol](https://github.com/fingerofgod-app/contracts/blob/main/contracts/token/FOG.sol)                                                                 | [0xB144E5f84BbA5b2b4Ea2fBa9d7364E8990FC7216](https://sonicscan.org/address/0xB144E5f84BbA5b2b4Ea2fBa9d7364E8990FC7216)  |
| **FogRewardPool**         | [contracts/distribution/FogRewardPool.sol](https://github.com/fingerofgod-app/contracts/blob/main/contracts/distribution/FogRewardPool.sol)                                  | [0x9112C2AE5C729bEE9a5C12CE1ec64073d812ef5A](https://sonicscan.org/address/0x9112C2AE5C729bEE9a5C12CE1ec64073d812ef5A)  |
| **Treasury**              | [contracts/Treasury.sol](https://github.com/fingerofgod-app/contracts/blob/main/contracts/Treasury.sol)                                                                    | [0x426E7741AE4544A6Bb5F0AA3Ad6d9623813bFFF7](https://sonicscan.org/address/0x426E7741AE4544A6Bb5F0AA3Ad6d9623813bFFF7)  |
| **Boardroom**             | [contracts/Boardroom.sol](https://github.com/fingerofgod-app/contracts/blob/main/contracts/Boardroom.sol)                                                                    | [0x5D26f9C6B02caF37a6C3D6d10B590e91e6ebD712](https://sonicscan.org/address/0x5D26f9C6B02caF37a6C3D6d10B590e91e6ebD712)  |
| **fHOG Oracle**           | [contracts/oracle/PoolOracle.sol](https://github.com/fingerofgod-app/contracts/blob/main/contracts/oracle/PoolOracle.sol)                                                    | [0x440B27C3Ac56b725a2f089a48D6fdA5550c46164](https://sonicscan.org/address/0x440B27C3Ac56b725a2f089a48D6fdA5550c46164)  |
| **fSNAKE Oracle**         | [contracts/oracle/PoolOracle.sol](https://github.com/fingerofgod-app/contracts/blob/main/contracts/oracle/PoolOracle.sol)                                                    | [0x69aE3A9CEb8d9Bb9e99dDCe6bAA85Cc8D84898E8](https://sonicscan.org/address/0x69aE3A9CEb8d9Bb9e99dDCe6bAA85Cc8D84898E8)  |

## Overview

- **fogHOG & fogSNAKE:** Pegged tokens designed to mirror the value of HOG and SNAKE respectively, featuring elastic supply mechanics.
- **FOG (Governance Token):** Empowers holders to influence protocol parameters and earn rewards through the Pantheon.
- **FogRewardPool:** Facilitate ongoing yield opportunities.
- **Treasury & Boardroom:** Work together to maintain price stability, direct expansions/contractions, and distribute rewards.
- **Oracles:** fHOG and fSNAKE oracles provide reliable pricing data to support our peg stability mechanisms.

## Getting Started

1. **Clone the Repo:**
   ```bash
   git clone https://github.com/fingerofgod-app/contracts.git fog-contracts

## Getting Started

1. **Clone the Repo:**
```bash
git clone https://github.com/fingerofgod-app/contracts.git fog-contracts
```

2. **Install Dependencies:**
```bash
cd fog-contracts
npm install
```

3. **Compile & Test:**
```bash
npx hardhat compile
npx hardhat test
```

4. **Deployment:**
Refer to the scripts/deploy/ folder for deployment scripts and configuration.

## Contributing

We welcome contributions from the community. Please open an issue or pull request with any improvements, bug fixes, or feature suggestions.

⸻

**Disclaimer:** Use of these contracts carries inherent risk. Always DYOR (do your own research) before interacting with any DeFi protocol. The FingerOfGod team is not liable for any financial losses.
