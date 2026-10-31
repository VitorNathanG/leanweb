import Tests.Http
import Tests.HttpSpec
import Tests.Framework
import Tests.Application

def main : IO Unit := do
  Tests.Http.run
  Tests.HttpSpec.run
  Tests.Framework.run
  Tests.Application.run
  IO.println "Core and application tests passed"
