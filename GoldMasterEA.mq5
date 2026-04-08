//+------------------------------------------------------------------+
//|                                                  GoldMasterEA.mq5 |
//|                        Gold (XAUUSD) Expert Advisor v1.00         |
//|                                                                    |
//|  Strategy: Multi-layer confluence entry with advanced risk mgmt   |
//|  Designed for XAUUSD - High Win Rate, Strict Loss Control         |
//|  Features: Real-time on-chart dashboard, ATR-based risk sizing    |
//+------------------------------------------------------------------+
#property copyright   "GoldMasterEA v1.00"
#property link        "https://github.com/Wycky1994/research-work"
#property version     "1.00"
#property strict
#property description "Production-grade Gold (XAUUSD) Expert Advisor"
#property description "Multi-layer confluence entry: HTF trend + EMA pullback + RSI + MACD + ATR"
#property description "Advanced risk management with partial close, trailing stop, break-even"

//--- Include trade library
#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/HistoryOrderInfo.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                   |
//+------------------------------------------------------------------+

//--- Strategy Settings
input group "=== Strategy Settings ==="
input ENUM_TIMEFRAMES EntryTimeframe   = PERIOD_M15;   // Entry timeframe (M15 or H1)
input ENUM_TIMEFRAMES TrendTimeframe   = PERIOD_H4;    // HTF trend timeframe (H4 or D1)
input int             EMA_Fast         = 50;           // Fast EMA period (trend filter)
input int             EMA_Slow         = 200;          // Slow EMA period (trend filter)
input int             EMA_Entry        = 21;           // Entry EMA period (pullback target)
input int             RSI_Period       = 14;           // RSI period
input int             MACD_Fast        = 12;           // MACD fast EMA
input int             MACD_Slow        = 26;           // MACD slow EMA
input int             MACD_Signal      = 9;            // MACD signal line
input int             ATR_Period       = 14;           // ATR period
input double          ATR_MinThreshold = 0.5;          // Min ATR in $ (avoid low-vol chop)
input double          EMABounceTolerance = 0.001;      // EMA bounce tolerance (0.1% default)

//--- Risk Management
input group "=== Risk Management ==="
input double          RiskPercent           = 1.0;     // Risk per trade (% of balance)
input double          ATRMultiplierSL       = 1.5;     // ATR multiplier for stop loss
input double          RewardRiskRatio       = 2.0;     // Reward:Risk ratio for take profit
input double          TrailingATRMultiplier = 1.0;     // ATR multiplier for trailing stop
input double          BreakEvenPips         = 50;      // Break-even offset in points
input double          PartialClosePercent   = 50.0;    // % to close at 1:1 RR
input int             MaxOpenTrades         = 2;       // Max simultaneous open trades
input double          MaxDailyLossPercent   = 3.0;     // Max daily loss % before stopping
input int             MaxSpreadPoints       = 50;      // Max spread in points to allow entry
input int             MagicNumber           = 123456;  // EA magic number

//--- Session Filter
input group "=== Session Filter ==="
input int             SessionStartHour = 7;            // Session start (UTC hour)
input int             SessionEndHour   = 17;           // Session end (UTC hour)

//--- Dashboard
input group "=== Dashboard Settings ==="
input bool            ShowDashboard        = true;     // Show on-chart dashboard
input int             DashboardX           = 20;       // Dashboard X position
input int             DashboardY           = 30;       // Dashboard Y position
input color           DashboardBGColor     = clrBlack; // Dashboard background color
input int             DashboardTransparency = 180;     // Background transparency (0-255)

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                   |
//+------------------------------------------------------------------+

//--- Indicator handles
int hEMA_Fast_HTF   = INVALID_HANDLE;   // 50 EMA on trend timeframe
int hEMA_Slow_HTF   = INVALID_HANDLE;   // 200 EMA on trend timeframe
int hEMA_Entry      = INVALID_HANDLE;   // 21 EMA on entry timeframe
int hRSI            = INVALID_HANDLE;   // RSI on entry timeframe
int hMACD           = INVALID_HANDLE;   // MACD on entry timeframe
int hATR            = INVALID_HANDLE;   // ATR on entry timeframe

//--- Trade objects
CTrade            Trade;
CPositionInfo     PositionInfo;

//--- Signal direction constants
#define SIGNAL_NONE  0
#define SIGNAL_BUY   1
#define SIGNAL_SELL  2

//--- Trade tracking
struct TradeRecord
{
   ulong  ticket;
   double entryPrice;
   double sl;
   double tp;
   double lots;
   int    direction;        // SIGNAL_BUY or SIGNAL_SELL
   bool   partialClosed;    // Has partial close been executed?
   bool   breakEvenSet;     // Has break-even been set?
   bool   trailingActive;   // Is trailing stop active?
   double trailingLevel;    // Current trailing stop level
   datetime openTime;
};

TradeRecord g_OpenTrades[10];   // Track up to 10 open trades
int         g_OpenTradesCount = 0;

//--- Daily statistics tracking
double   g_DayStartBalance  = 0.0;
double   g_DailyPnL         = 0.0;
datetime g_LastDayReset      = 0;

