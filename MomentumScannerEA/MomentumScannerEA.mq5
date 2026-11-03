//+------------------------------------------------------------------+
//|                                            MomentumScannerEA.mq5 |
//|  Multi-symbol trend + momentum EA for MetaTrader 5 (Exness-ready)|
//|                                                                  |
//|  Strategy summary                                                |
//|   1. Trend filter  (higher TF): EMA50 vs EMA200 + price vs EMA200|
//|   2. Strength      (signal TF): ADX above threshold and rising,  |
//|                                 +DI/-DI agree with the trend     |
//|   3. Momentum score(signal TF): N-bar move measured in ATRs      |
//|   4. Entry trigger (signal TF): pullback into the EMA21 zone,    |
//|                                 then a candle that closes back   |
//|                                 in trend direction and breaks    |
//|                                 the previous candle's high/low,  |
//|                                 with RSI confirming (not extreme)|
//|   5. Exits: SL beyond recent swing (min 1.5 ATR, max 3 ATR),     |
//|             TP = RewardRisk x SL, break-even at 1R, ATR trailing |
//|   6. Risk:  lot size from % of equity at risk, margin cap,       |
//|             max positions, per-currency exposure cap, daily loss |
//|             limit, max drawdown lock, spread + news filters      |
//|                                                                  |
//|  The EA scans every symbol in the list, ranks valid setups by    |
//|  momentum strength and opens only the strongest ones within the  |
//|  risk limits.                                                    |
//|                                                                  |
//|  No strategy is guaranteed to be profitable. Backtest and run    |
//|  on a demo account before trading real money.                    |
//+------------------------------------------------------------------+
#property copyright "Ashkar Jaleel"
#property version   "1.00"
#property description "Multi-symbol trend/momentum EA with ATR-based SL/TP and equity-protecting position sizing."

#include <Trade\Trade.mqh>

//--------------------------- Inputs ---------------------------------
input group "=== Symbols ==="
input string InpSymbols          = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,USDCHF,NZDUSD,EURJPY,GBPJPY,XAUUSD,XAGUSD,USOIL,UKOIL"; // Symbols to scan (base names)
input string InpSymbolSuffix     = "";      // Symbol suffix (Exness Standard = "m", Cent = "c", Pro/Raw/Zero = "")
input bool   InpAutoDetectSuffix = true;    // Auto-detect broker suffix if a name is not found

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES InpSignalTF = PERIOD_M15; // Signal / entry timeframe
input ENUM_TIMEFRAMES InpTrendTF  = PERIOD_H1;  // Trend filter timeframe

input group "=== Entry strategy ==="
input int    InpTrendFastEMA     = 50;    // Trend TF fast EMA
input int    InpTrendSlowEMA     = 200;   // Trend TF slow EMA
input int    InpPullbackEMA      = 21;    // Signal TF pullback EMA
input int    InpADXPeriod        = 14;    // ADX period
input double InpADXMin           = 22.0;  // Minimum ADX (trend strength)
input int    InpRSIPeriod        = 14;    // RSI period
input double InpRSIBuyMin        = 50.0;  // Buy: RSI must be >= this
input double InpRSIBuyMax        = 70.0;  // Buy: RSI must be <= this (avoid overbought)
input double InpRSISellMin       = 30.0;  // Sell: RSI must be >= this (avoid oversold)
input double InpRSISellMax       = 50.0;  // Sell: RSI must be <= this
input int    InpATRPeriod        = 14;    // ATR period
input double InpPullbackATR      = 0.5;   // Pullback must reach within X ATR of EMA
input int    InpPullbackBars     = 3;     // Look back this many bars for the pullback
input int    InpMomentumBars     = 10;    // Momentum lookback (bars)
input double InpMinMomentumATR   = 1.0;   // Minimum N-bar move in ATRs

input group "=== Exits ==="
input double InpSLATRMult        = 1.5;   // Minimum SL distance (x ATR)
input int    InpSwingLookback    = 10;    // Bars used to find the swing high/low for SL
input double InpSwingBufferATR   = 0.2;   // Extra buffer beyond the swing (x ATR)
input double InpMaxSLATR         = 3.0;   // Skip trade if SL would be wider than X ATR
input double InpRewardRisk       = 2.0;   // Take profit = RewardRisk x SL distance
input bool   InpUseBreakeven     = true;  // Move SL to break-even
input double InpBreakevenAtR     = 1.0;   // ...when profit reaches X R
input bool   InpUseTrailing      = true;  // ATR trailing stop
input double InpTrailStartR      = 1.5;   // Start trailing at X R profit
input double InpTrailATRMult     = 2.0;   // Trailing distance (x ATR)
input int    InpMaxBarsInTrade   = 0;     // Close after N signal-TF bars (0 = off)

