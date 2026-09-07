import Std

namespace LeanWeb

inductive Method where
  | get | head | post | put | patch | delete | options
  deriving DecidableEq, BEq, Repr

def Method.parse : String → Option Method
  | "GET" => some .get
  | "HEAD" => some .head
  | "POST" => some .post
  | "PUT" => some .put
  | "PATCH" => some .patch
  | "DELETE" => some .delete
  | "OPTIONS" => some .options
  | _ => none

structure Request where
  method : Method
  path : String
  query : String := ""
  headers : List (String × String) := []
  body : String := ""
  deriving Repr

/-- Header names are compared case-insensitively. Duplicate handling belongs to the parser. -/
def Request.header? (request : Request) (name : String) : Option String :=
  (request.headers.find? (fun entry => entry.1.toLower == name.toLower)).map Prod.snd

inductive Status where
  | ok | created | badRequest | unauthorized | forbidden | notFound
  | methodNotAllowed | requestTimeout | payloadTooLarge | internalServerError | notImplemented
  deriving DecidableEq, BEq, Repr

def Status.code : Status → Nat
  | .ok => 200
  | .created => 201
  | .badRequest => 400
  | .unauthorized => 401
  | .forbidden => 403
  | .notFound => 404
  | .methodNotAllowed => 405
  | .requestTimeout => 408
  | .payloadTooLarge => 413
  | .internalServerError => 500
  | .notImplemented => 501

def Status.reason : Status → String
  | .ok => "OK"
  | .created => "Created"
  | .badRequest => "Bad Request"
  | .unauthorized => "Unauthorized"
  | .forbidden => "Forbidden"
  | .notFound => "Not Found"
  | .methodNotAllowed => "Method Not Allowed"
  | .requestTimeout => "Request Timeout"
  | .payloadTooLarge => "Payload Too Large"
  | .internalServerError => "Internal Server Error"
  | .notImplemented => "Not Implemented"

inductive ContentType where
  | text | json
  deriving DecidableEq, BEq, Repr

def ContentType.value : ContentType → String
  | .text => "text/plain; charset=utf-8"
  | .json => "application/json; charset=utf-8"

/-- Fixed header choices keep application strings out of the HTTP header block. -/
structure Response where
  status : Status := .ok
  contentType : ContentType := .text
  body : String := ""
  deriving DecidableEq, BEq, Repr

def Response.text (body : String) (status : Status := .ok) : Response :=
  { status, body }

def Response.json (body : String) (status : Status := .ok) : Response :=
  { status, contentType := .json, body }

def Response.notFound : Response := .text "Not found\n" .notFound

end LeanWeb
