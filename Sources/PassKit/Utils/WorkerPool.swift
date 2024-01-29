import Logging

actor WorkerPool<W> where W: Worker {
  
  typealias WorkItem = W.WorkItem
  typealias WorkResult = W.WorkResult
  
  struct WorkerError: Error {}
  private let logger: Logger
  private var workers: [W] = []
  
  init(
    logger: Logger,
    workers: [W]
  ) {
    self.logger = logger
    self.workers = workers
  }
  
  func submit(work item: WorkItem) async throws -> WorkResult {
    guard let worker = workers.shuffled().first else {
      self.logger.error("No workers to submit job to. Workers: \(workers)")
      throw WorkerError()
    }
    return try await worker.submit(work: item)
  }
}

protocol Worker: Actor, Sendable {
  associatedtype WorkItem: Sendable
  associatedtype WorkResult: Sendable
  
  func submit(work: WorkItem) async throws -> WorkResult
}
