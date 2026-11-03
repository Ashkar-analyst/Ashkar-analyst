# MomentumScannerEA (MetaTrader 5, Exness-ready)

An Expert Advisor that scans a list of forex pairs and commodities (gold, silver, oil). It looks for instruments with **strong directional momentum**, then enters **buy or sell** on a pullback-and-resume pattern. Each trade gets an ATR/structure-based stop loss, a take profit set as a multiple of that stop, and a lot size calculated from a fixed % of equity.

> ⚠️ **No strategy is guaranteed to make money.** This EA hasn't been tested on your account. Backtest it, then run it on a **demo account for at least 4–8 weeks** before using real money. Only trade with money you can afford to lose.

## How it trades

| Step | Rule (defaults) |
|---|---|
| **Trend filter** (H1) | Buy only if EMA50 > EMA200 and price > EMA200. Sell only if the opposite holds. |
| **Trend strength** (M15) | ADX(14) ≥ 22 and rising. +DI > −DI for buys, −DI > +DI for sells. |
| **Momentum** (M15) | The last 10 bars moved at least 1 × ATR in the trend direction. |
| **Entry trigger** (M15) | Within the last 3 bars, price pulled back to within 0.5 ATR of EMA21. Then a candle closes back in the trend direction and breaks the previous candle's high (buy) or low (sell). RSI must be between 50 and 70 for buys, or between 30 and 50 for sells. |
| **Ranking** | All valid setups across all symbols are ranked by momentum × ADX. The strongest ones are opened first. |
| **Stop loss** | Beyond the 10-bar swing low/high plus 0.2 ATR, and at least 1.5 ATR away. A setup is skipped if the stop would need to be wider than 3 ATR. |
| **Take profit** | 2 × the stop distance (1:2 reward:risk). |
| **Management** | Stop moves to break-even (+0.1R) at 1R profit. A 2 × ATR trailing stop starts at 1.5R profit. |

## Equity protection

- **Lot size = risk-based.** By default each trade risks **0.5% of equity** (the lower of equity and balance). The loss in money is calculated with `OrderCalcProfit`, so the sizing is correct for JPY pairs, gold, oil and cent accounts.
- **Minimum lot too big?** The trade is **skipped**. It never rounds up to a lot that risks more than you allowed.
- **Margin cap:** a single new trade can use at most 30% of free margin.
- **Max 3 open positions**, and at most 2 positions leaning the same way on any one currency. This stops it from stacking several USD-short trades, for example.
- **Daily loss limit 3%:** no new trades for the rest of the day once it's hit. It can optionally close open trades too.
- **Max drawdown 10% from peak equity:** closes all EA trades and **locks** the EA. To unlock, set `InpResetDrawdownLock = true` once, then set it back to false. Deposits and withdrawals move peak equity too, so reset the lock after you withdraw money.
- **Spread filter:** skips a trade if the spread is more than 15% of ATR.
- **Session filter:** only trades 07:00–20:00 server time (Exness server time = GMT+0) and takes no new trades on Friday after 18:00.
- **News filter:** skips entries 30 minutes before or after high-impact events for that symbol's currencies, using the MT5 economic calendar. This only works live or on demo, not in the Strategy Tester.
- **Demo-only safety switch:** `InpDemoOnly = true` by default. With it on, the EA refuses to run on a real account.

## Installing on Exness MT5

1. Open an Exness **MT5** account. Start with a **demo** account. Standard, Pro, Raw Spread and Zero all work. Raw/Zero have lower spreads, which helps this kind of strategy.
2. In MetaTrader 5: **File → Open Data Folder → MQL5 → Experts**, then copy `MomentumScannerEA.mq5` into that folder.
3. Open **MetaEditor** (F4), open the file and press **Compile** (F7). It should show `0 errors`.
4. In MT5, click **Algo Trading** on the toolbar so it turns green.
5. Open any chart (for example EURUSD M15). Drag **MomentumScannerEA** from the Navigator onto it, tick **Allow Algo Trading**, then click OK.
   - You only need **one chart**. The EA trades every symbol in its list from that single chart.
6. Check the **Experts** tab. You should see a `Scanning: XAUUSDm`-style line for each symbol it found.

### Exness symbol names

| Account type | Example names | `InpSymbolSuffix` |
|---|---|---|
| Standard | `EURUSDm`, `XAUUSDm`, `USOILm` | `m` (auto-detected) |
| Standard Cent | `EURUSDc`, `XAUUSDc` | `c` (auto-detected) |
| Pro / Raw Spread / Zero | `EURUSD`, `XAUUSD`, `USOIL` | leave empty |

With `InpAutoDetectSuffix = true` (the default), the EA finds the right names automatically. Symbols your account doesn't offer are skipped and logged.

### Keeping it running 24/5

The EA only trades while MT5 is open and connected. To keep it running when your computer is off:
- use a **VPS** (Exness offers a free VPS for accounts that meet its deposit requirement, or use any Windows VPS), or
- the **MQL5 Virtual Hosting** built into MT5 (right-click your account in Navigator → *Register a Virtual Server*).

## Backtesting (do this first)

1. In MT5: **View → Strategy Tester** (Ctrl+R).
2. Expert: `MomentumScannerEA`. Symbol: any symbol from the list. Timeframe: M15.
3. Modelling: **Every tick based on real ticks**. Period: at least **2 years**.
4. Deposit: what you plan to trade with. Leverage: your account's leverage.
5. Run it. Check the **profit factor (> 1.3 is a good sign)**, **maximum equity drawdown**, and the number of trades (≥ 100 for meaningful results).
6. Optional: run an **optimisation** with *Custom max* as the criterion. The EA scores each run by recovery factor × profit factor. Watch out for **over-fitting**: settings that only work on the past. Check any optimised settings with a forward test on a period the optimiser didn't see.

## Key settings

| Input | Default | Notes |
|---|---|---|
| `InpRiskPercent` | 0.5 | % of equity risked per trade. 0.25–1.0 is sensible, and the EA warns above 2. |
| `InpRewardRisk` | 2.0 | TP as a multiple of the SL distance. |
| `InpMaxOpenPositions` | 3 | Total open trades across all symbols. |
| `InpDailyLossLimitPct` | 3.0 | Stop for the day after this loss. |
| `InpMaxDrawdownPct` | 10.0 | Hard lock from peak equity. |
| `InpSignalTF` / `InpTrendTF` | M15 / H1 | You can also try H1 / H4 for fewer, slower trades. |
| `InpADXMin` | 22 | Raise it for fewer, stronger-trend trades. |
| `InpDemoOnly` | true | Set to false only after successful demo testing. |
