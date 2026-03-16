//
//  BounceStrategy.swift
//  TreadingBot
//
//  Created by Igorchela on 19.01.26.
//

import Foundation

actor BounceStrategy: TradingStrategy, Resettable {
    private let (uiStream, uiContinuation) = AsyncStream<StrategyUIState>.makeStream()
    nonisolated var uiEvents: AsyncStream<StrategyUIState> { uiStream }
    
    // MARK: - Константы стратегии
    private enum Constants {
        // Поиск цели
        static let maxClusterAge: TimeInterval      = 60.0
        static let maxDistancePercentForTarget      = 1.0
        static let minStrengthZScoreForTarget       = 2.5
        static let minStrenghtZScoreForEncounter    = 2.5
        
        // Тонкий путь (thin path)
        static let thinPathThreshold = 3.3
        
        // Общая дистанция до кластера
        static let maxDistanceToCluster = 0.01 // 1%
        
        // Волатильность (спуфинг)
        static let volatilitySpikeRadius            = 0.002 // 0.2%
        static let volatilityConcentrationThreshold = 0.4
        static let maxSpreadPercent                 = 0.001 // 0.1%
        
        // Битва
        static let attackerMinVolume          = 0.5
        static let requiredLimitToAttackRatio = 1.5
        static let minRemainingLimitRatio     = 0.3 // 30% от начального объёма
        static let criticalVolumeDropRatio    = 0.4 // 40%
        
        // Стоп-лосс отступ
        static let stopLossOffsetPercent = 0.001 // 0.1%
        
        // Встречный кластер
        static let volumeStabilityThreshold = 0.9
    }
    
    // MARK: - Вспомогательные типы
    struct MonitoringContext {
        let cluster: Cluster
        let startTime: ContinuousClock.Instant
        let initialVolume: Double
        var hasTouched: Bool = false
    }
    
    struct Position {
        let entryPrice: Double
        let sourceClusterId: Double
        let initialVolume: Double
        let side: Side
        var stopLoss: Double
        var monitoringCluster: MonitoringContext? = nil
        var processedClusterIds: Set<Double> = []
    }
    
    enum StrategyState {
        case scanning
        case monitoring(MonitoringContext)
        case positionOpen(Position)
    }
    
    enum EncounterMonitoringResult {
        case continueMonitoring(MonitoringContext)
        case exitPosition
        case stopMonitoring
    }
    
    enum ExpectedOutcome {
        case shouldBeStrong
        case shouldBeWeak
    }
    
    enum BattleOutcome {
        case win
        case lose
        case pending
    }
    
    // MARK: - Свойства
    private var state: StrategyState = .scanning
    
    // MARK: - Протокол TradingStrategy
    func analyze(marketSnapshot: MarketSnapshot) async -> Signal? {
        let targetCluster = findTargetCluster(in: marketSnapshot)
      
        let statusMessage = targetCluster == nil ? "Производится поиск целевого кластера..." : "Целевой кластер найден и отслеживается"
        let newState = StrategyUIState(price: marketSnapshot.currentPrice,
                                       marketStatus: marketSnapshot.state.rawValue,
                                       //strategyState: String(describing: self.state),
                                       asks: formatUIClusters(from: marketSnapshot.clusters, side: .ask),
                                       bids: formatUIClusters(from: marketSnapshot.clusters, side: .bid),
                                       targetCluster: targetCluster.map { targetClusterInfo(cluster: $0) },
                                       statusMessage: statusMessage
        )
        uiContinuation.yield(newState)
        
        switch state {
        case .scanning:
            return await handleScanning(snapshot: marketSnapshot, foundCluster: targetCluster)
        case .monitoring(let context):
            return await handleMonitoring(context: context, snapshot: marketSnapshot)
        case .positionOpen(let position):
            return await handlePositionOpen(position: position, snapshot: marketSnapshot)
        }
    }
    
    func reset() async {
        state = .scanning
    }
    
    // MARK: - Обработка состояний
    private func handleScanning(snapshot: MarketSnapshot, foundCluster: Cluster?) async -> Signal? {
        guard let targetCluster = foundCluster else { return nil }
        let initialVolume = currentVolume(for: targetCluster, in: snapshot.book)
        let context = MonitoringContext(
            cluster: targetCluster,
            startTime: .now,
            initialVolume: initialVolume
        )
        
        logTargetAcquired(targetCluster, initialVolume: initialVolume, marketState: snapshot.state.rawValue)
        state = .monitoring(context)
        return nil
    }
    
    private func handleMonitoring(context: MonitoringContext, snapshot: MarketSnapshot) async -> Signal? {
        var context = context
        let cluster = context.cluster
        
        // 1. Проверка существования кластера
        guard clusterExists(cluster, in: snapshot) else {
            logClusterRemoved(cluster.trackingId)
            await reset()
            return nil
        }
        
        // 2. Базовые условия (дистанция и тонкий путь)
        guard isDistanceAcceptable(price: snapshot.currentPrice, cluster: cluster),
              isThinPath(cluster: cluster) else {
            logBasicConditionsFailed(cluster, price: snapshot.currentPrice)
            await reset()
            return nil
        }
        
        // 3. Проверка пробоя
        if isClusterBroken(cluster, by: snapshot.currentPrice) {
            logBreakthrough(cluster, price: snapshot.currentPrice)
            await reset()
            return nil
        }
        
        // 4. Стабильность объёма
        let volumeStatus = checkVolumeStability(
            cluster: cluster,
            currentVolume: currentVolume(for: cluster, in: snapshot.book),
            initialVolume: context.initialVolume,
            battleStats: snapshot.battleStats[cluster.trackingId]
        )
        switch volumeStatus {
        case .critical:
            logCriticalVolumeDrop(cluster)
            await reset()
            return nil
        case .pause:
            logVolumePause(cluster)
            return nil
        case .ok:
            break
        }
        
        // 5. Фиксация касания
        if !context.hasTouched && didPriceTouchCluster(price: snapshot.currentPrice, cluster: cluster) {
            context.hasTouched = true
            state = .monitoring(context)
            logTouch(cluster, price: snapshot.currentPrice)
        }
        
        guard context.hasTouched else { return nil }
        
        // 6. Защита от спуфинга
        guard await noVolatilitySpike(currentCluster: cluster, price: snapshot.currentPrice, book: snapshot.book) else {
            logVolatilitySpike(cluster)
            await reset()
            return nil
        }
        
        // 7. Анализ битвы
        guard let battleStats = snapshot.battleStats[cluster.trackingId] else {
            logWaitingForBattle(cluster)
            return nil
        }
        
        let battleOutcome = await checkBattleConditions(
            stats: battleStats,
            cluster: cluster,
            book: snapshot.book,
            initialVolume: context.initialVolume
        )
        
        switch battleOutcome {
        case .lose:
            logBattleLost(cluster, stats: battleStats, currentVolume: currentVolume(for: cluster, in: snapshot.book))
            await reset()
            return nil
        case .pending:
            logBattlePending(cluster, stats: battleStats, currentVolume: currentVolume(for: cluster, in: snapshot.book))
            return nil
        case .win:
            break // продолжаем
        }
        
        // 8. Проверка выхода цены из зоны (пружина)
        if isPriceBouncingOff(cluster: cluster, price: snapshot.currentPrice) {
            let position = createPosition(from: cluster, entryPrice: snapshot.currentPrice, context: context)
            logSignalFormed(cluster, position: position, snapshot: snapshot, currentVolume: currentVolume(for: cluster, in: snapshot.book))
            state = .positionOpen(position)
            return (cluster.side == .bid) ? .buy : .sell
        } else {
            logWaitingForBounce(cluster)
            return nil
        }
    }
    
    private func handlePositionOpen(position: Position, snapshot: MarketSnapshot) async -> Signal? {
        var position = position
        let price = snapshot.currentPrice
        
        // 1. Проверка стоп-лосса
        if isStopLossHit(position: position, currentPrice: price) {
            logStopLoss(position, price: price)
            await reset()
            return .exit
        }
        
        // 2. Проверка здоровья исходного кластера
        if let myCluster = snapshot.clusters.first(where: { $0.trackingId == position.sourceClusterId }) {
            let isHealthy = await checkLevelHealth(cluster: myCluster, snapshot: snapshot, initialVol: position.initialVolume)
            if !isHealthy {
                logBackstab(position, price: price)
                await reset()
                return .exit
            }
        }
        
        // 3. Работа с встречными кластерами
        if let monitoringContext = position.monitoringCluster {
            let result = await monitorEncounterCluster(
                context: monitoringContext,
                snapshot: snapshot,
                positionSide: position.side
            )
            
            switch result {
            case .continueMonitoring(let updatedContext):
                position.monitoringCluster = updatedContext
                state = .positionOpen(position)
                return nil
            case .exitPosition:
                await reset()
                return .exit
            case .stopMonitoring:
                position.monitoringCluster = nil
                position.processedClusterIds.insert(monitoringContext.cluster.trackingId)
                state = .positionOpen(position)
                return nil
            }
        } else {
            // Ищем новый встречный кластер
            guard let candidate = findEncounterCluster(in: snapshot, position: position) else {
                return nil
            }
            
            let initialVolume = currentVolume(for: candidate, in: snapshot.book)
            let context = MonitoringContext(
                cluster: candidate,
                startTime: .now,
                initialVolume: initialVolume,
                hasTouched: true
            )
            position.monitoringCluster = context
            state = .positionOpen(position)
            logEncounterMonitoringStarted(candidate)
            return nil
        }
    }
    
    // MARK: - Вспомогательные методы (логика проверок)
    
    private func clusterExists(_ cluster: Cluster, in snapshot: MarketSnapshot) -> Bool {
        snapshot.clusters.contains { $0.trackingId == cluster.trackingId }
    }
    
    private func isClusterBroken(_ cluster: Cluster, by price: Double) -> Bool {
        (cluster.side == .bid && price < cluster.lowerBound) ||
        (cluster.side == .ask && price > cluster.upperBound)
    }
    
    private func isPriceBouncingOff(cluster: Cluster, price: Double) -> Bool {
        (cluster.side == .bid && price > cluster.upperBound) ||
        (cluster.side == .ask && price < cluster.lowerBound)
    }
    
    private func isStopLossHit(position: Position, currentPrice: Double) -> Bool {
        (position.side == .bid && currentPrice <= position.stopLoss) ||
        (position.side == .ask && currentPrice >= position.stopLoss)
    }
    
    private enum VolumeStabilityStatus {
        case ok, pause, critical
    }
    
    private func checkVolumeStability(cluster: Cluster, currentVolume: Double, initialVolume: Double, battleStats: LevelBattleStats?) -> VolumeStabilityStatus {
        let volumeRatio = currentVolume / initialVolume
        guard volumeRatio < Constants.volumeStabilityThreshold else { return .ok }
        
        let attackerVol = battleStats?.attackerVolume ?? 0
        let volumeLost = initialVolume - currentVolume
        
        // Если потери объёма не объясняются атакой (лимитники просто ушли) — считаем это ослаблением
        if attackerVol < volumeLost * 0.5 {
            if volumeRatio < Constants.criticalVolumeDropRatio {
                return .critical
            } else {
                return .pause
            }
        }
        return .ok
    }
    
    private func checkBattleConditions(stats: LevelBattleStats, cluster: Cluster, book: LocalOrderBook, initialVolume: Double) async -> BattleOutcome {
        let attackerVol = stats.attackerVolume
        let defenderVolume = stats.defenderVolume
        let currentLimit = currentVolume(for: cluster, in: book)
        let totalDefensePower = currentLimit + defenderVolume
        
        // Недостаточно атакующих — ждём
        if attackerVol < Constants.attackerMinVolume {
            return .pending
        }
        
        // Лимиты истощены — проигрыш
        let minRequiredLimit = initialVolume * Constants.minRemainingLimitRatio
        if currentLimit < minRequiredLimit {
            return .lose
        }
        
        // Соотношение защиты к атаке
        let armorRatio = totalDefensePower / max(attackerVol, 1.0)
        
        // Если уровень силён (защитники активны) — пропускаем даже при меньшем armour
        if await stats.isStrong {
            return .win
        }
        
        return armorRatio >= Constants.requiredLimitToAttackRatio ? .win : .lose
    }
    
    private func checkLevelHealth(cluster: Cluster, snapshot: MarketSnapshot, initialVol: Double) async -> Bool {
        // Пробой — смерть
        if isClusterBroken(cluster, by: snapshot.currentPrice) {
            return false
        }
        
        // Если есть данные битвы — проверяем исход
        if let stats = snapshot.battleStats[cluster.trackingId] {
            let outcome = await checkBattleConditions(stats: stats, cluster: cluster, book: snapshot.book, initialVolume: initialVol)
            if outcome == .lose {
                return false
            }
        }
        
        return true
    }
    
    // MARK: - Встречные кластеры
    
    private func findEncounterCluster(in snapshot: MarketSnapshot, position: Position) -> Cluster? {
        let currentPrice = snapshot.currentPrice
        return snapshot.clusters
            .filter { cluster in
                let isClose = cluster.distancePercent < Constants.maxDistancePercentForTarget
                let isStrong = cluster.strengthZScore > Constants.minStrenghtZScoreForEncounter
                
                let isNotTarget = cluster.trackingId != position.sourceClusterId
                let isProcessed = !position.processedClusterIds.contains(cluster.trackingId)
                let isTouchCluster = didPriceTouchCluster(price: currentPrice, cluster: cluster)
                return isClose && isStrong && isNotTarget && isProcessed && isTouchCluster
            }
            .min { abs($0.price - currentPrice) < abs($1.price - currentPrice) }
    }
    
    private func monitorEncounterCluster(context: MonitoringContext, snapshot: MarketSnapshot, positionSide: Side) async -> EncounterMonitoringResult {
        let cluster = context.cluster
        let currentPrice = snapshot.currentPrice
        
        // Проверка существования
        guard clusterExists(cluster, in: snapshot) else {
            logEncounterClusterRemoved(cluster.trackingId)
            return .stopMonitoring
        }
        
        // Базовые условия
        guard isDistanceAcceptable(price: currentPrice, cluster: cluster),
              isThinPath(cluster: cluster) else {
            logEncounterBasicConditionsFailed(cluster)
            return .exitPosition
        }
        
        // Пробой в нежелательную сторону
        if isClusterBroken(cluster, by: currentPrice) {
            logEncounterBreakthrough(cluster)
            return .exitPosition
        }
        
        // Стабильность объёма
        let currentVol = currentVolume(for: cluster, in: snapshot.book)
        let volumeRatio = currentVol / context.initialVolume
        let expected = expectedBattleOutcome(for: cluster, positionSide: positionSide)
        
        if volumeRatio < Constants.volumeStabilityThreshold {
            let stats = snapshot.battleStats[cluster.trackingId]
            let attackerVol = stats?.attackerVolume ?? 0
            let volumeLost = context.initialVolume - currentVol
            
            // Аналогичная логика: если объём упал без атаки
            if attackerVol < volumeLost * 0.5 {
                if volumeRatio < Constants.criticalVolumeDropRatio {
                    if expected == .shouldBeStrong {
                        logEncounterCriticalDrop(cluster)
                        return .exitPosition
                    } else {
                        logEncounterCriticalDropButExpectedWeak(cluster)
                        // Продолжаем, т.к. это помогает пробою
                    }
                } else {
                    logEncounterVolumePause(cluster)
                    return .continueMonitoring(context)
                }
            }
        }
        
        // Защита от спуфинга
        guard await noVolatilitySpike(currentCluster: cluster, price: currentPrice, book: snapshot.book) else {
            logEncounterVolatilitySpike(cluster)
            return .exitPosition
        }
        
        // Анализ битвы
        guard let battleStats = snapshot.battleStats[cluster.trackingId] else {
            logEncounterWaitingForBattle(cluster)
            return .continueMonitoring(context)
        }
        
        let battleOutcome = await checkBattleConditions(stats: battleStats, cluster: cluster, book: snapshot.book, initialVolume: context.initialVolume)
        let isExpected = (battleOutcome == .win) == (expected == .shouldBeStrong)
        
        if !isExpected {
            logEncounterBattleUnexpected(cluster)
            return .exitPosition
        }
        
        // Проверка выхода в сторону позиции
        let isMovingInFavor = (positionSide == .bid && currentPrice > cluster.upperBound) ||
                              (positionSide == .ask && currentPrice < cluster.lowerBound)
        if isMovingInFavor {
            logEncounterMovedInFavor(cluster)
            return .stopMonitoring
        }
        
        return .continueMonitoring(context)
    }
    
    private func expectedBattleOutcome(for cluster: Cluster, positionSide: Side) -> ExpectedOutcome {
        switch (positionSide, cluster.side) {
        case (.bid, .ask), (.ask, .bid): return .shouldBeWeak
        case (.bid, .bid), (.ask, .ask): return .shouldBeStrong
        }
    }
    
    // MARK: - Поиск цели
    
    private func findTargetCluster(in snapshot: MarketSnapshot) -> Cluster? {
        let currentPrice = snapshot.currentPrice
        return snapshot.clusters
            .filter { cluster in
                let isValidDirection = cluster.side == .bid
                    ? currentPrice > cluster.upperBound
                    : currentPrice < cluster.lowerBound
                guard isValidDirection else { return false }
                
                let age = Date().timeIntervalSince(snapshot.battleStats[cluster.trackingId]?.firstSeen ?? Date())
                let isOld = age > Constants.maxClusterAge
                let isClose = cluster.distancePercent < Constants.maxDistancePercentForTarget
                let isStrong = cluster.strengthZScore > Constants.minStrengthZScoreForTarget
                
                return isOld && isClose && isStrong
            }
            .min { $0.distancePercent < $1.distancePercent }
    }
    
    // MARK: - Утилиты
    
    private func currentVolume(for cluster: Cluster, in book: LocalOrderBook) -> Double {
        switch cluster.side {
        case .bid:
            return book.bids
                .filter { $0.price >= cluster.lowerBound && $0.price <= cluster.upperBound }
                .reduce(0) { $0 + $1.quantity }
        case .ask:
            return book.asks
                .filter { $0.price >= cluster.lowerBound && $0.price <= cluster.upperBound }
                .reduce(0) { $0 + $1.quantity }
        }
    }
    
    private func isThinPath(cluster: Cluster) -> Bool {
        cluster.cumulativeVolume < cluster.totalVolume * Constants.thinPathThreshold
    }
    
    private func didPriceTouchCluster(price: Double, cluster: Cluster) -> Bool {
        switch cluster.side {
        case .bid: return price <= cluster.upperBound
        case .ask: return price >= cluster.lowerBound
        }
    }
    
    private func isDistanceAcceptable(price: Double, cluster: Cluster) -> Bool {
        let distance = abs(cluster.price - price) / price
        return distance <= Constants.maxDistanceToCluster
    }
    
    private func createPosition(from cluster: Cluster, entryPrice: Double, context: MonitoringContext) -> Position {
        let offset = entryPrice * Constants.stopLossOffsetPercent
        let stopLoss = cluster.side == .bid
            ? cluster.lowerBound - offset
            : cluster.upperBound + offset
        
        return Position(
            entryPrice: entryPrice,
            sourceClusterId: cluster.trackingId,
            initialVolume: context.initialVolume,
            side: cluster.side,
            stopLoss: stopLoss
        )
    }
    
    private func noVolatilitySpike(currentCluster: Cluster, price: Double, book: LocalOrderBook) async -> Bool {
        // Концентрация объёма в радиусе кластера
        let clusterLevels = (book.bids + book.asks).filter { level in
            abs(level.price - currentCluster.price) / currentCluster.price < Constants.volatilitySpikeRadius
        }
        let clusterVolume = clusterLevels.reduce(0) { $0 + $1.quantity }
        let totalVolume = book.bids.reduce(0) { $0 + $1.quantity } + book.asks.reduce(0) { $0 + $1.quantity }
        let concentration = totalVolume > 0 ? clusterVolume / totalVolume : 0
        let suddenConcentration = concentration > Constants.volatilityConcentrationThreshold
        
        // Аномальный спред
        guard let bestAsk = await book.bestAsk, let bestBid = await book.bestBid else {
            return true
        }
        let spread = bestAsk.price - bestBid.price
        let spreadPercent = spread / price
        let spreadSpike = spreadPercent > Constants.maxSpreadPercent
        
        return !suddenConcentration && !spreadSpike
    }
    
    // MARK: - Логирование (все принты вынесены, чтобы не загромождать логику)
    private func logTargetAcquired(_ cluster: Cluster, initialVolume: Double, marketState: String) {
        print("""
        🎯 Цель захвачена:
        ID: \(cluster.trackingId)
        Границы: \(cluster.lowerBound) ... \(cluster.upperBound)
        Дистанция: \(cluster.distancePercent)%
        Сторона: \(cluster.side)
        Сила (Z‑score): \(cluster.strengthZScore)
        Начальный объем: \(initialVolume) BTC
        Состояния рынка \(marketState)
        """)
    }
    
    private func logClusterRemoved(_ id: Double) {
        print("❌ [\(id)] Цель удалена из списка активных кластеров")
    }
    
    private func logBasicConditionsFailed(_ cluster: Cluster, price: Double) {
        print("❌ [\(cluster.trackingId)] Базовые условия нарушены (Цена: \(price) | ThinPath: \(isThinPath(cluster: cluster)))")
    }
    
    private func logBreakthrough(_ cluster: Cluster, price: Double) {
        let bound = cluster.side == .bid ? cluster.lowerBound : cluster.upperBound
        print("💀 [\(cluster.trackingId)] ПРОБОЙ! Цена \(price) прошила уровень \(bound)")
    }
    
    private func logCriticalVolumeDrop(_ cluster: Cluster) {
        print("💥 [\(cluster.trackingId)] КРИТИЧЕСКИЙ СБРОС ОБЪЁМА")
    }
    
    private func logVolumePause(_ cluster: Cluster) {
        print("⏳ [\(cluster.trackingId)] ПАУЗА: объём мерцает")
    }
    
    private func logTouch(_ cluster: Cluster, price: Double) {
        print("🎯 [\(cluster.trackingId)] КАСАНИЕ! Цена \(price) вошла в зону уровня.")
    }
    
    private func logVolatilitySpike(_ cluster: Cluster) {
        print("⚠️ [\(cluster.trackingId)] Обнаружен всплеск волатильности (спуфинг)")
    }
    
    private func logWaitingForBattle(_ cluster: Cluster) {
        print("⚔️ [\(cluster.trackingId)] Ждём первых рыночных ударов...")
    }
    
    private func logBattleLost(_ cluster: Cluster, stats: LevelBattleStats, currentVolume: Double) {
        print("🚩 [\(cluster.trackingId)] БИТВА ПРОИГРАНА: Агрессоры (\(stats.attackerVolume) BTC) > лимиты (\(currentVolume) BTC)")
    }
    
    private func logBattlePending(_ cluster: Cluster, stats: LevelBattleStats, currentVolume: Double) {
        print("⚔️ [\(cluster.trackingId)] Идет борьба... Агрессия: \(stats.attackerVolume) BTC | Лимиты: \(currentVolume) BTC")
    }
    
    private func logWaitingForBounce(_ cluster: Cluster) {
        print("🛡️ [\(cluster.trackingId)] Лимиты устояли! Ждём выхода цены из зоны...")
    }
    
    private func logSignalFormed(_ cluster: Cluster, position: Position, snapshot: MarketSnapshot, currentVolume: Double) {
        let timeString = Date().formatted(date: .omitted, time: .standard)
        print("""
        🚀🚀🚀 [\(cluster.trackingId)] СИГНАЛ СФОРМИРОВАН!
        Состояния рынка \(snapshot.state)
        Сторона: \(cluster.side)
        Позиция открыта по цене \(position.entryPrice) в \(timeString)
        Итоговый объем кластера: \(currentVolume)
        Объем поглощенной атаки: \(snapshot.battleStats[cluster.trackingId]?.attackerVolume ?? 0)
        """)
    }
    
    private func logStopLoss(_ position: Position, price: Double) {
        print("🛑 [STOP LOSS] Позиция закрыта по цене \(price). Убыток зафиксирован.")
    }
    
    private func logBackstab(_ position: Position, price: Double) {
        let timeString = Date().formatted(date: .omitted, time: .standard)
        print("🧨 [BACKSTAB] Наш защитный уровень ослаб. Закрываемся по цене \(price) в \(timeString)")
    }
    
    private func logEncounterMonitoringStarted(_ cluster: Cluster) {
        print("🔄 [\(cluster.trackingId)] Начат мониторинг встречного кластера.")
    }
    
    private func logEncounterClusterRemoved(_ id: Double) {
        print("❌ [\(id)] Встречный кластер исчез")
    }
    
    private func logEncounterBasicConditionsFailed(_ cluster: Cluster) {
        print("❌ [\(cluster.trackingId)] Базовые условия нарушены для встречного кластера")
    }
    
    private func logEncounterBreakthrough(_ cluster: Cluster) {
        print("💀 [\(cluster.trackingId)] Встречный кластер пробит в нежелательную сторону. Выход.")
    }
    
    private func logEncounterCriticalDrop(_ cluster: Cluster) {
        print("💥 [\(cluster.trackingId)] Критический сброс объёма на встречном кластере (ожидалась сила). Выход.")
    }
    
    private func logEncounterCriticalDropButExpectedWeak(_ cluster: Cluster) {
        print("📉 [\(cluster.trackingId)] Критический сброс объёма (помогает пробою). Продолжаем.")
    }
    
    private func logEncounterVolumePause(_ cluster: Cluster) {
        print("⏳ [\(cluster.trackingId)] Пауза: объём мерцает на встречном кластере")
    }
    
    private func logEncounterVolatilitySpike(_ cluster: Cluster) {
        print("⚠️ [\(cluster.trackingId)] Обнаружен всплеск волатильности на встречном кластере. Выход.")
    }
    
    private func logEncounterWaitingForBattle(_ cluster: Cluster) {
        print("⚔️ [\(cluster.trackingId)] Ждём первых рыночных ударов во встречный кластер...")
    }
    
    private func logEncounterBattleUnexpected(_ cluster: Cluster) {
        print("🚩 [\(cluster.trackingId)] Битва на встречном кластере идёт против ожиданий. Выход.")
    }
    
    private func logEncounterMovedInFavor(_ cluster: Cluster) {
        print("✅ [\(cluster.trackingId)] Цена вышла из встречного кластера в сторону позиции. Продолжаем.")
    }
    
    
    private func formatUIClusters(from clusters: [Cluster], side: Side) -> [ClusterRow] {
        // 1. Фильтруем: нужная сторона + сила > 2.5
        let filtered = clusters.filter {
            $0.side == side && $0.strengthZScore > 2.5
        }
        
        // 3. Сортируем (ASK — по возрастанию цены, BID — по убыванию)
        let sorted = side == .ask
            ? filtered.sorted { $0.price < $1.price }
            : filtered.sorted { $0.price > $1.price }

        // 4. Превращаем в UI-модели
        return sorted.prefix(5).map { cluster in
            ClusterRow(id: cluster.id,
                       price: cluster.price,
                       volume: cluster.totalVolume,
                       power: cluster.strengthZScore,
                       distancePercent: cluster.distancePercent)
        }
    }
    
    
    private func targetClusterInfo(cluster: Cluster) -> TargetClusterInfo {
        return TargetClusterInfo(id: cluster.id,
                                 lowerBound: cluster.lowerBound,
                                 upperBound: cluster.upperBound,
                                 type: String(describing: cluster.side),
                                 volume: cluster.totalVolume,
                                 power: cluster.strengthZScore)
    }
}
