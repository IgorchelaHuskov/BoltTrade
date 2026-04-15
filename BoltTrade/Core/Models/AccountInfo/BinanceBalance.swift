//
//  BinanceBalanceResponse.swift
//  BoltTrade
//
//  Created by Igorchela on 11.04.26.
//

import Foundation

// MARK: - Главный объект ответа
nonisolated struct BinanceAccountResponse: Codable {
    let totalWalletBalance: String          // Общий баланс кошелька
    let totalUnrealizedProfit: String       // Тот самый честный PnL (как в приложении)
    let totalMarginBalance: String          // Баланс + Профит (Equity)
    let availableBalance: String            // Доступно для новых сделок
    let maxWithdrawAmount: String           // Доступно к выводу
    let totalPositionInitialMargin: String  // Сумма маржи всех позиций (In positions)
    
    let assets: [AccountAsset]
    let positions: [AccountPosition]
}

// MARK: - Детали по активам (USDT, USDC и т.д.)
struct AccountAsset: Codable {
    let asset: String               // Название (USDT)
    let walletBalance: String       // Баланс конкретного актива
    let unrealizedProfit: String    // Профит по этому активу
    let availableBalance: String    // Доступно
    let updateTime: Int64
}

// MARK: - Детали по каждой позиции
struct AccountPosition: Codable {
    let symbol: String              // Пара (BTCUSDT)
    let positionSide: String        // BOTH, LONG или SHORT
    let positionAmt: String         // Размер (pa)
    let unrealizedProfit: String    // Профит конкретной сделки (up)
    let initialMargin: String       // Маржа (залог) этой сделки
    let isolatedWallet: String      // Для режима Isolated
    let entryPrice: String          // Цена входа (может быть в некоторых версиях API)
    let updateTime: Int64
}


nonisolated struct BinanceUserDataEvent: Codable {
    let e: String // "ACCOUNT_UPDATE"
    let a: UpdateData
    
    struct UpdateData: Codable {
        let P: [PositionUpdate]
    }
    
    struct PositionUpdate: Codable {
        let s: String // Символ (BTCUSDT)
        let pa: String // Новый размер позиции (если 0 - значит закрыта)
        let ep: String // Новая цена входа
        let iw: String
    }
}
