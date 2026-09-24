//+------------------------------------------------------------------+
//| SafeExnessEA.mq5                                                 |
//| Conservative rule-based MT5 EA for demo/strategy testing          |
//| Anti-grid, anti-martingale, risk guardrails, volatility filter    |
//+------------------------------------------------------------------+
#property strict
#property version "1.20"

#include <Trade/Trade.mqh>

input string            InpTradeSymbol         = "EURUSD";
input ENUM_TIMEFRAMES   InpEntryTF             = PERIOD_M15;
input ENUM_TIMEFRAMES   InpConfirmTF           = PERIOD_M15;
input ENUM_TIMEFRAMES   InpTrendTF             = PERIOD_H1;
input long              InpMagicNumber         = 20260924;
input double            InpRiskPercent         = 0.15;
input double            InpMaxDailyLossPercent = 0.75;
input double            InpMaxDrawdownPercent  = 8.00;
input int               InpMaxTradesPerDay    = 3;
input int               InpMaxConsecutiveLosses= 2;
input int               InpCooldownMinutes    = 90;
input int               InpMaxSpreadPoints    = 15;
input int               InpDeviationPoints    = 15;
input int               InpATRPeriod           = 14;
input double            InpSL_ATR_Multiplier   = 1.60;
input double            InpTP_ATR_Multiplier   = 2.00;
input double            InpMinATRPoints        = 25.0;
input double            InpMaxATRPoints        = 180.0;
input int               InpADXPeriod           = 14;
input double            InpMinADX              = 20.0;
input int               InpFastMAPeriod        = 20;
input int               InpSlowMAPeriod        = 50;
input int               InpRSIPeriod           = 14;
input double            InpBuyRSIConfirm       = 52.0;
input double            InpSellRSIConfirm      = 48.0;
input bool              InpUseSessionFilter    = true;
input int               InpSessionStartHour    = 7;
input int               InpSessionEndHour      = 20;
input bool              InpUseBreakEven        = true;
input double            InpBreakEvenAtR        = 1.20;
input int               InpBreakEvenOffsetPts  = 2;
input bool              InpCloseOnOpposite     = false;
input string            InpComment             = "SafeExnessEA";

CTrade trade;
string symbolName;
datetime lastEntryBar = 0;
datetime lastLossTime = 0;
double dayStartBalance = 0.0;
double peakEquity = 0.0;
int tradesToday = 0;
int consecutiveLosses = 0;
int currentDay = -1;

//+------------------------------------------------------------------+
int OnInit()
{
   symbolName = InpTradeSymbol;
   if(StringLen(symbolName) == 0) symbolName = _Symbol;
   if(!SymbolSelect(symbolName, true)) return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(symbolName);
   trade.SetAsyncMode(false);

   ResetDailyStateIfNeeded();
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("SafeExnessEA v1.20 initialized: ", symbolName);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("SafeExnessEA stopped. reason=", reason);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyStateIfNeeded();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > peakEquity) peakEquity = equity;

   ManageBreakEven();

   datetime bar = iTime(symbolName, InpEntryTF, 0);
   if(bar <= 0 || bar == lastEntryBar) return;
   lastEntryBar = bar;

   if(CountOurPositions() > 0)
   {
      if(InpCloseOnOpposite) CloseOnOppositeSignal();
      return; // hard anti-grid rule
   }

   if(!TradingAllowed()) return;
   int signal = GetSignal();
   if(signal == 1) OpenPosition(ORDER_TYPE_BUY);
   if(signal == -1) OpenPosition(ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0) return;
   ulong deal = trans.deal;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != symbolName) return;
   if(HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber) return;

   long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   double net = HistoryDealGetDouble(deal, DEAL_PROFIT)
              + HistoryDealGetDouble(deal, DEAL_SWAP)
              + HistoryDealGetDouble(deal, DEAL_COMMISSION);
   if(net < 0.0)
   {
      consecutiveLosses++;
      lastLossTime = TimeCurrent();
   }
   else if(net > 0.0)
   {
      consecutiveLosses = 0;
   }
}

