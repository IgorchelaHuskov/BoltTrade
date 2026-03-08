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
                statsByLevel[key] = LevelBattleStats(trackingId: key, side: cluster.side, price: cluster.price)
            }
        }
        
        // Очищаем старые (не обновлялись > 5 минут)
        let oldDate = Date().addingTimeInterval(-300)
        statsByLevel = statsByLevel.filter { $0.value.lastUpdated > oldDate }
    }
    
    
    // Обрабатываем трейд (вызывать из TradingEngine при каждом трейде)
    func procesTrade(trade: TradeStreams) {
        // 1. Ищем кластер по ФИЗИЧЕСКИМ границам
        guard let cluster = lastClusters.first(where: {
            trade.price >= $0.lowerBound && trade.price <= $0.upperBound
        }) else { return }
        
        let key = cluster.trackingId
        guard var stats = statsByLevel[key] else { return }

        // 2. Определяем тип рыночного ордера (Агрессора)
        // В Binance: m (isBuyerMaker) == true означает, что рыночный ордер был SELL
        let isMarketSell = trade.isBuyer
        let isMarketBuy = !trade.isBuyer

        switch cluster.side {
        case .bid:
            // Уровень BID (поддержка) защищают ЛИМИТНЫЕ покупатели.
            // Агрессоры для них — это те, кто ПРОДАЕТ по рынку.
            if isMarketSell {
                // Атака: бьют в лимиты продажами
                stats.attackerVolume += trade.quantity
            } else if isMarketBuy {
                // ЗАЩИТА: кто-то выкупает по рынку прямо от уровня
                stats.defenderVolume += trade.quantity
            }
            
        case .ask:
            // Уровень ASK (сопротивление) защищают ЛИМИТНЫЕ продавцы.
            // Агрессоры для них — это те, кто ПОКУПАЕТ по рынку.
            if isMarketBuy {
                // Атака: пытаются пробить покупками
                stats.attackerVolume += trade.quantity
            } else if isMarketSell {
                // ЗАЩИТА: кто-то заливает продажи по рынку, помогая лимитам
                stats.defenderVolume += trade.quantity
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

