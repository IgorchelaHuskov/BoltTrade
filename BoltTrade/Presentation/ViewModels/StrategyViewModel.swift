//
//  StrategyViewModel.swift
//  BoltTrade
//
//  Created by Igorchela on 15.03.26.
//

import Foundation

@MainActor
@Observable
final class StrategyViewModel {
    private(set) var ui: StrategyUIState?
    
    private var observationTask: Task<Void, Never>?
    
    init(strategy: BounceStrategy) {
        print("init StrategyViewModel")
        self.observationTask = Task {
            for await newState in strategy.uiEvents {
                self.ui = newState
            }
        }
    }
}
