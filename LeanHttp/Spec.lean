import LeanHttp.Types

set_option autoImplicit false

namespace LeanHttp.Spec

def ows (c : Char) : Bool := c == ' ' || c == '\t'

def token (c : Char) : Bool :=
  ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z') ||
  ('0' <= c && c <= '9') || "!#$%&'*+-.^_`|~".toList.contains c

def digits (text : String) : Bool :=
  !text.isEmpty && text.toList.all (fun c => '0' <= c && c <= '9')

def decimal (text : String) : Nat :=
  text.toList.foldl (fun n c => 10 * n + (c.toNat - '0'.toNat)) 0

def targetChar (c : Char) : Bool := 32 < c.toNat && c.toNat < 127 && c != '#'

def hostValue (text : String) : Bool :=
  !text.isEmpty && text.toList.all (fun c => targetChar c && !",/\\@?".toList.contains c)

def fieldValue (text : String) : Bool :=
  text.toList.all (fun c => (32 <= c.toNat || c == '\t') && c.toNat != 127)

def trimOWS (text : String) : String :=
  String.ofList ((text.toList.dropWhile ows).reverse.dropWhile ows).reverse

def asciiLower (text : String) : String :=
  String.ofList (text.toList.map fun c =>
    if 'A' <= c && c <= 'Z' then Char.ofNat (c.toNat + 32) else c)

def methodText : Method → String
  | .get => "GET" | .head => "HEAD" | .post => "POST" | .put => "PUT"
  | .patch => "PATCH" | .delete => "DELETE" | .options => "OPTIONS"

inductive Target where
  | origin (path : String) (query : Option String)
  | asterisk
  deriving DecidableEq, Repr

def Target.text : Target → String
  | .origin path none => path
  | .origin path (some query) => path ++ "?" ++ query
  | .asterisk => "*"

def Target.valid (target : Target) (method : Method) : Bool :=
  match target with
  | .origin path query =>
    path.toList.head? == some '/' && !path.toList.contains '?' && path.toList.all targetChar &&
      (query.getD "").toList.all targetChar
  | .asterisk => method == .options

structure Field where
  name : String
  value : String
  leading : String := ""
  trailing : String := ""
  deriving DecidableEq, Repr

def Field.line (field : Field) : String :=
  field.name ++ ":" ++ field.leading ++ field.value ++ field.trailing

def Field.text (field : Field) : String := field.line ++ "\r\n"

def Field.valid (field : Field) : Bool :=
  !field.name.isEmpty && field.name.toList.all token && fieldValue field.value &&
    trimOWS field.value == field.value && field.leading.toList.all ows &&
    field.trailing.toList.all ows

structure RequestForm where
  method : Method
  target : Target
  fields : List Field
  body : String := ""
  deriving Repr

def RequestForm.header (form : RequestForm) : String :=
  methodText form.method ++ " " ++ form.target.text ++ " HTTP/1.1\r\n" ++
    String.join (form.fields.map Field.text) ++ "\r\n"

def RequestForm.bytes (form : RequestForm) : ByteArray :=
  form.header.toUTF8 ++ form.body.toUTF8

def RequestForm.request (form : RequestForm) : Request :=
  let (path, query) := match form.target with
    | .origin path query => (path, query.getD "")
    | .asterisk => ("*", "")
  { method := form.method, path, query, body := form.body
    headers := form.fields.map (fun field => (asciiLower field.name, field.value)) }

def RequestForm.valid (form : RequestForm) (limit : Nat) : Bool :=
  let hosts := form.fields.filter (fun field => asciiLower field.name == "host")
  let lengths := form.fields.filter (fun field => asciiLower field.name == "content-length")
  let framed := match lengths with
    | [] => form.body.isEmpty
    | [field] => digits field.value && decimal field.value == form.body.toUTF8.size
    | _ => false
  form.target.valid form.method && form.fields.all Field.valid &&
    hosts.length == 1 && hosts.all (fun field => hostValue field.value) && framed &&
    form.fields.all (fun field =>
      asciiLower field.name != "transfer-encoding" && asciiLower field.name != "expect") &&
    form.bytes.size <= limit

abbrev RequestForm.Valid (form : RequestForm) (limit : Nat) : Prop := form.valid limit = true

/-- Complete request grammar, independent of the parser and its validation order. -/
def Represents (limit : Nat) (bytes : ByteArray) (request : Request) : Prop :=
  ∃ form : RequestForm, form.Valid limit ∧ bytes = form.bytes ∧ request = form.request

inductive Rejection where
  | tooLarge | bareLF | bareCR | headerControl | headerUTF8
  | requestLine | method | version | unsupportedVersion | unsupportedMethod | target
  | fieldName | fieldValue | duplicateHost | host | duplicateLength | length
  | transferEncoding | expect | missingHost | trailing | bodyUTF8
  deriving DecidableEq, BEq, Repr

