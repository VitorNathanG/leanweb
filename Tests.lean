import Tests.Http
import Tests.Framework
import Tests.Application

def main : IO Unit := do
  Tests.Http.run
  Tests.Framework.run
  Tests.Application.run
  IO.println "Core and application tests passed"
