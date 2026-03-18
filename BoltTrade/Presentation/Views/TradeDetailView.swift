//
//  TradeDetailView.swift
//  UIBOT
//
//  Created by Igorchela on 15.02.26.
//

import Foundation
import SwiftUI
// MARK: - Детальная информация о сделке (с кнопкой закрытия)
struct TradeDetailView: View {
    let trade: TradeHistoryItem
    @Binding var showTradeDetail: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Детали сделки")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: {
                    withAnimation {
                        showTradeDetail = false
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            VStack(alignment: .leading, spacing: 12) {
                DetailRow(label: "Пара", value: "BTC/USDT")
                DetailRow(label: "Дата входа", value: trade.entryDate.formatted())
                DetailRow(label: "Цена входа", value: String(format: "$%.2f", trade.entryPrice))
                DetailRow(label: "Сила кластера", value: String(format: ".2f", trade.power))
                DetailRow(label: "Объем кластера", value: String(format: ".2f", trade.volume))
                
                if let exitPrice = trade.exitPrice {
                    DetailRow(label: "Цена выхода", value: String(format: "$%.2f", exitPrice))
                    DetailRow(label: "Дата выхода", value: trade.entryDate.addingTimeInterval(3600).formatted())
                }
                
                Divider()
                
                DetailRow(label: "Прибыль/Убыток", value: String(format: "$%.2f (%.2f%%)", trade.profitLoss, trade.profitLossPercent), valueColor: trade.profitLoss >= 0 ? .green : .red)
                
                Divider()
                
                DetailRow(label: "Причина", value: trade.whyСlosePosition)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(10)
        }
        .frame(width: 400) // Фиксированная ширина
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 10)
    }
}
