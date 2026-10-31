# Rep Optimizer

Finds the **cheapest mix** of Auction House items to reach a reputation target,
using the real depth of the auction book rather than a single "market price".

Classic Era. `/rep` at the auction house.

## Why it scans instead of reading Auctionator

Auctionator's saved database cannot answer this question. Its
`Source/Database/Mixin.lua` collapses every scan into two numbers per item per
day — the minimum price and the *total* quantity:

```lua
available = available + info[j].available          -- SUM of every listing
if info[j].price < minPrice then minPrice = ... end
self:SetPrice(dbKey, minPrice, available)          -- only these survive
```

So it can tell you "47 bijous exist, cheapest is 2g" but never "3 at 2g, 5 at
3g, 39 at 8g". TSM is no better — its saved variables hold settings and
inventory; the AuctionDB comes from the Desktop App as market-value aggregates.

The depth is what decides the answer, so this addon runs its own targeted scan:
about 18 exact-name searches for Zandalar, a few seconds at the ~0.3s query
throttle. It never uses `getAll`.

## Why depth changes the maths

With a flat price, "21 bijous" costs 21 × the cheapest. With real listings you
walk up the supply curve, and the optimizer should switch items once the cheap
stock runs out.

Two things make this harder than it looks:

**You buy whole auctions.** A stack of 5 for 10g is all-or-nothing. So "the cost
of n items" is not n × unit price, and not even a running total over sorted unit
prices — it is a covering knapsack over lots. That is `Optimizer.CostCurve`, and
it is the primitive everything else is built on.

**Reconstructing which auctions to buy is its own trap.** The obvious approach --
record a parent pointer whenever `dp[m]` improves -- is wrong for 0/1 knapsack,
because `dp[n]` can be improved later by a different lot, so following the chain
re-enters a state that already spent the lot you just took. The same auction
then appears twice. That shipped once: it told the player to buy seven stacks of
ten when only four such auctions existed. `CostCurve` now records improvements
per layer and `Reconstruct` walks strictly earlier layers, so no lot can repeat.
`tests/fuzz.lua` checks ~8,000 reconstructions for repeats, cost agreement and
coverage.

This is also why a bare quantity is not an instruction. "Buy 128 Green Hakkari
Bijou" cannot be executed; on a real auction book, buying cheapest-first until
you have 128 costs **21% more** than the optimal set of auctions. So every row
reports the price cutoff and, on hover, the exact stacks to take.

**Greedy does not work.** "Always take the best value-for-money next" loses 45%
of the time in simulation. It walks to the finish line one purchase at a time
and its last step is chosen for its own value, not for how well it fits the gap
that is left — so it strands you buying a 125-rep bijou to close a 25-rep gap.

The solver instead enumerates how many turn-ins of each source, reads each
combination's true cost off the lot curves, and keeps the cheapest.

## Tokens are not automatically reputation

A Zandalar bijou gives **75 base rep plus an Honor Token** convertible to 50
more. The token does not have to be burned: 15 of them buy a Zandalar Signet
(quest 8246, repeatable at Exalted). Argent Dawn Valor Tokens are the same —
10 buy Mantles of the Dawn, which is what unlocks the shoulder enchants.

So the addon consumes only as many tokens as the target actually requires and
reports the rest as **kept**, not as wasted reputation. This drops the worst-case
overage from a whole turn-in to under one token, and in simulation 38% of runs
finish holding at least one spare token.

## Buying stays manual

`PlaceAuctionBid` has required a hardware event since patch 2.0, so no addon can
loop-buy.

The shopping list is **one row per item**, because the auction house can only be
searched for one name at a time. Clicking a row puts that row's own item into the
search box and runs the search; the purchase itself is yours to click.

## Files

