//
//  ContentView.swift
//  AutomaticTrading
//
//  Created by Igorchela on 21.12.25.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator
    
    var body: some View {
            Text("Hello")
        }

}


#Preview {
    ContentView().environment(AppCoordinator())
}