input group "=== Risk management ==="
input double InpRiskPercent       = 0.5;  // Risk per trade (% of equity)
input int    InpMaxOpenPositions  = 3;    // Max simultaneous positions (all symbols)
input int    InpMaxPerCurrency    = 2;    // Max positions exposed to one currency in the same direction
input double InpDailyLossLimitPct = 3.0;  // Stop opening trades after X% loss today
input bool   InpCloseOnDailyLimit = false;// Also close open trades when daily limit is hit
input double InpMaxDrawdownPct    = 10.0; // Close all and lock the EA at X% drawdown from peak equity
input bool   InpResetDrawdownLock = false;// Set true once to clear a drawdown lock / reset peak
input double InpMaxMarginUsePct   = 30.0; // A new trade may use at most X% of free margin
input double InpMaxSpreadATR      = 0.15; // Skip if spread > X * ATR

input group "=== Filters ==="
input bool   InpUseSessionFilter  = true; // Trade only during session hours (server time)
input int    InpSessionStartHour  = 7;    // Session start hour (Exness server = GMT+0)
input int    InpSessionEndHour    = 20;   // Session end hour
input int    InpFridayCutoffHour  = 18;   // No new trades on Friday after this hour
input bool   InpUseNewsFilter     = true; // Skip entries near high-impact news (live only)
input int    InpNewsMinutesBefore = 30;   // Minutes before news
input int    InpNewsMinutesAfter  = 30;   // Minutes after news

input group "=== General ==="
input bool   InpDemoOnly          = true; // Safety: refuse to trade on a REAL account
input ulong  InpMagic             = 26110301; // Magic number
input int    InpSlippagePoints    = 20;   // Max slippage (points)
input string InpTradeComment      = "MomentumEA"; // Order comment
input bool   InpVerbose           = true; // Print decisions to the Experts log
input bool   InpShowPanel         = true; // Show status panel on chart
input bool   InpPushNotifications = true; // Send push alerts to the MT5 phone app

//--------------------------- Types / globals ------------------------
struct SymbolData
  {
   string   name;
   int      hTrendFast;
   int      hTrendSlow;
   int      hPullback;
   int      hADX;
   int      hRSI;
   int      hATR;
   datetime lastBar;
  };

struct Candidate
  {
   int    idx;
   int    dir;     // +1 buy, -1 sell
   double score;
   double atr;
   double sl;
   double tp;
   double entry;
  };

CTrade     g_trade;
SymbolData g_syms[];

double   g_dayStartEq   = 0.0;
datetime g_day          = 0;
double   g_peakEq       = 0.0;
bool     g_haltedToday  = false;
bool     g_haltedDD     = false;
bool     g_busy         = false;
string   g_status       = "";

ulong    g_riskTickets[];
double   g_riskValues[];

string GvName(const string key) { return "MomEA_" + IntegerToString((long)InpMagic) + "_" + key; }

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
void Log(const string msg)
  {
   if(InpVerbose)
      Print("[MomentumEA] ", msg);
  }

// Push notification to the MetaTrader 5 mobile app (needs MetaQuotes ID set in
// Tools > Options > Notifications on the terminal running the EA)
void Notify(const string msg)
  {
   Log(msg);
   if(InpPushNotifications && !MQLInfoInteger(MQL_TESTER) && TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      SendNotification("MomentumEA: " + msg);
  }

bool CopyVal(const int handle, const int buffer, const int shift, const int count, double &out[])
  {
   ArraySetAsSeries(out, true);
   return(CopyBuffer(handle, buffer, shift, count, out) == count);
  }

bool SymbolExists(const string s)
  {
   bool custom = false;
   return(SymbolExist(s, custom));
  }

string ResolveSymbol(string base)
  {
   StringTrimLeft(base);
   StringTrimRight(base);
   if(base == "")
      return("");

   if(InpSymbolSuffix != "" && SymbolExists(base + InpSymbolSuffix))
      return(base + InpSymbolSuffix);
   if(SymbolExists(base))
      return(base);
   if(!InpAutoDetectSuffix)
      return("");

   // Common broker suffixes (Exness: "m" Standard, "c" Standard Cent)
   string sfx[] = {"m", "c", "z", "r", ".a", "_i", "pro", "."};
   for(int i = 0; i < ArraySize(sfx); i++)
      if(SymbolExists(base + sfx[i]))
         return(base + sfx[i]);

   // Last resort: any symbol that starts with the base name plus a short suffix
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      string n = SymbolName(i, false);
      if(StringFind(n, base) == 0 && StringLen(n) <= StringLen(base) + 4)
         return(n);
     }
   return("");
  }

