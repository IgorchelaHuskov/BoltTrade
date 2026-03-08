//
//  Kline.swift
//  AutomaticTrading
//
//  Created by Igorchela on 30.12.25.
//

import Foundation


struct Candle: Decodable, Sendable {
    let openTime: Int64
    let openPrice: Double
    let highPrice: Double
    let lowPrice: Double
    let closePrice: Double
    let volume: Double
    let closeTime: Int64
    let quoteAssetVolume: Double
    let takerBuyQuoteAssetVolume: Double
    
    // 1. Этот инициализатор нужен для SwiftData и ручного создания
    init(openTime: Int64, openPrice: Double, highPrice: Double, lowPrice: Double,
         closePrice: Double, volume: Double, closeTime: Int64,
         quoteAssetVolume: Double, takerBuyQuoteAssetVolume: Double) {
        self.openTime = openTime
        self.openPrice = openPrice
        self.highPrice = highPrice
        self.lowPrice = lowPrice
        self.closePrice = closePrice
        self.volume = volume
        self.closeTime = closeTime
        self.quoteAssetVolume = quoteAssetVolume
        self.takerBuyQuoteAssetVolume = takerBuyQuoteAssetVolume
    }
    
    // 2. Этот инициализатор нужен ТОЛЬКО для Binance API
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.openTime = try container.decode(Int64.self)
        
        let priceStr = try container.decode(String.self)
        let highPriceStr = try container.decode(String.self)
        let lowPriceStr = try container.decode(String.self)
        let closePriceStr = try container.decode(String.self)
        let volumeStr = try container.decode(String.self)
        
        self.closeTime = try container.decode(Int64.self)
        let quoteAssetVolumeStr = try container.decode(String.self)
        _ = try container.decode(Int.self)
        _ = try container.decode(String.self)
        let takerBuyQuoteAssetVolumeStr = try container.decode(String.self)
        
        self.openPrice = Double(priceStr) ?? 0
        self.highPrice = Double(highPriceStr) ?? 0
        self.lowPrice = Double(lowPriceStr) ?? 0
        self.closePrice = Double(closePriceStr) ?? 0
        self.volume = Double(volumeStr) ?? 0
        self.quoteAssetVolume = Double(quoteAssetVolumeStr) ?? 0
        self.takerBuyQuoteAssetVolume = Double(takerBuyQuoteAssetVolumeStr) ?? 0
    }
}
