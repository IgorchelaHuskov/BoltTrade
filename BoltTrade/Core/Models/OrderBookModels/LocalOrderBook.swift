//
//  LocalOrderBook.swift
//  AutomaticTrading
//
//  Created by Igorchela on 3.01.26.
//

import Foundation


struct LocalOrderBook: Sendable {
    var bids: [OrderBookLevel] = []
    var asks: [OrderBookLevel] = []
    var lastUpdateId: Int = 0
    
    var bestBid: OrderBookLevel? { bids.first }
    var bestAsk: OrderBookLevel? { asks.first }
}
