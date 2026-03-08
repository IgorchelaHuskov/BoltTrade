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


enum Signal {
    case buy, sell, noneSignal
}
