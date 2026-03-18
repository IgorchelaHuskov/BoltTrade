//
//  EntryConditionsView.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct EntryConditionsView: View {
    let target: TargetClusterInfo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: "УСЛОВИЯ ВХОДА", color: .orange)
            ConditionRow(text: "Тонкий путь (cumulative < total)", isMet: target.volumeRetainedPercent > 0)
            ConditionRow(text: "Касание произошло", isMet: target.hasTouched)
            ConditionRow(text: "Нет спуфинга", isMet: true) // должно приходить из логики
            if target.isWaitingForBounce {
                HStack {
                    Image(systemName: "hourglass").foregroundColor(.yellow)
                    Text(target.priceCondition).foregroundColor(.yellow)
                }
                .font(.caption)
                .padding(.top, 5)
            }
        }
    }
}
