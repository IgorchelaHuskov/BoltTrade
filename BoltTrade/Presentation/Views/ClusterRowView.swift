//
//  ClusterRowView.swift
//  BoltTrade
//
//  Created by Igorchela on 15.03.26.
//

import Foundation
import SwiftUI


struct ClusterRowView: View {
    let row: ClusterRow
    let color: Color
    
    var body: some View {
        HStack(spacing: 0) {
            // Цена
            Text("\(Int(row.price))")
                .frame(width: 80, alignment: .leading)
            
            // Сила (Z-Score)
            Text(String(format: "%.1f", row.power))
                .frame(width: 60, alignment: .center)
                .foregroundColor(color)
            
            Text(String(format: "%.1f", row.distancePercent))
                .frame(width: 60, alignment: .center)
                
            
            
            // Объем (справа)
            Spacer()
            Text(String(format: "%.1f BTC", row.volume))
                .frame(width: 80, alignment: .trailing)
        }
        .font(.system(.subheadline, design: .monospaced))
        .padding(.vertical, 2)
    }
}