int FindSymbolIndex(const string sym)
  {
   for(int i = 0; i < ArraySize(g_syms); i++)
      if(g_syms[i].name == sym)
         return(i);
   return(-1);
  }

double NormPrice(const string sym, const double price)
  {
   double tick  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(tick > 0)
      return(NormalizeDouble(MathRound(price / tick) * tick, digits));
   return(NormalizeDouble(price, digits));
  }

int VolumeDigits(const double step)
  {
   if(step <= 0)
      return(2);
   return((int)MathMax(0, MathCeil(-MathLog10(step) - 1e-9)));
  }

double StopsDistance(const string sym)
  {
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   long   stops  = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   long   freeze = SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   return((double)MathMax(stops, freeze) * point);
  }

bool IsOurPosition()
  {
   return((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic);
  }

int CountOurPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t != 0 && PositionSelectByTicket(t) && IsOurPosition())
         n++;
     }
   return(n);
  }

bool HasPosition(const string sym)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t != 0 && PositionSelectByTicket(t) && IsOurPosition() &&
         PositionGetString(POSITION_SYMBOL) == sym)
         return(true);
     }
   return(false);
  }

// Count open positions that are exposed to `cur` in direction `sign`
// (+1 = long that currency, -1 = short that currency).
int CurrencyExposure(const string cur, const int sign)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t) || !IsOurPosition())
         continue;
      string ps   = PositionGetString(POSITION_SYMBOL);
      int    pdir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      string b = SymbolInfoString(ps, SYMBOL_CURRENCY_BASE);
      string q = SymbolInfoString(ps, SYMBOL_CURRENCY_PROFIT);
      if(b == q)
        {
         if(q == cur && pdir == sign)
            n++;
         continue;
        }
      if(b == cur && pdir == sign)
         n++;
      if(q == cur && -pdir == sign)
         n++;
     }
   return(n);
  }

bool ExposureAllowed(const string sym, const int dir)
  {
   string b = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
   string q = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
   if(b == q)
      return(CurrencyExposure(q, dir) < InpMaxPerCurrency);
   if(CurrencyExposure(b, dir) >= InpMaxPerCurrency)
      return(false);
   if(CurrencyExposure(q, -dir) >= InpMaxPerCurrency)
      return(false);
   return(true);
  }

void CloseAllOurPositions(const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t) || !IsOurPosition())
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      g_trade.SetTypeFillingBySymbol(sym);
      if(g_trade.PositionClose(t))
         Log("Closed #" + IntegerToString((long)t) + " " + sym + " (" + reason + ")");
      else
         Log("Failed to close #" + IntegerToString((long)t) + " retcode=" + IntegerToString(g_trade.ResultRetcode()));
     }
  }

//+------------------------------------------------------------------+
//| Account-level risk state: daily loss limit & drawdown lock       |
//+------------------------------------------------------------------+
void UpdateRiskState()
  {
   double   eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   datetime now = TimeCurrent();
   datetime day = (datetime)((long)now - ((long)now % 86400));

   if(day != g_day)
     {
      g_day         = day;
      g_dayStartEq  = eq;
      g_haltedToday = false;
      GlobalVariableSet(GvName("day"), (double)g_day);
      GlobalVariableSet(GvName("dayeq"), g_dayStartEq);
     }

   if(eq > g_peakEq)
     {
      g_peakEq = eq;
      GlobalVariableSet(GvName("peak"), g_peakEq);
     }

   if(!g_haltedToday && g_dayStartEq > 0)
     {
      double dayLossPct = (g_dayStartEq - eq) / g_dayStartEq * 100.0;
      if(dayLossPct >= InpDailyLossLimitPct)
        {
         g_haltedToday = true;
         Notify(StringFormat("Daily loss limit hit (%.2f%%). No new trades until tomorrow.", dayLossPct));
         if(InpCloseOnDailyLimit)
            CloseAllOurPositions("daily loss limit");
        }
     }

   if(!g_haltedDD && g_peakEq > 0)
     {
      double ddPct = (g_peakEq - eq) / g_peakEq * 100.0;
      if(ddPct >= InpMaxDrawdownPct)
        {
         g_haltedDD = true;
         GlobalVariableSet(GvName("ddlock"), 1.0);
         Notify(StringFormat("MAX DRAWDOWN %.2f%% reached. Closing all trades and locking the EA.", ddPct));
         CloseAllOurPositions("max drawdown");
        }
     }
  }

