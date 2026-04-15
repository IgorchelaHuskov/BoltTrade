//
//  MarkPrice.swift
//  BoltTrade
//
//  Created by Igorchela on 14.04.26.
//

import Foundation

/*
 {
   "e": "markPriceUpdate",      // Event type
   "E": 1562305380000,          // Event time
   "s": "BTCUSDT",              // Symbol
   "p": "11794.15000000",       // Mark price
   "ap": "11794.15000000",   // Mark price moving average
   "i": "11784.62659091",        // Index price
   "P": "11784.25641265",        // Estimated Settle Price, only useful in the last hour before the settlement starts
   "r": "0.00038167",           // Funding rate
   "T": 1562306400000           // Next funding time
 }
 */


nonisolated struct MarkPrice: Codable {
    let e: String
    let E: Int
    let s: String
    let p: String
    let ap: String
    let i: String
    let P: String
    let r: String
    let T: Int
}
