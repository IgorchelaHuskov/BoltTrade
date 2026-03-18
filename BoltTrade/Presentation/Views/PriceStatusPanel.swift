//
//  PriceStatusPanel.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct PriceStatusPanel: View {
    let price: Double
    let marketStatus: String
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Current Price:").foregroundColor(.gray)
                Spacer()
                Text(String(format: "%.2f", price))
                    .font(.title2).bold()
                    .foregroundColor(.white)
            }
            HStack {
                Text("Состояние рынка:").foregroundColor(.gray)
                Spacer()
                Text(marketStatus.uppercased())
                    .foregroundColor(marketStatus == "TREND" ? .orange : .blue)
                    .bold()
            }
        }
        .font(.system(.body, design: .monospaced))
        .padding(10)
        .background(Color(white: 0.1))
        .cornerRadius(8)
    }
}
