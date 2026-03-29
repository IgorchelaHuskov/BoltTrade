//
//  LevelStatsManager.swift
//  TreadingBot
//
//  Created by Igorchela on 18.02.26.
//

import Foundation

actor LevelStatsManager {
    // Статистика по каждому trackingId
    private var statsByLevel: [Double: LevelBattleStats] = [:]
    private var lastClusters: [Cluster] = []
    
    // Обновляем список кластеров (вызывать из TradingEngine после кластеризации)
    func updateClusters(clusters: [Cluster]) {
        self.lastClusters = clusters.sorted { $0.price < $1.price }
        
        // Добавляем новые кластеры в статистику
        for cluster in clusters {
            let key = cluster.trackingId
            if statsByLevel[key] == nil {
                statsByLevel[key] = LevelBattleStats(trackingId: key, side: cluster.side, price: cluster.price, totalAttackerVolume: 0)
            }
        }
        
        // Очищаем старые (не обновлялись > 5 минут)
        let oldDate = Date().addingTimeInterval(-300)
        statsByLevel = statsByLevel.filter { $0.value.lastUpdated > oldDate }
    }
    
    
    // Обрабатываем трейд (вызывать из TradingEngine при каждом трейде)
    func procesTrade(trade: TradeStreams) async {
        // 1. Ищем кластер по ФИЗИЧЕСКИМ границам
        guard let cluster = lastClusters.first(where: {
            trade.price >= $0.lowerBound && trade.price <= $0.upperBound
        }) else { return }
        
        let key = cluster.trackingId
        guard var stats = statsByLevel[key] else { return }

        // 2. Определяем тип рыночного ордера (Агрессора)
        // m = true означает Buyer is Maker -> Агрессор SELL
        // m = false означает Buyer is Not Maker -> Агрессор BUY
        let isAggressiveBuy = !trade.isMaker
        let isAggressiveSell = trade.isMaker

        switch cluster.side {
        case .bid: // Уровень поддержки (Лимитные покупки)
            if isAggressiveSell {
                await stats.addAttackerVolume(trade.quantity, at: Date()) // Продавец бьет в лимиты покупок
            } else if isAggressiveBuy {
                stats.defenderVolume += trade.quantity // Рыночный покупатель помогает защищать
            }
            
        case .ask: // Уровень сопротивления (Лимитные продажи)
            if isAggressiveBuy {
                await stats.addAttackerVolume(trade.quantity, at: Date()) // Покупатель бьет в лимиты продаж
            } else if isAggressiveSell {
                stats.defenderVolume += trade.quantity // Рыночный продавец помогает защищать
            }
        }

        
        stats.lastUpdated = Date()
        statsByLevel[key] = stats
    }

    
    // Получить статистику для конкретного кластера
    func getAllStats() -> [Double: LevelBattleStats] {
        return statsByLevel
    }
    
}

