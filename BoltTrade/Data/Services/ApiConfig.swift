//
//  ApiConfig.swift
//  AutomaticTrading
//
//  Created by Igorchela on 23.12.25.
//

import Foundation

struct APIConfig: Decodable {
    let binanceKlineURL: String
    let binanceOrderBookURL: String
    let binanceOrderBookWebsocketURL: String
    let binanceTradeWebsocketURL: String
    
    // Синглтон для доступа из любой части приложения
    static let shared: APIConfig? = {
        do {
            return try loadConfig()
        } catch {
            print("Не получилось загрузть API Config")
            return nil
        }
    }()
    
    
    private static func loadConfig() throws -> APIConfig {
        guard let url = Bundle.main.url(forResource: "APIConfig", withExtension: "json") else {
            throw ApiConfigError.fileNotFound
        }
        
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(APIConfig.self, from: data)
        } catch  let error as DecodingError {
            throw ApiConfigError.decodingfailed(underlyingError: error)
        } catch {
            throw ApiConfigError.dataLoadingFailed(underlyingError: error)
        }
    }
}
