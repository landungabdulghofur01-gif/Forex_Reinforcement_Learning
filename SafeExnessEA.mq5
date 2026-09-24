//+------------------------------------------------------------------+
//| SafeExnessEA.mq5                                                 |
//| Rule-based MT5 EA: anti-grid, anti-martingale, risk-based lots    |
//| EURUSD default; M5 entry, M15 confirmation, H1 trend filter      |
//+------------------------------------------------------------------+
#property strict
#property version "1.10"

#include <Trade/Trade.mqh>

input string           InpTradeSymbol          = "EURUSD";
input ENUM_TIMEFRAMES  InpEntryTF              = PERIOD_M5;
input ENUM_TIMEFRAMES  InpConfirmTF            = PERIOD_M15;
input ENUM_TIMEFRAMES  InpTrendTF              = PERIOD_H1;
input long             InpMagicNumber          = 20260924;
input double           InpRiskPercent          = 0.25;
input double           InpMaxDailyLossPercent  = 1.00;
input double           InpMaxDrawdownPercent   = 10.00;
input int              InpMaxSpreadPoints     = 20;
input int              InpDeviationPoints     = 20;
input int              InpATRPeriod            = 14;
input double           InpSL_ATR_Multiplier    = 1.50;
input double           InpTP_ATR_Multiplier    = 2.20;
input int              InpFastMAPeriod         = 20;
input int              InpSlowMAPeriod         = 50;
input int              InpRSIPeriod            = 14;
input double           InpBuyRSIConfirm        = 52.0;
input double           InpSellRSIConfirm       = 48.0;
input bool             InpUseSessionFilter     = true;
input int              InpSessionStartHour     = 1;
input int              InpSessionEndHour       = 22;
input bool             InpUseBreakEven         = true;
input double           InpBreakEvenAtR         = 1.00;
input int              InpBreakEvenOffsetPts   = 2;
input bool             InpCloseOnOpposite     = false;
input string           InpComment               = "SafeExnessEA";

CTrade   trade;
datetime lastEntryBar = 0;
string   symbolName;

//+------------------------------------------------------------------+
int OnInit()
{
   symbolName = InpTradeSymbol;
   if(StringLen(symbolName) == 0)
      symbolName = _Symbol;

   if(!SymbolSelect(symbolName, true))
   {
      Print("Cannot select symbol: ", symbolName);
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(symbolName);
   trade.SetAsyncMode(false);

   Print("SafeExnessEA initialized on ", symbolName,
         " | risk=", DoubleToString(InpRiskPercent, 2), "%");
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
   ManageBreakEven();

   datetime currentBar = iTime(symbolName, InpEntryTF, 0);
   if(currentBar <= 0 || currentBar == lastEntryBar)
      return;
   lastEntryBar = currentBar;

   if(CountOurPositions() > 0)
   {
      if(InpCloseOnOpposite)
         CloseOnOppositeSignal();
      return; // anti-grid: never add to an existing position
   }

   if(!TradingAllowed())
      return;

   int signal = GetSignal();
   if(signal == 1)
      OpenPosition(ORDER_TYPE_BUY);
   else if(signal == -1)
      OpenPosition(ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
bool TradingAllowed()
{
   if(!IsSessionAllowed())
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(symbolName, tick) || tick.bid <= 0 || tick.ask <= 0)
      return false;

   int spread = (int)MathRound((tick.ask - tick.bid) / SymbolInfoDouble(symbolName, SYMBOL_POINT));
   if(spread > InpMaxSpreadPoints)
   {
      Print("Spread blocked: ", spread, " points");
      return false;
   }

   if(DailyLossLimitHit())
   {
      Print("Daily loss limit reached");
      return false;
   }

   if(DrawdownLimitHit())
   {
      Print("Drawdown limit reached");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
int GetSignal()
{
   double trendClose = iClose(symbolName, InpTrendTF, 1);
   double trendFast  = GetMA(symbolName, InpTrendTF, InpFastMAPeriod, 1);
   double trendSlow  = GetMA(symbolName, InpTrendTF, InpSlowMAPeriod, 1);

   double confirmClose = iClose(symbolName, InpConfirmTF, 1);
   double confirmFast  = GetMA(symbolName, InpConfirmTF, InpFastMAPeriod, 1);
   double confirmSlow  = GetMA(symbolName, InpConfirmTF, InpSlowMAPeriod, 1);
   double confirmRSI   = GetRSI(symbolName, InpConfirmTF, InpRSIPeriod, 1);
   double entryRSI     = GetRSI(symbolName, InpEntryTF, InpRSIPeriod, 1);

   if(trendClose <= 0 || confirmClose <= 0 || trendFast <= 0 || trendSlow <= 0 ||
      confirmFast <= 0 || confirmSlow <= 0 || confirmRSI < 0 || entryRSI < 0)
      return 0;

   bool bullish = trendClose > trendSlow && trendFast > trendSlow &&
                  confirmClose > confirmSlow && confirmFast > confirmSlow &&
                  confirmRSI >= InpBuyRSIConfirm && entryRSI >= 50.0;

   bool bearish = trendClose < trendSlow && trendFast < trendSlow &&
                  confirmClose < confirmSlow && confirmFast < confirmSlow &&
                  confirmRSI <= InpSellRSIConfirm && entryRSI <= 50.0;

   if(bullish) return 1;
   if(bearish) return -1;
   return 0;
}

//+------------------------------------------------------------------+
void OpenPosition(const ENUM_ORDER_TYPE orderType)
{
   MqlTick tick;
   if(!SymbolInfoTick(symbolName, tick))
      return;

   double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);
   double atr = GetATR(symbolName, InpEntryTF, InpATRPeriod, 1);
   if(atr <= 0 || point <= 0)
      return;

   double minStop = (double)SymbolInfoInteger(symbolName, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double slDistance = MathMax(atr * InpSL_ATR_Multiplier, minStop + 2.0 * point);
   double tpDistance = MathMax(atr * InpTP_ATR_Multiplier, minStop + 2.0 * point);
   double price = orderType == ORDER_TYPE_BUY ? tick.ask : tick.bid;
   double sl = orderType == ORDER_TYPE_BUY ? price - slDistance : price + slDistance;
   double tp = orderType == ORDER_TYPE_BUY ? price + tpDistance : price - tpDistance;

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double volume = CalculateRiskVolume(slDistance);
   if(volume <= 0)
   {
      Print("Volume calculation returned zero; trade skipped");
      return;
   }

   bool ok = false;
   if(orderType == ORDER_TYPE_BUY)
      ok = trade.Buy(volume, symbolName, 0.0, sl, tp, InpComment);
   else
      ok = trade.Sell(volume, symbolName, 0.0, sl, tp, InpComment);

   if(!ok)
      Print("Order failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   else
      Print("Order opened: ", orderType == ORDER_TYPE_BUY ? "BUY" : "SELL",
            " volume=", DoubleToString(volume, VolumeDigits()),
            " SL=", DoubleToString(sl, digits), " TP=", DoubleToString(tp, digits));
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
      minVolume <= 0 || maxVolume <= 0 || step <= 0)
      return 0.0;

   double riskMoney = balance * InpRiskPercent / 100.0;
   double lossPerLot = stopDistance / tickSize * tickValue;
   if(lossPerLot <= 0)
      return 0.0;

   double volume = riskMoney / lossPerLot;
   volume = MathMin(maxVolume, MathMax(minVolume, volume));
   volume = MathFloor(volume / step) * step;
   volume = NormalizeDouble(volume, VolumeDigits());

   if(volume < minVolume)
      return 0.0;
   return volume;
}

//+------------------------------------------------------------------+
int VolumeDigits()
{
   double step = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_STEP);
   int digits = 0;
   while(digits < 8 && NormalizeDouble(step, digits) != step)
      digits++;
   return digits;
}

//+------------------------------------------------------------------+
int CountOurPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == symbolName &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
bool IsSessionAllowed()
{
   if(!InpUseSessionFilter)
      return true;

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(InpSessionStartHour < InpSessionEndHour)
      return t.hour >= InpSessionStartHour && t.hour < InpSessionEndHour;
   return t.hour >= InpSessionStartHour || t.hour < InpSessionEndHour;
}

//+------------------------------------------------------------------+
bool DailyLossLimitHit()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.hour = 0; t.min = 0; t.sec = 0;
   datetime start = StructToTime(t);
   if(!HistorySelect(start, TimeCurrent()))
      return false;

   double pnl = 0.0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != symbolName) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;
      pnl += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      pnl += HistoryDealGetDouble(ticket, DEAL_SWAP);
      pnl += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }

   double limit = AccountInfoDouble(ACCOUNT_BALANCE) * InpMaxDailyLossPercent / 100.0;
   return pnl <= -limit;
}

