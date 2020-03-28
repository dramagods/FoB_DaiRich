usePlugin("@nomiclabs/buidler-truffle5");
usePlugin("@nomiclabs/buidler-waffle");
usePlugin("@nomiclabs/buidler-etherscan");
usePlugin("buidler-typechain");

// This is a sample Buidler task. To learn how to create your own go to
// https://buidler.dev/guides/create-task.html
task("accounts", "Prints the list of accounts", async () => {
  const accounts = await web3.eth.getAccounts();

  for (const account of accounts) {
    console.log(account);
  }
});

const INFURA_API_KEY = "2063d9b85a8a42c98e83cf061b6c4dc5";
const ROPSTEN_PRIVATE_KEY = "";
const KOVAN_PRIVATE_KEY = "9ea578ced1f44b1b8d26a54e744941ce";

const HDWalletProvider = require('truffle-hdwallet-provider')
const MNEMONIC = "armed speak monitor prison icon host method stereo zebra fame illness sleep"
const ROPSTEN_URL = process.env.ROPSTEN_URL
const KOVAN_URL = process.env.KOVAN_URL

module.exports = {
  defaultNetwork: "buidlerevm",
  networks: {
    rinkeby: {
      url: `https://ropsten.infura.io/v3/${INFURA_API_KEY}`,
      accounts: [ROPSTEN_PRIVATE_KEY]
    },
    kovan: {
      provider: () => new HDWalletProvider(MNEMONIC, `https://kovan.infura.io/v3/${INFURA_API_KEY}`),
      url: `https://kovan.infura.io/v3/${INFURA_API_KEY}`,
      from: "0x3e9a8e5Fc9246eC11ce56Ec5b727e6168C6F808e",
      network_id: 42
    },
  },
  solc: {
    version: "0.5.5"
  }
};