bool SessionOK()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(t.day_of_week == 0 || t.day_of_week == 6)
      return(false);
   if(t.day_of_week == 5 && t.hour >= InpFridayCutoffHour)
      return(false);
   if(!InpUseSessionFilter)
      return(true);
   if(InpSessionStartHour <= InpSessionEndHour)
      return(t.hour >= InpSessionStartHour && t.hour < InpSessionEndHour);
   return(t.hour >= InpSessionStartHour || t.hour < InpSessionEndHour); // overnight window
  }

bool CanOpenNew(string &why)
  {
   if(g_haltedDD)                  { why = "drawdown lock"; return(false); }
   if(g_haltedToday)               { why = "daily loss limit"; return(false); }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { why = "Algo Trading disabled in terminal"; return(false); }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           { why = "EA not allowed to trade"; return(false); }
   if(!SessionOK())                { why = "outside session"; return(false); }
   if(CountOurPositions() >= InpMaxOpenPositions) { why = "max positions open"; return(false); }
   why = "scanning";
   return(true);
  }

//+------------------------------------------------------------------+
//| News filter (MQL5 economic calendar, live/demo only)             |
//+------------------------------------------------------------------+
bool CurrencyHasHighImpactNews(const string cur, const datetime from, const datetime to)
  {
   if(cur == "")
      return(false);
   MqlCalendarValue vals[];
   int n = CalendarValueHistory(vals, from, to, NULL, cur);
   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(CalendarEventById(vals[i].event_id, ev) && ev.importance == CALENDAR_IMPORTANCE_HIGH)
         return(true);
     }
   return(false);
  }

