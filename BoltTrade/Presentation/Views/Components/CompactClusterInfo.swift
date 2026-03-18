//
//  CompactClusterInfo.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct CompactClusterInfo: View {
    let cluster: TargetClusterInfo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("#\(String(format: "%.0f", cluster.id))").font(.caption).foregroundColor(.white)
                Spacer()
                Text(cluster.type)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(cluster.type == "Поддержка" ? Color.green.opacity(0.3) : Color.red.opacity(0.3))
                    .cornerRadius(4)
            }
            HStack {
                BoundView(label: "L", value: cluster.lowerBound)
                Spacer()
                BoundView(label: "U", value: cluster.upperBound, alignment: .trailing)
            }
            HStack {
                LabeledValue(label: "Объём", value: String(format: "%.2f BTC", cluster.currentVolume))
                Spacer()
                LabeledValue(label: "Сила", value: String(format: "%.1fσ", cluster.power))
            }
            if cluster.attackerVolume > 0 || cluster.defenderVolume > 0 {
                HStack {
                    LabeledValue(label: "Атака", value: String(format: "%.2f", cluster.attackerVolume))
                    Spacer()
                    LabeledValue(label: "Защита", value: String(format: "%.2f", cluster.defenderVolume))
                }
                .font(.caption2)
                .foregroundColor(.gray)
            }
            if cluster.initialVolume > 0 {
                HStack {
                    Text("Удержано:").font(.caption2).foregroundColor(.gray)
                    Text(String(format: "%.1f%%", cluster.volumeRetainedPercent))
                        .font(.caption)
                        .foregroundColor(cluster.volumeRetainedPercent > 80 ? .green : .orange)
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}
