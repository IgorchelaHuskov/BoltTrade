//
//  SectionHeader.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct SectionHeader: View {
    let title: String
    let color: Color
    
    var body: some View {
        Text(title)
            .font(.caption).bold()
            .foregroundColor(color)
            .padding(.top, 4)
    }
}
