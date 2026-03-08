//
//  File.swift
//  AutomaticTrading
//
//  Created by Igorchela on 3.01.26.
//

import Foundation

// Единая модель для локальной книги заказов
struct OrderBookLevel: Sendable, Equatable {
    var price: Double
    var quantity: Double
    
    nonisolated init(price: Double, quantity: Double) {
        self.price = price
        self.quantity = quantity
    }
}
