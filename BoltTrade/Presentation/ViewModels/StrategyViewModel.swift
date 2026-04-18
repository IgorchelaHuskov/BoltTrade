//
//  StrategyViewModel.swift
//  BoltTrade
//
//  Created by Igorchela on 15.03.26.
//

import Foundation

@MainActor
@Observable
final class StrategyViewModel {
    private(set) var ui: StrategyUIState?
    private(set) var accountInfo: AccountInfo = AccountInfo()
    private(set) var currentAmountUSDT: Double = 100.0
    
    private let strategy: BounceStrategy
    private let dataProvider: DataProvider
    private var observationTask: Task<Void, Never>?
    private var balanceTask: Task<Void, Never>?
    
    // --- ИСТОЧНИК ПРАВДЫ ДЛЯ РАСЧЕТОВ ---
    private var baseWalletBalance: Double = 0.0
    private var baseInitialMargin: Double = 0.0
    private var currentPositionAmt: Double = 0.0
    private var currentEntryPrice: Double = 0.0
    
    private var lastListenKey: String?
    // ------------------------------------

    init(strategy: BounceStrategy, dataProvider: DataProvider)  {
        self.strategy = strategy
        self.dataProvider = dataProvider
        
        self.observationTask = Task {
            for await newState in strategy.uiEvents {
                self.ui = newState
            }
        }
        
        fetchInitialBalance()
        
        Task {
            await loadCurrentAmount()
        }
    }
    
    private func fetchInitialBalance() {
        balanceTask?.cancel()
        
        balanceTask = Task {
            do {
                let listenKey = try await dataProvider.getListenKey()
                self.lastListenKey = listenKey
                
                // Получаем базу через REST (даже если позиций 0)
                let balances = try await dataProvider.fetchAccountBalance()
                self.syncBaseData(from: balances) // Сохраняем кошелек и маржу
                
                Task {
                    while !Task.isCancelled {
                        // Ждем 30 минут
                        try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                        
                        // Продлеваем ключ
                        if let currentKey = self.lastListenKey {
                            await self.dataProvider.keepAliveListenKey(key: currentKey)
                        }
                    }
                }
                
                await withTaskGroup(of: Void.self) { group in
                    
                    // ПОТОК А: Всегда слушаем изменения аккаунта
                    group.addTask {
                        do {
                            let userStream = try await self.dataProvider.listenAccountUpdates(listenKey: listenKey)
                            for await event in userStream {
                                // Находим обновление по BTC
                                if let btc = event.a.P.first(where: { $0.s == "BTCUSDT" }) {
                                    print("MARGIN = \(btc.iw)")
                                    await self.updatePositionInternals(
                                        amt: btc.pa,
                                        entry: btc.ep,
                                        margin: btc.iw // <-- ВАЖНО: берем новую маржу из WS
                                    )
                                }
                            }
                        } catch { print("Stream аккаунта упал") }
                    }
                    
                    // ПОТОК Б: Всегда слушаем цену
                    group.addTask {
                        do {
                            let priceStream = try await self.dataProvider.subscribeToMarkPrice()
                            for await newPriceData in priceStream {
                                await self.recalculateLiveUI(markPrice: Double(newPriceData.p) ?? 0)
                            }
                        } catch { print("Stream цены упал") }
                    }
                }
            } catch {
                print("❌ Ошибка: \(error)")
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                fetchInitialBalance()
            }
        }
    }

    // Дорабатываем метод обновления "внутрянки"
    private func updatePositionInternals(amt: String, entry: String, margin: String?) {
        self.currentPositionAmt = Double(amt) ?? 0.0
        self.currentEntryPrice = Double(entry) ?? 0.0
        
        // Если позиция открылась/закрылась/изменилась - обновляем маржу залога!
        if let marginStr = margin, let newMargin = Double(marginStr) {
            self.baseInitialMargin = newMargin
        } else if self.currentPositionAmt == 0 {
            // Если позиция закрыта, маржа залога должна стать 0
            self.baseInitialMargin = 0
        }
    }

    // Сохраняем начальные цифры
    private func syncBaseData(from: BinanceAccountResponse) {
        self.baseWalletBalance = Double(from.totalWalletBalance) ?? 0.0
        self.baseInitialMargin = Double(from.totalPositionInitialMargin) ?? 0.0
        
        if let btc = from.positions.first(where: { $0.symbol == "BTCUSDT" }) {
            self.currentPositionAmt = Double(btc.positionAmt) ?? 0.0
            self.currentEntryPrice = Double(btc.entryPrice) ?? 0.0
        }
        // Сразу рисуем то, что получили из REST
        self.updateAccountInfo(from: from)
    }


    // Тот самый живой расчет, который крутится в Потоке Б
    private func recalculateLiveUI(markPrice: Double) {
        // 1. Честный PnL (обновляется каждую секунду)
        let pnl = (markPrice - currentEntryPrice) * currentPositionAmt
        
        // 2. Total Balance (Equity) — это то, что сверху (Баланс + Профит)
        let totalBalance = baseWalletBalance + pnl
        
        // 3. Available (Доступно для новых сделок)
        // В Binance: Margin Balance - Используемая Маржа
        let liveAvailable = totalBalance - baseInitialMargin
        
        // 4. To Withdraw (Доступно к выводу)
        // Снять можно только "чистый" остаток кошелька за вычетом залога.
        // Прибыль снять нельзя, пока позиция не закрыта!
        let withdrawable = baseWalletBalance - baseInitialMargin
        
        self.accountInfo = AccountInfo(
            totalBalance: String(format: "%.2f", totalBalance),
            // Здесь ставим max(0, ...), чтобы не уйти в минус при ликвидации
            available: String(format: "%.2f", max(0, liveAvailable)),
            
            // К выводу: либо доступная маржа, либо чистый баланс (что меньше)
            availableToWithdraw: String(format: "%.2f", max(0, min(liveAvailable, withdrawable))),
            
            // Это поле ДОЛЖНО обновляться только из ACCOUNT_UPDATE (событие "iw" или "im")
            inPosition: String(format: "%.2f", baseInitialMargin),
            
            pnl: String(format: "%.2f", pnl),
            pnlPercentage: baseInitialMargin > 0 ? String(format: "%.2f", (pnl / baseInitialMargin) * 100) : "0.00"
        )
    }

    private func updateAccountInfo(from: BinanceAccountResponse) {
        let totalMargin = Double(from.totalMarginBalance) ?? 0.0
        let pnl = Double(from.totalUnrealizedProfit) ?? 0.0
        
        self.accountInfo = AccountInfo(
            totalBalance: String(format: "%.2f", totalMargin),
            available: String(format: "%.2f", Double(from.availableBalance) ?? 0.0),
            availableToWithdraw: String(format: "%.2f", Double(from.maxWithdrawAmount) ?? 0.0),
            inPosition: String(format: "%.2f", baseInitialMargin),
            pnl: String(format: "%.2f", pnl),
            pnlPercentage: "0.00"
        )
    }
    
    
    private func loadCurrentAmount() async {
        let amount = await strategy.getAmountUSDT()
        self.currentAmountUSDT = amount
    }
    
    func setAmountUSDT(_ newAmount: Double) {
        Task {
            await strategy.updateAmountUSDT(newAmount)
            await MainActor.run {
                self.currentAmountUSDT = newAmount
            }
        }
    }
}
