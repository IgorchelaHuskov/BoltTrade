//
//  StatusRow.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct StatusRow: View {
    let message: String
    let color: Color
    
    var body: some View {
        HStack {
            Text("СТАТУС:").foregroundColor(.gray)
            Text(message).foregroundColor(color)
        }
        .font(.caption)
    }
}
