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
    var lastUpdated: Date = Date()
    var firstSeen: Date = Date()
    
    // Для расчёта рефилла
    var attackerVolumeHistory: [(volume: Double, timestamp: Date)] = []
    let historyWindowSeconds: TimeInterval = 60
    
    mutating func addAttackerVolume(_ volume: Double, at time: Date) {
        attackerVolumeHistory.append((volume, time))
        attackerVolume += volume
        
        // Удаляем старые записи
        attackerVolumeHistory = attackerVolumeHistory.filter {
            time.timeIntervalSince($0.timestamp) < historyWindowSeconds
        }
    }
    
    var recentAttackerVolume: Double {
        return attackerVolumeHistory.reduce(0) { $0 + $1.volume }
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
