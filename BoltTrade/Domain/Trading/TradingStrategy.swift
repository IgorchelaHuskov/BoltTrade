//
//  TradingStrategy.swift
//  TreadingBot
//
//  Created by Igorchela on 19.01.26.
//

import Foundation

protocol Resettable {
    func reset() async
}

protocol TradingStrategy: AnyObject {
    func analyze(marketSnapshot: MarketSnapshot) async -> Signal?
}


nonisolated enum Signal {
    case buy(quantity: Double)
    case sell(quantity: Double)
    case exit(side: Side) 
}

