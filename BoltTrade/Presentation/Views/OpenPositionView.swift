//
//  OpenPositionView.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import Foundation
import SwiftUI

struct OpenPositionView: View {
    let position: PositionInfo
    let currentPrice: Double
    let message: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(position.side == .bid ? "🟢 LONG" : "🔴 SHORT")
                    .font(.headline)
                    .foregroundColor(position.side == .bid ? .green : .red)
                Spacer()
                Text(UIUtilities.formatDuration(Date().timeIntervalSince(position.openTime)))
                    .font(.caption).foregroundColor(.gray)
            }
            
            HStack {
                VStack(alignment: .leading) {
                    Text("Вход").font(.caption2).foregroundColor(.gray)
                    Text(String(format: "%.2f", position.entryPrice)).font(.title3).bold()
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("P&L").font(.caption2).foregroundColor(.gray)
                    HStack(spacing: 4) {
                        Text(String(format: "%+.2f$", position.pnlAbsolute))
                        Text("(\(String(format: "%+.1f%%", position.pnlPercent)))")
                    }
                    .font(.title3).bold()
                    .foregroundColor(position.pnlAbsolute >= 0 ? .green : .red)
                }
            }
            
            Divider().background(Color.gray)
            
            if let encounter = position.encounterCluster {
                SectionHeader(title: "ПРЕПЯТСТВИЕ ВПЕРЕДИ", color: .red)
                //CompactClusterInfo(cluster: encounter)
                BattleMonitoringView(target: encounter, message: message)
                
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.3), lineWidth: 1))
    }
}
