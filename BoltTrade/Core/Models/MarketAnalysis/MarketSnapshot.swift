//
//  MarketSnapshot.swift
//  TreadingBot
//
//  Created by Igorchela on 19.02.26.
//

import Foundation
struct MarketSnapshot: Sendable {
    let timestamp: Date
    let currentPrice: Double
    let state: MarketStateAnalyzer.MarketState
    let metrics: MarketMetrics
    let config: MarketConfig?
    let bin: (pct: Double, abs: Double)
    let clusters: [Cluster]
    let book: LocalOrderBook
    let battleStats: [Double: LevelBattleStats]
}