//--- All-time and today statistics
int      g_TotalTradesToday  = 0;
int      g_WinsTodayCount    = 0;
int      g_LossesTodayCount  = 0;
double   g_SumWinsToday      = 0.0;
double   g_SumLossesToday    = 0.0;
int      g_TotalTradesAll    = 0;
int      g_WinsAllCount      = 0;
int      g_LossesAllCount    = 0;
double   g_SumWinsAll        = 0.0;
double   g_SumLossesAll      = 0.0;

//--- Dashboard object names prefix (for easy deletion)
string   g_DashPrefix = "GMea_";

//--- Timer counter for dashboard refresh pacing
datetime g_LastTimerUpdate = 0;

//--- Track previous RSI for crossover detection
double   g_PrevRSI = 0.0;
//--- Track previous MACD histogram for crossover detection
double   g_PrevMACD = 0.0;
//--- Track previous close for EMA proximity check
double   g_PrevClose = 0.0;

//--- ATR volatility classification thresholds (multiples of ATR_MinThreshold)
#define ATR_LOW_VOL_RATIO  1.5    // Below this multiple = LOW VOL
#define ATR_HIGH_VOL_RATIO 4.0    // Above this multiple = HIGH VOL

//+------------------------------------------------------------------+
//| DETECT BROKER-SUPPORTED ORDER FILLING MODE                        |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetBrokerFillingMode()
{
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   if((filling & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;

   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| INITIALIZATION                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Set trade magic number
   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(10);

   //--- Detect broker-supported order filling policy and apply it
   ENUM_ORDER_TYPE_FILLING fillingMode = GetBrokerFillingMode();
   Trade.SetTypeFilling(fillingMode);

   //--- Create indicator handles
   hEMA_Fast_HTF = iMA(_Symbol, TrendTimeframe, EMA_Fast,  0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_HTF = iMA(_Symbol, TrendTimeframe, EMA_Slow,  0, MODE_EMA, PRICE_CLOSE);
   hEMA_Entry    = iMA(_Symbol, EntryTimeframe, EMA_Entry, 0, MODE_EMA, PRICE_CLOSE);
   hRSI          = iRSI(_Symbol, EntryTimeframe, RSI_Period, PRICE_CLOSE);
   hMACD         = iMACD(_Symbol, EntryTimeframe, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   hATR          = iATR(_Symbol, EntryTimeframe, ATR_Period);

   //--- Validate handles
   if(hEMA_Fast_HTF == INVALID_HANDLE || hEMA_Slow_HTF == INVALID_HANDLE ||
      hEMA_Entry    == INVALID_HANDLE || hRSI == INVALID_HANDLE ||
      hMACD         == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Alert("GoldMasterEA: Failed to create indicator handles! Check symbol/timeframe.");
      return INIT_FAILED;
   }

   //--- Record day-start balance
   g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_LastDayReset    = TimeCurrent();

   //--- Create dashboard objects
   if(ShowDashboard)
      CreateDashboardObjects();

   //--- Start 1-second timer for dashboard refresh
   EventSetTimer(1);

   //--- Load historical statistics
   CalculateStatistics();

   Print("GoldMasterEA v1.00 initialized successfully on ", _Symbol,
         " | Entry TF: ", EnumToString(EntryTimeframe),
         " | Trend TF: ", EnumToString(TrendTimeframe));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DE-INITIALIZATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Stop timer
   EventKillTimer();

   //--- Delete dashboard objects
   if(ShowDashboard)
      DeleteDashboardObjects();

   //--- Release indicator handles
   if(hEMA_Fast_HTF != INVALID_HANDLE) IndicatorRelease(hEMA_Fast_HTF);
   if(hEMA_Slow_HTF != INVALID_HANDLE) IndicatorRelease(hEMA_Slow_HTF);
   if(hEMA_Entry    != INVALID_HANDLE) IndicatorRelease(hEMA_Entry);
   if(hRSI          != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMACD         != INVALID_HANDLE) IndicatorRelease(hMACD);
   if(hATR          != INVALID_HANDLE) IndicatorRelease(hATR);

   Print("GoldMasterEA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| MAIN TICK HANDLER                                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Reset daily stats at start of new trading day
   ResetDailyStatsIfNewDay();

   //--- Update open trades list from broker
   SyncOpenTrades();

   //--- Manage existing open trades (trailing stop, break-even, partial close)
   ManageOpenTrades();

   //--- Only evaluate entries on new bar (M1 check for efficiency)
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, EntryTimeframe, 0);
   if(currentBarTime == lastBarTime)
   {
      //--- Still update dashboard every tick
      if(ShowDashboard)
         UpdateDashboard();
      return;
   }
   lastBarTime = currentBarTime;

   //--- Check daily loss circuit breaker
   if(CheckDailyLoss())
   {
      if(ShowDashboard) UpdateDashboard();
      return;
   }

   //--- Check spread filter
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints)
   {
      if(ShowDashboard) UpdateDashboard();
      return;
   }

   //--- Check session filter
   if(!IsWithinSession())
   {
      if(ShowDashboard) UpdateDashboard();
      return;
   }

   //--- Check max open trades
   if(CountOpenTrades() >= MaxOpenTrades)
   {
      if(ShowDashboard) UpdateDashboard();
      return;
   }

   //--- Evaluate entry signal
   int signal = CheckEntrySignal();

   //--- Execute trade if signal confirmed
   if(signal == SIGNAL_BUY || signal == SIGNAL_SELL)
   {
      OpenTrade(signal);
   }

   //--- Update dashboard
   if(ShowDashboard) UpdateDashboard();
}

//+------------------------------------------------------------------+
//| TIMER HANDLER — Dashboard refresh every second                    |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(ShowDashboard)
      UpdateDashboard();
}

//+------------------------------------------------------------------+
//| CHECK ENTRY SIGNAL                                                 |
//| Returns SIGNAL_BUY, SIGNAL_SELL, or SIGNAL_NONE                  |
//+------------------------------------------------------------------+
int CheckEntrySignal()
{
   //--- Fetch indicator values
   double emaFastHTF[], emaSlowHTF[], emaEntry[];
   double rsi[], macdMain[], macdSignal[], macdHist[];
   double atr[];

   ArraySetAsSeries(emaFastHTF, true);
   ArraySetAsSeries(emaSlowHTF, true);
   ArraySetAsSeries(emaEntry,   true);
   ArraySetAsSeries(rsi,        true);
   ArraySetAsSeries(macdMain,   true);
   ArraySetAsSeries(macdSignal, true);
   ArraySetAsSeries(macdHist,   true);
   ArraySetAsSeries(atr,        true);

   //--- Need at least 3 bars of data for crossover detection
   if(CopyBuffer(hEMA_Fast_HTF, 0, 0, 3, emaFastHTF) < 3) return SIGNAL_NONE;
   if(CopyBuffer(hEMA_Slow_HTF, 0, 0, 3, emaSlowHTF) < 3) return SIGNAL_NONE;
   if(CopyBuffer(hEMA_Entry,    0, 0, 3, emaEntry)   < 3) return SIGNAL_NONE;
   if(CopyBuffer(hRSI,          0, 0, 3, rsi)        < 3) return SIGNAL_NONE;
   if(CopyBuffer(hMACD,         0, 0, 3, macdMain)   < 3) return SIGNAL_NONE;
   if(CopyBuffer(hMACD,         1, 0, 3, macdSignal) < 3) return SIGNAL_NONE;
   if(CopyBuffer(hMACD,         2, 0, 3, macdHist)   < 3) return SIGNAL_NONE;  // Histogram buffer
   if(CopyBuffer(hATR,          0, 0, 3, atr)        < 3) return SIGNAL_NONE;

   //--- Store for dashboard use
   g_PrevRSI  = rsi[1];
   g_PrevMACD = macdHist[1];
   g_PrevClose = iClose(_Symbol, EntryTimeframe, 1);

   //--- Current values (index 0 = current forming candle, index 1 = last closed candle)
   double fastHTF  = emaFastHTF[0];
   double slowHTF  = emaSlowHTF[0];
   double entryEMA = emaEntry[1];       // Use closed candle for signal
   double rsiNow   = rsi[1];
   double rsiPrev  = rsi[2];
   double histNow  = macdHist[1];
   double histPrev = macdHist[2];
   double atrNow   = atr[1];

   //--- Current close price of last closed candle
   double closeNow  = iClose(_Symbol, EntryTimeframe, 1);
   double closePrev = iClose(_Symbol, EntryTimeframe, 2);

   //--- [FILTER 1] ATR minimum threshold — avoid low-volatility chop
   if(atrNow < ATR_MinThreshold)
      return SIGNAL_NONE;

   //--- [FILTER 2] HTF Trend Filter — 50 EMA vs 200 EMA on H4/D1
   bool bullishHTF = (fastHTF > slowHTF);   // 50 EMA above 200 EMA = bullish trend
   bool bearishHTF = (fastHTF < slowHTF);   // 50 EMA below 200 EMA = bearish trend

   //--- ===== BUY SIGNAL =====
   if(bullishHTF)
   {
      //--- [FILTER 3B] Price pulls back to 21 EMA and bounces
      //    Last closed candle: close was near or below 21 EMA, now bouncing above
      bool emaBounce = (closePrev <= entryEMA * (1.0 + EMABounceTolerance)) && (closeNow > entryEMA);

      //--- [FILTER 4B] RSI(14) crosses above 40 from below (early momentum catch)
      bool rsiCross = (rsiPrev < 40.0) && (rsiNow >= 40.0);

      //--- [FILTER 5B] MACD histogram turns positive (momentum confirmation)
      bool macdBull = (histPrev <= 0.0) && (histNow > 0.0);

      if(emaBounce && rsiCross && macdBull)
         return SIGNAL_BUY;
   }

   //--- ===== SELL SIGNAL =====
   if(bearishHTF)
   {
      //--- [FILTER 3S] Price pulls back to 21 EMA from above and bounces down
      bool emaBounce = (closePrev >= entryEMA * (1.0 - EMABounceTolerance)) && (closeNow < entryEMA);

      //--- [FILTER 4S] RSI(14) crosses below 60 from above
      bool rsiCross = (rsiPrev > 60.0) && (rsiNow <= 60.0);

      //--- [FILTER 5S] MACD histogram turns negative
      bool macdBear = (histPrev >= 0.0) && (histNow < 0.0);

      if(emaBounce && rsiCross && macdBear)
         return SIGNAL_SELL;
   }

   return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| NORMALIZE LOT SIZE to broker constraints                          |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   return lots;
}

//+------------------------------------------------------------------+
//| CALCULATE LOT SIZE based on risk %                                |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   if(slDistance <= 0.0) return 0.0;

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPercent / 100.0);
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pointValue = tickValue / tickSize * _Point;

   if(pointValue <= 0.0) return 0.0;

   double lots = riskAmount / (slDistance / _Point * pointValue);

   return NormalizeLots(lots);
}

