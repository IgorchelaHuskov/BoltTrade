//
//  TechnicalIndicators.swift
//  TreadingBot
//
//  Created by Igorchela on 7.02.26.
//

import Foundation

struct TechnicalIndicators {
    
    static func calculateATR(highs: [Double], lows: [Double], closes: [Double], period: Int = 14) -> Double {
        // 1. Проверка: нужно минимум period + 1 свечей,
        // так как расчет TR начинается со второго элемента (i-1)
        guard highs.count > period else { return 0 }
        
        var atrValues: [Double] = []
        
        // 2. Считаем все True Range
        for i in highs.indices.dropFirst() {
            let tr = max(
                highs[i] - lows[i],
                abs(highs[i] - closes[i-1]),
                abs(lows[i] - closes[i-1])
            )
            atrValues.append(tr)
        }
        
        // 3. Первое значение ATR (SMA)
        // Важно: берем ровно первые 'period' значений TR
        let initialTRSlice = atrValues.prefix(period)
        var atr = initialTRSlice.reduce(0, +) / Double(period)
        
        // 4. Последующие значения (сглаживание Уайлдера)
        // Начинаем с индекса 'period', так как индексы 0...(period-1) уже ушли в initialATR
        guard atrValues.count > period else { return 0 }
        for i in period..<atrValues.count {
            let tr = atrValues[i]
            atr = (atr * Double(period - 1) + tr) / Double(period)
        }
        
        
        return atr
    }
    
    
    static func calculate_adx(highs: [Double], lows: [Double], closes: [Double], period: Int = 14) -> Double {
        // 1. Считаем «Сырые» DM (за 1 день)
        
        // DM+ (Движение вверх): насколько сегодняшний максимум выше вчерашнего
        let dmPlus = zip(highs, highs.dropFirst()).map { yesterday, today in
            let diff = today - yesterday
            return diff > 0 ? diff : 0
        }
        
        // DM- (Движение вниз): насколько сегодняшний минимум ниже вчерашнего
        let dmMinus = zip(lows, lows.dropFirst()).map { yesterday, today in
            let diff = yesterday - today
            return diff > 0 ? diff : 0
        }
        
        // Если DM+ больше, чем DM-, то DM- обнуляем. И наоборот. Победить в моменте должен кто-то один.
        let finalDmPlus = zip(dmPlus, dmMinus).map { p, m in p > m ? p : 0 }
        let finalDmMinus = zip(dmPlus, dmMinus).map { p, m in m > p ? m : 0 }
        
        var atrValues: [Double] = []
        for i in highs.indices.dropFirst() {
            let tr = max(
                highs[i] - lows[i],
                abs(highs[i] - closes[i-1]),
                abs(lows[i] - closes[i-1])
            )
            atrValues.append(tr)
        }
        
        // 2.  Считаем первую "точку опоры" (простое среднее) первые 14 значений из списков выше
        let initialDmPlusSlice = finalDmPlus.prefix(period)
        var smoothDmPlus = initialDmPlusSlice.reduce(0, +) / Double(period)
        
        let initialDmMinusSlice = finalDmMinus.prefix(period)
        var smoothDmMinus = initialDmMinusSlice.reduce(0, +) / Double(period)
        
        let initialTRSlice = atrValues.prefix(period)
        var smoothAtr = initialTRSlice.reduce(0, +) / Double(period)
        
        
        // 3. Основной цикл сглаживания (начиная с 15-й записи)
        var dxHistory: [Double] = []
        guard finalDmPlus.count > period,
              finalDmMinus.count > period else { return 0 }
        
        for i in period..<finalDmPlus.count {
            // Сглаживание по Уайлдеру (13 вчерашних + 1 сегодняшнее)
            let dmP = finalDmPlus[i]
            let dmM = finalDmMinus[i]
            let tr = atrValues[i]
            
            smoothDmPlus = (smoothDmPlus * Double(period-1) + dmP) / Double(period)
            smoothDmMinus = (smoothDmMinus * Double(period-1) + dmM) / Double(period)
            smoothAtr = (smoothAtr * Double(period - 1) + tr) / Double(period)
            
            // Считаем +DI и -DI
            let plusDI = (smoothDmPlus / smoothAtr) * 100
            let minusDI = (smoothDmMinus / smoothAtr) * 100
            
            // Считаем DX (чистая сила без направления)
            let dx = (abs(plusDI - minusDI) / (plusDI + minusDI)) * 100
            dxHistory.append(dx)
        }
        
        // 4: Финальный ADX (сглаживаем сам DX)
        // 1. Первая точка ADX = среднее первых 14 значений DX
        let dxHistirySlice = dxHistory.prefix(period)
        var adIndex = dxHistirySlice.reduce(0, +) / Double(period)
        
        // 2. Идем по остальным DX и сглаживаем их так же
        // Для каждого dx_val в dx_history (после 14-го):
        for i in period..<dxHistory.count {
            let dxVal = dxHistory[i]
            adIndex = (adIndex * Double(period-1) + dxVal) / Double(period)
        }
        
        return adIndex
    }
    
    
    static func calculateRVI(highs: [Double], lows: [Double], atr14: Double, period: Int = 20) -> Double {
        guard highs.count >= period && lows.count >= period else { return 1.0 }
        
        let recentHighs = highs.suffix(period)
        let recentLows = lows.suffix(period)
        let avgRange = zip(recentHighs, recentLows)
            .map { h, l in h - l }
            .reduce(0, +) / Double(period)
        
        return atr14 > 0 ? avgRange / atr14 : 1.0
    }
    
    
    static func calculateVolatilityRatio(atr5: Double, atr14: Double) -> Double {
        return atr14 > 0 ? atr5 / atr14 : 1.0
    }
        
    
    static func calculateSMA(values: [Double], period: Int = 20) -> Double {
        guard values.count >= period else {
            return values.reduce(0, +) / Double(max(1, values.count))
        }
        return values.suffix(period).reduce(0, +) / Double(period)
    }
        
    
    static func calculatePriceDeviation(currentPrice: Double, sma: Double) -> Double {
        return sma > 0 ? abs(currentPrice - sma) / sma : 0
    }
}
