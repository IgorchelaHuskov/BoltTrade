//
//  LevelBattleStats.swift
//  TreadingBot
//
//  Created by Igorchela on 18.02.26.
//

import Foundation

struct LevelBattleStats: Sendable {
    let trackingId: Double
    let side: Side
    let price: Double
    var defenderVolume: Double = 0
    var attackerVolume: Double = 0
    var totalAttackerVolume: Double = 0
    var lastUpdated: Date = Date()
    var firstSeen: Date = Date()
    
    var attackerVolumeHistory: [(volume: Double, timestamp: Date)] = []
    let historyWindowSeconds: TimeInterval = 60
    
    mutating func addAttackerVolume(_ volume: Double, at time: Date) {
        attackerVolumeHistory.append((volume, time))
        totalAttackerVolume += volume  // добавляем к накопленному
        
        let cutoff = time.addingTimeInterval(-historyWindowSeconds)
        attackerVolumeHistory = attackerVolumeHistory.filter { $0.timestamp > cutoff }
        attackerVolume = attackerVolumeHistory.reduce(0) { $0 + $1.volume }
    }
    
    var recentAttackerVolume: Double {
        return attackerVolume
    }
    
    var isAttackerExhausted: Bool {
        guard attackerVolumeHistory.count >= 3 else { return false }
        
        let totalVolume = attackerVolumeHistory.reduce(0) { $0 + $1.volume }
        let average = totalVolume / Double(attackerVolumeHistory.count)
        
        let lastThree = attackerVolumeHistory.suffix(3)
        let lastThreeAverage = lastThree.reduce(0) { $0 + $1.volume } / 3
        
        return lastThreeAverage < average * 0.5
    }
    
    var ratio: Double {
        defenderVolume > 0 ? attackerVolume / defenderVolume : attackerVolume
    }
    
    var isUnderAttack: Bool {
        ratio > 2.0
    }
    
    var isStrong: Bool {
        ratio < 0.5 && defenderVolume > 1.0
    }
}
