//
//  MarketConfigEntity.swift
//  TreadingBot
//
//  Created by Igorchela on 12.02.26.
//

import SwiftData
import Foundation

@Model
final class MarketConfigEntity {
    @Attribute(.unique) var stateKey: String // "flat", "strongUptrend" и т.д.
    var coefficient: Double
    var minPct: Double
    var maxPct: Double
    var adxThreshold: Double?
    var rviThreshold: Double?
    var volatilityRatio: Double?
    var lastUpdated: Date // Чтобы знать, когда пора переобучаться

    init(state: MarketStateAnalyzer.MarketState, config: MarketConfig) {
        self.stateKey = state.rawValue
        self.coefficient = config.coefficient
        self.minPct = config.minPct
        self.maxPct = config.maxPct
        self.adxThreshold = config.adxThreshold
        self.rviThreshold = config.rviThreshold
        self.volatilityRatio = config.volatilityRatio
        self.lastUpdated = Date()
    }
}