def Rejection.response (error : Rejection) : Response :=
  let (message, status) := match error with
    | .tooLarge => ("Request too large", Status.payloadTooLarge)
    | .unsupportedVersion => ("Only HTTP/1.1 is supported", .notImplemented)
    | .unsupportedMethod => ("Unsupported method", .notImplemented)
    | .transferEncoding => ("Transfer-Encoding is not supported", .notImplemented)
    | .expect => ("Expect is not supported", .notImplemented)
    | .bareLF => ("Bare LF in headers", .badRequest)
    | .bareCR => ("Bare CR in headers", .badRequest)
    | .headerControl => ("Control character in headers", .badRequest)
    | .headerUTF8 => ("Invalid UTF-8 in headers", .badRequest)
    | .requestLine => ("Malformed request line", .badRequest)
    | .method => ("Malformed method", .badRequest)
    | .version => ("Malformed HTTP version", .badRequest)
    | .target => ("Invalid request target", .badRequest)
    | .fieldName => ("Malformed header name", .badRequest)
    | .fieldValue => ("Invalid header value", .badRequest)
    | .duplicateHost => ("Duplicate Host", .badRequest)
    | .host => ("Invalid Host", .badRequest)
    | .duplicateLength => ("Duplicate Content-Length", .badRequest)
    | .length => ("Invalid Content-Length", .badRequest)
    | .missingHost => ("Missing Host", .badRequest)
    | .trailing => ("Trailing bytes after request", .badRequest)
    | .bodyUTF8 => ("Invalid UTF-8 in body", .badRequest)
  .text (message ++ "\n") status

structure Check where
  passes : Bool
  error : Rejection
  deriving Repr

abbrev ChecksPass (checks : List Check) : Prop := checks.all Check.passes = true

/-- Only the first failed condition determines the rejection. -/
abbrev FirstFailure (checks : List Check) (error : Rejection) : Prop :=
  (checks.find? (fun check => !check.passes)).map Check.error = some error

/-- UTF-8 is specified by an encoding witness, not a call to a decoder. -/
def UTF8 (bytes : ByteArray) : Prop := ∃ text : String, text.toUTF8 = bytes

def headerEnd (bytes : ByteArray) : Option Nat :=
  ((List.range bytes.size).find? (fun start =>
    bytes.extract start (start + 4) == "\r\n\r\n".toUTF8)).map (· + 4)

def scanChecks (bytes : ByteArray) : List Check :=
  (List.range ((headerEnd bytes).getD bytes.size)).flatMap fun i =>
    let byte := bytes.data[i]?
    [⟨byte != some 10 || (i > 0 && bytes.data[i - 1]? == some 13), .bareLF⟩,
     ⟨byte != some 13 || i + 1 >= bytes.size || bytes.data[i + 1]? == some 10, .bareCR⟩,
     ⟨!(byte.getD 0 < 32 && byte != some 9 && byte != some 10 && byte != some 13) &&
       byte != some 127, .headerControl⟩]

private structure FieldView where
  originalName : String
  name : String
  value : String
  hasColon : Bool

private def prependPart (c : Char) : List (List Char) → List (List Char)
  | [] => [[c]]
  | part :: rest => (c :: part) :: rest

private def splitChar (separator : Char) (text : String) : List String :=
  (text.toList.foldr (fun c rest =>
    if c == separator then [] :: rest else prependPart c rest) [[]]).map String.ofList

private def splitLines : List Char → List (List Char)
  | [] => [[]]
  | '\r' :: '\n' :: rest => [] :: splitLines rest
  | c :: rest => prependPart c (splitLines rest)

private def fieldView (line : String) : FieldView :=
  let parts := splitChar ':' line
  { originalName := parts.headD ""
    name := asciiLower (parts.headD "")
    value := trimOWS (String.intercalate ":" (parts.drop 1))
    hasColon := parts.length > 1 }

structure Head where
  text : String
  endPos : Nat
  deriving Repr

abbrev Head.Matches (head : Head) (bytes : ByteArray) : Prop :=
  headerEnd bytes = some head.endPos ∧
    head.text.toUTF8 = bytes.extract 0 (head.endPos - 4)

private def Head.words (head : Head) : List String :=
  splitChar ' ' (String.ofList ((splitLines head.text.toList).headD []))

private def Head.fields (head : Head) : List FieldView :=
  ((splitLines head.text.toList).drop 1).map (fun line => fieldView (String.ofList line))

def Head.bodyLength (head : Head) : Nat :=
  ((head.fields.find? (fun field => field.name == "content-length")).map
    (fun field => decimal field.value)).getD 0

def Head.total (head : Head) : Nat := head.endPos + head.bodyLength

