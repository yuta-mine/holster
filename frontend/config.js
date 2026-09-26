// Addresses written by `forge script script/DeployV4.s.sol` (contracts/deployments/v4-<chainId>.json).
// Fill these in after deploying, or run `node frontend/sync-config.mjs` to copy them from the deployments folder.
export const NETWORKS = {
  84532: {
    name: "Base Sepolia",
    rpc: "https://sepolia.base.org",
    explorer: "https://sepolia.basescan.org",
    multicall3: "0xcA11bde05977b3631167028862bE2a173976CA11",
    poolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    hook: "0x1565E63927c90248d077F6D832462D20773C10c0",
    router: "0x6Dd11dcbABAB48FD45716af3400D981Ecb966406",
    base: "0x5B7a39546a76D656c13e83834e78762eCb668E25",
    quote: "0x6ba420ac953a7fb336459E88BFf14AF17F24D86d",
    // the same pool with the band off (script/DeployV4.s.sol): an LP that only re-places out of range
    baseline: "0xc74D05D7A1Ff478b39c0a78613fD60870eE910c0",
    aqua: {
      aqua: "0x759C97e32e893CDC8CB2A644f30D793A2B1402b6",
      router: "0x3de705D645996B10c59438E45FA59f8a8B27Afb2",
      holster: "0xb9e9bD0074B2e1c458bA2e8573ba8272E7C43292",
      base: "0x1C4E9AAa73B8d4eb711EF98707CFC9Cf41D16db4",
      quote: "0x726afBCD6eB693e933f3A838411DFBaD20a56BE2",
      orderHash: "0x407d446a3c3bdc995d9de9632b2fc0c1649cfdd3622e1de39db200a171ef864b",
      order: "0x000000000000000000000000000000000000000000000000000000000000002000000000000000000000000035ce5fe2a91fe5cc6f15a37a9fe32ffedc45bcee40000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000005e205cb9e9bd0074b2e1c458ba2e8573ba8272e7c432921c4e9aaa73b8d4eb711ef98707cfc9cf41d16db4726afbcd6eb693e933f3a838411dfbad20a56be2001e03e801f401f4001e1d4c00000000000000010000000000000000000000000000",
      // parameters the strategy was shipped with (script/DeployAqua.s.sol defaults)
      widthBps: 1000, upperBps: 500, lowerBps: 500, deployBps: 7500,
    },
  },
  31337: {
    name: "Local (anvil)",
    rpc: "http://127.0.0.1:8545",
    explorer: "",
    hook: "",
    router: "",
    base: "",
    quote: "",
    baseline: "",
  },
};

export const DEFAULT_CHAIN_ID = 84532;