//+------------------------------------------------------------------+
bool DrawdownLimitHit()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0) return false;
   return ((balance - equity) / balance * 100.0) >= InpMaxDrawdownPercent;
}

//+------------------------------------------------------------------+
double GetMA(const string symbol, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int handle = iMA(symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return 0.0;
   double buffer[]; ArraySetAsSeries(buffer, true);
   double value = 0.0;
   if(CopyBuffer(handle, 0, shift, 1, buffer) == 1) value = buffer[0];
   IndicatorRelease(handle);
   return value;
}

//+------------------------------------------------------------------+
double GetRSI(const string symbol, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int handle = iRSI(symbol, tf, period, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return -1.0;
   double buffer[]; ArraySetAsSeries(buffer, true);
   double value = -1.0;
   if(CopyBuffer(handle, 0, shift, 1, buffer) == 1) value = buffer[0];
   IndicatorRelease(handle);
   return value;
}

//+------------------------------------------------------------------+
double GetATR(const string symbol, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int handle = iATR(symbol, tf, period);
   if(handle == INVALID_HANDLE) return 0.0;
   double buffer[]; ArraySetAsSeries(buffer, true);
   double value = 0.0;
   if(CopyBuffer(handle, 0, shift, 1, buffer) == 1) value = buffer[0];
   IndicatorRelease(handle);
   return value;
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
      if(risk <= 0) continue;
      double profitDistance = type == POSITION_TYPE_BUY ? current - open : open - current;
      if(profitDistance < risk * InpBreakEvenAtR) continue;

      double newSL = type == POSITION_TYPE_BUY ? open + InpBreakEvenOffsetPts * point
                                                : open - InpBreakEvenOffsetPts * point;
      newSL = NormalizeDouble(newSL, digits);
      bool improve = type == POSITION_TYPE_BUY ? (sl == 0 || newSL > sl) : (sl == 0 || newSL < sl);
      if(improve && !trade.PositionModify(ticket, newSL, tp))
         Print("Break-even failed: ", trade.ResultRetcodeDescription());
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
      {
         if(!trade.PositionClose(ticket))
            Print("Close failed: ", trade.ResultRetcodeDescription());
      }
   }
}
//+------------------------------------------------------------------+
