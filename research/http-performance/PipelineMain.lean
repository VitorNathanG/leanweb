import LeanHttp
import Example

open LeanHttp

inductive Mode where
  | parse | handle | render | pipeline

def main : IO Unit := do
  let iterations := 100000
  let mut inputs : Array ByteArray := #[]
  let mut requests : Array Request := #[]
  let mut responses : Array Response := #[]
  for i in [:64] do
    let input := s!"GET /health?probe={i} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".toUTF8
    let .ok (some request) := Wire.parse input
      | throw (IO.userError "Invalid pipeline probe input")
    inputs := inputs.push input
    requests := requests.push request
    let code := String.singleton (Char.ofNat (97 + i % 26))
    responses := responses.push (.json ("{\"status\":\"" ++ code ++ "k\"}"))
  let services : Example.Services := { greeting := pure "unused" }
  for repetition in [:3] do
    for (name, mode) in [("parse", Mode.parse), ("handle", .handle), ("render", .render),
        ("pipeline", .pipeline)] do
      let mut checksum := 0
      let started ← IO.monoNanosNow
      for i in [:iterations] do
        let index := i % 64
        match mode with
        | .parse =>
          let .ok (some request) := Wire.parse inputs[index]!
            | throw (IO.userError "Probe parsing failed")
          checksum := checksum + request.query.utf8ByteSize
        | .handle =>
          let some prepared := requests[index]?
            | throw (IO.userError "Missing prepared request")
          let result ← Example.app.handle services prepared
          checksum := checksum + result.body.utf8ByteSize
        | .render =>
          let some prepared := responses[index]?
            | throw (IO.userError "Missing prepared response")
          let rendered := Wire.render prepared
          checksum := checksum + rendered.size + rendered[rendered.size - 4]!.toNat
        | .pipeline =>
          let .ok (some request) := Wire.parse inputs[index]!
            | throw (IO.userError "Probe parsing failed")
          let result ← Example.app.handle services request
          checksum := checksum + (Wire.render result).size
      let elapsed := (← IO.monoNanosNow) - started
      if checksum == 0 then throw (IO.userError "Unused benchmark result")
      IO.println ("{\"mode\":\"" ++ name ++ "\",\"repetition\":" ++ toString (repetition + 1) ++
        ",\"iterations\":" ++ toString iterations ++ ",\"nanoseconds\":" ++ toString elapsed ++
        ",\"checksum\":" ++ toString checksum ++ "}")