bool NewsBlocked(const string sym)
  {
   if(!InpUseNewsFilter || MQLInfoInteger(MQL_TESTER))
      return(false);
   datetime now  = TimeTradeServer();
   datetime from = now - InpNewsMinutesAfter * 60;
   datetime to   = now + InpNewsMinutesBefore * 60;
   string b = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
   string q = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
   if(CurrencyHasHighImpactNews(q, from, to))
      return(true);
   if(b != q && CurrencyHasHighImpactNews(b, from, to))
      return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| Signal logic                                                     |
//+------------------------------------------------------------------+
bool Evaluate(const int idx, Candidate &c)
  {
   string sym = g_syms[idx].name;

   if(HasPosition(sym))
      return(false);

   long tradeMode = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED || tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY)
      return(false);

   // Market must be live (fresh quotes)
   if(TimeCurrent() - (datetime)SymbolInfoInteger(sym, SYMBOL_TIME) > 300)
      return(false);

   SymbolData s = g_syms[idx];
   if(BarsCalculated(s.hTrendSlow) <= 0 || BarsCalculated(s.hADX) <= 0 || BarsCalculated(s.hATR) <= 0)
      return(false);

   // --- Trend filter on higher timeframe (last closed bar)
   double fast[], slow[];
   if(!CopyVal(s.hTrendFast, 0, 1, 1, fast) || !CopyVal(s.hTrendSlow, 0, 1, 1, slow))
      return(false);
   double trendClose = iClose(sym, InpTrendTF, 1);
   if(trendClose <= 0)
      return(false);
   bool trendUp   = fast[0] > slow[0] && trendClose > slow[0];
   bool trendDown = fast[0] < slow[0] && trendClose < slow[0];
   if(!trendUp && !trendDown)
      return(false);

   // --- Signal timeframe data (index 0 = last closed bar)
   int need = (int)MathMax(MathMax(InpSwingLookback, InpMomentumBars), InpPullbackBars) + 2;
   double ema[], adx[], pdi[], mdi[], rsi[], atr[];
   if(!CopyVal(s.hPullback, 0, 1, InpPullbackBars + 1, ema)) return(false);
   if(!CopyVal(s.hADX, 0, 1, 2, adx))  return(false);
   if(!CopyVal(s.hADX, 1, 1, 1, pdi))  return(false);
   if(!CopyVal(s.hADX, 2, 1, 1, mdi))  return(false);
   if(!CopyVal(s.hRSI, 0, 1, 1, rsi))  return(false);
   if(!CopyVal(s.hATR, 0, 1, 1, atr))  return(false);

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(sym, InpSignalTF, 1, need, r) != need)
      return(false);

   double a = atr[0];
   if(a <= 0)
      return(false);

   // --- Trend strength
   if(adx[0] < InpADXMin || adx[0] <= adx[1])
      return(false);

   int dir = 0;
   if(trendUp && pdi[0] > mdi[0])
      dir = 1;
   else if(trendDown && mdi[0] > pdi[0])
      dir = -1;
   if(dir == 0)
      return(false);

   // --- Momentum (N-bar move in ATRs, signed with direction)
   double momentum = (r[0].close - r[InpMomentumBars].close) / a * dir;
   if(momentum < InpMinMomentumATR)
      return(false);

   // --- Pullback into EMA zone within the last few bars + resumption candle
   bool pulledBack = false;
   for(int k = 1; k <= InpPullbackBars; k++)
     {
      if(dir > 0 && r[k].low  <= ema[k] + InpPullbackATR * a) pulledBack = true;
      if(dir < 0 && r[k].high >= ema[k] - InpPullbackATR * a) pulledBack = true;
     }
   if(!pulledBack)
      return(false);

   bool trigger;
   if(dir > 0)
      trigger = r[0].close > ema[0] && r[0].close > r[0].open && r[0].close > r[1].high &&
                rsi[0] >= InpRSIBuyMin && rsi[0] <= InpRSIBuyMax;
   else
      trigger = r[0].close < ema[0] && r[0].close < r[0].open && r[0].close < r[1].low &&
                rsi[0] >= InpRSISellMin && rsi[0] <= InpRSISellMax;
   if(!trigger)
      return(false);

   // --- Spread filter
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(ask <= 0 || bid <= 0)
      return(false);
   if(ask - bid > InpMaxSpreadATR * a)
     {
      Log(sym + ": setup skipped, spread too wide");
      return(false);
     }

   // --- Stop loss beyond the swing, take profit at R multiple
   double entry = (dir > 0) ? ask : bid;
   double swing = (dir > 0) ? r[0].low : r[0].high;
   for(int k = 0; k < InpSwingLookback; k++)
     {
      if(dir > 0) swing = MathMin(swing, r[k].low);
      else        swing = MathMax(swing, r[k].high);
     }
   double slDist = (dir > 0) ? (entry - (swing - InpSwingBufferATR * a))
                             : ((swing + InpSwingBufferATR * a) - entry);
   slDist = MathMax(slDist, InpSLATRMult * a);
   if(slDist > InpMaxSLATR * a)
     {
      Log(sym + ": setup skipped, stop would be too wide");
      return(false);
     }
   double minDist = StopsDistance(sym) + (ask - bid);
   if(slDist <= minDist)
      slDist = minDist * 1.5;

   c.idx   = idx;
   c.dir   = dir;
   c.atr   = a;
   c.entry = entry;
   c.sl    = NormPrice(sym, entry - dir * slDist);
   c.tp    = NormPrice(sym, entry + dir * slDist * InpRewardRisk);
   c.score = momentum * (adx[0] / 25.0);
   return(true);
  }

//+------------------------------------------------------------------+
//| Position sizing: risk a fixed % of equity, respect margin        |
//+------------------------------------------------------------------+
double CalcLots(const string sym, const int dir, const double entry, const double sl)
  {
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double base      = MathMin(equity, balance);           // conservative
   double riskMoney = base * InpRiskPercent / 100.0;
   if(riskMoney <= 0)
      return(0);

   ENUM_ORDER_TYPE type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double profit = 0;
   if(!OrderCalcProfit(type, sym, 1.0, entry, sl, profit))
      return(0);
   double lossPerLot = MathAbs(profit);
   if(lossPerLot <= 0)
      return(0);

   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double limit  = SymbolInfoDouble(sym, SYMBOL_VOLUME_LIMIT);
   if(step <= 0)
      step = 0.01;

   double lots = MathFloor((riskMoney / lossPerLot) / step) * step;
   if(lots < minLot)
     {
      Log(StringFormat("%s: min lot %.2f would risk %.2f (> %.2f allowed). Trade skipped to protect equity.",
                       sym, minLot, minLot * lossPerLot, riskMoney));
      return(0);
     }
   lots = MathMin(lots, maxLot);
   if(limit > 0)
      lots = MathMin(lots, limit);

   // Margin cap
   double margin = 0;
   if(OrderCalcMargin(type, sym, lots, entry, margin) && margin > 0)
     {
      double allowed = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * InpMaxMarginUsePct / 100.0;
      if(margin > allowed)
        {
         lots = MathFloor((lots * allowed / margin) / step) * step;
         if(lots < minLot)
           {
            Log(sym + ": not enough free margin within the margin cap. Trade skipped.");
            return(0);
           }
        }
     }
   return(NormalizeDouble(lots, VolumeDigits(step)));
  }

