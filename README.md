# ClankRaceV4

**ClankRaceV4** — bet-triggered, lazily-resolved on-chain races on
[Robinhood Chain](https://robinhoodchain.blockscout.com) (chainId `4663`).

This is the V4.1 race contract deployed at
`0xbdc68cf2d2a55b84a56b3d32c0d68f9b8d86525a`. Source:
[`ClankRaceV4.sol`](./ClankRaceV4.sol).

## How it works

- **No cron creates rounds.** `bet()` lazily resolves the previous closed round
  (if its betting window has elapsed) and opens a fresh one. Empty time burns
  zero gas — gas is only spent when someone bets, claims, or finalizes the week.
- Each round accepts ETH bets during a `bettingWindowBlocks` window
  (default 5 blocks) and resolves the winner from `blockhash(closeBlock)`.
- A 2% deployer cut is routed to `deployerTreasury` on each resolution; the rest
  of the pot is split proportionally among winning bettors.
- `finalizeWeek()` settles the weekly racer pool when the 7-day epoch elapses.

## Roles

| Role | Field | Purpose |
| --- | --- | --- |
| Owner | `owner` | Config + role assignment |
| Manager | `manager` | Operational calls |
| Deployer treasury | `deployerTreasury` | 2% cut recipient |
| NFT | `nft` | `ClankNFT` ERC-721 (`0x4F53…F9BD`) — the 100-robot collection |

## Deployment

| Item | Value |
| --- | --- |
| Chain | Robinhood Chain (EVM, chainId `4663`) |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | https://robinhoodchain.blockscout.com |
| Race contract (V4.1) | `0xbdc68cf2d2a55b84a56b3d32c0d68f9b8d86525a` |
| ClankNFT (ERC-721) | `0x4F53885a60A20798C28691771571F701CD7aF9BD` |
| Compiler | `solc 0.8.26`, optimizer **off** |

The deployed runtime bytecode matches a local compile of
`ClankRaceV4.sol` with optimizer disabled (only the trailing compiler metadata
hash differs, which does not affect contract behavior).

## Build

Standalone contract — no imports. Compile with any `solc 0.8.26`:

```bash
solc ClankRaceV4.sol   # optimizer must be OFF to match deployment (no --optimize flag)
# or via Foundry (set optimizer = false in foundry.toml):
forge build
```

## License

MIT.
