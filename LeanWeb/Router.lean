import LeanWeb.Http

namespace LeanWeb

/-- Handlers can return pure responses, IO actions, or dependency-injected actions. -/
abbrev Handler (α : Type) := Request → α

structure RouteKey where
  method : Method
  path : String
  deriving DecidableEq, Repr

def Request.routeKey (request : Request) : RouteKey :=
  { method := request.method, path := request.path }

structure Route (α : Type) where
  key : RouteKey
  handler : Handler α

/-- An ambiguous route table cannot be constructed without a false proof. -/
structure Router (α : Type) where
  routes : List (Route α)
  unique : (routes.map Route.key).Nodup

namespace Router

def empty : Router α := ⟨[], by simp⟩

def add (router : Router α) (key : RouteKey) (handler : Handler α)
    (fresh : key ∉ router.routes.map Route.key := by decide) : Router α :=
  ⟨⟨key, handler⟩ :: router.routes, by simp [fresh, router.unique]⟩

def lookup : List (Route α) → RouteKey → Option (Handler α)
  | [], _ => none
  | route :: rest, key =>
    if route.key = key then some route.handler else lookup rest key

def dispatch (router : Router α) (fallback : Handler α) : Handler α :=
  fun request => match lookup router.routes request.routeKey with
    | some handler => handler request
    | none => fallback request

/-- Every selected handler belongs to a route with exactly the requested method and path. -/
theorem lookup_sound (routes : List (Route α)) (key : RouteKey) (handler : Handler α)
    (found : lookup routes key = some handler) :
    ∃ route ∈ routes, route.key = key ∧ route.handler = handler := by
  induction routes with
  | nil => simp [lookup] at found
  | cons route rest ih =>
    simp only [lookup] at found
    split at found
    next equal =>
      exact ⟨route, by simp, equal, Option.some.inj found⟩
    next =>
      obtain ⟨matched, member, equal, selected⟩ := ih found
      exact ⟨matched, List.mem_cons_of_mem route member, equal, selected⟩

/-- Lookup fails exactly when the method/path key is absent. -/
theorem lookup_none_iff (routes : List (Route α)) (key : RouteKey) :
    lookup routes key = none ↔ key ∉ routes.map Route.key := by
  induction routes with
  | nil => simp [lookup]
  | cons route rest ih =>
    by_cases equal : route.key = key
    · simp [lookup, equal]
    · simp [lookup, equal, ih, Ne.symm equal]

theorem dispatch_missing (router : Router α) (fallback : Handler α) (request : Request)
    (missing : request.routeKey ∉ router.routes.map Route.key) :
    router.dispatch fallback request = fallback request := by
  simp [dispatch, (lookup_none_iff _ _).mpr missing]

/-- Adding a fresh route makes it immediately reachable. -/
theorem dispatch_added (router : Router α) (key : RouteKey) (handler fallback : Handler α)
    (fresh : key ∉ router.routes.map Route.key) (request : Request)
    (matched : request.routeKey = key) :
    (router.add key handler fresh).dispatch fallback request = handler request := by
  simp [dispatch, add, lookup, matched]

/-- Adding a distinct route does not change how an existing request is dispatched. -/
theorem dispatch_add_other (router : Router α) (key : RouteKey) (handler fallback : Handler α)
    (fresh : key ∉ router.routes.map Route.key) (request : Request)
    (different : key ≠ request.routeKey) :
    (router.add key handler fresh).dispatch fallback request =
      router.dispatch fallback request := by
  simp [dispatch, add, lookup, different]

end Router
end LeanWeb
