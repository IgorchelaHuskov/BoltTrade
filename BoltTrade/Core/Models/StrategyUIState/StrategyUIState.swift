//
//  StrategyUIState.swift
//  BoltTrade
//
//  Created by Igorchela on 15.03.26.
//

import Foundation

struct StrategyUIState {
    let price: Double
    let marketStatus: String        // "FLAT", "TREND", etc.
    
    // Данные для стакана
    let asks: [ClusterRow]
    let bids: [ClusterRow]
    
    // Целевой кластер
    let targetCluster: TargetClusterInfo?
    let statusMessage: String
    
    let positionInfo: PositionInfo?  // nil, если позиция не открыта
    let tradeHistory: [TradeHistoryItem]
}

struct ClusterRow: Identifiable {
    let id: Double // Используем цену или ID кластера
    let price: Double
    let volume: Double
    let power: Double // strengthZScore
    let distancePercent: Double
}

struct TargetClusterInfo {
    let id: Double
    let lowerBound: Double
    let upperBound: Double
    let type: String // "Сопротивление" / "Поддержка"
    let volume: Double
    let power: Double // strengthZScore
    
    // поля для детализации (из handleMonitoring)
    var hasTouched: Bool = false
    var monitoringDuration: TimeInterval = 0
    var attackerVolume: Double = 0
    var defenderVolume: Double = 0
    var armorRatio: Double = 0
    var initialVolume: Double = 0
    var currentVolume: Double = 0
    var volumeRetainedPercent: Double = 100.0
    var isWaitingForBounce: Bool = false
    var currentPrice: Double = 0
    var priceCondition: String = ""
}

// MARK: - PositionInfo
struct PositionInfo {
    let side: Side                 // .bid = LONG, .ask = SHORT
    let entryPrice: Double
    let openTime: Date
    let pnlPercent: Double
    let pnlAbsolute: Double
    let sourceCluster: TargetClusterInfo?
    let encounterCluster: TargetClusterInfo?
}


struct TradeHistoryItem: Identifiable {
    let id = UUID()
    let entryDate: Date
    let exitData: Date
    let entryPrice: Double
    let exitPrice: Double?
    let profitLoss: Double
    let profitLossPercent: Double
    let isOpen: Bool
    let whyСlosePosition: String
    let side: Side
    let power: Double
    let volume: Double
}
