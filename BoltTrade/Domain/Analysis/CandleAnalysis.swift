//
//  CandleAnalysis.swift
//  TreadingBot
//
//  Created by Igorchela on 26.02.26.
//

import Foundation

struct CandleAnalysis {
    static func analyzeCandlePattern(current: Candle, previous: Candle) -> CandlePattern {
        let bodySize = abs(current.closePrice - current.openPrice)
        let totalRange = current.highPrice - current.lowPrice
        let lowerWick = min(current.openPrice, current.closePrice) - current.lowPrice
        let upperWick = current.highPrice - max(current.openPrice, current.closePrice)
        
        // Доджи
        if bodySize < totalRange * 0.1 {
            return .doji
        }
        
        // Длинная тень
        if lowerWick > bodySize * 2 || upperWick > bodySize * 2 {
            return .longWick
        }
        
        // Поглощение
        if current.closePrice > current.openPrice && // бычья свеча
           previous.closePrice < previous.openPrice && // предыдущая медвежья
           current.openPrice < previous.closePrice &&
           current.closePrice > previous.openPrice {
            return .engulfing
        }
        
        if current.closePrice < current.openPrice && // медвежья свеча
           previous.closePrice > previous.openPrice && // предыдущая бычья
           current.openPrice > previous.closePrice &&
           current.closePrice < previous.openPrice {
            return .engulfing
        }
        
        return current.closePrice > current.openPrice ? .bullish : .bearish
    }
}
