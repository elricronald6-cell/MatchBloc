# MatchBloc

Matching-fund rounds on BOT Chain.

A sponsor seeds a matching pool and opens a round. Projects register. Anyone
can back a project with BOT. When the round closes, the pool is split between
projects **by how many distinct wallets backed them** — not by how much those
wallets gave.

That single choice is the whole design. Ten people giving 1 BOT each pull ten
times the match of one person giving 10 BOT. The pool rewards reach, and a
single large backer cannot buy the match.

## How a round runs

1. `createRound(name, durationSecs)` with the pool attached. Minimum 0.1 BOT,
   1–90 days.
2. `registerProject(roundId, name)` — anyone, up to 64 projects per round, any
   time before the clock runs out. The cap keeps settlement bounded.
3. `back(projectId)` with BOT. **Your first contribution is what earns match
   weight**; topping up adds to the project's raised total but not to its
   backer count. A project owner cannot back their own project.
4. `settleRound(roundId)` — **permissionless** once the round ends. Each
   project's match is fixed at `pool × backers / totalBackers`. A sponsor who
   goes quiet cannot strand the pool.
5. `claim(projectId)` — the project owner collects raised + matched, minus one
   fee (2.5% default, capped 5%), once.

Two edges worth knowing: a round that ends with no backers at all refunds the
whole pool to its sponsor, and integer-division dust that cannot be split
evenly becomes protocol fees rather than being stranded in the contract.

## Build and deploy

```bash
npm install
npx hardhat test          # 15 tests
npm run deploy:testnet    # BOT Chain testnet, chain 968
npm run deploy:mainnet    # BOT Chain mainnet, chain 677
```

Create `.env` from `.env.example` with your `PRIVATE_KEY` first. The deploy
script prints the network name **and** the chain id.

After deploying, paste the address into `CONTRACT_ADDRESS` in
`frontend/index.html`. For mainnet also swap the five network values flagged in
the comment block directly above it, and set `label` to `"MAINNET"`.

## Frontend

Single file, no build step, ethers v6 from cdnjs. **Memphis**: confetti
terrazzo ground, squiggles and zigzags, clashing pop colours, everything
slightly off-axis. Rounds are a tilted scatter rather than a neat grid, and
each project's backer count is drawn as a row of confetti shapes — because the
shape count *is* the match weight.

The page ends with the BOT Chain ecosystem footer, carrying links to
**botchain.ai** and the **block explorer**. The explorer href is read from the
`NETWORK` config at the top of the file, so the five-value mainnet swap updates
it too. No chain ID is printed anywhere on the page — these sites move from
testnet to mainnet, so a rendered chain ID would be wrong half the time.