//+------------------------------------------------------------------+
//| Scan all symbols, rank, and open the best setups                 |
//+------------------------------------------------------------------+
void ScanAndTrade()
  {
   Candidate list[];
   int n = 0;

   for(int i = 0; i < ArraySize(g_syms); i++)
     {
      datetime bt = iTime(g_syms[i].name, InpSignalTF, 0);
      if(bt == 0 || bt == g_syms[i].lastBar)
         continue;
      g_syms[i].lastBar = bt;

      Candidate c;
      if(Evaluate(i, c))
        {
         ArrayResize(list, n + 1);
         list[n++] = c;
        }
     }
   if(n == 0)
      return;

   // Sort strongest momentum first
   for(int i = 0; i < n - 1; i++)
      for(int j = i + 1; j < n; j++)
         if(list[j].score > list[i].score)
           {
            Candidate tmp = list[i];
            list[i] = list[j];
            list[j] = tmp;
           }

   for(int i = 0; i < n; i++)
     {
      if(CountOurPositions() >= InpMaxOpenPositions)
         break;
      OpenTrade(list[i]);
     }
  }

void OpenTrade(const Candidate &c)
  {
   string sym = g_syms[c.idx].name;
   string side = (c.dir > 0) ? "BUY" : "SELL";

   if(!ExposureAllowed(sym, c.dir))
     {
      Log(sym + " " + side + ": skipped, currency exposure limit reached");
      return;
     }
   if(NewsBlocked(sym))
     {
      Log(sym + " " + side + ": skipped, high-impact news window");
      return;
     }

   // Re-price with the latest quote, keep the same SL distance
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double entry  = (c.dir > 0) ? ask : bid;
   double slDist = MathAbs(c.entry - c.sl);
   double sl = NormPrice(sym, entry - c.dir * slDist);
   double tp = NormPrice(sym, entry + c.dir * slDist * InpRewardRisk);

   double lots = CalcLots(sym, c.dir, entry, sl);
   if(lots <= 0)
      return;

   g_trade.SetTypeFillingBySymbol(sym);
   bool ok = (c.dir > 0) ? g_trade.Buy(lots, sym, 0.0, sl, tp, InpTradeComment)
                         : g_trade.Sell(lots, sym, 0.0, sl, tp, InpTradeComment);
   uint rc = g_trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
      Notify(StringFormat("%s %s %.2f lots @ %s  SL %s  TP %s  (score %.2f, risk %.2f%%)",
                       side, sym, lots,
                       DoubleToString(entry, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                       DoubleToString(sl, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                       DoubleToString(tp, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                       c.score, InpRiskPercent));
   else
      Log(StringFormat("%s %s failed: retcode %u (%s)", side, sym, rc, g_trade.ResultRetcodeDescription()));
  }

//+------------------------------------------------------------------+
//| Trade management: break-even, trailing stop, time exit           |
//+------------------------------------------------------------------+
double InitialRisk(const ulong ticket, const long posId, const double open, const double curSL)
  {
   int sz = ArraySize(g_riskTickets);
   for(int i = 0; i < sz; i++)
      if(g_riskTickets[i] == ticket)
         return(g_riskValues[i]);

   double r = 0;
   if(HistorySelectByPosition(posId))
     {
      int total = HistoryOrdersTotal();
      for(int k = 0; k < total; k++)
        {
         ulong o = HistoryOrderGetTicket(k);
         double osl = HistoryOrderGetDouble(o, ORDER_SL);
         if(osl > 0)
           {
            r = MathAbs(open - osl);
            break;
           }
        }
     }
   if(r <= 0 && curSL > 0)
      r = MathAbs(open - curSL);

   if(r > 0)
     {
      if(sz > 500) { ArrayResize(g_riskTickets, 0); ArrayResize(g_riskValues, 0); sz = 0; }
      ArrayResize(g_riskTickets, sz + 1);
      ArrayResize(g_riskValues, sz + 1);
      g_riskTickets[sz] = ticket;
      g_riskValues[sz]  = r;
     }
   return(r);
  }

void ManagePositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurPosition())
         continue;

      string   sym    = PositionGetString(POSITION_SYMBOL);
      long     type   = PositionGetInteger(POSITION_TYPE);
      long     posId  = PositionGetInteger(POSITION_IDENTIFIER);
      double   open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double   sl     = PositionGetDouble(POSITION_SL);
      double   tp     = PositionGetDouble(POSITION_TP);
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);

      int idx = FindSymbolIndex(sym);
      if(idx < 0)
         continue;

      // Time-based exit
      if(InpMaxBarsInTrade > 0 && iBarShift(sym, InpSignalTF, opened) >= InpMaxBarsInTrade)
        {
         g_trade.SetTypeFillingBySymbol(sym);
         if(g_trade.PositionClose(ticket))
            Log(sym + ": closed after max bars in trade");
         continue;
        }

      double risk = InitialRisk(ticket, posId, open, sl);
      if(risk <= 0)
         continue;
      double atrv[];
      if(!CopyVal(g_syms[idx].hATR, 0, 1, 1, atrv))
         continue;
      double a     = atrv[0];
      double bid   = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask   = SymbolInfoDouble(sym, SYMBOL_ASK);
      double stops = StopsDistance(sym);

      if(type == POSITION_TYPE_BUY)
        {
         double gain  = bid - open;
         double newSL = sl;
         if(InpUseBreakeven && gain >= InpBreakevenAtR * risk)
           {
            double be = open + 0.1 * risk;
            if(newSL < be) newSL = be;
           }
         if(InpUseTrailing && gain >= InpTrailStartR * risk)
           {
            double tr = bid - InpTrailATRMult * a;
            if(tr > newSL) newSL = tr;
           }
         newSL = NormPrice(sym, newSL);
         if(newSL > sl + 0.05 * a && bid - newSL > stops)
            if(g_trade.PositionModify(ticket, newSL, tp))
               Log(StringFormat("%s BUY: SL moved to %s", sym, DoubleToString(newSL, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS))));
        }
      else
        {
         double gain  = open - ask;
         double curSL = (sl > 0) ? sl : DBL_MAX;
         double newSL = curSL;
         if(InpUseBreakeven && gain >= InpBreakevenAtR * risk)
           {
            double be = open - 0.1 * risk;
            if(newSL > be) newSL = be;
           }
         if(InpUseTrailing && gain >= InpTrailStartR * risk)
           {
            double tr = ask + InpTrailATRMult * a;
            if(tr < newSL) newSL = tr;
           }
         if(newSL == DBL_MAX)
            continue;
         newSL = NormPrice(sym, newSL);
         if(newSL < curSL - 0.05 * a && newSL - ask > stops)
            if(g_trade.PositionModify(ticket, newSL, tp))
               Log(StringFormat("%s SELL: SL moved to %s", sym, DoubleToString(newSL, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS))));
        }
     }
  }

