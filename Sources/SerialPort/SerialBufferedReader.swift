import Foundation
import Dispatch
import PosixInputStream
import Trace

//  SerialBufferedReader is a high level helper that sits in front of the low level
//  PosixInputStream provided by SerialPort.  The reader accepts requests to deliver
//  bytes in three different shapes: by requesting a fixed number of bytes, by
//  reading until a delimiter, or by draining the entire buffer.  Incoming bytes
//  arrive on a background stream handler which feeds them into an in-memory buffer.
//  A dedicated serial DispatchQueue (bufferQueue) protects that buffer as well as
//  the queue of outstanding read requests.  Completion handlers run on an optional
//  client supplied callback queue to keep API consumers in control of threading.
//
//  The core control flow is therefore:
//  1.  An API method enqueues a PendingRequest and optionally installs a timeout.
//  2.  The request is stored in an ordered FIFO list that models the read queue.
//  3.  When bytes arrive, or when state changes, satisfyPendingRequests() iterates
//      the queue in order and fulfills requests whose conditions are met.
//  4.  Completed requests are dispatched back to the caller on callbackQueue.
//  5.  Terminal errors drain the request queue and surface the error to clients.
//
//  Extensive comments have been added throughout this file describing how each
//  piece participates in that flow, how the queues interact, and how errors and
//  timeouts are enforced.
public final class SerialBufferedReader {

  public enum ReadError: Error {
    case timeout
    case stream(Trace)
    case closed
  }

  private let serial: SerialPort
  private let stream: PosixInputStream
  //  All work that touches the internal buffer or the pending request queue is
  //  funneled through bufferQueue.  By serializing access we avoid locks while
  //  guaranteeing that enqueueing requests and appending bytes happens in a
  //  predictable order.
  private let bufferQueue: DispatchQueue
  //  Completion handlers are not executed on bufferQueue because bufferQueue is a
  //  critical section.  Instead they are bounced onto callbackQueue so that users
  //  can observe results on a thread of their choice (defaulting to global).
  private let callbackQueue: DispatchQueue
  //  When a reader is attached to an already configured SerialPort we retain the
  //  original handler and forward all events to it so that existing observers are
  //  not disrupted by the buffered reader.
  private let forwardingHandler: ((Result<Data, Trace>) -> Void)?

  //  The in-memory staging area for bytes that have been read from the underlying
  //  stream but have not yet been handed off to client callbacks.
  private var buffer = Data()
  //  Pending read requests are stored by UUID for O(1) access.  The actual FIFO
  //  order is maintained separately in the order array below.
  private var pending = [UUID: PendingRequest]()
  //  A simple FIFO list of request identifiers.  Requests are processed from the
  //  front whenever new data arrives or state changes.
  private var order = [UUID]()
  //  Once a terminal error is recorded no further reads succeed.  The error is
  //  captured so that late callers immediately receive the failure.
  private var terminalError: ReadError? = nil

  public convenience init(serialPort: SerialPort, callbackQueue: DispatchQueue? = nil) {
    let existingHandler = serialPort.stream.handler
    self.init(serialPort: serialPort,
              callbackQueue: callbackQueue,
              forwardingHandler: existingHandler)
  }

  internal init(serialPort: SerialPort,
                callbackQueue: DispatchQueue?,
                forwardingHandler: ((Result<Data, Trace>) -> Void)?) {

    self.serial = serialPort
    self.stream = serialPort.stream
    self.callbackQueue = callbackQueue ?? DispatchQueue.global(qos: .default)
    //  bufferQueue is the synchronization hub.  Everything that mutates shared
    //  state runs on this queue so that request/response ordering matches the
    //  order in which operations were scheduled.
    self.bufferQueue  = DispatchQueue(label: "SerialBufferedReader.buffer")
    self.forwardingHandler = forwardingHandler

    installHandler()
  }

  deinit {
    teardown(for: .closed)
  }

  
  //MARK: - Public API
  
  public func invalidate() {
    //  invalidate() simulates the SerialPort shutting down: pending requests are
    //  failed with `.closed` and the stream handler is restored.  This mirrors
    //  the behavior seen during deinit but is available explicitly to clients.
    teardown(for: .closed)
  }

  
  
