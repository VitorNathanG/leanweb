import LeanWeb.Decoding

namespace LeanWeb.Example

structure Services where
  greeting : IO String

def health : VerifiedHandler (fun _ response =>
    response.status = .ok ∧ response.body = "{\"status\":\"ok\"}") where
  run := fun _ => .json "{\"status\":\"ok\"}"
  ensures := fun _ => ⟨rfl, rfl⟩

def echo : VerifiedHandler (fun request response =>
    response.status = .ok ∧ response.body = request.body) where
  run := fun request => .text request.body
  ensures := fun _ => ⟨rfl, rfl⟩

def greeting : Handler (Action Services) := fun _ services => do
  return .text (← services.greeting)

def divisionPre (request : Request) (input : Nat × Nat) : Prop :=
  (request.body.toNat? = some input.1 ∧
    ∃ text, Decoder.queryValue request "by" = .ok text ∧ text.toNat? = some input.2) ∧
  (0 < input.2 ∧ input.1 ≤ 1000000 ∧ input.2 ≤ 1000000)

def divisionDecoder : Decoder (Nat × Nat) divisionPre :=
  (Decoder.bodyNat.zip (Decoder.queryNat "by")).refine
    (fun input => 0 < input.2 ∧ input.1 ≤ 1000000 ∧ input.2 ≤ 1000000)
    (.invalid "division: body must be 0..1000000 and by must be 1..1000000")

def divisionResult (quotient remainder : Nat) : Response :=
  .json ("{\"quotient\":" ++ toString quotient ++ ",\"remainder\":" ++ toString remainder ++ "}")

def divisionPost (_ : Request) (input : Nat × Nat) (response : Response) : Prop :=
  ∃ quotient remainder, response = divisionResult quotient remainder ∧
    input.2 * quotient + remainder = input.1 ∧ remainder < input.2

def divisionController : Controller (Nat × Nat) divisionPre divisionPost where
  run := fun _ input _ => divisionResult (input.1 / input.2) (input.1 % input.2)
  ensures := by
    intro request input pre
    exact ⟨input.1 / input.2, input.1 % input.2, rfl,
      Nat.div_add_mod input.1 input.2, Nat.mod_lt input.1 pre.2.1⟩

def division := divisionController.bind divisionDecoder

def routes : Router (Action Services) :=
  (Router.empty : Router (Action Services))
    |>.add ⟨.get, "/"⟩ greeting
    |>.add ⟨.get, "/health"⟩ health.lift
    |>.add ⟨.head, "/health"⟩ health.lift
    |>.add ⟨.post, "/echo"⟩ echo.lift
    |>.add ⟨.post, "/divide"⟩ division.lift

def bodyAllowed (request : Request) : Bool := request.body.toUTF8.size <= 65536

def rejectBody : Handler (Action Services) :=
  fun _ _ => pure (.text "Body exceeds application limit\n" .payloadTooLarge)

def app : Application Services where
  router := routes
  middleware := Middleware.guard bodyAllowed rejectBody

/-- The application rejects oversized bodies before dispatch, for every injected service. -/
theorem oversized_body_rejected (request : Request) (services : Services)
    (oversized : 65536 < request.body.toUTF8.size) :
    app.handle services request =
      pure (Response.text "Body exceeds application limit\n" .payloadTooLarge) := by
  have denied : bodyAllowed request = false := by
    simp only [bodyAllowed, decide_eq_false_iff_not]
    exact Nat.not_le_of_lt oversized
  simp [Application.handle, app, Middleware.guard, denied, rejectBody, ReaderT.run]

end LeanWeb.Example
