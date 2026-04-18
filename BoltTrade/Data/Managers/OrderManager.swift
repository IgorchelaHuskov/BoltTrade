//
//  OrderManager.swift
//  BoltTrade
//
//  Created by Igorchela on 15.04.26.
//

import Foundation

actor OrderManager {
    private let dataProvider: DataProvider
    private var lastQuantity: String?
    
    init(dataProvider: DataProvider) {
        self.dataProvider = dataProvider
    }
    
    func openPosition(signal: Signal) async {
        let symbol = "BTCUSDT"
        
        // Извлекаем данные из сигнала
        let sideStr: String
        let qty: Double
        
        switch signal {
        case .buy(let q):
            sideStr = "BUY"; qty = q
        case .sell(let q):
            sideStr = "SELL"; qty = q
        case .exit: return
        }
        
        let formattedQty = String(format: "%.3f", qty)
        self.lastQuantity = formattedQty // Запоминаем объем для последующего закрытия
        
        do {
            // Оставляем только ШАГ 1: Вход по рынку
            try await dataProvider.sendOrder(params: [
                "symbol": symbol,
                "side": sideStr,
                "type": "MARKET",
                "quantity": formattedQty
            ])
            
        } catch {
            print("❌ Ошибка входа по рынку: \(error)")
        }
    }


    
    // В OrderManager
    func closePosition(side: Side) async {
        let symbol = "BTCUSDT"
        guard let qty = lastQuantity else { return }
        let closeSide = (side == .bid) ? "SELL" : "BUY"
        
        do {
            try await dataProvider.sendOrder(params: [
                "symbol": symbol,
                "side": closeSide,
                "type": "MARKET",
                "quantity": qty,
                "reduceOnly": "true" // Гарантирует, что мы только закрываем
            ])
            
            // 3. Чистим ордера (удаляем страховку/стоп-лосс)
            try await dataProvider.cancelAllOpenOrders(symbol: symbol)
            
            // 4. Сбрасываем локальное состояние
            self.lastQuantity = nil
            
        } catch {
            print("❌ Ошибка при закрытии позиции: \(error)")
        }
    }

        
    // 3. УДАЛЕНИЕ ВСЕХ ОРДЕРОВ (Чтобы стоп не остался висеть)
    private func cancelAllOrders(symbol: String) async throws {
        try await dataProvider.cancelAllOpenOrders(symbol: symbol)
    }

}
