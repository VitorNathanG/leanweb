import LeanWeb.Router

namespace LeanWeb

abbrev Middleware (α : Type) := Handler α → Handler α

namespace Middleware

def identity : Middleware α := fun next => next

/-- The outer middleware sees the request first and the response last. -/
def compose (outer inner : Middleware α) : Middleware α :=
  fun next => outer (inner next)

/-- A rejected request returns the rejection action without selecting the next handler. -/
def guard (allow : Request → Bool) (reject : Handler α) : Middleware α :=
  fun next request => if allow request then next request else reject request

theorem guard_denied (allow : Request → Bool) (reject next : Handler α) (request : Request)
    (denied : allow request = false) :
    guard allow reject next request = reject request := by
  simp [guard, denied]

theorem guard_allowed (allow : Request → Bool) (reject next : Handler α) (request : Request)
    (allowed : allow request = true) :
    guard allow reject next request = next request := by
  simp [guard, allowed]

theorem compose_assoc (a b c : Middleware α) :
    compose (compose a b) c = compose a (compose b c) := rfl

theorem identity_left (middleware : Middleware α) :
    compose identity middleware = middleware := rfl

theorem identity_right (middleware : Middleware α) :
    compose middleware identity = middleware := rfl

end Middleware
end LeanWeb
