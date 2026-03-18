//
//  File.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct TradingDashboard: View {
    let ui: StrategyUIState
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                PriceStatusPanel(price: ui.price, marketStatus: ui.marketStatus)
                Divider().background(Color.gray.opacity(0.5))
                OrderBookView(asks: ui.asks, bids: ui.bids)
                Divider().background(Color.gray.opacity(0.5))
                StateDependentView(ui: ui)
            }
            .padding()
        }
        .background(Color(white: 0.05))
        .foregroundColor(.white)
    }
}