//+------------------------------------------------------------------+
bool TradingAllowed()
{
   if(!IsSessionAllowed()) return false;
   if(tradesToday >= InpMaxTradesPerDay) return false;
   if(consecutiveLosses >= InpMaxConsecutiveLosses) return false;
   if(lastLossTime > 0 && (TimeCurrent() - lastLossTime) < InpCooldownMinutes * 60) return false;
   if(DailyLossLimitHit() || DrawdownLimitHit()) return false;

   MqlTick tick;
   if(!SymbolInfoTick(symbolName, tick)) return false;
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   if(point <= 0) return false;
   int spread = (int)MathRound((tick.ask - tick.bid) / point);
   if(spread > InpMaxSpreadPoints) return false;

   double atr = GetATR(symbolName, InpEntryTF, InpATRPeriod, 1);
   double atrPoints = atr / point;
   if(atrPoints < InpMinATRPoints || atrPoints > InpMaxATRPoints) return false;
   return true;
}

//+------------------------------------------------------------------+
int GetSignal()
{
   double trendClose = iClose(symbolName, InpTrendTF, 1);
   double trendFast = GetMA(symbolName, InpTrendTF, InpFastMAPeriod, 1);
   double trendSlow = GetMA(symbolName, InpTrendTF, InpSlowMAPeriod, 1);
   double confirmClose = iClose(symbolName, InpConfirmTF, 1);
   double confirmFast = GetMA(symbolName, InpConfirmTF, InpFastMAPeriod, 1);
   double confirmSlow = GetMA(symbolName, InpConfirmTF, InpSlowMAPeriod, 1);
   double confirmRSI = GetRSI(symbolName, InpConfirmTF, InpRSIPeriod, 1);
   double entryRSI = GetRSI(symbolName, InpEntryTF, InpRSIPeriod, 1);
   double adx = GetADX(symbolName, InpConfirmTF, InpADXPeriod, 1);

   if(trendClose <= 0 || trendFast <= 0 || trendSlow <= 0 || confirmClose <= 0 ||
      confirmFast <= 0 || confirmSlow <= 0 || confirmRSI < 0 || entryRSI < 0 || adx < 0)
      return 0;
   if(adx < InpMinADX) return 0;

   bool buy = trendClose > trendSlow && trendFast > trendSlow &&
              confirmClose > confirmSlow && confirmFast > confirmSlow &&
              confirmRSI >= InpBuyRSIConfirm && entryRSI >= 50.0;
   bool sell = trendClose < trendSlow && trendFast < trendSlow &&
               confirmClose < confirmSlow && confirmFast < confirmSlow &&
               confirmRSI <= InpSellRSIConfirm && entryRSI <= 50.0;
   if(buy) return 1;
   if(sell) return -1;
   return 0;
}

//+------------------------------------------------------------------+
void OpenPosition(const ENUM_ORDER_TYPE type)
{
   MqlTick tick;
   if(!SymbolInfoTick(symbolName, tick)) return;
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);
   double atr = GetATR(symbolName, InpEntryTF, InpATRPeriod, 1);
   if(point <= 0 || atr <= 0) return;

   double minStop = SymbolInfoInteger(symbolName, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double slDistance = MathMax(atr * InpSL_ATR_Multiplier, minStop + 2 * point);
   double tpDistance = MathMax(atr * InpTP_ATR_Multiplier, minStop + 2 * point);
   double price = type == ORDER_TYPE_BUY ? tick.ask : tick.bid;
   double sl = type == ORDER_TYPE_BUY ? price - slDistance : price + slDistance;
   double tp = type == ORDER_TYPE_BUY ? price + tpDistance : price - tpDistance;
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double volume = CalculateRiskVolume(slDistance);
   if(volume <= 0) return; // do not force broker minimum lot

   bool ok = type == ORDER_TYPE_BUY
             ? trade.Buy(volume, symbolName, 0.0, sl, tp, InpComment)
             : trade.Sell(volume, symbolName, 0.0, sl, tp, InpComment);
   if(!ok)
      Print("Order failed: ", trade.ResultRetcodeDescription());
   else
      tradesToday++;
}

//+------------------------------------------------------------------+
double CalculateRiskVolume(const double stopDistance)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double tickSize = SymbolInfoDouble(symbolName, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbolName, SYMBOL_TRADE_TICK_VALUE);
   double minVolume = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_STEP);
   if(balance <= 0 || stopDistance <= 0 || tickSize <= 0 || tickValue <= 0 ||
      minVolume <= 0 || maxVolume <= 0 || step <= 0) return 0.0;

   double riskMoney = balance * InpRiskPercent / 100.0;
   double lossPerLot = stopDistance / tickSize * tickValue;
   if(lossPerLot <= 0) return 0.0;

   double volume = riskMoney / lossPerLot;
   // Small accounts must skip the trade if minimum broker volume is too risky.
   if(volume < minVolume)
   {
      Print("Trade skipped: minimum lot exceeds risk limit. calculated=",
            DoubleToString(volume, 4), " minimum=", DoubleToString(minVolume, 2));
      return 0.0;
   }
   volume = MathMin(maxVolume, volume);
   volume = MathFloor(volume / step) * step;
   volume = NormalizeDouble(volume, VolumeDigits());
   return volume >= minVolume ? volume : 0.0;
}

