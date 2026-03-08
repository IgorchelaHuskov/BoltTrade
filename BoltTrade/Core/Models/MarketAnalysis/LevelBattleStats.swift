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
        var defenderVolume: Double = 0  // кто защищает уровень
        var attackerVolume: Double = 0  // кто атакует уровень
        var lastUpdated: Date = Date()
        var firstSeen: Date = Date()
        
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
