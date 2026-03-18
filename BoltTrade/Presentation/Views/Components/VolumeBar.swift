//
//  File.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct VolumeBar: View {
    let current: Double
    let initial: Double
    let percent: Double
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: geometry.size.width, height: 30)
                RoundedRectangle(cornerRadius: 8)
                    .fill(UIUtilities.changeColor(percent))
                    .frame(width: min(geometry.size.width * CGFloat(percent / 100), geometry.size.width), height: 30)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 40)
                    .offset(x: geometry.size.width * 0.5 - 1)
                Text("\(percent, specifier: "%.1f")%")
                    .font(.caption).bold()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
