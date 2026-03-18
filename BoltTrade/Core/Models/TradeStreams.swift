//
//  Trade.swift
//  TreadingBot
//
//  Created by Igorchela on 19.01.26.
//

/*
 {
   "e": "trade",       // Event type
   "E": 1672515782136, // Event time
   "s": "BNBBTC",      // Symbol
   "t": 12345,         // Trade ID
   "p": "0.001",       // Price
   "q": "100",         // Quantity
   "T": 1672515782136, // Trade time
   "m": true,          // Is the buyer the market maker?
   "M": true           // Ignore
 }
 */


import Foundation

struct TradeStreams: Decodable, Sendable {
    let eventType: String
    let eventTime: Int
    let symbol: String
    let tradeID: Int
    let price: Double
    let quantity: Double
    let tradeTime: Int
    let isMaker: Bool  // агрессивный ПОКУПАТЕЛЬ?
    
    enum CodingKeys: String, CodingKey {
        case eventType = "e"
        case eventTime = "E"
        case symbol = "s"
        case tradeID = "t"
        case price = "p"
        case quantity = "q"
        case tradeTime = "T"
        case isMaker = "m"
    }
    
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.eventType = try container.decode(String.self, forKey: .eventType)
        self.eventTime = try container.decode(Int.self, forKey: .eventTime)
        self.symbol = try container.decode(String.self, forKey: .symbol)
        self.tradeID = try container.decode(Int.self, forKey: .tradeID)
        let priceStrind = try container.decode(String.self, forKey: .price)
        let quantityString = try container.decode(String.self, forKey: .quantity)
        self.tradeTime = try container.decode(Int.self, forKey: .tradeID)
        self.isMaker = try container.decode(Bool.self, forKey: .isMaker)
        
        self.price = Double(priceStrind) ?? 0
        self.quantity = Double(quantityString) ?? 0
    }
}