| File | What it does |
|---|---|
| `Optimizer.lua` | Pure Lua, no WoW API. Cost curves, reconstruction, the solver. |
| `Data.lua` | Faction tables. Every rep value checked against the Classic quest pages (IDs in comments). |
| `Scanner.lua` | Targeted AH scan; paging, throttle handling, per-listing harvest. |
| `Core.lua` | Reads your live standing, builds curves, formats the answer. |
| `UI.lua` | The window. |
| `Init.lua` | Saved variables, `/rep`. |

## Tests

`Optimizer.lua` touches no WoW API, so it runs outside the game:

```
cd tests
lua run_tests.lua     # 33 unit checks incl. lot handling and token accounting
lua fuzz.lua          # 400 random books vs exhaustive brute force
lua integration.lua   # Data + Core + Optimizer against a mocked WoW API
lua scanner_test.lua  # 16 checks against a mocked frame/auction API
                      # (incl. the 'second scan hangs' regression)
lua ui_test.lua       # loads UI.lua against a mocked widget API and CLICKS things
lua perf_test.lua     # guards against the Argent Dawn solver blow-up
```

All six pass.

`ui_test.lua` exists because several UI bugs reached the player that reading the
code did not catch: a click target hardcoded to the wrong item, text overlapping
from fixed offsets, and a closure calling a local declared later in the file
(which Lua compiles as a nil global). They only appear when the code runs.

`perf_test.lua` exists because adding Argent Dawn -- ten turn-ins -- made the
solver's enumeration exponential and WoW killed the script mid-frame. It asserts
every faction solves in under half a second against a deep auction book. The fuzz test is the important one — it confirms the solver
returns the true optimum, not merely a good answer.

## Replacement auction UIs (TSM, Auctioneer, aux)

**TSM cannot be driven from another addon.** Its public API (`Core/API.lua`)
exposes 31 functions covering prices, groups, quantities and item info -- and
nothing for shopping, search, browse or query. So click-to-search cannot work
under TSM, and no amount of effort here changes that.

What the addon does instead: clicking a row opens a copy box with the item name
pre-selected (Ctrl+C), and a **TSM group** button produces an import string for
the whole shopping list. Paste it into TSM > Groups > Import, then use Shopping
to search that group -- one search covering every item, which is faster than
clicking each row anyway.

The addon tracks whether the auction house is open via the `AUCTION_HOUSE_SHOW` /
`AUCTION_HOUSE_CLOSED` events, not by whether Blizzard's auction frame is
visible -- TSM4 hides that frame entirely, which used to make scanning refuse to
start. Scanning works under TSM.

Clicking a shopping-list line can only drive Blizzard's browse pane. Under a
replacement UI it prints the item name to chat instead of erroring.

Note that TSM does its own AH scanning; if it is mid-scan the two will contend
for the same throttle and this scan will be slower.

## Known limits

- **Classic values, not TBC.** Patch 2.0.1 raised many of these (Abyssal Scepter
  150→350, Timbermaw 50→75, Valor Token 25→50). Edit `Data.lua` for a later realm.
- The optimizer cannot see your quest log, so it will happily suggest Abyssal
  Scepters before you are Revered.
- Very large targets cap the search for performance; the window says so when
  that happens.
- **Argent Dawn:** the five commission quests pay 200 rep once each (modelled
  with `limit = 1`); the repeatable versions pay 10 rep per 30 items.
  Scourgestones, Healthy Dragon Scale and the cauldron reagents are
  Bind-on-Pickup, so they are not listed. The window reports the cost and lets
  you judge it.
- Timbermaw is absent because both of its turn-in items are Bind-on-Pickup —
  there is genuinely nothing to optimise. See the spreadsheet.
- If the auction house cannot cover the target, the addon does **not** refuse:
  it reports how far the listings can get you and prices that. It distinguishes
  "the listings are short" from "we stopped the search early", because blaming
  the market for our own cap is a lie.
- The racial bonus is read from `UnitRace()`. There is no checkbox: the game
  already knows whether you are Human.


## Install

Copy this folder into `World of Warcraft/_classic_era_/Interface/AddOns/` and name it `RepOptimizer`.

## License

MIT. See [LICENSE](LICENSE).
