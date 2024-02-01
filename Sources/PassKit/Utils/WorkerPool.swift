protocol Worker: Actor, Sendable {
  associatedtype WorkItem: Sendable
  associatedtype WorkResult: Sendable
  
  func submit(work: WorkItem) async throws -> WorkResult
}

struct WorkerPoolError: Error {}

actor WorkerPool<W> where W: Worker {
  
  typealias WorkItem = W.WorkItem
  typealias WorkResult = W.WorkResult
  
  private var workers: [W] = []
  private var currentIndex: Int = 0
  
  init(
    workers: [W]
  ) {
    self.workers = workers
  }
  
  func submit(work item: WorkItem) async throws -> WorkResult {
    try await self.getNextWorker()
      .submit(work: item)
  }
  
  private func getNextWorker() throws -> W {
    guard !self.workers.isEmpty else {
      throw WorkerPoolError()
    }
    let nextWorker = self.workers[currentIndex]
    self.currentIndex = (self.currentIndex + 1) % self.workers.count
    return nextWorker
  }
}
