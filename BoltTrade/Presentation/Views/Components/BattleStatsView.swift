//
//  BattleStatsView.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct BattleStatsView: View {
    let target: TargetClusterInfo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "БИТВА ЗА УРОВЕНЬ", color: .orange)
            HStack {
                VStack(alignment: .leading) {
                    Text("Агрессоры (Market)").font(.caption2).foregroundColor(.gray)
                    Text(String(format: "%.2f BTC", target.attackerVolume)).font(.subheadline).bold()
                    Text("\(Int(target.attackerVolume / max(target.attackerVolume + target.defenderVolume, 1) * 100))% power")
                        .font(.caption2).foregroundColor(.red)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Лимиты + Защитники").font(.caption2).foregroundColor(.gray)
                    Text(String(format: "%.2f BTC", target.defenderVolume)).font(.subheadline).bold()
                    Text("\(Int(target.defenderVolume / max(target.attackerVolume + target.defenderVolume, 1) * 100))% power")
                        .font(.caption2).foregroundColor(.green)
                }
            }
            if target.armorRatio > 0 {
                HStack {
                    Text("Armor Ratio:").foregroundColor(.gray)
                    Text(String(format: "%.1fx", target.armorRatio)).bold()
                    ArmorIndicator(ratio: target.armorRatio)
                }
                .font(.caption)
            }
        }
    }
}