//+------------------------------------------------------------------+
//| Status panel                                                     |
//+------------------------------------------------------------------+
void DrawPanel()
  {
   if(!InpShowPanel || (MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)))
      return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPct  = (g_dayStartEq > 0) ? (eq - g_dayStartEq) / g_dayStartEq * 100.0 : 0;
   double ddPct   = (g_peakEq > 0) ? (g_peakEq - eq) / g_peakEq * 100.0 : 0;
   string txt = "MomentumScannerEA\n";
   txt += StringFormat("Symbols: %d   Open positions: %d / %d\n", ArraySize(g_syms), CountOurPositions(), InpMaxOpenPositions);
   txt += StringFormat("Equity: %.2f   Today: %+.2f%%   DD from peak: %.2f%%\n", eq, dayPct, ddPct);
   txt += StringFormat("Risk/trade: %.2f%%   Daily limit: %.1f%%   Max DD: %.1f%%\n", InpRiskPercent, InpDailyLossLimitPct, InpMaxDrawdownPct);
   txt += "Status: " + g_status;
   Comment(txt);
  }

//+------------------------------------------------------------------+
//| Main loop                                                        |
//+------------------------------------------------------------------+
void Process()
  {
   if(g_busy)
      return;
   g_busy = true;

   UpdateRiskState();
   ManagePositions();

   string why;
   if(CanOpenNew(why))
      ScanAndTrade();
   g_status = why;
   DrawPanel();

   g_busy = false;
  }