//+------------------------------------------------------------------+
int VolumeDigits()
{
   double step = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_STEP);
   int digits = 0;
   while(digits < 8 && NormalizeDouble(step, digits) != step) digits++;
   return digits;
}

//+------------------------------------------------------------------+
int CountOurPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == symbolName &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
bool IsSessionAllowed()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(InpSessionStartHour < InpSessionEndHour)
      return t.hour >= InpSessionStartHour && t.hour < InpSessionEndHour;
   return t.hour >= InpSessionStartHour || t.hour < InpSessionEndHour;
}

//+------------------------------------------------------------------+
void ResetDailyStateIfNeeded()
{
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(t.day_of_year == currentDay) return;
   currentDay = t.day_of_year;
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   tradesToday = 0;
   consecutiveLosses = 0;
   lastLossTime = 0;
}

//+------------------------------------------------------------------+
bool DailyLossLimitHit()
{
   if(dayStartBalance <= 0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double limit = dayStartBalance * InpMaxDailyLossPercent / 100.0;
   return equity <= dayStartBalance - limit;
}

//+------------------------------------------------------------------+
bool DrawdownLimitHit()
{
   if(peakEquity <= 0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return ((peakEquity - equity) / peakEquity * 100.0) >= InpMaxDrawdownPercent;
}

//+------------------------------------------------------------------+
double GetMA(const string symbol, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int h = iMA(symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(h == INVALID_HANDLE) return 0.0;
   double b[]; ArraySetAsSeries(b, true); double v = 0.0;
   if(CopyBuffer(h, 0, shift, 1, b) == 1) v = b[0];
   IndicatorRelease(h); return v;
}

//+------------------------------------------------------------------+
double GetRSI(const string symbol, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int h = iRSI(symbol, tf, period, PRICE_CLOSE);
   if(h == INVALID_HANDLE) return -1.0;
   double b[]; ArraySetAsSeries(b, true); double v = -1.0;
   if(CopyBuffer(h, 0, shift, 1, b) == 1) v = b[0];
   IndicatorRelease(h); return v;
}

//+------------------------------------------------------------------+
double GetATR(const string symbol, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int h = iATR(symbol, tf, period);
   if(h == INVALID_HANDLE) return 0.0;
   double b[]; ArraySetAsSeries(b, true); double v = 0.0;
   if(CopyBuffer(h, 0, shift, 1, b) == 1) v = b[0];
   IndicatorRelease(h); return v;
}

//+------------------------------------------------------------------+
double GetADX(const string symbol, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int h = iADX(symbol, tf, period);
   if(h == INVALID_HANDLE) return -1.0;
   double b[]; ArraySetAsSeries(b, true); double v = -1.0;
   if(CopyBuffer(h, 0, shift, 1, b) == 1) v = b[0];
   IndicatorRelease(h); return v;
}

//+------------------------------------------------------------------+
void ManageBreakEven()
{
   if(!InpUseBreakEven) return;
   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbolName ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double current = type == POSITION_TYPE_BUY ? SymbolInfoDouble(symbolName, SYMBOL_BID)
                                                  : SymbolInfoDouble(symbolName, SYMBOL_ASK);
      double risk = MathAbs(open - sl);
      double profitDistance = type == POSITION_TYPE_BUY ? current - open : open - current;
      if(risk <= 0 || profitDistance < risk * InpBreakEvenAtR) continue;

      double newSL = type == POSITION_TYPE_BUY ? open + InpBreakEvenOffsetPts * point
                                                : open - InpBreakEvenOffsetPts * point;
      newSL = NormalizeDouble(newSL, digits);
      bool improve = type == POSITION_TYPE_BUY ? (sl == 0 || newSL > sl) : (sl == 0 || newSL < sl);
      if(improve) trade.PositionModify(ticket, newSL, tp);
   }
}

//+------------------------------------------------------------------+
void CloseOnOppositeSignal()
{
   int signal = GetSignal();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbolName ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if((type == POSITION_TYPE_BUY && signal == -1) ||
         (type == POSITION_TYPE_SELL && signal == 1))
         trade.PositionClose(ticket);
   }
}
//+------------------------------------------------------------------+
