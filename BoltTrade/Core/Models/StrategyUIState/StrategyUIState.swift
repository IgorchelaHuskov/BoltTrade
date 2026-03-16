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
    //let strategyState: String       // "SCANNING", "MONITORING"
    
    // Данные для стакана
    let asks: [ClusterRow]
    let bids: [ClusterRow]
    
    // Целевой кластер
    let targetCluster: TargetClusterInfo?
    let statusMessage: String        
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
}
