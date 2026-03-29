//
//  BinCalculate.swift
//  TreadingBot
//
//  Created by Igorchela on 7.02.26.
//

import Foundation

actor BinCalculator {
    
    private let tickSize: Double = 0.1
    
    func calculateBin( metrics: MarketMetrics,
                       currentPrice: Double,
                       marketState: MarketStateAnalyzer.MarketState,
                       configs: [MarketStateAnalyzer.MarketState: MarketConfig] ) -> (pct: Double, abs: Double) {
        
        let atrPercent = metrics.atr14 / currentPrice
        
        guard let config = configs[marketState] else {
            print("⚠️ Нет конфига для состояния: \(marketState)")
            return (0.001, currentPrice * 0.001) // fallback
        }
        
        let rawBin = atrPercent * config.coefficient
        let binPctUnrounded = max(config.minPct, min(config.maxPct, rawBin))
        let binPct = roundToNiceValue(binPct: binPctUnrounded)
        let binSizeAbsUnrounded = currentPrice * binPct
        let binSizeAbs = roundToNiceAbsValue(binAbs: binSizeAbsUnrounded)
        
        /*print("""
            📊 BinCalculator DEBUG:
               ATR%: \(String(format: "%.4f", atrPercent * 100))%
               rawBin: \(String(format: "%.4f", rawBin * 100))%
               config.min: \(String(format: "%.4f", config.minPct * 100))%
               config.max: \(String(format: "%.4f", config.maxPct * 100))%
               unrounded: \(String(format: "%.4f", binPctUnrounded * 100))%
               rounded: \(String(format: "%.4f", binPct * 100))%
            """) */
        
        return (binPct, binSizeAbs)
    }
    
    
    private func roundToNiceValue(binPct: Double) -> Double {
        // Округляем до 0.01% (0.0001)
        // 0.1335% → 0.13% (0.0013)
        // 0.1382% → 0.14% (0.0014)
        // 0.1523% → 0.15% (0.0015)
        
        let step = 0.0001  // 0.01%
        let rounded = (binPct / step).rounded() * step
        
        // Защита от слишком маленьких шагов
        return max(0.0005, rounded)  // не меньше 0.05%
    }
    
    private func roundToNiceAbsValue(binAbs: Double) -> Double {
        return max(tickSize, (binAbs / tickSize).rounded() * tickSize)
    }
}
