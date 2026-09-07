import LeanWeb.Application

namespace LeanWeb

inductive DecodeError where
  | missing (field : String)
  | invalid (field : String)
  | duplicate (field : String)
  deriving DecidableEq, Repr

def DecodeError.toResponse (error : DecodeError) : Response :=
  .text (match error with
    | .missing field => s!"Missing field: {field}\n"
    | .invalid field => s!"Invalid field: {field}\n"
    | .duplicate field => s!"Duplicate field: {field}\n") .badRequest

/-- A decoder must establish its declared relation between the request and the decoded value. -/
structure Decoder (α : Type) (valid : Request → α → Prop) where
  decode : Request → Except DecodeError α
  sound : ∀ request value, decode request = .ok value → valid request value

namespace Decoder

/-- Parse a bounded-length unsigned decimal, retaining its relation to the source text. -/
def nat (source : Request → Except DecodeError String) (field : String)
    (maxDigits : Nat := 20) : Decoder Nat (fun request value =>
      ∃ text, source request = .ok text ∧ text.toNat? = some value) where
  decode request :=
    match source request with
    | .error error => .error error
    | .ok text =>
      -- Keep the wire syntax explicit: upstream toNat? also accepts digit separators.
      if text.length > maxDigits || text.isEmpty ||
          !text.toList.all (fun c => '0' <= c && c <= '9') then .error (.invalid field)
      else match text.toNat? with
        | some value => .ok value
        | none => .error (.invalid field)
  sound request value decoded := by
    split at decoded
    next error => cases decoded
    next text sourceOk =>
      split at decoded
      next => cases decoded
      next =>
        split at decoded
        next parsed parsedOk =>
          cases decoded
          exact ⟨text, sourceOk, parsedOk⟩
        next => cases decoded

def bodyNat : Decoder Nat (fun request value => request.body.toNat? = some value) where
  decode := (nat (fun request => .ok request.body) "body").decode
  sound request value decoded := by
    obtain ⟨text, sourceOk, parsed⟩ :=
      (nat (fun request => .ok request.body) "body").sound request value decoded
    cases Except.ok.inj sourceOk
    exact parsed

/-- Raw query binding: exact keys, no percent or plus decoding, and no duplicate selected key. -/
def queryValue (request : Request) (name : String) : Except DecodeError String := do
  let mut value : Option String := none
  if !request.query.isEmpty then
    for entry in request.query.splitOn "&" do
      let [key, text] := entry.splitOn "=" | throw (.invalid "query")
      if key.isEmpty then throw (.invalid "query")
      if key == name then
        if value.isSome then throw (.duplicate name)
        value := some text
  match value with
  | some text => return text
  | none => throw (.missing name)

def queryNat (name : String) := nat (fun request => queryValue request name) name

/-- Decode left to right; both source relations hold on success. -/
def zip (left : Decoder α p) (right : Decoder β q) :
    Decoder (α × β) (fun request value => p request value.1 ∧ q request value.2) where
  decode request := do
    let a ← left.decode request
    let b ← right.decode request
    return (a, b)
  sound request value decoded := by
    simp only [Bind.bind, Except.bind] at decoded
    split at decoded
    next error => cases decoded
    next a leftOk =>
      split at decoded
      next error => cases decoded
      next b rightOk =>
        cases decoded
        exact ⟨left.sound request a leftOk, right.sound request b rightOk⟩

/-- Runtime validation strengthens an existing decoder's contract. -/
def refine (decoder : Decoder α valid) (constraint : α → Prop) [DecidablePred constraint]
    (error : DecodeError) : Decoder α (fun request value => valid request value ∧ constraint value) where
  decode request := do
    let value ← decoder.decode request
    if constraint value then return value else throw error
  sound request value decoded := by
    simp only [Bind.bind, Except.bind] at decoded
    split at decoded
    next error => cases decoded
    next parsed parsedOk =>
      split at decoded
      next accepted =>
        cases decoded
        exact ⟨decoder.sound request value parsedOk, accepted⟩
      next => cases decoded

/-- Select either rejection or a controller supplied with the decoder's proof. -/
def handle (decoder : Decoder α valid) (reject : DecodeError → β)
    (next : (request : Request) → (value : α) → valid request value → β) : Handler β :=
  fun request => match decoded : decoder.decode request with
    | .error error => reject error
    | .ok value => next request value (decoder.sound request value decoded)

theorem handle_error (decoder : Decoder α valid) (reject : DecodeError → β)
    (next : (request : Request) → (value : α) → valid request value → β)
    (request : Request) (error : DecodeError) (decoded : decoder.decode request = .error error) :
    decoder.handle reject next request = reject error := by
  unfold handle
  split
  next actual h =>
    cases Except.error.inj (h.symm.trans decoded)
    rfl
  next value h => cases h.symm.trans decoded

theorem handle_ok (decoder : Decoder α valid) (reject : DecodeError → β)
    (next : (request : Request) → (value : α) → valid request value → β)
    (request : Request) (value : α) (decoded : decoder.decode request = .ok value) :
    decoder.handle reject next request = next request value (decoder.sound request value decoded) := by
  unfold handle
  split
  next error h => cases h.symm.trans decoded
  next actual h =>
    cases Except.ok.inj (h.symm.trans decoded)
    rfl

end Decoder

/-- A pure controller can require a precondition and prove a response contract using that proof. -/
structure Controller (α : Type) (pre : Request → α → Prop)
    (post : Request → α → Response → Prop) where
  run : (request : Request) → (value : α) → pre request value → Response
  ensures : ∀ request value proof, post request value (run request value proof)

/-- The resulting handler proves either an explicit decoding error or the controller's contract. -/
def Controller.bind (controller : Controller α pre post) (decoder : Decoder α pre) :
    VerifiedHandler (fun request response =>
      (∃ error, decoder.decode request = .error error ∧ response = error.toResponse) ∨
      (∃ value, decoder.decode request = .ok value ∧ pre request value ∧ post request value response)) where
  run := decoder.handle DecodeError.toResponse controller.run
  ensures request := by
    cases decoded : decoder.decode request with
    | error error =>
      exact Or.inl ⟨error, rfl, decoder.handle_error _ _ request error decoded⟩
    | ok value =>
      refine Or.inr ⟨value, rfl, decoder.sound request value decoded, ?_⟩
      rw [decoder.handle_ok _ _ request value decoded]
      exact controller.ensures request value (decoder.sound request value decoded)

end LeanWeb
