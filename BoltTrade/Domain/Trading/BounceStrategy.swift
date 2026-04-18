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
    private var amountUSDT  = 100.0
    
    //MARK: UI
    private let (uiStream, uiContinuation) = AsyncStream<StrategyUIState>.makeStream()
    nonisolated var uiEvents: AsyncStream<StrategyUIState> { uiStream }
    
    // MARK: - Константы стратегии
    private enum Constants {
        // Поиск цели
        static let maxDistancePercentForTarget = 0.5
        static let minFinalStrength            = 0.1
        static let maxDistanceToCluster        = 0.3
        
        // Мониторинг
        static let thinPathThreshold                = 3.3       // Тонкий путь (thin path)
        static let volatilitySpikeRadius            = 0.002     // 0.2%
        static let volatilityConcentrationThreshold = 0.4
        static let maxSpreadPercent                 = 0.001     // 0.1%
        static let volumeStability                  = 0.6       // Стабильность обьема
        
        // Битва
        static let attackerMinVolume            = 1.0
        static let requiredLimitToAttackRatio   = 4.0
        static let minRemainingLimitRatio       = 0.6    // 40% от начального объёма
        static let criticalVolumeDropRatio      = 0.4    // 40%
        static let refillSignificanceThreshold  = 0.3    // для значимости рефилла  30% от начального объёма
        static let refillBonusMultiplier        = 0.7    // снижаем требования на 30% при рефилле
        static let confirmationSamplesCount     = 10     // для замер среднего обьема
        
        // Стоп-лосс отступ
        static let stopLossOffsetPercent    = 0.01      // 1%
        static let totalCosts               = 0.0011    // 0.11% (комиссии + спред)
        static let breakEvenActivation      = 0.0015    // 0.2%
        
        // кредитное плече
        static let defaultLeverage          = 50.0
        
        // Пороги скорости подхода (% в секунду)
        static let mediumVelocityThreshold  = 0.2       // > 0.2%/с - средняя скорость
        static let highVelocityThreshold    = 0.5       // > 0.5%/с - высокая скорость
        
        // Гистерезис
        static let tickSize         = 0.1     // минимальный шаг цены (можно получать из market data)
        static let hysteresisTicks  = 4       // сколько тиков отступа
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
        var volumeSamples: [Double] = []
        var isConfirmed: Bool = false
        let firstSeenAt: ContinuousClock.Instant
        let firstSeenPrice: Double
        var lastTotalAttackerVolume: Double = 0
        var lastVolume: Double = 0
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
        let sourceClusterStartTime: ContinuousClock.Instant
        let openTime: Date
        var sourceMonitoringContext: MonitoringContext?   // для исходного кластера
        var encounterMonitoringContext: MonitoringContext? // для встречного
        var processedClusterIds: Set<Double> = []
        var hasEverExitedInProfit: Bool = false
    }
    
    struct RREvaluation {
        let stopPrice: Double
        let ratio: Double
    }
    
    struct OrderAction {
        let side: Side
        let entryPrice: Double
        let stopPrice: Double
    }

    
    enum StrategyState {
        case scanning
        case monitoring(MonitoringContext)
        case positionOpen(Position)
    }
    
    enum BattleOutcome {
        case win
        case lose
        case pending
    }
    
    enum ClusterStatus {
        case confirming(MonitoringContext)      // Набираем сэмплы
        case active(MonitoringContext)          // Объем подтвержден, ждем касания/битвы
        case battlePending(MonitoringContext)   // Идет активная битва
        case bounceConfirmed(MonitoringContext) // ОТСКОК (то, что раньше было Win)
        case broken(String)                     // Уровень уничтожен/пробит (то, что раньше вызывало reset)
    }
    
    private enum EvaluationMode {
        case entry      // для поиска входа
        case protective // для защитного кластера в позиции
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
    
    func updateAmountUSDT(_ newAmount: Double) {
        amountUSDT = newAmount
        log("💰 Сумма для торговли обновлена: \(amountUSDT) USDT")
    }
    
    func getAmountUSDT() -> Double {
        return amountUSDT
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
            firstSeenPrice: snapshot.currentPrice,
            lastTotalAttackerVolume: snapshot.battleStats[targetCluster.trackingId]?.totalAttackerVolume ?? 0,
            lastVolume: firstVolume
        )
        
        logTargetAcquired(targetCluster, initialVolume: firstVolume, marketState: snapshot.state.rawValue)
        state = .monitoring(context)
        return nil
    }
    
    
    private func handleMonitoring(context: MonitoringContext, snapshot: MarketSnapshot) async -> Signal? {
        let status = await evaluateCluster(context: context, snapshot: snapshot, mode: .entry)
        
        switch status {
        case .confirming(let ctx), .active(let ctx), .battlePending(let ctx):
            state = .monitoring(ctx)
            return nil
            
        case .broken:
            await reset()
            return nil
            
        case .bounceConfirmed(let ctx):
            guard let rr = calculateRR(currentCluster: ctx.cluster, currentPrice: snapshot.currentPrice, allClusters: snapshot.clusters, minStrength: Constants.minFinalStrength),
                  rr.ratio >= 2.0 else {
                await reset()
                return nil
            }
            
            let position = createPosition(from: ctx.cluster, entryPrice: snapshot.currentPrice, context: ctx, stopPrice: rr.stopPrice)
            state = .positionOpen(position)
            
            
            let quantity = (self.amountUSDT * Constants.defaultLeverage) / snapshot.currentPrice
            
            // Возвращаем сигнал со всеми деталями
            if ctx.cluster.side == .bid {
                return .buy(quantity: quantity)
            } else {
                return .sell(quantity: quantity)
            }
        }
    }
    
    private func handlePositionOpen(position: Position, snapshot: MarketSnapshot) async -> Signal? {
        var position = position
        let price = snapshot.currentPrice
        
        // 1. Стоп-лосс
        if isStopLossHit(position: position, currentPrice: price) {
            let whyClosePosition = logStopLoss(position, price: price)
            addTradeToHistory(entryPosition: position, exitPrice: price, exitDate: Date(), whyClosePosition: whyClosePosition)
            await reset()
            return .exit(side: position.side)
        }
        
        // 2. Жесткий Тейк-профит 1%
        let takeProfitPercent: Double = 0.03 // 1%
        let isTakeProfitHit: Bool
        
        if position.side == .bid {
            // Для лонга: цена входа + 1%
            isTakeProfitHit = price >= position.entryPrice * (1.0 + takeProfitPercent)
        } else {
            // Для шорта: цена входа - 1%
            isTakeProfitHit = price <= position.entryPrice * (1.0 - takeProfitPercent)
        }
        
        if isTakeProfitHit {
            log("💰 [TP 1%] Цель достигнута по цене \(price). Закрываем профит.")
            addTradeToHistory(entryPosition: position, exitPrice: price, exitDate: Date(), whyClosePosition: "Take Profit 1%")
            await reset()
            return .exit(side: position.side)
        }
        
        // Ищем защитника (своя сторона)
        let nearestProtective = findProtectiveCluster(for: position.side, currentPrice: snapshot.currentPrice, allClusters: snapshot.clusters, excludeId: position.sourceClusterId)
        
        // Если мониторинг уже идет
        if let ctx = position.encounterMonitoringContext {
            // ПРОВЕРКА НА ПЕРЕКЛЮЧЕНИЕ:
            // Если появился кластер ближе, чем тот, что мы мониторим сейчас
            if let newNearest = nearestProtective, newNearest.trackingId != ctx.cluster.trackingId {
                log("🔄 Смена щита: найден более близкий кластер \(newNearest.trackingId)")
                position.encounterMonitoringContext = createNewContext(for: newNearest, snapshot: snapshot)
                position.processedClusterIds.insert(newNearest.trackingId)
                state = .positionOpen(position)
                return nil // Выходим, чтобы на следующем тике начать evaluate уже нового контекста
            }
            
            let status = await evaluateCluster(context: ctx, snapshot: snapshot, mode: .protective)
            
            switch status {
            case .confirming(let newCtx), .active(let newCtx), .battlePending(let newCtx):
                position.encounterMonitoringContext = newCtx
                state = .positionOpen(position)
                
            case .broken:
                // ДЛЯ ЗАЩИТЫ: Если уровень пал, мы ВЫХОДИМ из позиции
                log("Защитный уровень пробит! Закрываем позицию.")
                addTradeToHistory(entryPosition: position, exitPrice: price, exitDate: Date(), whyClosePosition: "Защитный уровень пробит!")
                await reset()
                return .exit(side: position.side)
                
            case .bounceConfirmed:
                // Уровень отработал, цена ушла в нашу сторону
                log("Защита отскочила, сидим дальше")
                position.encounterMonitoringContext = nil // Сбрасываем мониторинг до следующей коррекции
                state = .positionOpen(position)
            }
            
        } else if let protective = nearestProtective, !position.processedClusterIds.contains(protective.trackingId) {
            // Помечаем, что мы взяли этот кластер в работу
            position.processedClusterIds.insert(protective.trackingId)
            position.encounterMonitoringContext = createNewContext(for: protective, snapshot: snapshot)
            logEncounterMonitoringStarted(protective)
            state = .positionOpen(position)
            
        } else if position.encounterMonitoringContext != nil {
            position.encounterMonitoringContext = nil
            state = .positionOpen(position)
        }

        return nil
    }
    
    // MARK: - Вспомогательные методы (логика проверок)
    
    private func evaluateCluster(context: MonitoringContext,
                                 snapshot: MarketSnapshot,
                                 mode: EvaluationMode) async -> ClusterStatus {
        var context = context
        let cluster = context.cluster
        let price = snapshot.currentPrice
        
        // ========== 1. Существование и дистанция (только entry) ==========
        if mode == .entry {
            guard clusterExists(cluster, in: snapshot) else {
                return .broken("Cluster removed")
            }
            //let distance = abs(price - cluster.price) / cluster.price
            if cluster.distancePercent > Constants.maxDistanceToCluster {
                return .broken("Price too far")
            }
        }
        
        // ========== 2. Подтверждение объёма ==========
        if !context.isConfirmed {
            if mode == .protective {
                // Для защитного кластера сразу считаем подтверждённым, берём текущий объём
                context.isConfirmed = true
                context.initialVolume = currentVolume(for: cluster, in: snapshot.book)
            } else {
                let currentVol = currentVolume(for: cluster, in: snapshot.book)
                context.volumeSamples.append(currentVol)
                if context.volumeSamples.count >= Constants.confirmationSamplesCount {
                    context.initialVolume = context.volumeSamples.reduce(0, +) / Double(context.volumeSamples.count)
                    context.isConfirmed = true
                    context.volumeSamples = []
                    return .active(context)
                }
                return .confirming(context)
            }
        }
        
        // ========== 3. Базовые условия и пробой ==========
        if mode == .entry {
            if !isDistanceAcceptable(price: price, cluster: cluster) || !isThinPath(cluster: cluster) {
                return .broken("Basic conditions failed")
            }
        }
        
        // Пробой уровня – критично для обоих режимов
        if isClusterBroken(cluster, by: price) {
            return .broken("Breakthrough")
        }
        
        // ========== 4. Стабильность объёма ==========
        let currentVol = currentVolume(for: cluster, in: snapshot.book)
        let stats = snapshot.battleStats[cluster.trackingId]
        let volStatus = checkVolumeStability(cluster: cluster, currentVolume: currentVol,initialVolume: context.initialVolume, battleStats: stats)
        if case .critical = volStatus {
            return .broken("Volume drop")
        }
        
        // Обновляем контекст
        context.lastVolume = currentVol
        context.lastTotalAttackerVolume = stats?.totalAttackerVolume ?? 0
        
        // ========== 5. Касание уровня ==========
        if mode == .protective {
            // Для защиты считаем, что касание уже было (или не нужно)
            context.hasTouched = true
        } else {
            if !context.hasTouched && didTouchLevelWithHysteresis(cluster: cluster, price: price) {
                context.hasTouched = true
            }
            guard context.hasTouched else {
                return .active(context)
            }
        }
        
        // ========== 6. Защита от волатильности и анализ битвы ==========
        // Для protective можно также пропустить noVolatilitySpike (опционально),
        // но оставим общую проверку для единообразия.
        guard await noVolatilitySpike(currentCluster: cluster, price: price, book: snapshot.book),
              let battleStats = stats else { return .battlePending(context) }
        
        let battleOutcome = await checkBattleConditions(stats: battleStats,
                                                        cluster: cluster,
                                                        book: snapshot.book,
                                                        initialVolume: context.initialVolume,
                                                        context: context,
                                                        snapshot: snapshot)
        
        switch battleOutcome {
        case .lose:
            return .broken("Battle lost")
        case .pending:
            return .battlePending(context)
        case .win:
            if isBouncingOffWithHysteresis(cluster: cluster, price: price) {
                return .bounceConfirmed(context)
            }
            return .battlePending(context)
        }
    }
    
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
    
    private func calculateRR(currentCluster: Cluster,
                             currentPrice: Double,
                             allClusters: [Cluster],
                             minStrength: Double,
                             tickSize: Double = Constants.tickSize,
                             hysteresisTicks: Int = Constants.hysteresisTicks) -> RREvaluation? {
        let isBid = currentCluster.side == .bid
        
        // Точка входа – текущая цена (цена, по которой будет открыта позиция)
        let entryPrice = currentPrice
        
        // Стоп-лосс – за противоположным краем кластера + отступ
        let stopOffset = entryPrice * Constants.stopLossOffsetPercent
        let stopPrice = isBid
            ? currentCluster.lowerBound - stopOffset
            : currentCluster.upperBound + stopOffset
        
        // Минимальное безопасное расстояние – 2.5 ширины кластера
        let minSafeDistance = currentCluster.binSize * 2.5
        
        // Фильтруем кластеры противоположной стороны (препятствия)
        let oppositeSideClusters = allClusters.filter { $0.side == (isBid ? .ask : .bid) }
        
        // Сортируем по расстоянию от цены входа до ближайшей границы препятствия
        let sortedObstacles = oppositeSideClusters
            .map { cluster -> (cluster: Cluster, distance: Double) in
                let distance = isBid
                    ? cluster.lowerBound - entryPrice   // для long: расстояние до нижней границы ask-кластера
                    : entryPrice - cluster.upperBound   // для short: расстояние до верхней границы bid-кластера
                return (cluster, distance)
            }
            .filter { $0.distance > 0 } // только те, что впереди
            .sorted { $0.distance < $1.distance }
        
        // Проверяем, есть ли сильный кластер слишком близко
        if let first = sortedObstacles.first,
           first.distance < minSafeDistance,
           first.cluster.strength >= minStrength {
            log("🚫 Препятствие: кластер \(first.cluster.trackingId) на расстоянии \(first.distance) < \(minSafeDistance)")
            return nil
        }
        
        // Ищем цель: первый сильный кластер, который находится дальше minSafeDistance
        let targetCluster = sortedObstacles.first {
            $0.distance >= minSafeDistance && $0.cluster.strength >= minStrength
        }?.cluster
        
        let finalTargetPrice: Double
        if let target = targetCluster {
            // Цель – граница кластера, которую цена должна достичь
            finalTargetPrice = isBid ? target.lowerBound : target.upperBound
        } else {
            log("❌ Нет безопасной цели на разумном расстоянии")
            return nil
        }
        
        let risk = abs(entryPrice - stopPrice)
        let reward = abs(finalTargetPrice - entryPrice)
        guard risk > 0 else { return nil }
        let ratio = reward / risk
        
        log("📐 Риск/прибыль: \(String(format: "%.2f", ratio)) (риск \(risk), прибыль \(reward))")
        
        return RREvaluation(stopPrice: stopPrice, ratio: ratio)
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
        guard volumeRatio < Constants.volumeStability else { return .ok }
        
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
        let attackerVol = stats.attackerVolume
        let defenderVol = stats.defenderVolume
        let currentLimit = currentVolume(for: cluster, in: book)
        
        
        // 2. Тройной фильтр выживания (поражение)
        let isLimitDepleted = currentLimit < (initialVolume * Constants.volumeStability)
        let isDefenseOverwhelmed = attackerVol > (defenderVol * 2.0) && attackerVol > 2.0
        
        if isLimitDepleted || isDefenseOverwhelmed {
            logBattleLost(cluster, stats: stats, isLimitDepleted: isLimitDepleted, isDefenseOverwhelmed: isDefenseOverwhelmed, currentVolume: currentVolume(for: cluster, in: book))
            return .lose
        }
        
        // 3. Расчёт брони (armor)
        let effectiveDefense = currentLimit + (defenderVol * 1.2)
        let armorRatio = effectiveDefense / max(attackerVol, 1.0)
        
        // 4. Скорость подхода
        let elapsedSeconds = context.firstSeenAt.duration(to: .now).components.seconds
        var velocity: Double = 0
        
        if elapsedSeconds > 0 {
            let priceChange = abs(snapshot.currentPrice - context.firstSeenPrice)
            let priceChangePercent = (priceChange / context.firstSeenPrice) * 100
            velocity = priceChangePercent / Double(elapsedSeconds)
        }
        
        let isStatsStrong = await stats.isStrong
        var requiredRatio = isStatsStrong ? 2.5 : Constants.requiredLimitToAttackRatio
        
        if velocity > Constants.highVelocityThreshold {
            requiredRatio *= 1.5
            log("⚡ Высокая скорость подхода: \(String(format: "%.2f", velocity))%/с, требования увеличены до \(requiredRatio)")
        } else if velocity > Constants.mediumVelocityThreshold {
            requiredRatio *= 1.2
            log("⚠️ Средняя скорость подхода: \(String(format: "%.2f", velocity))%/с, требования увеличены до \(requiredRatio)")
        } else {
            log("🐢 Низкая скорость подхода: \(String(format: "%.2f", velocity))%/с, стандартные требования \(requiredRatio)")
        }
        
        // 5. ИСТОЩЕНИЕ АГРЕССОРА
        let isExhausted = await stats.isAttackerExhausted
        if isExhausted {
            log("😫 [\(cluster.trackingId)] АГРЕССОР ИСТОЩЁН! Последние атаки слабее среднего ")
        }
        
        // 6. МИКРООТСКОП
        let rebounded = isOutsideLevelWithHysteresis(cluster: cluster, price: snapshot.currentPrice)
        if !rebounded {
            let targetBound = cluster.side == .bid ? cluster.upperBound : cluster.lowerBound
            let offset = Constants.tickSize * Double(Constants.hysteresisTicks)
            log("⏳ [\(cluster.trackingId)] Ожидание отскопа... Цена: \(snapshot.currentPrice), нужно \(cluster.side == .bid ? "выше" : "ниже") \(targetBound + (cluster.side == .bid ? offset : -offset))")
            return .pending
        }
        
        // 7. УСЛОВИЕ ПОБЕДЫ
        let battleIsReal = stats.totalAttackerVolume > max(initialVolume * 0.05, 3.0)
        let isStrongDefense = armorRatio >= requiredRatio && !isLimitDepleted
        let hasStrongSignal = (isStrongDefense && isExhausted) && battleIsReal
       
        
        if rebounded && hasStrongSignal {
            log("✅ [\(cluster.trackingId)] ПОБЕДА!")
            
            if isStrongDefense {
                log("🛡️ Сильная защита: armorRatio \(String(format: "%.2f", armorRatio)) >= \(String(format: "%.2f", requiredRatio))")
            }
            if isExhausted {
                log("😫 Агрессор истощён")
            }
            
            return .win
        }
        
        log("⏳ [\(cluster.trackingId)] Ожидание... armorRatio: \(String(format: "%.2f", armorRatio)) < \(String(format: "%.2f", requiredRatio))")
        return .pending
    }
    
        
    // MARK: - Поиск цели
    func findTargetCluster(in snapshot: MarketSnapshot) -> Cluster? {
        let currentPrice = snapshot.currentPrice
        
        // Ищем все подходящие кластеры (и bid, и ask)
        let candidates = snapshot.clusters.filter { cluster in
            let isValidDirection = isOutsideLevelWithHysteresis(cluster: cluster, price: currentPrice)
            guard isValidDirection else { return false }
            
            let isHighQuality = cluster.strength > Constants.minFinalStrength
            let isClose = cluster.distancePercent < Constants.maxDistancePercentForTarget
            
            return isHighQuality && isClose
        }
        
        // Выбираем самый сильный
        return candidates.max { $0.strength < $1.strength }
    }
    
    
    private func findProtectiveCluster(for side: Side, currentPrice: Double, allClusters: [Cluster], excludeId: Double) -> Cluster? {
        let isLong = side == .bid
        let maxDistance = 0.002
        
        let relevant = allClusters.filter { cluster in
            guard cluster.trackingId != excludeId else { return false }
            if isLong {
                guard cluster.side == .bid && cluster.upperBound < currentPrice else { return false }
                let distance = (currentPrice - cluster.upperBound) / currentPrice
                return distance <= maxDistance && cluster.strength > Constants.minFinalStrength
            } else {
                guard cluster.side == .ask && cluster.lowerBound > currentPrice else { return false }
                let distance = (cluster.lowerBound - currentPrice) / currentPrice
                return distance <= maxDistance && cluster.strength > Constants.minFinalStrength
            }
        }
        
        return relevant.sorted { lhs, rhs in
            if isLong {
                return lhs.upperBound > rhs.upperBound
            } else {
                return lhs.lowerBound < rhs.lowerBound
            }
        }.first
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
    
    
    
    private func createNewContext(for cluster: Cluster, snapshot: MarketSnapshot) -> MonitoringContext {
        let currentVol = currentVolume(for: cluster, in: snapshot.book)
        let currentAttacker = snapshot.battleStats[cluster.trackingId]?.totalAttackerVolume ?? 0
        
        return MonitoringContext(
            cluster: cluster,
            startTime: .now,
            initialVolume: currentVol,
            volumeSamples: [currentVol],
            firstSeenAt: .now,
            firstSeenPrice: snapshot.currentPrice,
            lastTotalAttackerVolume: currentAttacker,
            lastVolume: currentVol
        )
    }

    
    private func createPosition(from cluster: Cluster, entryPrice: Double, context: MonitoringContext, stopPrice: Double) -> Position {
        return Position(entryPrice: entryPrice,
                        sourceClusterId: cluster.trackingId,
                        initialVolume: context.initialVolume,
                        power: cluster.strength,
                        side: cluster.side,
                        stopLoss: stopPrice,
                        entryLowerBound: cluster.lowerBound,
                        entryUpperBound: cluster.upperBound,
                        sourceClusterStartTime: context.startTime,
                        openTime: Date(),
                        sourceMonitoringContext: context
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
    
    private func logEncounterBasicConditionsFailed(_ cluster: Cluster) -> String {
        return "❌ [\(cluster.trackingId)-\(cluster.side)] Базовые условия нарушены для встречного кластера"
    }
    
    private func logEncounterBreakthrough(_ cluster: Cluster) -> String {
        return "💀 [\(cluster.trackingId)-\(cluster.side)] Встречный кластер пробит в нежелательную сторону."
    }
    
    private func logEncounterCriticalDrop(_ cluster: Cluster) -> String {
        return "💥 [\(cluster.trackingId)-\(cluster.side)] Критический сброс объёма на встречном кластере (ожидалась сила). Выход."
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
    
    private func logTakeProfit(_ position: Position, price: Double) -> String {
        let profitPercent = position.side == .bid
            ? (price - position.entryPrice) / position.entryPrice * 100
            : (position.entryPrice - price) / position.entryPrice * 100
        return "💰 [TAKE PROFIT] Позиция закрыта по цене \(price). Прибыль: \(String(format: "%.2f", profitPercent))%"
    }
    
    private func logEncounterBattleUnexpected(_ cluster: Cluster) -> String {
        return "🚩 [\(cluster.trackingId)-\(cluster.side)] Битва на встречном кластере идёт против ожиданий. Выход."
    }
    
    private func logEncounterMovedInFavor(_ cluster: Cluster) {
        log("✅ [\(cluster.trackingId)-\(cluster.side)] Цена вышла из встречного кластера в сторону позиции. Продолжаем.")
    }
    
    private func logEncounterMonitoringStarted(_ cluster: Cluster) {
        log("🔄 [\(cluster.trackingId)-\(cluster.side) - \(cluster.upperBound)...\(cluster.lowerBound) ] Начат мониторинг встречного кластера.")
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
            let encounterClusterInfo: TargetClusterInfo? = position.encounterMonitoringContext.map { context in
                currentTargetClusterInfo(cluster: context.cluster, context: context, snapshot: snapshot)
            }
            
            // 3. Расчёт P&L (условный размер 100 единиц базовой валюты)
            let price = snapshot.currentPrice
            let entry = position.entryPrice

            // 1. Считаем чистое изменение цены (коэффициент)
            let priceChange: Double
            if position.side == .bid {
                priceChange = (price - entry) / entry
            } else {
                priceChange = (entry - price) / entry
            }

            // 2. Теперь считаем оба значения правильно:
            // Проценты: коэффициент * 100 * плечо
            let pnlPercent = priceChange * 100 * Constants.defaultLeverage

            // Деньги: коэффициент * сумма ставки * плечо
            let pnlAbsolute = priceChange * self.amountUSDT * Constants.defaultLeverage

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
            $0.side == side && $0.strength > Constants.minFinalStrength
        }
        
        // 3. Сортируем (ASK — по возрастанию цены, BID — по убыванию)
        let sorted = side == .ask
            ? filtered.sorted { $0.price < $1.price }
            : filtered.sorted { $0.price > $1.price }
        
        // 4. Превращаем в UI-модели, используя trackingId для идентификации
        return sorted.prefix(3).map { cluster in
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
        
        let pnlAbsolute: Double
        let pnlPercent: Double
        
        if entryPosition.side == .bid {
            // Для LONG: (exitPrice - entryPrice) / entryPrice * investmentAmount * leverage
            pnlAbsolute = ((exitPrice - entryPosition.entryPrice) / entryPosition.entryPrice) * self.amountUSDT * Constants.defaultLeverage
            pnlPercent = ((exitPrice - entryPosition.entryPrice) / entryPosition.entryPrice) * 100 * Constants.defaultLeverage
        } else {
            // Для SHORT: (entryPrice - exitPrice) / entryPrice * investmentAmount * leverage
            pnlAbsolute = ((entryPosition.entryPrice - exitPrice) / entryPosition.entryPrice) * self.amountUSDT * Constants.defaultLeverage
            pnlPercent = ((entryPosition.entryPrice - exitPrice) / entryPosition.entryPrice) * 100 * Constants.defaultLeverage
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
