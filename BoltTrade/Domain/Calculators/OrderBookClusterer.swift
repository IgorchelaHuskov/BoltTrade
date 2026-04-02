//
//  OrderBookClusterer.swift
//  TreadingBot
//
//  Created by Igorchela on 1.02.26.
//

import Foundation

actor OrderBookClusterer {
    private var previousClusters: [Double: Cluster] = [:]
    private var clusterBirthdays: [Double: Date] = [:]
    private let maturityTime: TimeInterval = 60.0 // 1 минута для полного доверия уровню
    
    // Для консистентного отслеживания
    private let trackingBinSize: Double = 100.0
    private var trackingHistory: [Double: TrackingInfo] = [:]
    
    private enum Constants {
        static let minOrderSize: Double = 0.001
        static let distanceThreshold: Double = 0.02
        static let significantMoveThreshold: Double = 0.1
        static let timeWeightInitial: Double = 0.2
        static let timeWeightGrowthFactor: Double = 0.8
        static let flipThreshold: Double = 3.0
        static let insidePressureBoost: Double = 0.5
        static let maxTrackingAge: TimeInterval = 300 // 5 минут
        static let minMaturityForOutput: TimeInterval = 15.0 // 15 секунд минимальный возраст
    }
    
    private struct TrackingInfo {
        let originalClusterId: Double
        let firstDetected: Date
        var lastUpdated: Date
        var currentClusterId: Double?
        var highestStrength: Double
    }
    
    
    func clusterOrderBook(localOrderBook: LocalOrderBook,
                          binSizeAbs: Double,
                          currentPrice: Double,
                          marketState: MarketStateAnalyzer.MarketState = .unknown,
                          configs: [MarketStateAnalyzer.MarketState: MarketConfig]) -> [Cluster] {
        
        guard binSizeAbs > 0 else { return [] }
        
        // 1. Агрегация ордеров
        let (clusterDict, totalBidVol, totalAskVol) = aggregateOrderBook(localOrderBook: localOrderBook, binSizeAbs: binSizeAbs)
        
        // 2. Получение конфигурации и статистики
        guard let config = configs[marketState] ?? configs[.flat] else { return [] }
        let bidStats = calculateStats(clusterDict.values.map { $0.bid }.filter { $0 > 0 })
        let askStats = calculateStats(clusterDict.values.map { $0.ask }.filter { $0 > 0 })
        
        // 3. Создание кластеров
        let clusters = createClusters(clusterDict: clusterDict,
                                      binSizeAbs: binSizeAbs,
                                      currentPrice: currentPrice,
                                      totalBidVol: totalBidVol,
                                      totalAskVol: totalAskVol,
                                      config: config,
                                      bidStats: bidStats,
                                      askStats: askStats)
        // 4. Обеспечение консистентности ID
        let consistentClusters = ensureConsistentTracking(rawClusters: clusters, binSizeAbs: binSizeAbs)
        
        // 4. Обновление памяти
        updateMemory(currentClusters: consistentClusters)
        
        // 5. Cортировка
        let sortedCluster = consistentClusters.sorted { $0.strengthZScore > $1.strengthZScore }
        return sortedCluster
    }
    
    
    // MARK: - Aggregation
    private func aggregateOrderBook(localOrderBook: LocalOrderBook,
                                    binSizeAbs: Double) -> (clusterDict: [Double: (bid: Double, ask: Double)],
                                                            totalBidVol: Double, totalAskVol: Double) {
        var clusterDict: [Double : (bid: Double, ask: Double)] = [:]
        var totalBidVol = 0.0
        var totalAskVol = 0.0
        
        for ask in localOrderBook.asks where ask.quantity >= Constants.minOrderSize {
            let binLow = floor(ask.price / binSizeAbs) * binSizeAbs
            clusterDict[binLow, default: (0, 0)].ask += ask.quantity
            totalAskVol += ask.quantity
        }
        
        for bid in localOrderBook.bids where bid.quantity >= Constants.minOrderSize {
            let binLow = floor(bid.price / binSizeAbs) * binSizeAbs
            clusterDict[binLow, default: (0, 0)].bid += bid.quantity
            totalBidVol += bid.quantity
        }
        
        return (clusterDict, totalBidVol, totalAskVol)
    }
    
    
    // MARK: - Cluster Creation
    private func createClusters( clusterDict: [Double: (bid: Double, ask: Double)],
                                 binSizeAbs: Double,
                                 currentPrice: Double,
                                 totalBidVol: Double,
                                 totalAskVol: Double,
                                 config: MarketConfig,
                                 bidStats: (mean: Double, stdev: Double),
                                 askStats: (mean: Double, stdev: Double) ) -> [Cluster] {
        
        clusterDict.compactMap { (binLow, volumes) -> Cluster? in
            let isPriceInside = currentPrice >= binLow && currentPrice <= (binLow + binSizeAbs)
            
            /*// 1. Определяем сторону (Side) с учетом истории
            let sideResult = determineSide(binLow: binLow, bidVol: volumes.bid, askVol: volumes.ask)
            let side = sideResult.side
             */
            // 1. Определяем сторону (Side) строго по географии относительно цены
            let clusterMidPrice = binLow + binSizeAbs / 2.0
            let side: Side = clusterMidPrice < currentPrice ? .bid : .ask
            
            // 2. Расчеты метрик и создание Cluster .
            let dominantVol = isPriceInside ? (volumes.bid + volumes.ask) : (side == .bid ? volumes.bid : volumes.ask) // Считаем доминанту (если цена внутри — берем суммарный вес "битвы")
            let totalSideVol = side == .bid ? totalBidVol : totalAskVol
            let volumeShare = (dominantVol / totalSideVol) * 100
            
            let stats = side == .bid ? bidStats : askStats
            let zScore = stats.stdev > 0 ? max(0, (dominantVol - stats.mean) / stats.stdev) : 0
            let rawPressure = (volumes.bid + volumes.ask) > 0 ? abs(volumes.bid - volumes.ask) / (volumes.bid + volumes.ask) : 0
            
            // --- ВРЕМЕННОЙ ВЕС (Time-Weighted) ---
            let trustFactor = calculateTimeWeight(binLow: binLow, isPriceInside: isPriceInside, volumeShare: volumeShare, threshold: config.coefficient * 0.5)
            
            // --- ПАРАМЕТРЫ ВЫЖИВАНИЯ ---
            let effectivePressure = isPriceInside ? max(rawPressure, Constants.insidePressureBoost) : rawPressure

            
            // Итоговая сила с учетом времени и близости цены
            let strength = zScore * effectivePressure * (volumeShare / 100.0) * trustFactor * (isPriceInside ? 2.0 : 1.0)
            
            // Глубины Рынка (Market Depth)
            let cumulativeVolume = calculateCumulativeVolume(for: binLow, side: side, in: clusterDict, totalVol: totalSideVol)
            
            // средняя цена кластера
            let clusterPrice = binLow + binSizeAbs / 2.0
            
            return Cluster(id: binLow,
                           price: clusterPrice,
                           totalVolume: dominantVol,
                           strength: strength,
                           strengthZScore: zScore,
                           distancePercent: abs(clusterPrice - currentPrice) / currentPrice * 100,
                           side: side,
                           cumulativeVolume: cumulativeVolume,
                           volumeShare: volumeShare,
                           binSize: binSizeAbs,
                           lowerBound: binLow,
                           upperBound: binLow + binSizeAbs
            )
        }
    }
    
    
    // MARK: - Memory Management
    // МЕТОД: Очистка старых данных
    private func updateMemory(currentClusters: [Cluster]) {
        var newCache: [Double: Cluster] = [:]
        let currentIds = Set(currentClusters.map { $0.id })
        
        for c in currentClusters {
            newCache[c.id] = c
        }
        
        self.previousClusters = newCache
        self.clusterBirthdays = self.clusterBirthdays.filter {
            currentIds.contains($0.key)
        }
    }
    
    
    // MARK: - Consistent Tracking
    private func ensureConsistentTracking(rawClusters: [Cluster], binSizeAbs: Double) -> [Cluster] {
        let now = Date()
        var trackingMap: [Double: Cluster] = [:]  // trackingId -> объединённый кластер

        for var cluster in rawClusters {
            // Вычисляем базовый trackingId (округление до 100.0)
            let trackingId = calculateTrackingId(for: cluster.price, trackingBinSize: 100.0)
            
            // Поиск существующих trackingId в радиусе
            let nearbyHistory = findNearbyTrackingHistory(targetId: trackingId, radius: trackingBinSize * 1.5)
            let finalTrackingID: Double
            if let existing = nearbyHistory.first, abs(existing.key - trackingId) <= trackingBinSize * 1.5 {
                finalTrackingID = existing.key
            } else {
                finalTrackingID = trackingId
            }
            
            cluster.trackingId = finalTrackingID
            
            // Обновляем историю отслеживания
            updateTrackingHistory(for: finalTrackingID, cluster: cluster, now: now)
            
            // Группировка по trackingId – объединяем или оставляем сильнейший
            if let existingCluster = trackingMap[finalTrackingID] {
                // Выбираем кластер с максимальной силой
                if cluster.strength > existingCluster.strength {
                    trackingMap[finalTrackingID] = cluster
                }
                // При необходимости можно объединять объёмы, но для простоты оставляем сильнейший
            } else {
                trackingMap[finalTrackingID] = cluster
            }
        }
        
        cleanupOldTrackingHistory(currentTime: now)
        return Array(trackingMap.values)
    }
    
    
    private func calculateTrackingId(for price: Double, trackingBinSize: Double) -> Double {
        // Округляем до ближайшего trackingBinSize
        return (price / trackingBinSize).rounded() * trackingBinSize
    }
    
    
    // МЕТОД поиска по радиусу
    private func findNearbyTrackingHistory(targetId: Double, radius: Double) -> [Double: TrackingInfo] {
        let now = Date()
        return trackingHistory.filter { trackingId, info in
            now.timeIntervalSince(info.lastUpdated) < Constants.maxTrackingAge &&
            abs(trackingId - targetId) <= radius
        }
    }

    
    private func updateTrackingHistory(for trackingId: Double, cluster: Cluster, now: Date) {
        if var info = trackingHistory[trackingId] {
            // СУЩЕСТВУЕТ → обновляем
            info.lastUpdated = now
            info.currentClusterId = cluster.id
            info.highestStrength = max(info.highestStrength, cluster.strengthZScore)
            trackingHistory[trackingId] = info
        } else {
            // НОВЫЙ trackingId
            trackingHistory[trackingId] = TrackingInfo(
                originalClusterId: cluster.id,
                firstDetected: now,
                lastUpdated: now,
                currentClusterId: cluster.id,
                highestStrength: cluster.strengthZScore
            )
        }
    }

    
        
    private func cleanupOldTrackingHistory(currentTime: Date) {
        trackingHistory = trackingHistory.filter { _, info in
            currentTime.timeIntervalSince(info.lastUpdated) <= Constants.maxTrackingAge
        }
    }
    
    
    // MARK: - Helper Methods
    private func calculateStats(_ data: [Double]) -> (mean: Double, stdev: Double) {
        guard !data.isEmpty else { return (0, 0) }
        let mean = data.reduce(0, +) / Double(data.count)
        let vSum = data.reduce(0) { $0 + pow($1 - mean, 2) }
        return (mean, sqrt(vSum / Double(data.count)))
    }
    
    
    // Определяет сторону кластера с защитой от "дребезга" (гистерезис)
    private func determineSide(binLow: Double, bidVol: Double, askVol: Double) -> (side: Side, isFlipped: Bool) {
        // Получаем сторону из предыдущего кадра (если она была)
        guard let previousSide = previousClusters[binLow]?.side else {
            // Если кластер новый — просто берем того, кто сильнее
            return (bidVol > askVol ? .bid : .ask, false)
        }
        
        let ratio = max(bidVol, askVol) / max(min(bidVol, askVol), 0.001)
        return (ratio > 4.0 ? (bidVol > askVol ? .bid : .ask) : previousSide, ratio > 4.0)
    }
    
    
    // МЕТОД: Расчет зрелости кластера
    private func calculateTimeWeight(binLow: Double, isPriceInside: Bool, volumeShare: Double, threshold: Double) -> Double {
        let now = Date()
        
        // УСИЛЕННАЯ ПРОВЕРКА: +50% к порогу для начала отсчета
        let activationThreshold = threshold * 1.5
        
        if volumeShare > activationThreshold {
            if clusterBirthdays[binLow] == nil {
                clusterBirthdays[binLow] = now
            }
        } else {
            clusterBirthdays.removeValue(forKey: binLow)
            return 0.1
        }
        
        if isPriceInside {
            // Даже при цене внутри - минимальное доверие 0.3 для новых кластеров
            guard let birthday = clusterBirthdays[binLow] else { return 0.3 }
            let age = now.timeIntervalSince(birthday)
            if age < Constants.minMaturityForOutput {
                return 0.3 + (age / Constants.minMaturityForOutput) * 0.3
            }
            return 1.0
        }
        
        guard let birthday = clusterBirthdays[binLow] else {
            return Constants.timeWeightInitial
        }
        
        let age = now.timeIntervalSince(birthday)
        
        // УСИЛЕНИЕ: Медленнее рост доверия для новых кластеров
        if age < Constants.minMaturityForOutput {
            return Constants.timeWeightInitial
        }
        
        return min(1.0, Constants.timeWeightInitial + (age / maturityTime) * Constants.timeWeightGrowthFactor)
    }
    
    
    //  Метод: Определения Глубины Рынка (Market Depth)
    private func calculateCumulativeVolume(for targetBin: Double,
                                           side: Side,
                                           in dict: [Double: (bid: Double, ask: Double)],
                                           totalVol: Double) -> Double {
        var cumVol = 0.0
        
        for (binPrice, volumes) in dict {
            // Кумулятив для bid (все уровни ≤ target)
            if side == .bid && binPrice <= targetBin {
                cumVol += volumes.bid
            }
            // Кумулятив для ask (все уровни ≥ target)
            else if side == .ask && binPrice >= targetBin {
                cumVol += volumes.ask
            }
        }
        
        return totalVol > 0 ? cumVol / totalVol * 100 : 0  // % от общего объёма
    }
}