//+------------------------------------------------------------------+
//| OPEN TRADE                                                         |
//+------------------------------------------------------------------+
void OpenTrade(int signal)
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR, 0, 0, 3, atr) < 3) return;
   double atrNow = atr[1];

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double entryPrice = 0.0, sl = 0.0, tp = 0.0;
   double slDistance = atrNow * ATRMultiplierSL;
   double tpDistance = slDistance * RewardRiskRatio;

   if(signal == SIGNAL_BUY)
   {
      entryPrice = ask;
      sl         = NormalizeDouble(entryPrice - slDistance, _Digits);
      tp         = NormalizeDouble(entryPrice + tpDistance, _Digits);
   }
   else if(signal == SIGNAL_SELL)
   {
      entryPrice = bid;
      sl         = NormalizeDouble(entryPrice + slDistance, _Digits);
      tp         = NormalizeDouble(entryPrice - tpDistance, _Digits);
   }
   else return;

   //--- Calculate lot size
   double lots = CalculateLotSize(slDistance);
   if(lots <= 0.0)
   {
      Print("GoldMasterEA: Lot size calculation failed. slDistance=", slDistance);
      return;
   }

   //--- Place order
   bool result = false;
   if(signal == SIGNAL_BUY)
      result = Trade.Buy(lots, _Symbol, entryPrice, sl, tp, "GoldMasterEA Buy");
   else
      result = Trade.Sell(lots, _Symbol, entryPrice, sl, tp, "GoldMasterEA Sell");

   if(result)
   {
      Print("GoldMasterEA: Order placed. Signal=", (signal == SIGNAL_BUY ? "BUY" : "SELL"),
            " | Lots=", lots, " | Entry=", entryPrice,
            " | SL=", sl, " | TP=", tp, " | ATR=", atrNow);
      //--- Re-sync trades after opening
      SyncOpenTrades();
   }
   else
   {
      Print("GoldMasterEA: Order failed. Error=", GetLastError(),
            " | RetCode=", Trade.ResultRetcode(),
            " | RetComment=", Trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| MANAGE OPEN TRADES                                                 |
//| Handles: trailing stop, break-even, partial close                 |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR, 0, 0, 3, atr) < 3) return;
   double atrNow = atr[1];

   for(int i = 0; i < g_OpenTradesCount; i++)
   {
      ulong ticket = g_OpenTrades[i].ticket;

      //--- Select position by ticket
      if(!PositionSelectByTicket(ticket)) continue;

      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL  = PositionGetDouble(POSITION_SL);
      double currentTP  = PositionGetDouble(POSITION_TP);
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double lots       = PositionGetDouble(POSITION_VOLUME);
      int    direction  = g_OpenTrades[i].direction;

      double slDistance = MathAbs(entryPrice - g_OpenTrades[i].sl);
      if(slDistance <= 0.0) continue;

      double price  = (direction == SIGNAL_BUY) ? currentBid : currentAsk;
      double profit = (direction == SIGNAL_BUY) ? (price - entryPrice) : (entryPrice - price);

      //--- === PARTIAL CLOSE at 1:1 RR ===
      if(!g_OpenTrades[i].partialClosed && profit >= slDistance)
      {
         double closeLots = NormalizeLots(lots * (PartialClosePercent / 100.0));
         double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

         if(closeLots >= minLot && closeLots < lots)
         {
            if(Trade.PositionClosePartial(ticket, closeLots))
            {
               g_OpenTrades[i].partialClosed = true;
               Print("GoldMasterEA: Partial close executed. Ticket=", ticket,
                     " | Closed=", closeLots, " lots at 1:1 RR");
            }
         }
      }

      //--- === BREAK-EVEN after 1:1 RR ===
      if(!g_OpenTrades[i].breakEvenSet && profit >= slDistance)
      {
         double newSL;
         double bePips = BreakEvenPips * _Point;

         if(direction == SIGNAL_BUY)
            newSL = NormalizeDouble(entryPrice + bePips, _Digits);
         else
            newSL = NormalizeDouble(entryPrice - bePips, _Digits);

         //--- Only modify if new SL is better than current SL
         bool shouldModify = false;
         if(direction == SIGNAL_BUY  && newSL > currentSL) shouldModify = true;
         if(direction == SIGNAL_SELL && newSL < currentSL) shouldModify = true;

         if(shouldModify)
         {
            if(Trade.PositionModify(ticket, newSL, currentTP))
            {
               g_OpenTrades[i].breakEvenSet = true;
               g_OpenTrades[i].sl           = newSL;
               Print("GoldMasterEA: Break-even set. Ticket=", ticket, " | SL moved to=", newSL);
            }
         }
      }

      //--- === TRAILING STOP after 1:1 RR ===
      if(profit >= slDistance)
      {
         double trailDistance = atrNow * TrailingATRMultiplier;
         double newTrailSL;

         if(direction == SIGNAL_BUY)
         {
            newTrailSL = NormalizeDouble(price - trailDistance, _Digits);
            if(newTrailSL > currentSL)
            {
               if(Trade.PositionModify(ticket, newTrailSL, currentTP))
               {
                  g_OpenTrades[i].trailingActive = true;
                  g_OpenTrades[i].trailingLevel  = newTrailSL;
                  g_OpenTrades[i].sl             = newTrailSL;
               }
            }
         }
         else // SELL
         {
            newTrailSL = NormalizeDouble(price + trailDistance, _Digits);
            if(newTrailSL < currentSL)
            {
               if(Trade.PositionModify(ticket, newTrailSL, currentTP))
               {
                  g_OpenTrades[i].trailingActive = true;
                  g_OpenTrades[i].trailingLevel  = newTrailSL;
                  g_OpenTrades[i].sl             = newTrailSL;
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CHECK DAILY LOSS CIRCUIT BREAKER                                   |
//| Returns true if trading should stop                               |
//+------------------------------------------------------------------+
bool CheckDailyLoss()
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdown   = g_DayStartBalance - equity;
   double drawdownPct = (g_DayStartBalance > 0) ? (drawdown / g_DayStartBalance * 100.0) : 0.0;

   g_DailyPnL = equity - g_DayStartBalance;

   if(drawdownPct >= MaxDailyLossPercent)
   {
      static bool alerted = false;
      if(!alerted)
      {
         Print("GoldMasterEA: Max daily loss reached (", DoubleToString(drawdownPct, 2),
               "%). Trading stopped for today.");
         alerted = true;
      }
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| SESSION FILTER                                                     |
//| Returns true if current time is within the allowed trading session|
//+------------------------------------------------------------------+
bool IsWithinSession()
{
   datetime now    = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   int hour = dt.hour;

   //--- Check if within session window
   if(SessionStartHour < SessionEndHour)
      return (hour >= SessionStartHour && hour < SessionEndHour);
   else
      return (hour >= SessionStartHour || hour < SessionEndHour);  // Handles overnight sessions
}

//+------------------------------------------------------------------+
//| GET TREND DIRECTION (HTF)                                          |
//| Returns SIGNAL_BUY (bullish), SIGNAL_SELL (bearish), SIGNAL_NONE  |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
   double emaFast[], emaSlow[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);

   if(CopyBuffer(hEMA_Fast_HTF, 0, 0, 2, emaFast) < 2) return SIGNAL_NONE;
   if(CopyBuffer(hEMA_Slow_HTF, 0, 0, 2, emaSlow) < 2) return SIGNAL_NONE;

   if(emaFast[0] > emaSlow[0]) return SIGNAL_BUY;
   if(emaFast[0] < emaSlow[0]) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| COUNT OPEN TRADES tagged with our magic number                    |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| SYNC OPEN TRADES from broker positions                            |
//+------------------------------------------------------------------+
void SyncOpenTrades()
{
   //--- Build fresh list of open positions for our EA
   g_OpenTradesCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;

      //--- Try to find existing record to preserve state (partial close, break-even, etc.)
      bool found = false;
      for(int j = 0; j < g_OpenTradesCount; j++)
      {
         if(g_OpenTrades[j].ticket == ticket) { found = true; break; }
      }

      if(!found && g_OpenTradesCount < 10)
      {
         int idx = g_OpenTradesCount;
         g_OpenTrades[idx].ticket         = ticket;
         g_OpenTrades[idx].entryPrice     = PositionGetDouble(POSITION_PRICE_OPEN);
         g_OpenTrades[idx].sl             = PositionGetDouble(POSITION_SL);
         g_OpenTrades[idx].tp             = PositionGetDouble(POSITION_TP);
         g_OpenTrades[idx].lots           = PositionGetDouble(POSITION_VOLUME);
         g_OpenTrades[idx].direction      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                                             SIGNAL_BUY : SIGNAL_SELL;
         g_OpenTrades[idx].partialClosed  = false;
         g_OpenTrades[idx].breakEvenSet   = false;
         g_OpenTrades[idx].trailingActive = false;
         g_OpenTrades[idx].trailingLevel  = 0.0;
         g_OpenTrades[idx].openTime       = (datetime)PositionGetInteger(POSITION_TIME);
         g_OpenTradesCount++;
      }
   }

   //--- Remove closed trades from our tracking array
   int newCount = 0;
   TradeRecord temp[10];
   for(int i = 0; i < g_OpenTradesCount; i++)
   {
      if(PositionSelectByTicket(g_OpenTrades[i].ticket))
      {
         temp[newCount] = g_OpenTrades[i];
         newCount++;
      }
   }
   g_OpenTradesCount = newCount;
   for(int i = 0; i < newCount; i++)
      g_OpenTrades[i] = temp[i];
}

//+------------------------------------------------------------------+
//| RESET DAILY STATS if new trading day has started                  |
//+------------------------------------------------------------------+
void ResetDailyStatsIfNewDay()
{
   datetime now = TimeCurrent();
   MqlDateTime dtNow, dtLast;
   TimeToStruct(now,            dtNow);
   TimeToStruct(g_LastDayReset, dtLast);

   if(dtNow.day != dtLast.day || dtNow.mon != dtLast.mon || dtNow.year != dtLast.year)
   {
      g_DayStartBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
      g_TotalTradesToday  = 0;
      g_WinsTodayCount    = 0;
      g_LossesTodayCount  = 0;
      g_SumWinsToday      = 0.0;
      g_SumLossesToday    = 0.0;
      g_LastDayReset      = now;
      Print("GoldMasterEA: New day detected. Daily stats reset. Balance=", g_DayStartBalance);
   }
}

//+------------------------------------------------------------------+
//| CALCULATE STATISTICS from history                                 |
//+------------------------------------------------------------------+
void CalculateStatistics()
{
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);  // Start of today

   g_TotalTradesAll  = 0;
   g_WinsAllCount    = 0;
   g_LossesAllCount  = 0;
   g_SumWinsAll      = 0.0;
   g_SumLossesAll    = 0.0;
   g_TotalTradesToday = 0;
   g_WinsTodayCount  = 0;
   g_LossesTodayCount = 0;
   g_SumWinsToday    = 0.0;
   g_SumLossesToday  = 0.0;

   if(!HistorySelect(0, TimeCurrent())) return;

   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      //--- Only our EA's deals
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC)  != MagicNumber) continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL)  != _Symbol)     continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY)  != DEAL_ENTRY_OUT) continue;

      double profit    = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);

      g_TotalTradesAll++;
      if(profit > 0) { g_WinsAllCount++;   g_SumWinsAll   += profit; }
      else           { g_LossesAllCount++; g_SumLossesAll += MathAbs(profit); }

      if(dealTime >= dayStart)
      {
         g_TotalTradesToday++;
         if(profit > 0) { g_WinsTodayCount++;   g_SumWinsToday   += profit; }
         else           { g_LossesTodayCount++; g_SumLossesToday += MathAbs(profit); }
      }
   }
}

