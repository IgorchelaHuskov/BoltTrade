//
//  HeaderRow.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct HeaderRow: View {
    let title: String
    let badge: String
    let badgeColor: Color
    
    var body: some View {
        HStack {
            Text(title).font(.headline).foregroundColor(.yellow)
            Spacer()
            Text(badge)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(badgeColor.opacity(0.3))
                .cornerRadius(4)
        }
    }
}
