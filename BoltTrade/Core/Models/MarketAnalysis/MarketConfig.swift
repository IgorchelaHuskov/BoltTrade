//
//  MarketConfig.swift
//  TreadingBot
//
//  Created by Igorchela on 28.01.26.
//

import Foundation


struct MarketConfig: Sendable {
    var coefficient: Double
    var minPct: Double
    var maxPct: Double
    var adxThreshold: Double?
    var rviThreshold: Double?
    var volatilityRatio: Double?
}


struct MarketMetrics: Sendable {
    let atr14: Double
    let atr5: Double
    let adx: Double
    let rvi: Double
    let volatilityRatio: Double
    let sma20: Double
    let priceDeviation: Double
    
    let trendDirection: Double           // -1 до +1 (направление тренда)
    let trendStrength: Double            // 0 до 1 (сила тренда)
    let lowerLows: Int                   // количество более низких минимумов
    let higherHighs: Int                 // количество более высоких максимумов
    let lowerHighs: Int                  // количество более низких максимумов
    let higherLows: Int                  // количество более высоких минимумов
    let priceVsSMA50: Double             // отклонение от SMA50
    let volumeTrend: Double              // тренд объема (-1 до +1)
    let candlePattern: CandlePattern     // паттерн последней свечи
}

nonisolated enum CandlePattern: Sendable {
    case bullish    // бычья
    case bearish    // медвежья
    case doji       // неопределенность
    case longWick   // длинная тень
    case engulfing  // поглощение
}


struct MarketStateData: Sendable {
    let metrics: MarketMetrics
    let marketState: MarketStateAnalyzer.MarketState
    let bin: (pct: Double, abs: Double)
}