  public func read ( count: Int, timeout: DispatchTimeInterval? = nil, completion: @escaping (Result<Data, ReadError>) -> Void ) {

    //  All read requests hop onto bufferQueue so they can examine and mutate the
    //  shared buffer synchronously with other operations.
    bufferQueue.async {

      guard count > 0 else {
        self.callbackQueue.async {
          completion(.success(Data()))
        }
        return
      }

      if let error = self.terminalError {
        self.callbackQueue.async {
          completion(.failure(error))
        }
        return
      }

      //  If there is already enough buffered data we can immediately satisfy the
      //  request without registering it in the pending queue.
      if self.buffer.count >= count {

        let chunk = self.buffer.prefix(count)
        self.buffer.removeFirst(count)

        self.callbackQueue.async {
          completion(.success(Data(chunk)))
        }

        return
      }

      //  Otherwise enqueue the request so that satisfyPendingRequests() can pick
      //  it up when future bytes arrive.  The optional timeout is also scheduled
      //  here.
      let request = PendingRequest(kind: .count(count), completion: completion)
      self.enqueue(request, timeout: timeout)
    }
  }

  
  
  public func read ( until delimiter: UInt8, includeDelimiter: Bool, timeout: DispatchTimeInterval? = nil, completion: @escaping (Result<Data, ReadError>) -> Void ) {

    bufferQueue.async {

      if let error = self.terminalError {
        self.callbackQueue.async {
          completion(.failure(error))
        }
        return
      }

      //  In the delimiter based read we search the current buffer for the target
      //  byte.  If found we can deliver the slice immediately.
      if let index = self.buffer.firstIndex(of: delimiter) {

        let afterDelimiter = self.buffer.index(after: index)
        let endIndex       = includeDelimiter ? afterDelimiter : index

        let chunk = self.buffer[..<endIndex]
        self.buffer.removeSubrange(self.buffer.startIndex..<afterDelimiter)

        self.callbackQueue.async {
          completion(.success(Data(chunk)))
        }

        return
      }

      //  Otherwise the request is queued so future bytes can be checked for the
      //  delimiter.  The pending queue keeps requests in FIFO order so that once
      //  the delimiter arrives earlier requests are satisfied first.
      let request = PendingRequest(kind: .delimiter(delimiter, include: includeDelimiter),
                                   completion: completion)
      self.enqueue(request, timeout: timeout)
    }
  }

  
  
  public func read ( timeout: DispatchTimeInterval? = nil, completion: @escaping (Result<Data, ReadError>) -> Void ) {

    bufferQueue.async {

      if let error = self.terminalError {
        self.callbackQueue.async {
          completion(.failure(error))
        }
        return
      }

      //  A drain request can complete immediately if there are no outstanding
      //  pending requests waiting ahead of it.  This prevents it from consuming
      //  bytes that earlier requests are expecting.
      if self.order.isEmpty {

        let chunk = self.buffer
        self.buffer.removeAll(keepingCapacity: false)

        self.callbackQueue.async {
          completion(.success(chunk))
        }

        return
      }

      let request = PendingRequest(kind: .drain, completion: completion)
      //  Drains still respect FIFO ordering, so they are enqueued behind any
      //  existing request.  Calling satisfyPendingRequests() immediately gives
      //  the queue a chance to fulfill the drain if the buffer is already free.
      self.enqueue(request, timeout: timeout)
      self.satisfyPendingRequests()
    }
  }
  
  
  
  
  //MARK: Implmentation
  
  private func installHandler() {

    let forward = forwardingHandler

    stream.handler = { [weak self] result in

      forward?(result)

      guard let self = self else { return }

      //  Every event from the stream is re-serialized onto bufferQueue so the
      //  handler can cooperate with any in-flight read requests.  Success events
      //  append bytes, while failures transition the reader into a terminal error
      //  state.
      switch result {
        case .success(let data):
          self.bufferQueue.async {
            self.appendIncoming(data)
          }

        case .failure(let trace):
          self.bufferQueue.async {
            self.handleStreamError(trace)
          }
      }
    }
  }

  private func appendIncoming(_ data: Data) {

    guard terminalError == nil else { return }
    guard data.isEmpty == false else { return }

    //  Incoming bytes are appended and then we immediately try to satisfy any
    //  waiting requests.  Because we run on bufferQueue, this will process the
    //  queue before any new read requests are enqueued.
    buffer.append(data)
    satisfyPendingRequests()
  }

  private func handleStreamError(_ trace: Trace) {

    guard terminalError == nil else { return }

    terminalError = .stream(trace)

    //  Transitioning into a terminal state drains every pending request so
    //  callers are notified promptly that no additional data will be delivered.
    let requests = drainPendingRequests()
    dispatch(requests: requests, with: .failure(.stream(trace)))
  }

