import LeanWeb.Middleware

namespace LeanWeb

/-- A pure controller together with its application-specific response contract. -/
structure VerifiedHandler (post : Request → Response → Prop) where
  run : Handler Response
  ensures : ∀ request, post request (run request)

def VerifiedHandler.lift [Monad m] (handler : VerifiedHandler post) : Handler (m Response) :=
  fun request => pure (handler.run request)

/-- Dependencies are explicit and typed, rather than resolved through reflection. -/
abbrev Action (Context : Type) := ReaderT Context IO Response

structure Application (Context : Type) where
  router : Router (Action Context)
  middleware : Middleware (Action Context) := Middleware.identity
  fallback : Handler (Action Context) := fun _ _ => pure Response.notFound

def Application.handle (app : Application Context) (context : Context) : Request → IO Response :=
  fun request => (app.middleware (app.router.dispatch app.fallback) request).run context

end LeanWeb
