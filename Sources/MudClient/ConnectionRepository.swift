//
//  ConnectionRepository.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/11/24.
//

final actor ConnectionRepository {
    var currentConnection: Connection?
    var connections: [Connection] = []
    
    func addConnection(_ connection: Connection) {
        connections.append(connection)
    }
    
    func setActive(_ connection: Connection) {
        currentConnection = connection
    }
}
