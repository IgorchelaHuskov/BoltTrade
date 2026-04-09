//
//  OrderBookView.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct OrderBookView: View {
    let asks: [ClusterRow]
    let bids: [ClusterRow]
    
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            OrderBookColumn(title: "ASK", color: .red, items: asks)
            OrderBookColumn(title: "BID", color: .green, items: bids)
        }
    }
}

struct OrderBookColumn: View {
    let title: String
    let color: Color
    let items: [ClusterRow]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).bold().foregroundColor(color)
            if items.isEmpty {
                Text("Нет данных")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 5)
            } else {
                ForEach(items) { item in
                    ClusterRowView(row: item, color: color)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ClusterRowView: View {
    let row: ClusterRow
    let color: Color
    
    var body: some View {
        HStack {
            Text(String(format: "%.2f", row.id)).frame(width: 70, alignment: .leading)
            Text(String(format: "%.2f", row.volume)).frame(width: 50, alignment: .trailing)
            Text(String(format: "%.1fσ", row.power))
                .frame(width: 40, alignment: .trailing)
                .foregroundColor(row.power > 2.5 ? color : .gray)
            if row.distancePercent > 0 {
                Text(String(format: "%.1f%%", row.distancePercent))
                    .frame(width: 40, alignment: .trailing)
                    .foregroundColor(.gray)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(color.opacity(0.1))
        .cornerRadius(4)
    }
}
