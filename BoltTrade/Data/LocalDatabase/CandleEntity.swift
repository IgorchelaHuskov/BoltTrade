//
//  CandleEntity.swift
//  TreadingBot
//
//  Created by Igorchela on 12.02.26.
//

import SwiftData

@Model
final class CandleEntity {
    @Attribute(.unique) var openTime: Int64
    var openPrice: Double
    var highPrice: Double
    var lowPrice: Double
    var closePrice: Double
    var volume: Double
    var closeTime: Int64
    var quoteAssetVolume: Double
    var takerBuyQuoteAssetVolume: Double
    
    init(dto: Candle) {
        self.openTime = dto.openTime
        self.openPrice = dto.openPrice
        self.highPrice = dto.highPrice
        self.lowPrice = dto.lowPrice
        self.closePrice = dto.closePrice
        self.volume = dto.volume
        self.closeTime = dto.closeTime
        self.quoteAssetVolume = dto.quoteAssetVolume
        self.takerBuyQuoteAssetVolume = dto.takerBuyQuoteAssetVolume
    }
}

extension CandleEntity {
    func toCandle() -> Candle {
        return Candle(
            openTime: self.openTime,
            openPrice: self.openPrice,
            highPrice: self.highPrice,
            lowPrice: self.lowPrice,
            closePrice: self.closePrice,
            volume: self.volume,
            closeTime: self.closeTime,
            quoteAssetVolume: self.quoteAssetVolume,
            takerBuyQuoteAssetVolume: self.takerBuyQuoteAssetVolume
        )
    }
}