//+------------------------------------------------------------------+
//| CREATE DASHBOARD OBJECTS                                           |
//+------------------------------------------------------------------+
void CreateDashboardObjects()
{
   //--- Background rectangle
   string bg = g_DashPrefix + "BG";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE,   DashboardX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE,   DashboardY);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE,        360);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE,        530);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR,      DashboardBGColor);
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE,  BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR,        clrDimGray);
   ObjectSetInteger(0, bg, OBJPROP_WIDTH,        1);
   ObjectSetInteger(0, bg, OBJPROP_BACK,         true);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE,   false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN,       true);

   //--- Create all text label objects (content set in UpdateDashboard)
   string labels[] =
   {
      "Title",      // EA name & version
      "Status",     // Active/Paused
      "Balance",    // Account balance
      "Equity",     // Account equity
      "Margin",     // Free margin
      "DailyPnL",   // Today's P&L
      "Trades",     // Open trades / Max
      "Sep1",       // Section separator
      "MktTitle",   // Market Conditions header
      "Spread",     // Current spread
      "ATR",        // ATR value & label
      "Trend",      // HTF trend
      "RSI",        // RSI value
      "MACD",       // MACD status
      "Session",    // Session status
      "Sep2",       // Section separator
      "TrdTitle",   // Trade Info header
      "TrdEntry",   // Entry price
      "TrdCurrent", // Current price
      "TrdSLTP",    // SL/TP
      "TrdPnL",     // Trade P&L
      "TrdTrail",   // Trailing stop
      "TrdPartial", // Partial close
      "Sep3",       // Section separator
      "StatTitle",  // Statistics header
      "StatToday",  // Today's trades
      "StatWinRate",// Win rate
      "StatAvgWin", // Average win
      "StatAvgLoss",// Average loss
      "StatPF"      // Profit factor
   };

   int rows = ArraySize(labels);
   for(int i = 0; i < rows; i++)
   {
      string name = g_DashPrefix + labels[i];
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, DashboardX + 10);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, DashboardY + 10 + i * 17);
      ObjectSetInteger(0, name, OBJPROP_COLOR,     clrWhite);
      ObjectSetString(0,  name, OBJPROP_FONT,      "Courier New");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  8);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,    true);
      ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   }

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| DELETE ALL DASHBOARD OBJECTS                                       |
//+------------------------------------------------------------------+
void DeleteDashboardObjects()
{
   //--- Delete all objects with our prefix
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, g_DashPrefix) == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| SET DASHBOARD LABEL                                                |
//| Helper to set text and color of a dashboard label object          |
//+------------------------------------------------------------------+
void SetDashLabel(string key, string text, color clr = clrWhite)
{
   string name = g_DashPrefix + key;
   ObjectSetString(0,  name, OBJPROP_TEXT,  text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| UPDATE DASHBOARD                                                   |
//| Refreshes all dashboard labels with current market data           |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   if(!ShowDashboard) return;

   //--- === SECTION A: EA STATUS ===
   SetDashLabel("Title", "  *** GOLD MASTER EA  v1.00 ***", clrGold);

   //--- Determine status
   string statusText = "  Status : ACTIVE";
   color  statusClr  = clrLimeGreen;

   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(CheckDailyLoss())
   {
      statusText = "  Status : PAUSED (Max Loss)";
      statusClr  = clrRed;
   }
   else if(!IsWithinSession())
   {
      statusText = "  Status : PAUSED (Outside Session)";
      statusClr  = clrOrange;
   }
   else if(spread > MaxSpreadPoints)
   {
      statusText = "  Status : PAUSED (High Spread)";
      statusClr  = clrYellow;
   }
   SetDashLabel("Status", statusText, statusClr);

   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   SetDashLabel("Balance", StringFormat("  Balance: $%.2f", balance), clrWhite);
   SetDashLabel("Equity",  StringFormat("  Equity : $%.2f", equity),
                equity >= balance ? clrLimeGreen : clrRed);
   SetDashLabel("Margin",  StringFormat("  Margin : $%.2f", freeMargin), clrWhite);

   double pnlPct = (g_DayStartBalance > 0) ? (g_DailyPnL / g_DayStartBalance * 100.0) : 0.0;
   color pnlClr  = (g_DailyPnL >= 0) ? clrLimeGreen : clrRed;
   SetDashLabel("DailyPnL", StringFormat("  DayP&L : $%.2f  (%.2f%%)", g_DailyPnL, pnlPct), pnlClr);

   int openCount = CountOpenTrades();
   SetDashLabel("Trades", StringFormat("  Trades : %d / %d open", openCount, MaxOpenTrades), clrWhite);

   //--- Separator
   SetDashLabel("Sep1", "  --------------------------------", clrDimGray);

   //--- === SECTION B: MARKET CONDITIONS ===
   SetDashLabel("MktTitle", "  --- Market Conditions ---", clrSilver);

   //--- Spread
   color spreadClr = clrLimeGreen;
   if(spread > MaxSpreadPoints * 0.7) spreadClr = clrYellow;
   if(spread > MaxSpreadPoints)       spreadClr = clrRed;
   SetDashLabel("Spread", StringFormat("  Spread : %d pts", (int)spread), spreadClr);

   //--- ATR
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   double atrVal = 0.0;
   string atrLabel = "N/A";
   color  atrClr   = clrWhite;
   if(CopyBuffer(hATR, 0, 0, 2, atrBuf) >= 2)
   {
      atrVal = atrBuf[1];
      if(atrVal < ATR_MinThreshold * ATR_LOW_VOL_RATIO)       { atrLabel = "LOW VOL";    atrClr = clrYellow; }
      else if(atrVal > ATR_MinThreshold * ATR_HIGH_VOL_RATIO) { atrLabel = "HIGH VOL";   atrClr = clrOrangeRed; }
      else                                                      { atrLabel = "NORMAL";     atrClr = clrLimeGreen; }
   }
   SetDashLabel("ATR", StringFormat("  ATR(14): %.4f  [%s]", atrVal, atrLabel), atrClr);

   //--- HTF Trend
   int trend = GetTrendDirection();
   string trendText = "  Trend  : NEUTRAL  [=]";
   color  trendClr  = clrGray;
   if(trend == SIGNAL_BUY)  { trendText = "  Trend  : BULLISH  [^]"; trendClr = clrLimeGreen; }
   if(trend == SIGNAL_SELL) { trendText = "  Trend  : BEARISH  [v]"; trendClr = clrRed;       }
   SetDashLabel("Trend", trendText, trendClr);

   //--- RSI
   double rsiBuf[];
   ArraySetAsSeries(rsiBuf, true);
   double rsiVal = 50.0;
   if(CopyBuffer(hRSI, 0, 0, 2, rsiBuf) >= 2)
      rsiVal = rsiBuf[1];
   color rsiClr = clrWhite;
   if(rsiVal < 35)       rsiClr = clrLimeGreen;   // Oversold
   else if(rsiVal > 65)  rsiClr = clrRed;          // Overbought
   SetDashLabel("RSI", StringFormat("  RSI(14): %.1f", rsiVal), rsiClr);

   //--- MACD
   double macdHistBuf[];
   ArraySetAsSeries(macdHistBuf, true);
   double macdHistVal = 0.0;
   string macdText = "N/A";
   color  macdClr  = clrWhite;
   if(CopyBuffer(hMACD, 2, 0, 2, macdHistBuf) >= 2)
   {
      macdHistVal = macdHistBuf[1];
      if(macdHistVal > 0) { macdText = "BULLISH"; macdClr = clrLimeGreen; }
      else                 { macdText = "BEARISH"; macdClr = clrRed; }
   }
   SetDashLabel("MACD", StringFormat("  MACD   : %s (%.5f)", macdText, macdHistVal), macdClr);

   //--- Session
   bool inSession = IsWithinSession();
   string sessText = inSession ? "  Session: ACTIVE (London/NY)" : "  Session: INACTIVE";
   color  sessClr  = inSession ? clrLimeGreen : clrGray;
   SetDashLabel("Session", sessText, sessClr);

   //--- Separator
   SetDashLabel("Sep2", "  --------------------------------", clrDimGray);

   //--- === SECTION C: TRADE INFORMATION ===
   SetDashLabel("TrdTitle", "  --- Trade Information ---", clrSilver);

   if(openCount > 0 && g_OpenTradesCount > 0)
   {
      //--- Show info for first open trade
      if(PositionSelectByTicket(g_OpenTrades[0].ticket))
      {
         double ep      = PositionGetDouble(POSITION_PRICE_OPEN);
         double cp      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double posSL   = PositionGetDouble(POSITION_SL);
         double posTP   = PositionGetDouble(POSITION_TP);
         double posProfit = PositionGetDouble(POSITION_PROFIT);

         SetDashLabel("TrdEntry",   StringFormat("  Entry  : %.5f", ep), clrWhite);
         SetDashLabel("TrdCurrent", StringFormat("  Price  : %.5f", cp), clrWhite);
         SetDashLabel("TrdSLTP",    StringFormat("  SL/TP  : %.5f / %.5f", posSL, posTP), clrYellow);

         color profitClr = (posProfit >= 0) ? clrLimeGreen : clrRed;
         SetDashLabel("TrdPnL", StringFormat("  P&L    : $%.2f", posProfit), profitClr);

         string trailText = g_OpenTrades[0].trailingActive ?
                            StringFormat("Active at %.5f", g_OpenTrades[0].trailingLevel) :
                            "Not yet triggered";
         SetDashLabel("TrdTrail",   StringFormat("  Trail  : %s", trailText), clrWhite);

         string partialText = g_OpenTrades[0].partialClosed ? "Executed" :
                              StringFormat("Pending at %.5f", ep + (ep - posSL));
         SetDashLabel("TrdPartial", StringFormat("  Partial: %s", partialText), clrWhite);
      }
   }
   else
   {
      SetDashLabel("TrdEntry",   "  Entry  : No open trades", clrGray);
      SetDashLabel("TrdCurrent", "  Price  : --",             clrGray);
      SetDashLabel("TrdSLTP",    "  SL/TP  : -- / --",        clrGray);
      SetDashLabel("TrdPnL",     "  P&L    : --",             clrGray);
      SetDashLabel("TrdTrail",   "  Trail  : --",             clrGray);
      SetDashLabel("TrdPartial", "  Partial: --",             clrGray);
   }

   //--- Separator
   SetDashLabel("Sep3", "  --------------------------------", clrDimGray);

   //--- === SECTION D: STATISTICS ===
   SetDashLabel("StatTitle", "  --- Statistics ---", clrSilver);

   //--- Refresh stats periodically (not every tick to avoid history scan overhead)
   static datetime lastStatCalc = 0;
   if(TimeCurrent() - lastStatCalc > 60)
   {
      CalculateStatistics();
      lastStatCalc = TimeCurrent();
   }

   SetDashLabel("StatToday",
                StringFormat("  Today  : %d trades (%dW / %dL)",
                             g_TotalTradesToday, g_WinsTodayCount, g_LossesTodayCount),
                clrWhite);

   //--- Win rate today
   double wrToday = (g_TotalTradesToday > 0) ?
                    ((double)g_WinsTodayCount / g_TotalTradesToday * 100.0) : 0.0;
   double wrAll   = (g_TotalTradesAll > 0) ?
                    ((double)g_WinsAllCount / g_TotalTradesAll * 100.0) : 0.0;
   color wrClr = (wrAll >= 55.0) ? clrLimeGreen : ((wrAll >= 45.0) ? clrYellow : clrRed);
   SetDashLabel("StatWinRate",
                StringFormat("  WinRate: %.1f%% today / %.1f%% all", wrToday, wrAll),
                wrClr);

   //--- Average win / loss
   double avgWin  = (g_WinsAllCount  > 0) ? (g_SumWinsAll  / g_WinsAllCount)  : 0.0;
   double avgLoss = (g_LossesAllCount > 0) ? (g_SumLossesAll / g_LossesAllCount) : 0.0;
   SetDashLabel("StatAvgWin",  StringFormat("  AvgWin : $%.2f", avgWin),  clrLimeGreen);
   SetDashLabel("StatAvgLoss", StringFormat("  AvgLoss: $%.2f", avgLoss), clrRed);

   //--- Profit factor
   double pf = (g_SumLossesAll > 0) ? (g_SumWinsAll / g_SumLossesAll) : 0.0;
   color pfClr = (pf >= 1.5) ? clrLimeGreen : ((pf >= 1.0) ? clrYellow : clrRed);
   SetDashLabel("StatPF", StringFormat("  PFactor: %.2f", pf), pfClr);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| END OF EXPERT ADVISOR                                              |
//+------------------------------------------------------------------+
