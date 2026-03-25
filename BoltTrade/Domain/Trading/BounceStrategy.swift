//
//  BounceStrategy.swift
//  TreadingBot
//
//  Created by Igorchela on 19.01.26.
//

import Foundation

actor BounceStrategy: TradingStrategy, Resettable {
    // MARK: - Свойства
    private var state: StrategyState = .scanning
    private var tradeHistory: [TradeHistoryItem] = []
    
    //MARK: UI
    private let (uiStream, uiContinuation) = AsyncStream<StrategyUIState>.makeStream()
    nonisolated var uiEvents: AsyncStream<StrategyUIState> { uiStream }
    
    // MARK: - Константы стратегии
    private enum Constants {
        // Поиск цели
        static let maxClusterAge: TimeInterval = 180.0     // 3 минуты (даем уровню настояться)
        static let maxDistancePercentForTarget = 0.5       // (0.5%) - отлично
        static let minStrengthZScoreForTarget  = 0.0       // золотая середина аномальности
        static let minFinalStrength            = 0.0       // видим "кирпичные стены", а не только "бетон"
        
        // Тонкий путь (thin path)
        static let thinPathThreshold = 3.3
        
        // Общая дистанция до кластера
        static let maxDistanceToCluster = 0.01
        
        // Волатильность (спуфинг)
        static let volatilitySpikeRadius            = 0.002 // 0.2%
        static let volatilityConcentrationThreshold = 0.4
        static let maxSpreadPercent                 = 0.001 // 0.1%
        
        // Битва
        static let attackerMinVolume          = 1.0
        static let requiredLimitToAttackRatio = 4.0
        static let minRemainingLimitRatio     = 0.6 // 40% от начального объёма
        static let criticalVolumeDropRatio    = 0.4 // 40%
        static let refillSignificanceThreshold: Double = 0.3  // для значимости рефилла  30% от начального объёма
        static let refillBonusMultiplier: Double = 0.7        // снижаем требования на 30% при рефилле
        
        // Стоп-лосс отступ
        static let stopLossOffsetPercent = 0.001 // 0.1%
        
        // Встречный кластер
        static let volumeStabilityThreshold      = 0.9
        static let minStrenghtZScoreForEncounter = 2.2
        
        // Трейлинг-стоп
        static let totalCosts               = 0.0011   // 0.11% (комиссии + спред)
        static let breakEvenActivation      = 0.0015    // 0.2%
        static let trailingStepPercent      = 0.002    // 1%
        static let minStopMoveRelative      = 0.1      // 10% от шага
        static let defaultLeverage          = 50       // кредитное плечо
        
        // UI
        static let uiMinStrengthZScore      = 3.0
        static let uiMinStrength            = 0.1
        
        // ... другие константы
        static let confirmationSamplesCount = 10 // для замер среднего обьема
        
        // Пороги скорости подхода (% в секунду)
        static let mediumVelocityThreshold: Double = 0.2   // > 0.2%/с - средняя скорость
        static let highVelocityThreshold: Double = 0.5     // > 0.5%/с - высокая скорость
        
        // Гистерезис
        static let tickSize: Double = 0.1           // минимальный шаг цены (можно получать из market data)
        static let hysteresisTicks: Int = 2         // сколько тиков отступа
    }
    
    private enum VolumeStabilityStatus {
        case ok, pause, critical
    }
    
    // MARK: - Вспомогательные типы
    struct MonitoringContext {
        let cluster: Cluster
        let startTime: ContinuousClock.Instant
        var initialVolume: Double
        var hasTouched: Bool = false
        var totalRefilledVolume: Double = 0
        var volumeSamples: [Double] = []
        var isConfirmed: Bool = false
        let firstSeenAt: ContinuousClock.Instant
        let firstSeenPrice: Double
    }
    
    struct Position {
        let entryPrice: Double
        let sourceClusterId: Double
        let initialVolume: Double
        let power: Double
        let side: Side
        var stopLoss: Double
        let entryLowerBound: Double
        let entryUpperBound: Double
        var monitoringCluster: MonitoringContext? = nil
        var processedClusterIds: Set<Double> = []
        let sourceClusterStartTime: ContinuousClock.Instant
        let openTime: Date
        let leverage: Double
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
    
    // MARK: - Протокол TradingStrategy
    func analyze(marketSnapshot: MarketSnapshot) async -> Signal? {
        // 1. Сначала ищем потенциальный кластер
        let foundCluster = findTargetCluster(in: marketSnapshot)
        
        // 2. ВЫПОЛНЯЕМ ЛОГИКУ (переключаем стейты)
        let signal: Signal?
        switch state {
        case .scanning:
            signal = await handleScanning(snapshot: marketSnapshot, foundCluster: foundCluster)
        case .monitoring(let context):
            signal = await handleMonitoring(context: context, snapshot: marketSnapshot)
        case .positionOpen(let position):
            signal = await handlePositionOpen(position: position, snapshot: marketSnapshot)
        }
        
        // 3.ОБНОВЛЯЕМ UI (на основе уже нового состояния)
        updateUI(snapshot: marketSnapshot, targetCluster: foundCluster)
        
        return signal
    }

    func reset() async {
        state = .scanning
    }
    
    // MARK: - Обработка состояний
    private func handleScanning(snapshot: MarketSnapshot, foundCluster: Cluster?) async -> Signal? {
        guard let targetCluster = foundCluster else { return nil }
        let firstVolume = currentVolume(for: targetCluster, in: snapshot.book)
        let context = MonitoringContext(
                    cluster: targetCluster,
                    startTime: .now,
                    initialVolume: firstVolume,
                    volumeSamples: [firstVolume],
                    isConfirmed: false,
                    firstSeenAt: .now,
                    firstSeenPrice: snapshot.currentPrice
                )
        
        logTargetAcquired(targetCluster, initialVolume: firstVolume, marketState: snapshot.state.rawValue)
        state = .monitoring(context)
        return nil
    }
    
    private func handleMonitoring(context: MonitoringContext, snapshot: MarketSnapshot) async -> Signal? {
        var context = context
        let cluster = context.cluster
        
        // 1. подтверждения обьема
        if !context.isConfirmed {
            log("📊 [\(cluster.trackingId)] Фаза подтверждения, собрано замеров: \(context.volumeSamples.count)")
            
            // Проверяем, существует ли кластер
            guard clusterExists(cluster, in: snapshot) else {
                log("❌ [\(cluster.trackingId)] Кластер исчез до подтверждения объёма")
                await reset()
                return nil
            }
            
            // Проверяем, не ушла ли цена слишком далеко
            let distance = abs(snapshot.currentPrice - cluster.price) / cluster.price
            if distance > Constants.maxDistanceToCluster * 2 {
                log("❌ [\(cluster.trackingId)] Цена ушла далеко от кластера, отменяем мониторинг")
                await reset()
                return nil
            }
            
            // Собираем замеры объёма
            let currentVol = currentVolume(for: cluster, in: snapshot.book)
            var newSamples = context.volumeSamples
            newSamples.append(currentVol)
            context.volumeSamples = newSamples
            
            // Проверяем, набрали ли достаточно замеров
            if newSamples.count >= Constants.confirmationSamplesCount {
                // Усредняем
                let totalVolume = newSamples.reduce(0, +)
                let avgVolume = totalVolume / Double(newSamples.count)
                context.initialVolume = avgVolume
                context.isConfirmed = true
                context.volumeSamples = []
                
                log("✅ [\(cluster.trackingId)] Объём подтверждён! Среднее значение: \(avgVolume)")
                
                // ОБНОВЛЯЕМ СОСТОЯНИЕ с подтверждённым контекстом
                state = .monitoring(context)
                // Продолжаем выполнение в основную логику
            } else {
                // Ещё не набрали, сохраняем и выходим
                state = .monitoring(context)
                return nil
            }
        }
        
        // 2. Проверка существования кластера
        guard clusterExists(cluster, in: snapshot) else {
            logClusterRemoved(cluster.trackingId)
            await reset()
            return nil
        }
        
        // 3. Базовые условия (дистанция и тонкий путь)
        guard isDistanceAcceptable(price: snapshot.currentPrice, cluster: cluster),
              isThinPath(cluster: cluster) else {
            logBasicConditionsFailed(cluster, price: snapshot.currentPrice)
            await reset()
            return nil
        }
        
        // 4. Проверка пробоя
        if isClusterBroken(cluster, by: snapshot.currentPrice) {
            logBreakthrough(cluster, price: snapshot.currentPrice)
            await reset()
            return nil
        }
        
        // 5. РАСЧЁТ РЕФИЛЛА
        let currentVol = currentVolume(for: cluster, in: snapshot.book)
        let volumeDecrease = max(0, context.initialVolume - currentVol)
        let actualMarketHit = await snapshot.battleStats[cluster.trackingId]?.recentAttackerVolume ?? 0
        let refilled = max(0, actualMarketHit - volumeDecrease)

        if refilled > 0 {
            context.totalRefilledVolume += refilled
            
            // Логируем только значительный рефилл (> 0.5% от начального объёма)
            let refillPercent = (refilled / context.initialVolume) * 100
            if refillPercent > 0.5 {
                log("🔄 [\(cluster.trackingId)] Рефилл: +\(String(format: "%.2f", refilled)) BTC (\(String(format: "%.2f", refillPercent))%), всего: \(String(format: "%.2f", context.totalRefilledVolume)) BTC (\(String(format: "%.1f", context.totalRefilledVolume / context.initialVolume * 100))%)")
            }
            
            // сохраняем обновлённый контекст
            state = .monitoring(context)
        }
        
        // 5. Стабильность объёма
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
            return nil
        case .ok:
            break
        }
        
        // 6. Фиксация касания
        if !context.hasTouched && didTouchLevelWithHysteresis(cluster: cluster, price: snapshot.currentPrice) {
            context.hasTouched = true
            state = .monitoring(context)
            logTouch(cluster, price: snapshot.currentPrice)
        }
        
        guard context.hasTouched else { return nil }
        
        // 7. Защита от спуфинга
        guard await noVolatilitySpike(currentCluster: cluster, price: snapshot.currentPrice, book: snapshot.book) else {
            logVolatilitySpike(cluster)
            await reset()
            return nil
        }
        
        // 8. Анализ битвы
        guard let battleStats = snapshot.battleStats[cluster.trackingId] else {
            logWaitingForBattle(cluster)
            return nil
        }
        
        let battleOutcome = await checkBattleConditions(
            stats: battleStats,
            cluster: cluster,
            book: snapshot.book,
            initialVolume: context.initialVolume,
            context: context,
            snapshot: snapshot
        )
        
        switch battleOutcome {
        case .lose:
            await reset()
            return nil
        case .pending:
            logBattlePending(cluster, stats: battleStats, currentVolume: currentVolume(for: cluster, in: snapshot.book))
            return nil
        case .win:
            break // продолжаем
        }
        
        // 9. Проверка выхода цены из зоны (пружина)
        if isBouncingOffWithHysteresis(cluster: cluster, price: snapshot.currentPrice) {
            // Проверяем свободный путь и риск/прибыль
            guard let rr = calculateRR(currentCluster: cluster, allClusters: snapshot.clusters, minStrength: Constants.minStrenghtZScoreForEncounter) else {
                logNoFreePath(cluster)
                await reset()
                return nil
            }
            
            // Минимальное приемлемое соотношение
            let minRatio = 2.0
            guard rr.ratio >= minRatio else {
                logLowRiskReward(cluster, ratio: rr.ratio)
                await reset()
                return nil
            }
            
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
            let whyClosePosition = logStopLoss(position, price: price)
            addTradeToHistory(entryPosition: position, exitPrice: price, exitDate: Date(), whyClosePosition: whyClosePosition)
            await reset()
            return .exit
        }
        
        // 2. Логика переноса стоп-лосса (Трейлинг)
        if let newStopLoss = calculateTrailingStop(position: position, currentPrice: price) {
            position.stopLoss = newStopLoss
            self.state = .positionOpen(position)
            logStopLossUpdated(position: position)
        }
        
        // 3. Проверка здоровья исходного кластера (только если цена еще внутри его зоны)
        if let myCluster = snapshot.clusters.first(where: { $0.trackingId == position.sourceClusterId }) {
            let hasExitedInProfit: Bool
            if position.side == .bid {
                hasExitedInProfit = snapshot.currentPrice > position.entryUpperBound
            } else {
                hasExitedInProfit = snapshot.currentPrice < position.entryLowerBound
            }
            
            if !hasExitedInProfit {
                // Цена еще внутри зоны или пробила в минус – проверяем здоровье
                if let context = position.monitoringCluster {
                    let isHealthy = await checkLevelHealth(cluster: myCluster, snapshot: snapshot, initialVol: position.initialVolume, context: context)
                    if !isHealthy {
                        let whyClosePosition = logBackstab(position, price: snapshot.currentPrice)
                        addTradeToHistory(entryPosition: position, exitPrice: price, exitDate: Date(), whyClosePosition: whyClosePosition)
                        await reset()
                        return .exit
                    }
                }
            }
        }
        
        // 4. Мониторинг встречных кластеров
        if let encounterContext = position.monitoringCluster {
            // Уже есть активный встречный кластер – продолжаем мониторить
            let result = await monitorEncounterCluster(
                context: encounterContext,
                snapshot: snapshot,
                positionSide: position.side,
                position: position
            )
            switch result {
            case .continueMonitoring(let updatedContext):
                position.monitoringCluster = updatedContext
                state = .positionOpen(position)
            case .exitPosition:
                // Причина уже залогирована внутри monitorEncounterCluster
                await reset()
                return .exit
            case .stopMonitoring:
                position.monitoringCluster = nil
                position.processedClusterIds.insert(encounterContext.cluster.trackingId)
                state = .positionOpen(position)
            }
        } else {
            // Нет активного встречного кластера – ищем новый
            if let encounter = findEncounterCluster(in: snapshot, position: position) {
                let initialVol = currentVolume(for: encounter, in: snapshot.book)
                let newContext = MonitoringContext(
                    cluster: encounter,
                    startTime: .now,
                    initialVolume: initialVol,
                    volumeSamples: [initialVol],
                    firstSeenAt: .now,
                    firstSeenPrice: price
                )
                position.monitoringCluster = newContext
                state = .positionOpen(position)
                logEncounterMonitoringStarted(encounter)
            }
        }
        
        return nil
    }
    
    // MARK: - Вспомогательные методы (логика проверок)
    // Проверка: цена находится СНАРУЖИ уровня (с гистерезисом)
    private func isOutsideLevelWithHysteresis(cluster: Cluster, price: Double) -> Bool {
        let offset = Constants.tickSize * Double(Constants.hysteresisTicks)
        
        if cluster.side == .bid {
            // Для поддержки (bid): цена должна быть ВЫШЕ верхней границы + отступ
            return price > cluster.upperBound + offset
        } else {
            // Для сопротивления (ask): цена должна быть НИЖЕ нижней границы - отступ
            return price < cluster.lowerBound - offset
        }
    }

    // Проверка: цена коснулась уровня (с гистерезисом)
    private func didTouchLevelWithHysteresis(cluster: Cluster, price: Double) -> Bool {
        if cluster.side == .bid {
            // Касание поддержки: цена вошла в зону (верхняя граница + отступ)
            return price <= cluster.upperBound + (Constants.tickSize * Double(Constants.hysteresisTicks))
        } else {
            // Касание сопротивления: цена вошла в зону (нижняя граница - отступ)
            return price >= cluster.lowerBound - (Constants.tickSize * Double(Constants.hysteresisTicks))
        }
    }

    // Проверка: цена вышла из уровня (отскок) с гистерезисом
    private func isBouncingOffWithHysteresis(cluster: Cluster, price: Double) -> Bool {
        if cluster.side == .bid {
            // Отскок от поддержки: цена вышла ВЫШЕ верхней границы + отступ
            return price > cluster.upperBound + (Constants.tickSize * Double(Constants.hysteresisTicks))
        } else {
            // Отскок от сопротивления: цена вышла НИЖЕ нижней границы - отступ
            return price < cluster.lowerBound - (Constants.tickSize * Double(Constants.hysteresisTicks))
        }
    }
    
    private func calculateTrailingStop(position: Position, currentPrice: Double) -> Double? {
        let isLong = position.side == .bid
        
        // Процент чистого движения цены от входа
        let priceMovePercent = (currentPrice - position.entryPrice) / position.entryPrice * (isLong ? 1 : -1)
        
        // Цена "истинного" безубытка (Break-even Price)
        let breakEvenPrice = isLong
            ? position.entryPrice * (1 + Constants.totalCosts)
            : position.entryPrice * (1 - Constants.totalCosts)
        
        // Проверка: мы уже перевели стоп в БУ?
        let isAlreadyInSafeZone = isLong
            ? position.stopLoss >= (breakEvenPrice - 0.0001)
            : position.stopLoss <= (breakEvenPrice + 0.0001)
        
        // А) ПЕРЕВОД В БЕЗУБЫТОК
        if !isAlreadyInSafeZone && priceMovePercent >= Constants.breakEvenActivation {
            log("🛡 БЕЗУБЫТОК: Цена прошла \(String(format: "%.2f", priceMovePercent * 100))%. Ставим стоп на покрытие комиссий.")
            return breakEvenPrice
        }
        
        // Б) ТРЕЙЛИНГ-СТОП
        guard priceMovePercent >= Constants.trailingStepPercent else { return nil }
        
        let potentialNewStop = isLong
            ? currentPrice * (1 - Constants.trailingStepPercent)
            : currentPrice * (1 + Constants.trailingStepPercent)
        
        // Минимальное изменение стопа, чтобы не дёргать его по 1 доллару
        let stopMoveThreshold = position.entryPrice * (Constants.trailingStepPercent * Constants.minStopMoveRelative)
        let stopDifference = abs(potentialNewStop - position.stopLoss)
        
        if stopDifference >= stopMoveThreshold {
            if isLong && potentialNewStop > position.stopLoss {
                return potentialNewStop
            }
            if !isLong && potentialNewStop < position.stopLoss {
                return potentialNewStop
            }
        }
        
        return nil
    }
    
    private func calculateRR(currentCluster: Cluster, allClusters: [Cluster], minStrength: Double) -> (ratio: Double, target: Double, stop: Double)? {
        let isBid = currentCluster.side == .bid
        let direction = isBid ? 1.0 : -1.0
        
        // Точка входа — край кластера, с которого заходит цена
        let entryPrice = isBid ? currentCluster.upperBound : currentCluster.lowerBound
        
        // Стоп за противоположным краем + 20% ширины
        let stopPadding = currentCluster.binSize * 0.2
        let stopPrice = isBid
            ? (currentCluster.lowerBound - stopPadding)
            : (currentCluster.upperBound + stopPadding)
        
        // Минимальное расстояние до цели — 2.5 ширины кластера (чтобы пропустить шум)
        let minDistance = currentCluster.binSize * 2.5
        
        // Ищем ближайший сильный кластер в направлении движения
        let targetCluster = allClusters
            .filter { cluster in
                // 1. Фильтр аномальности
                let isStatisticallyStrong = cluster.strengthZScore >= minStrength
                // 2. Фильтр качества (чтобы не пугаться "пустых" объемов)
                let isHighQuality = cluster.strength > Constants.minFinalStrength
                
                guard isStatisticallyStrong && isHighQuality else { return false }
                
                // 3. Расстояние в направлении движения
                let distance = (cluster.price - entryPrice) * direction
                return distance > minDistance
            }
            .min { abs($0.price - entryPrice) < abs($1.price - entryPrice) }
        
        // Если целевой кластер найден — используем его цену, иначе консервативная цель (5 ширин)
        let finalTargetPrice: Double
        if let target = targetCluster {
            finalTargetPrice = target.price
        } else {
            finalTargetPrice = entryPrice + (direction * currentCluster.binSize * 5.0)
        }
        
        let risk = abs(entryPrice - stopPrice)
        let reward = abs(finalTargetPrice - entryPrice)
        guard risk > 0 else { return nil }
        let ratio = reward / risk
        
        return (ratio, finalTargetPrice, stopPrice)
    }
    
    private func clusterExists(_ cluster: Cluster, in snapshot: MarketSnapshot) -> Bool {
        snapshot.clusters.contains { $0.trackingId == cluster.trackingId }
    }
    
    private func isClusterBroken(_ cluster: Cluster, by price: Double) -> Bool {
        (cluster.side == .bid && price < cluster.lowerBound) ||
        (cluster.side == .ask && price > cluster.upperBound)
    }
    
    private func isStopLossHit(position: Position, currentPrice: Double) -> Bool {
        (position.side == .bid && currentPrice <= position.stopLoss) ||
        (position.side == .ask && currentPrice >= position.stopLoss)
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
    
    private func checkBattleConditions(stats: LevelBattleStats,
                                       cluster: Cluster,
                                       book: LocalOrderBook,
                                       initialVolume: Double,
                                       context: MonitoringContext,
                                       snapshot: MarketSnapshot) async -> BattleOutcome {
        let attackerVol = stats.attackerVolume     // Сколько в нас ударили рынком (агрессия)
        let defenderVol = stats.defenderVolume     // Сколько мы выкупили встречным рынком (активная защита)
        let currentLimit = currentVolume(for: cluster, in: book) // Что осталось в стакане прямо сейчас
        
        // 1. Проверка на "Пустоту"
        if attackerVol < Constants.attackerMinVolume {
            return .pending
        }
        
        // 2. Тройной фильтр выживания (Выходим, если...)
        // А) Лимиты съели больше чем на 40% (порог 0.6)
        let isLimitDepleted = currentLimit < (initialVolume * Constants.minRemainingLimitRatio)
        // Б) Агрессор влил в 2 раза больше, чем мы смогли активно защитить
        let isDefenseOverwhelmed = attackerVol > (defenderVol * 2.0) && attackerVol > 2.0
        
        if isLimitDepleted || isDefenseOverwhelmed {
            logBattleLost(cluster, stats: stats, isLimitDepleted: isLimitDepleted, isDefenseOverwhelmed: isDefenseOverwhelmed, currentVolume: currentVolume(for: cluster, in: book))
            return .lose
        }
        
        // 3. Расчет итоговой мощности брони (Armor)
        // Мы суммируем то, что СТОИТ (лимит), и то, что РЕАЛЬНО ОТБИТО (defenderVol)
        // Но лимитам даем приоритет (коэффициент 1.0), а защите (0.7), так как она уже в прошлом
        let effectiveDefense = currentLimit + (defenderVol * 1.2)
        let armorRatio = effectiveDefense / max(attackerVol, 1.0)
        
        // 4. ВЫЧИСЛЯЕМ СКОРОСТЬ ПОДХОДА
        let elapsedSeconds = context.firstSeenAt.duration(to: .now).components.seconds
        var velocity: Double = 0
        
        if elapsedSeconds > 0 {
            let priceChange = abs(snapshot.currentPrice - context.firstSeenPrice)
            let priceChangePercent = (priceChange / context.firstSeenPrice) * 100
            velocity = priceChangePercent / Double(elapsedSeconds)
        }
        
        let isStatsStrong = await stats.isStrong
        var requiredRatio = isStatsStrong ? 2.5 : Constants.requiredLimitToAttackRatio
        
        // Корректируем порог в зависимости от скорости подхода
        if velocity > Constants.highVelocityThreshold {
            requiredRatio *= 1.5
            log("⚡ Высокая скорость подхода: \(String(format: "%.2f", velocity))%/с, требования увеличены до \(requiredRatio)")
        } else if velocity > Constants.mediumVelocityThreshold {
            requiredRatio *= 1.2
            log("⚠️ Средняя скорость подхода: \(String(format: "%.2f", velocity))%/с, требования увеличены до \(requiredRatio)")
        } else {
            log("🐢 Низкая скорость подхода: \(String(format: "%.2f", velocity))%/с, стандартные требования \(requiredRatio)")
        }
        
        // 5. ПРОВЕРКА ЗНАЧИТЕЛЬНОГО РЕФИЛЛА
        let hasSignificantRefill = context.totalRefilledVolume > (initialVolume * Constants.refillSignificanceThreshold)
        let refillPercent = context.totalRefilledVolume / initialVolume * 100
            
        // ЕСЛИ ЕСТЬ ЗНАЧИТЕЛЬНЫЙ РЕФИЛЛ — СНИЖАЕМ ТРЕБОВАНИЯ
        var finalRequiredRatio = requiredRatio
        if hasSignificantRefill {
            // Рефилл даёт бонус: снижаем требования на 30%
            finalRequiredRatio = requiredRatio * Constants.refillBonusMultiplier
            log("💪 [\(cluster.trackingId)] ЗНАЧИТЕЛЬНЫЙ РЕФИЛЛ! Подлито \(String(format: "%.2f", context.totalRefilledVolume)) BTC (\(String(format: "%.0f", refillPercent))%)")
            log("📉 Требования снижены: \(String(format: "%.2f", requiredRatio)) → \(String(format: "%.2f", finalRequiredRatio))")
        }
        
        // 6. ПРОВЕРКА МИКРООТСКОПА
        let rebounded = isOutsideLevelWithHysteresis(cluster: cluster, price: snapshot.currentPrice)
        if !rebounded {
            // Цена ещё не отскочила, ждём
            let targetBound = cluster.side == .bid ? cluster.upperBound : cluster.lowerBound
            let offset = Constants.tickSize * Double(Constants.hysteresisTicks)
            log("⏳ [\(cluster.trackingId)] Ожидание отскопа... Цена: \(snapshot.currentPrice), нужно \(cluster.side == .bid ? "выше" : "ниже") \(targetBound + (cluster.side == .bid ? offset : -offset))")
            return .pending
        }
        
        // 7. УСЛОВИЕ ПОБЕДЫ (с учётом отскопа)
        if armorRatio >= finalRequiredRatio && !isLimitDepleted {
            log("✅ [\(cluster.trackingId)] ПОБЕДА! armorRatio: \(String(format: "%.2f", armorRatio)) >= \(String(format: "%.2f", finalRequiredRatio))")
            
            if hasSignificantRefill {
                log("🌟 Благодаря рефиллу (\(String(format: "%.0f", refillPercent))%) вход даже при более низком armorRatio!")
            }
            
            return .win
        }
            
            log("⏳ [\(cluster.trackingId)] Ожидание... armorRatio: \(String(format: "%.2f", armorRatio)) < \(String(format: "%.2f", finalRequiredRatio))")
            return .pending
    }

    
    private func checkLevelHealth(cluster: Cluster, snapshot: MarketSnapshot, initialVol: Double, context: MonitoringContext) async -> Bool {
        // Пробой — смерть
        if isClusterBroken(cluster, by: snapshot.currentPrice) {
            return false
        }
        
        // Если есть данные битвы — проверяем исход
        if let stats = snapshot.battleStats[cluster.trackingId] {
            let outcome = await checkBattleConditions(stats: stats,
                                                      cluster: cluster,
                                                      book: snapshot.book,
                                                      initialVolume: initialVol,
                                                      context: context,
                                                      snapshot: snapshot)
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
                // 1. Статистическая аномалия (базовый порог 2.5)
                let isStrong = cluster.strengthZScore > Constants.minStrenghtZScoreForEncounter
                
                // 2. Реальное давление (наша "стена" должна иметь силу)
                let isHighQuality = cluster.strength > Constants.minFinalStrength
                
                // 3. Дистанция и факт касания
                let isClose = cluster.distancePercent < Constants.maxDistancePercentForTarget
                let isTouchCluster = didTouchLevelWithHysteresis(cluster: cluster, price: currentPrice)
                
                // 4. Проверка, что это не тот же самый кластер, от которого мы зашли
                let isNotTarget = cluster.trackingId != position.sourceClusterId
                let isProcessed = !position.processedClusterIds.contains(cluster.trackingId)
                
                return isStrong && isHighQuality && isClose && isTouchCluster && isNotTarget && isProcessed
            }
            .min { abs($0.price - currentPrice) < abs($1.price - currentPrice) }
    }
    
    private func monitorEncounterCluster(context: MonitoringContext, snapshot: MarketSnapshot, positionSide: Side, position: Position) async -> EncounterMonitoringResult {
        let context = context
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
            let whyClosePosition = logEncounterBasicConditionsFailed(cluster)
            addTradeToHistory(entryPosition: position, exitPrice: snapshot.currentPrice, exitDate: Date(), whyClosePosition: whyClosePosition)
            return .exitPosition
        }
        
        // Пробой в нежелательную сторону
        if isClusterBroken(cluster, by: currentPrice) {
            let whyClosePosition = logEncounterBreakthrough(cluster)
            addTradeToHistory(entryPosition: position, exitPrice: snapshot.currentPrice, exitDate: Date(), whyClosePosition: whyClosePosition)
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
                        let whyClosePosition = logEncounterCriticalDrop(cluster)
                        addTradeToHistory(entryPosition: position, exitPrice: snapshot.currentPrice, exitDate: Date(), whyClosePosition: whyClosePosition)
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
            let whyClosePosition = logEncounterVolatilitySpike(cluster)
            addTradeToHistory(entryPosition: position, exitPrice: snapshot.currentPrice, exitDate: Date(), whyClosePosition: whyClosePosition)
            return .exitPosition
        }
        
        // Анализ битвы
        guard let battleStats = snapshot.battleStats[cluster.trackingId] else {
            logEncounterWaitingForBattle(cluster)
            return .continueMonitoring(context)
        }
        
        let battleOutcome = await checkBattleConditions(stats: battleStats,
                                                        cluster: cluster,
                                                        book: snapshot.book,
                                                        initialVolume: context.initialVolume,
                                                        context: context,
                                                        snapshot: snapshot)
        let isExpected = (battleOutcome == .win) == (expected == .shouldBeStrong)
        
        if !isExpected {
            let whyClosePosition = logEncounterBattleUnexpected(cluster)
            addTradeToHistory(entryPosition: position, exitPrice: snapshot.currentPrice, exitDate: Date(), whyClosePosition: whyClosePosition)
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
    func findTargetCluster(in snapshot: MarketSnapshot) -> Cluster? {
        let currentPrice = snapshot.currentPrice
        return snapshot.clusters
            .filter { cluster in
                // 1. Направление (мы должны быть СНАРУЖИ уровня, чтобы в него удариться)
                let isValidDirection = isOutsideLevelWithHysteresis(cluster: cluster, price: currentPrice)
                guard isValidDirection else { return false }
                
                // 2. Статистическая аномалия (базовый порог)
                let isStatisticallyStrong = cluster.strengthZScore > Constants.minStrengthZScoreForTarget
                
                // 3. Качество уровня
                let isHighQuality = cluster.strength > Constants.minFinalStrength
                
                // 4. Дистанция
                let isClose = cluster.distancePercent < Constants.maxDistancePercentForTarget
                
                // 5. Актуальность (используем firstSeen, если есть, иначе считаем свежим)
                let age: TimeInterval
                if let firstSeen = snapshot.battleStats[cluster.trackingId]?.firstSeen {
                    age = Date().timeIntervalSince(firstSeen)
                } else {
                    age = 0  // если нет статистики, считаем свежим
                }
                let isFresh = age < Constants.maxClusterAge
                
                return isStatisticallyStrong && isHighQuality && isClose && isFresh
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
            power: cluster.strength,
            side: cluster.side,
            stopLoss: stopLoss,
            entryLowerBound: cluster.lowerBound,
            entryUpperBound: cluster.upperBound,
            sourceClusterStartTime: context.startTime,
            openTime: Date(),
            leverage: Double(Constants.defaultLeverage)
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
    private func log(_ message: String) {
        print(message)  // можно заменить на реальную систему логирования
    }
    
    private func logTargetAcquired(_ cluster: Cluster, initialVolume: Double, marketState: String) {
        log("""
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
        log("❌ [\(id)] Цель удалена из списка активных кластеров")
    }
    
    private func logBasicConditionsFailed(_ cluster: Cluster, price: Double) {
        log("❌ [\(cluster.trackingId)] Базовые условия нарушены (Цена: \(price) | ThinPath: \(isThinPath(cluster: cluster)))")
    }
    
    private func logBreakthrough(_ cluster: Cluster, price: Double) {
        let bound = cluster.side == .bid ? cluster.lowerBound : cluster.upperBound
        log("💀 [\(cluster.trackingId)] ПРОБОЙ! Цена \(price) прошила уровень \(bound)")
    }
    
    private func logCriticalVolumeDrop(_ cluster: Cluster) {
        log("💥 [\(cluster.trackingId)] КРИТИЧЕСКИЙ СБРОС ОБЪЁМА")
    }
    
    private func logTouch(_ cluster: Cluster, price: Double) {
        log("🎯 [\(cluster.trackingId)] КАСАНИЕ! Цена \(price) вошла в зону уровня.")
    }
    
    private func logVolatilitySpike(_ cluster: Cluster) {
        log("⚠️ [\(cluster.trackingId)] Обнаружен всплеск волатильности (спуфинг)")
    }
    
    private func logWaitingForBattle(_ cluster: Cluster) {
        log("⚔️ [\(cluster.trackingId)] Ждём первых рыночных ударов...")
    }
    
    private func logBattleLost(_ cluster: Cluster, stats: LevelBattleStats, isLimitDepleted: Bool, isDefenseOverwhelmed: Bool, currentVolume: Double) {
        if isDefenseOverwhelmed {
            log("🚩 Проигрыш по агрессии: Покупатель \(stats.attackerVolume) сильнее Защитника \(stats.defenderVolume)")
        } else if isLimitDepleted {
            log("🚩 Проигрыш по лимитам: Стенку съели, осталось \(currentVolume)")
        }
    }
    
    private func logBattlePending(_ cluster: Cluster, stats: LevelBattleStats, currentVolume: Double) {
        log("⚔️ [\(cluster.trackingId)] Идет борьба... Агрессия: \(stats.attackerVolume) BTC | Лимиты: \(currentVolume) BTC")
    }
    
    private func logWaitingForBounce(_ cluster: Cluster) {
        log("🛡️ [\(cluster.trackingId)] Лимиты устояли! Ждём выхода цены из зоны...")
    }
    
    private func logSignalFormed(_ cluster: Cluster, position: Position, snapshot: MarketSnapshot, currentVolume: Double) {
        let timeString = Date().formatted(date: .omitted, time: .standard)
        log("""
        🚀🚀🚀 [\(cluster.trackingId)] СИГНАЛ СФОРМИРОВАН!
        Состояния рынка \(snapshot.state)
        Сторона: \(cluster.side)
        Позиция открыта по цене \(position.entryPrice) в \(timeString)
        Итоговый объем кластера: \(currentVolume)
        Объем поглощенной атаки: \(snapshot.battleStats[cluster.trackingId]?.attackerVolume ?? 0)
        """)
    }
    
    private func logStopLoss(_ position: Position, price: Double) -> String {
        return "🛑 [STOP LOSS] Позиция закрыта по цене \(price)."
    }
    
    private func logBackstab(_ position: Position, price: Double) -> String {
        let timeString = Date().formatted(date: .omitted, time: .standard)
        return "🧨 [BACKSTAB] Наш защитный уровень ослаб. Закрываемся по цене \(price) в \(timeString)"
    }
    
    private func logEncounterMonitoringStarted(_ cluster: Cluster) {
        log("🔄 [\(cluster.trackingId)-\(cluster.side)] Начат мониторинг встречного кластера.")
    }
    
    private func logEncounterClusterRemoved(_ id: Double) {
        log("❌ [\(id)] Встречный кластер исчез")
    }
    
    private func logEncounterBasicConditionsFailed(_ cluster: Cluster) -> String {
        return "❌ [\(cluster.trackingId)-\(cluster.side)] Базовые условия нарушены для встречного кластера"
    }
    
    private func logEncounterBreakthrough(_ cluster: Cluster) -> String {
        return "💀 [\(cluster.trackingId)-\(cluster.side)] Встречный кластер пробит в нежелательную сторону. Выход."
    }
    
    private func logEncounterCriticalDrop(_ cluster: Cluster) -> String {
        return "💥 [\(cluster.trackingId)-\(cluster.side)] Критический сброс объёма на встречном кластере (ожидалась сила). Выход."
    }
    
    private func logEncounterCriticalDropButExpectedWeak(_ cluster: Cluster) {
        log("📉 [\(cluster.trackingId)-\(cluster.side)] Критический сброс объёма (помогает пробою). Продолжаем.")
    }
    
    private func logEncounterVolumePause(_ cluster: Cluster) {
        log("⏳ [\(cluster.trackingId)-\(cluster.side)] Пауза: объём мерцает на встречном кластере")
    }
    
    private func logEncounterVolatilitySpike(_ cluster: Cluster) -> String {
        return "⚠️ [\(cluster.trackingId)-\(cluster.side)] Обнаружен всплеск волатильности на встречном кластере. Выход."
    }
    
    private func logEncounterWaitingForBattle(_ cluster: Cluster) {
        log("⚔️ [\(cluster.trackingId)-\(cluster.side)] Ждём первых рыночных ударов во встречный кластер...")
    }
    
    private func logEncounterBattleUnexpected(_ cluster: Cluster) -> String {
        return "🚩 [\(cluster.trackingId)-\(cluster.side)] Битва на встречном кластере идёт против ожиданий. Выход."
    }
    
    private func logEncounterMovedInFavor(_ cluster: Cluster) {
        log("✅ [\(cluster.trackingId)-\(cluster.side)] Цена вышла из встречного кластера в сторону позиции. Продолжаем.")
    }
    
    private func logNoFreePath(_ cluster: Cluster) {
        log("🚫 [\(cluster.trackingId)-\(cluster.side)] Нет свободного пути: ближайший сильный кластер слишком близко.")
    }
    
    private func logLowRiskReward(_ cluster: Cluster, ratio: Double) {
        log("📉 [\(cluster.trackingId)-\(cluster.side)] Недостаточное соотношение риск/прибыль: \(String(format: "%.2f", ratio)) < 2.0")
    }
    
    private func logStopLossUpdated(position: Position) {
        log("Позиция STOP LOSE передвинулась на \(position.stopLoss)")
    }
    
    // MARK: Методы для UI
    private func updateUI(snapshot: MarketSnapshot, targetCluster: Cluster?) {
        var clusterToShow: TargetClusterInfo? = nil
        var message = "Производится поиск..."
        var positionInfo: PositionInfo? = nil
        
        switch self.state {
        case .scanning:
            if let found = targetCluster {
                clusterToShow = currentTargetClusterInfo(cluster: found, context: nil, snapshot: snapshot)
                message = "Кластер найден, проверяем условия..."
            }
            
        case .monitoring(let context):
            clusterToShow = currentTargetClusterInfo(
                cluster: context.cluster,
                context: context,
                snapshot: snapshot
            )
            if clusterToShow?.hasTouched == true {
                if clusterToShow?.isWaitingForBounce == true {
                    message = "Ждем пружину... \(clusterToShow?.priceCondition ?? "")"
                } else {
                    message = "Идет битва за уровень"
                }
            } else {
                message = "Ожидаем касания уровня"
            }
            
        case .positionOpen(let position):
            // 1. Информация о родном кластере
            let sourceClusterInfo: TargetClusterInfo? = snapshot.clusters.first(where: { $0.trackingId == position.sourceClusterId }).map { cluster in
                let sourceContext = MonitoringContext(
                    cluster: cluster,
                    startTime: position.sourceClusterStartTime,
                    initialVolume: position.initialVolume,
                    hasTouched: true,
                    firstSeenAt: .now,
                    firstSeenPrice: snapshot.currentPrice
                )
                return currentTargetClusterInfo(cluster: cluster, context: sourceContext, snapshot: snapshot)
            }
            
            // 2. Информация о встречном кластере (если есть)
            let encounterClusterInfo: TargetClusterInfo? = position.monitoringCluster.map { context in
                currentTargetClusterInfo(cluster: context.cluster, context: context, snapshot: snapshot)
            }
            
            // 3. Расчёт P&L (условный размер 100 единиц базовой валюты)
            let price = snapshot.currentPrice
            let entry = position.entryPrice
            let rawPnLPercent = (price - entry) / entry * 100  // процент относительно входа
            let pnlPercent = rawPnLPercent * position.leverage  // процент с учётом плеча
            let pnlAbsolute = rawPnLPercent * 100.0            // абсолютный P&L в USDT при инвестиции 100 USDT
            
            positionInfo = PositionInfo(
                side: position.side,
                entryPrice: position.entryPrice,
                openTime: position.openTime,
                pnlPercent: pnlPercent,
                pnlAbsolute: pnlAbsolute,
                sourceCluster: sourceClusterInfo,
                encounterCluster: encounterClusterInfo
            )
            
            message = "Позиция открыта"
        }
        
        let newState = StrategyUIState(
            price: snapshot.currentPrice,
            marketStatus: snapshot.state.rawValue,
            asks: clustersForUi(from: snapshot.clusters, side: .ask),
            bids: clustersForUi(from: snapshot.clusters, side: .bid),
            targetCluster: clusterToShow,
            statusMessage: message,
            positionInfo: positionInfo,
            tradeHistory: tradeHistory
        )
        
        uiContinuation.yield(newState)
    }
    
    private func clustersForUi(from clusters: [Cluster], side: Side) -> [ClusterRow] {
        // 1. Фильтруем: нужная сторона + сила > 2.5
        let filtered = clusters.filter {
            $0.side == side && $0.strengthZScore > Constants.uiMinStrengthZScore && $0.strength > Constants.uiMinStrength
        }
        
        // 3. Сортируем (ASK — по возрастанию цены, BID — по убыванию)
        let sorted = side == .ask
            ? filtered.sorted { $0.price < $1.price }
            : filtered.sorted { $0.price > $1.price }
        
        // 4. Превращаем в UI-модели, используя trackingId для идентификации
        return sorted.prefix(2).map { cluster in
            ClusterRow(id: cluster.trackingId,   // используем trackingId вместо id
                       price: cluster.price,
                       volume: cluster.totalVolume,
                       power: cluster.strength,
                       distancePercent: cluster.distancePercent)
        }
    }
    
    private func currentTargetClusterInfo(cluster: Cluster, context: MonitoringContext?, snapshot: MarketSnapshot) -> TargetClusterInfo {
        var info = TargetClusterInfo(
            id: cluster.trackingId,
            lowerBound: cluster.lowerBound,
            upperBound: cluster.upperBound,
            type: cluster.side == .bid ? "Поддержка" : "Сопротивление",
            volume: cluster.totalVolume,
            power: cluster.strength
        )
        
        if let context = context {
            // Данные из контекста мониторинга
            info.hasTouched = context.hasTouched
            
            // Время наблюдения
            let elapsed = context.startTime.duration(to: .now)
            info.monitoringDuration = TimeInterval(elapsed.components.seconds)
            
            // Данные об объеме
            info.initialVolume = context.initialVolume
            info.currentVolume = currentVolume(for: cluster, in: snapshot.book)
            info.volumeRetainedPercent = (info.currentVolume / info.initialVolume) * 100
            
            // Данные о битве
            if let battleStats = snapshot.battleStats[cluster.trackingId] {
                info.attackerVolume = battleStats.attackerVolume
                info.defenderVolume = battleStats.defenderVolume
                let totalDefense = info.currentVolume + battleStats.defenderVolume
                info.armorRatio = totalDefense / max(battleStats.attackerVolume, 1.0)
            }
            
            // Статус ожидания пружины
            let isBouncing = isBouncingOffWithHysteresis(cluster: cluster, price: snapshot.currentPrice)
            info.isWaitingForBounce = context.hasTouched && !isBouncing
            
            // Условие для пружины
            if cluster.side == .bid {
                info.priceCondition = "цена выше \(String(format: "%.2f", cluster.upperBound))"
            } else {
                info.priceCondition = "цена ниже \(String(format: "%.2f", cluster.lowerBound))"
            }
            info.currentPrice = snapshot.currentPrice
        }
        
        return info
    }
    
    private func addTradeToHistory(entryPosition: Position, exitPrice: Double, exitDate: Date, whyClosePosition: String) {
        let investmentAmount = 100.0 // сумма входа в USDT
        let leverage = entryPosition.leverage
        
        let pnlAbsolute: Double
        let pnlPercent: Double
        
        if entryPosition.side == .bid {
            // Для LONG: (exitPrice - entryPrice) / entryPrice * investmentAmount * leverage
            pnlAbsolute = ((exitPrice - entryPosition.entryPrice) / entryPosition.entryPrice) * investmentAmount * leverage
            pnlPercent = ((exitPrice - entryPosition.entryPrice) / entryPosition.entryPrice) * 100 * leverage
        } else {
            // Для SHORT: (entryPrice - exitPrice) / entryPrice * investmentAmount * leverage
            pnlAbsolute = ((entryPosition.entryPrice - exitPrice) / entryPosition.entryPrice) * investmentAmount * leverage
            pnlPercent = ((entryPosition.entryPrice - exitPrice) / entryPosition.entryPrice) * 100 * leverage
        }
        
        let item = TradeHistoryItem(
            entryDate: entryPosition.openTime,
            exitData: exitDate,
            entryPrice: entryPosition.entryPrice,
            exitPrice: exitPrice,
            profitLoss: pnlAbsolute,
            profitLossPercent: pnlPercent,
            isOpen: false,
            whyСlosePosition: whyClosePosition,
            side: entryPosition.side,
            power: entryPosition.power,
            volume: entryPosition.initialVolume
        )
        tradeHistory.append(item)
        // Опционально: ограничить размер истории
        if tradeHistory.count > 100 {
            tradeHistory.removeFirst(tradeHistory.count - 100)
        }
    }
}
