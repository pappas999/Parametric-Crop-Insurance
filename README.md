# Description

Example of a decentralized crop insurance insurance product that makes using of Chainlink Oracles to obtain external data from multiple weather APIs

# Walkthrough

Please refer to the <a href="blog.chain.link/decentralized-insurance-product">technical article</a> on the Chainlink official blog
<br/>

# Run product

The contracts can be deployed to Kovan either via <a href="https://remix.ethereum.org/#version=soljson-v0.4.24+commit.e67f0147.js&optimize=true&evmVersion=null&gist=79cf8c59f1fbf6e6a0327920c9a9c49a">this Remix link</a>, or via Truffle commands below.

#### Setup Environment Variables
You'll need a `MNEMONIC` and a kovan `KOVAN_RPC_URL` environment variable. Your `MNEMONIC` is your seed phrase of your wallet. You can find a `KOVAN_RPC_URL` from node provider services like [Infura](https://infura.io/)

Then, either set them in a `bash_profile` file or export them into your terminal like:

```bash
export MNEMONIC='cat dog frog....'
export KOVAN_RPC_URL='www.infura.io/abcdefg'
```

#### Install dependencies

```sh
# install packages.
npm install

# compile contract
truffle complie

# migrate contract
# First update truffle-config.js to contain correct key information for your wallet and infura provider

truffle deploy --reset --network kovan

```

Once the contract is deployed and you have the master contract address. You need to fund it with some ETH and LINK to be used in the creation of insurance contracts. Once that's done, you can then interact with the InsuranceContracts functions via any Contract interaction method, such as <a href="https://www.myetherwallet.com/interface/interact-with-contract">MyEtherWallet</a>
