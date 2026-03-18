//
//  TradeHistoryView.swift
//  UIBOT
//
//  Created by Igorchela on 15.02.26.
//

import Foundation
import SwiftUI
// MARK: - История сделок
struct TradeHistoryView: View {
    let trades: [TradeHistoryItem]
    @Binding var selectedTrade: TradeHistoryItem?
    @Binding var showTradeDetail: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(trades) { trade in
                        TradeHistoryItemView(trade: trade)
                            .onTapGesture {
                                withAnimation {
                                    selectedTrade = trade
                                    showTradeDetail = true
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedTrade?.id == trade.id && showTradeDetail ? Color.blue.opacity(0.2) : Color.clear)
                            )
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