  private func teardown(for error: ReadError) {

    bufferQueue.async {

      guard self.terminalError == nil else { return }

      self.terminalError = error

      //  teardown() mirrors handleStreamError(): remove all pending requests,
      //  fail them with the provided error, and restore the original stream
      //  handler so ownership of the SerialPort returns to the caller.
      let requests = self.drainPendingRequests()

      self.dispatch(requests: requests, with: .failure(error))
      self.stream.handler = self.forwardingHandler
    }
  }



  private func enqueue(_ request: PendingRequest, timeout: DispatchTimeInterval?) {

    pending[request.id] = request
    order.append(request.id)

    //  Each request can have an optional timeout.  We use a timer source bound
    //  to bufferQueue so that the timeout fires in the same serialized context
    //  as the rest of the state machine.
    if let timeout = timeout {
      scheduleTimeout(for: request, interval: timeout)
    }
  }

  private func scheduleTimeout(for request: PendingRequest, interval: DispatchTimeInterval) {

    let timer = DispatchSource.makeTimerSource(queue: bufferQueue)
    let deadline = DispatchTime.now() + interval

    let requestID = request.id

    timer.schedule(deadline: deadline)
    timer.setEventHandler { [weak self] in
      self?.handleTimeout(for: requestID)
    }
    timer.resume()

    request.timer = timer
  }

  private func handleTimeout(for id: UUID) {

    guard let request = removeRequest(with: id) else { return }

    //  Timeouts are delivered just like other failures: the request is removed
    //  from the queue and its completion handler is executed on callbackQueue.
    dispatch(request: request, result: .failure(.timeout))
    satisfyPendingRequests()
  }

  private func satisfyPendingRequests() {

    var fulfilled = [(PendingRequest, Data)]()
    var consumed  = [UUID]()

    requestLoop: for id in order {

      guard let request = pending[id] else { continue }

      //  Requests are evaluated in FIFO order.  If a request cannot be fulfilled
      //  yet we break out of the loop so later requests do not leapfrog it.
      switch request.kind {
        case .count(let expected):

          guard buffer.count >= expected else { break requestLoop }

          let chunk = buffer.prefix(expected)
          buffer.removeFirst(expected)

          fulfilled.append((request, Data(chunk)))
          consumed.append(id)

        case .delimiter(let delimiter, let include):

          guard let index = buffer.firstIndex(of: delimiter) else { break requestLoop }

          //  When the delimiter is found we remove bytes up to (and optionally
          //  including) the delimiter so subsequent requests only see the
          //  remaining data.
          let afterDelimiter = buffer.index(after: index)
          let endIndex       = include ? afterDelimiter : index

          let chunk = buffer[..<endIndex]
          buffer.removeSubrange(buffer.startIndex..<afterDelimiter)

          fulfilled.append((request, Data(chunk)))
          consumed.append(id)

        case .drain:

          let chunk = buffer
          buffer.removeAll(keepingCapacity: false)

          //  Drains always succeed once they reach the front of the queue
          //  because they consume whatever data is currently buffered.
          fulfilled.append((request, chunk))
          consumed.append(id)
      }
    }

    for id in consumed {
      _ = removeRequest(with: id)
    }

    for (request, data) in fulfilled {
      dispatch(request: request, result: .success(data))
    }
  }

  @discardableResult
  private func removeRequest(with id: UUID) -> PendingRequest? {

    guard let request = pending.removeValue(forKey: id) else { return nil }

    //  Requests can only be removed from the middle of the queue via timeouts or
    //  cancellations.  We keep `order` in sync so that satisfyPendingRequests()
    //  continues iterating correctly.
    if let index = order.firstIndex(of: id) {
      order.remove(at: index)
    }

    request.timer?.cancel()
    request.timer = nil

    return request
  }

  private func drainPendingRequests() -> [PendingRequest] {

    let requests = order.compactMap { pending[$0] }

    pending.removeAll(keepingCapacity: false)
    order.removeAll(keepingCapacity: false)

    for request in requests {
      //  Cancel any outstanding timers so they do not fire after we have already
      //  decided the terminal state for those requests.
      request.timer?.cancel()
      request.timer = nil
    }

    return requests
  }

  private func dispatch(request: PendingRequest, result: Result<Data, ReadError>) {
    //  Completions are dispatched asynchronously to avoid re-entrancy on
    //  bufferQueue and to respect the caller's desired execution context.
    callbackQueue.async {
      request.completion(result)
    }
  }

  private func dispatch(requests: [PendingRequest], with result: Result<Data, ReadError>) {

    guard requests.isEmpty == false else { return }

    //  Batch dispatch keeps the ordering guarantees while minimizing the number
    //  of context switches.  Each completion runs in FIFO order.
    callbackQueue.async {
      for request in requests {
        request.completion(result)
      }
    }
  }
}

