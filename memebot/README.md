# memebot: Solana memecoin paper-trading bot

Watches newly promoted Solana memecoins, filters out obvious rugs, and **paper trades**
them (simulated money, real live prices). No wallet, no private keys, no real funds.

## Strategy: many small bets, let the rare winner run

Coins that do 200x are very rare, and most new launches go to zero. You can't predict
which one will run, so the bot spreads small fixed bets and manages each one the same way:

1. **Find**: polls DexScreener for newly promoted Solana tokens.
2. **Filter**: age 3 min–6 h, liquidity ≥ $8k, market cap $10k–$500k (early enough to
   have 200x headroom), real 1h volume, more buys than sells, not already vertical.
3. **Safety**: RugCheck report must have no "danger" risks (mint authority, freeze authority,
   etc.) and a low risk score.
4. **Buy** a fixed $20 (paper).
5. **Exit**:
   - -50% before any profit → stop loss
   - **2x → sell half (your stake is back; the rest is a free ride)**
   - 5x / 20x / 100x → sell 15% / 10% / 10% more
   - The last 15% (the "moonbag") rides, with a 45% trailing stop from its peak
   - Liquidity pulled ≥70% → exit (rug); no movement after 90 min → exit
6. **Missed-trade tracker**: it keeps tracking tokens it *skipped* for 24 h, so the report
   shows which filters cost you a big winner. Use that to tune `config.toml`.

## Run it on your computer

Needs Python 3.11+.

```bash
cd memebot
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp config.example.toml config.toml # optional: edit settings

python -m memebot run --hours 4    # a 4-hour session (see "Daily sessions" below)
python -m memebot run              # no time limit; Ctrl+C to stop
python -m memebot report           # in another terminal: P&L, open positions, missed runners
python -m memebot report --missed 20   # only show skipped tokens that went 20x+
python -m memebot close            # close positions now (e.g. if the session was cut short)
python -m memebot reset            # wipe paper data and start over
```

## Daily sessions (laptop not on 24/7)

`run --hours N` runs for N hours. In the last hour it stops opening new positions, and
when time is up it sells everything **except moonbags** (positions that already hit a
take-profit, so your stake is already back). Moonbags carry over to the next session.
Ctrl+C does the same early. So nothing unprotected is left open while the laptop is off.

Everything is saved in `data/`: `state.json` (portfolio, survives restarts),
`trades.csv` (every simulated buy and sell, opens in Excel/Tableau) and `bot.log`.

## Tests

```bash
pip install pytest
python -m pytest -q
```

## Before ever going live

- Paper-trade for at least a few weeks. Real fills on tiny pools are worse than the
  simulated 3% slippage, and some tokens can't be sold at all (honeypots).
- Live mode isn't built yet on purpose. When it is: a separate burner wallet with only
  money you can afford to lose, the key in an environment variable, never in code or git.
- This is not financial advice. Most memecoin traders lose money.