//+------------------------------------------------------------------+
//| Init / deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpRiskPercent <= 0 || InpRiskPercent > 5.0)
     {
      Print("RiskPercent must be between 0 and 5. Recommended: 0.25 - 1.0");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpRewardRisk <= 0 || InpSLATRMult <= 0 || InpMaxSLATR < InpSLATRMult || InpMaxOpenPositions < 1)
     {
      Print("Invalid exit / position parameters.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpRiskPercent > 2.0)
      Print("WARNING: risk per trade above 2% can grow drawdowns very quickly.");

   bool isTester = (bool)MQLInfoInteger(MQL_TESTER);
   if(InpDemoOnly && !isTester && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL)
     {
      Print("InpDemoOnly=true and this is a REAL account. Set InpDemoOnly=false only after demo testing.");
      return(INIT_FAILED);
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   // Load symbols
   string parts[];
   int cnt = StringSplit(InpSymbols, ',', parts);
   ArrayResize(g_syms, 0);
   for(int i = 0; i < cnt; i++)
     {
      string sym = ResolveSymbol(parts[i]);
      if(sym == "")
        {
         Print("Symbol not found on this account, skipped: ", parts[i]);
         continue;
        }
      if(FindSymbolIndex(sym) >= 0)
         continue;
      if(!SymbolSelect(sym, true))
        {
         Print("Could not add to Market Watch: ", sym);
         continue;
        }

      SymbolData s;
      s.name       = sym;
      s.hTrendFast = iMA(sym, InpTrendTF, InpTrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
      s.hTrendSlow = iMA(sym, InpTrendTF, InpTrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      s.hPullback  = iMA(sym, InpSignalTF, InpPullbackEMA, 0, MODE_EMA, PRICE_CLOSE);
      s.hADX       = iADX(sym, InpSignalTF, InpADXPeriod);
      s.hRSI       = iRSI(sym, InpSignalTF, InpRSIPeriod, PRICE_CLOSE);
      s.hATR       = iATR(sym, InpSignalTF, InpATRPeriod);
      s.lastBar    = iTime(sym, InpSignalTF, 0); // don't trade a stale bar on start-up

      if(s.hTrendFast == INVALID_HANDLE || s.hTrendSlow == INVALID_HANDLE || s.hPullback == INVALID_HANDLE ||
         s.hADX == INVALID_HANDLE || s.hRSI == INVALID_HANDLE || s.hATR == INVALID_HANDLE)
        {
         Print("Indicator creation failed for ", sym);
         continue;
        }
      int n = ArraySize(g_syms);
      ArrayResize(g_syms, n + 1);
      g_syms[n] = s;
      Print("Scanning: ", sym);
     }

   if(ArraySize(g_syms) == 0)
     {
      Print("No valid symbols. Check InpSymbols / InpSymbolSuffix.");
      return(INIT_FAILED);
     }

   // Restore risk state (survives restarts)
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(InpResetDrawdownLock)
     {
      GlobalVariableDel(GvName("ddlock"));
      GlobalVariableDel(GvName("peak"));
     }
   g_haltedDD = GlobalVariableCheck(GvName("ddlock")) && GlobalVariableGet(GvName("ddlock")) > 0;
   g_peakEq   = GlobalVariableCheck(GvName("peak")) ? GlobalVariableGet(GvName("peak")) : eq;
   datetime now = TimeCurrent();
   datetime day = (datetime)((long)now - ((long)now % 86400));
   if(GlobalVariableCheck(GvName("day")) && (datetime)GlobalVariableGet(GvName("day")) == day)
     {
      g_day        = day;
      g_dayStartEq = GlobalVariableGet(GvName("dayeq"));
     }
   if(g_haltedDD)
      Print("EA is LOCKED due to max drawdown. Set InpResetDrawdownLock=true once to unlock.");

   EventSetTimer(2);
   Process();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i = 0; i < ArraySize(g_syms); i++)
     {
      IndicatorRelease(g_syms[i].hTrendFast);
      IndicatorRelease(g_syms[i].hTrendSlow);
      IndicatorRelease(g_syms[i].hPullback);
      IndicatorRelease(g_syms[i].hADX);
      IndicatorRelease(g_syms[i].hRSI);
      IndicatorRelease(g_syms[i].hATR);
     }
   Comment("");
  }

void OnTick()  { Process(); }
void OnTimer() { Process(); }

//+------------------------------------------------------------------+
//| Custom optimisation criterion: recovery factor x profit factor   |
//+------------------------------------------------------------------+
double OnTester()
  {
   double trades = TesterStatistics(STAT_TRADES);
   double profit = TesterStatistics(STAT_PROFIT);
   double dd     = TesterStatistics(STAT_EQUITY_DD);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   if(trades < 30 || profit <= 0)
      return(0.0);
   double recovery = (dd > 0) ? profit / dd : profit;
   return(recovery * MathMin(pf, 3.0));
  }
//+------------------------------------------------------------------+
