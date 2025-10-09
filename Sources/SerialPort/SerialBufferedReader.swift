import Foundation
import Dispatch
import PosixInputStream
import Trace

public final class SerialBufferedReader {

  public enum ReadError: Error {
    case timeout
    case stream(Trace)
    case closed
  }

  private let serial: SerialPort
  private let stream: PosixInputStream
  private let bufferQueue: DispatchQueue
  private let callbackQueue: DispatchQueue
  private let forwardingHandler: ((Result<Data, Trace>) -> Void)?

  private var buffer = Data()
  private var pending = [UUID: PendingRequest]()
  private var order = [UUID]()
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
    self.bufferQueue  = DispatchQueue(label: "SerialBufferedReader.buffer")
    self.forwardingHandler = forwardingHandler

    installHandler()
  }

  deinit {
    teardown(for: .closed)
  }

  
  //MARK: - Public API
  
  public func invalidate() {
    teardown(for: .closed)
  }

  
  
  public func read ( count: Int, timeout: DispatchTimeInterval? = nil, completion: @escaping (Result<Data, ReadError>) -> Void ) {

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

      if self.buffer.count >= count {

        let chunk = self.buffer.prefix(count)
        self.buffer.removeFirst(count)

        self.callbackQueue.async {
          completion(.success(Data(chunk)))
        }

        return
      }

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

      if self.order.isEmpty {

        let chunk = self.buffer
        self.buffer.removeAll(keepingCapacity: false)

        self.callbackQueue.async {
          completion(.success(chunk))
        }

        return
      }

      let request = PendingRequest(kind: .drain, completion: completion)
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

    buffer.append(data)
    satisfyPendingRequests()
  }

  private func handleStreamError(_ trace: Trace) {

    guard terminalError == nil else { return }

    terminalError = .stream(trace)

    let requests = drainPendingRequests()
    dispatch(requests: requests, with: .failure(.stream(trace)))
  }

  private func teardown(for error: ReadError) {

    bufferQueue.async {

      guard self.terminalError == nil else { return }

      self.terminalError = error

      let requests = self.drainPendingRequests()

      self.dispatch(requests: requests, with: .failure(error))
      self.stream.handler = self.forwardingHandler
    }
  }



  private func enqueue(_ request: PendingRequest, timeout: DispatchTimeInterval?) {

    pending[request.id] = request
    order.append(request.id)

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

    dispatch(request: request, result: .failure(.timeout))
    satisfyPendingRequests()
  }

  private func satisfyPendingRequests() {

    var fulfilled = [(PendingRequest, Data)]()
    var consumed  = [UUID]()

    requestLoop: for id in order {

      guard let request = pending[id] else { continue }

      switch request.kind {
        case .count(let expected):

          guard buffer.count >= expected else { break requestLoop }

          let chunk = buffer.prefix(expected)
          buffer.removeFirst(expected)

          fulfilled.append((request, Data(chunk)))
          consumed.append(id)

        case .delimiter(let delimiter, let include):

          guard let index = buffer.firstIndex(of: delimiter) else { break requestLoop }

          let afterDelimiter = buffer.index(after: index)
          let endIndex       = include ? afterDelimiter : index

          let chunk = buffer[..<endIndex]
          buffer.removeSubrange(buffer.startIndex..<afterDelimiter)

          fulfilled.append((request, Data(chunk)))
          consumed.append(id)

        case .drain:

          let chunk = buffer
          buffer.removeAll(keepingCapacity: false)

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
      request.timer?.cancel()
      request.timer = nil
    }

    return requests
  }

  private func dispatch(request: PendingRequest, result: Result<Data, ReadError>) {
    callbackQueue.async {
      request.completion(result)
    }
  }

  private func dispatch(requests: [PendingRequest], with result: Result<Data, ReadError>) {

    guard requests.isEmpty == false else { return }

    callbackQueue.async {
      for request in requests {
        request.completion(result)
      }
    }
  }
}

