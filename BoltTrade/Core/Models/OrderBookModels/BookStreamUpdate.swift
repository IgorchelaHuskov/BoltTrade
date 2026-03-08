//
//  OrderBookStreamUpdate.swift
//  AutomaticTrading
//
//  Created by Igorchela on 1.01.26.
//

import Foundation

/*
 {
   "e": "depthUpdate", // Event type
   "E": 1672515782136, // Event time
   "s": "BNBBTC",      // Symbol
   "U": 157,           // First update ID in event
   "u": 160,           // Final update ID in event
   "b": [              // Bids to be updated
     [
       "0.0024",       // Price level to be updated
       "10"            // Quantity
     ]
   ],
   "a": [              // Asks to be updated
     [
       "0.0026",       // Price level to be updated
       "100"           // Quantity
     ]
   ]
 }
 */

nonisolated struct OrderBookStreamUpdate: Decodable, Sendable {
    let eventType: String
    let eventTime: Int
    let symbol: String
    let firstUpdateID: Int
    let finalUpdateID: Int
    let bids: [OrderBookEntryStream]
    let asks: [OrderBookEntryStream]
    
    enum CodingKeys: String, CodingKey {
        case eventType = "e"
        case eventTime = "E"
        case symbol = "s"
        case firstUpdateID = "U"
        case finalUpdateID = "u"
        case bids = "b"
        case asks = "a"
    }
}


struct OrderBookEntryStream: Decodable, Sendable {
    let price: Double
    let quantity: Double

    init(from decoder: Decoder) throws {
        // Данные приходят как ["4.00000000", "431.00000000"]
        var container = try decoder.unkeyedContainer()
        let priceString = try container.decode(String.self)
        let quantityString = try container.decode(String.self)
        
        self.price = Double(priceString) ?? 0
        self.quantity = Double(quantityString) ?? 0
    }
}