/-- Ordered obligations over header text; they do not decode a request. -/
def Head.checks (head : Head) (limit : Nat) : List Check := Id.run do
  let words := head.words
  let method := words.headD ""
  let target := (words.drop 1).headD ""
  let version := (words.drop 2).headD ""
  let methods := ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
  let line := [
    ⟨words.length == 3, Rejection.requestLine⟩,
    ⟨!method.isEmpty && method.toList.all token, .method⟩,
    ⟨version == "HTTP/1.1", if version.toList.take 5 == "HTTP/".toList then
      .unsupportedVersion else .version⟩,
    ⟨methods.contains method, .unsupportedMethod⟩,
    ⟨(target.toList.head? == some '/' || (target == "*" && method == "OPTIONS")) &&
      target.toList.all targetChar, .target⟩]
  let fields := head.fields
  let conditions := fields.zipIdx |>.flatMap fun (field, i) =>
    let host := field.name == "host"
    let length := field.name == "content-length"
    let prior := fields.take i
    [⟨field.hasColon && !field.originalName.isEmpty &&
       field.originalName.toList.all token, .fieldName⟩,
     ⟨fieldValue field.value, .fieldValue⟩,
     ⟨!host || !(prior.any (fun field => field.name == "host")), .duplicateHost⟩,
     ⟨!host || hostValue field.value, .host⟩,
     ⟨!length || !(prior.any (fun field => field.name == "content-length")), .duplicateLength⟩,
     ⟨!length || digits field.value, .length⟩,
     ⟨!length || decimal field.value <= limit - head.endPos, .tooLarge⟩,
     ⟨field.name != "transfer-encoding", .transferEncoding⟩,
     ⟨field.name != "expect", .expect⟩]
  return line ++ conditions ++ [⟨fields.any (fun field => field.name == "host"), .missingHost⟩]

inductive Outcome where
  | needMore
  | rejected (error : Rejection)
  | complete (request : Request)

def Outcome.result : Outcome → Except Response (Option Request)
  | .needMore => .ok none
  | .rejected error => .error error.response
  | .complete request => .ok (some request)

/-- Outcomes once a byte-matched UTF-8 header is available. -/
inductive HeaderOutcome (limit : Nat) (bytes : ByteArray) (head : Head) : Outcome → Prop where
  | rejected {error : Rejection} (failure : FirstFailure (head.checks limit) error) :
      HeaderOutcome limit bytes head (.rejected error)
  | tooLarge (passed : ChecksPass (head.checks limit)) (large : head.total > limit) :
      HeaderOutcome limit bytes head (.rejected .tooLarge)
  | needMore (passed : ChecksPass (head.checks limit))
      (fits : head.total <= limit) (short : bytes.size < head.total) :
      HeaderOutcome limit bytes head .needMore
  | trailing (passed : ChecksPass (head.checks limit))
      (fits : head.total <= limit) (long : bytes.size > head.total) :
      HeaderOutcome limit bytes head (.rejected .trailing)
  | bodyUTF8 (passed : ChecksPass (head.checks limit))
      (fits : head.total <= limit) (exact : bytes.size = head.total)
      (invalid : ¬UTF8 (bytes.extract head.endPos head.total)) :
      HeaderOutcome limit bytes head (.rejected .bodyUTF8)
  | complete {request : Request} (passed : ChecksPass (head.checks limit))
      (exact : bytes.size = head.total) (represented : Represents limit bytes request) :
      HeaderOutcome limit bytes head (.complete request)

/-- Outcomes after byte-level header framing checks have passed. -/
inductive FramedOutcome (limit : Nat) (bytes : ByteArray) : Outcome → Prop where
  | needMore (missing : headerEnd bytes = none) (room : bytes.size < limit) :
      FramedOutcome limit bytes .needMore
  | exhausted (missing : headerEnd bytes = none) (full : bytes.size = limit) :
      FramedOutcome limit bytes (.rejected .tooLarge)
  | headerUTF8 {endPos : Nat} (boundary : headerEnd bytes = some endPos)
      (invalid : ¬UTF8 (bytes.extract 0 (endPos - 4))) :
      FramedOutcome limit bytes (.rejected .headerUTF8)
  | header {head : Head} {result : Outcome}
      (source : head.Matches bytes) (outcome : HeaderOutcome limit bytes head result) :
      FramedOutcome limit bytes result

/-- Buffer outcomes only: EOF, wall-clock deadlines, and IO failures belong to the server. -/
inductive RequestOutcome (limit : Nat) (bytes : ByteArray) : Outcome → Prop where
  | tooLarge (large : bytes.size > limit) : RequestOutcome limit bytes (.rejected .tooLarge)
  | scan {error : Rejection} (within : bytes.size <= limit)
      (failure : FirstFailure (scanChecks bytes) error) :
      RequestOutcome limit bytes (.rejected error)
  | framed {result : Outcome} (within : bytes.size <= limit) (passed : ChecksPass (scanChecks bytes))
      (outcome : FramedOutcome limit bytes result) : RequestOutcome limit bytes result

def responseHeader (response : Response) : String :=
  String.intercalate "\r\n" [
    "HTTP/1.1 " ++ toString response.status.code ++ " " ++ response.status.reason,
    "Content-Type: " ++ response.contentType.value,
    "Content-Length: " ++ toString response.body.toUTF8.size,
    "Connection: close", "", ""]

abbrev ResponseRepresents (response : Response) (headOnly : Bool) (bytes : ByteArray) : Prop :=
  bytes = (responseHeader response).toUTF8 ++
    (if headOnly then ByteArray.empty else response.body.toUTF8)

end LeanHttp.Spec
