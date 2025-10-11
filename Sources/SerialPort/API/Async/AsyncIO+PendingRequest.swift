import Foundation
import Dispatch

extension AsyncIO {

  final class PendingRequest {

    enum Kind {
      case count(Int)
      case delimiter(UInt8, include: Bool)
      case drain
    }

    let id = UUID()
    let kind: Kind
    let completion: (Result<Data, ReadError>) -> Void
    var timer: DispatchSourceTimer?

    init(kind: Kind, completion: @escaping (Result<Data, ReadError>) -> Void) {
      self.kind = kind
      self.completion = completion
    }
  }

  final class PendingWrite {

    let id = UUID()
    let completion: (Result<Int, WriteError>) -> Void
    var timer: DispatchSourceTimer?

    init(completion: @escaping (Result<Int, WriteError>) -> Void) {
      self.completion = completion
    }
  }
}
