//
//  ConfigError.swift
//  AutomaticTrading
//
//  Created by Igorchela on 30.12.25.
//

import Foundation


enum ApiConfigError: Error, LocalizedError {
    case fileNotFound
    case dataLoadingFailed(underlyingError: Error)
    case decodingfailed(underlyingError: Error)
    
    var errorDescription: String? {
        switch self {
            
        case .fileNotFound:
            return "Файл Api конфигурации не найден"
        case .dataLoadingFailed(underlyingError: let error):
            return "Не удвлось загрузить файл API конфигурации \(error.localizedDescription)"
        case .decodingfailed(underlyingError: let error):
            return "Не удолось декадировать API конфигурацию \(error.localizedDescription)"
        }
    }
}
