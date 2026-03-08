//
//  OrderBook.swift
//  AutomaticTrading
//
//  Created by Igorchela on 30.12.25.
//

import Foundation

/*
 {
     "lastUpdateId": 1027024,
     "bids": [
         [
             "4.00000000",      // PRICE
             "431.00000000"     // QTY
         ]
     ],
     "asks": [["4.00000200", "12.00000000"]]
 }


 */


nonisolated struct OrderBookSnapshot: Decodable, Sendable{
    let lastUpdateId: Int
    let bids: [OrderBookEntrySnapshot]
    let asks: [OrderBookEntrySnapshot]
}

nonisolated struct OrderBookEntrySnapshot: Decodable, Sendable {
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
