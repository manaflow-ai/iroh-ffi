import Foundation

func irohConnectWithTaskCancellation(
    attempt: any ConnectAttemptProtocol
) async throws -> Connection {
    try await withTaskCancellationHandler(operation: {
        do {
            try Task.checkCancellation()
            let connection = try await attempt.connect()
            try Task.checkCancellation()
            return connection
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }, onCancel: {
        attempt.cancel()
    })
}
