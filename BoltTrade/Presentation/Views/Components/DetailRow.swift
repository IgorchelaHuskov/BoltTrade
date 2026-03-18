//
//  DetailRow.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI


struct DetailRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(valueColor)
                .fontWeight(.medium)
        }
    }
}
