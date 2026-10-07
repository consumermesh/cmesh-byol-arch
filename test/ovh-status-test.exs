#!/usr/bin/env elixir
# Tests the presentation and control logic in scripts/ovh-status.exs against the shape the
# OVHcloud API actually returns.
#
# The endpoint does NOT return a summary. It returns the full 17-step list:
#
#   [%{"comment" => "Checking BIOS version",    "status" => "done",  "error" => ""},
#    %{"comment" => "Running Hardware Reboot",   "status" => "doing", "error" => ""},
#    %{"comment" => "Running BYOLinux Configure","status" => "todo",  "error" => ""}, ...]
#
# This suite exists because the first version of the renderer was written for a flat
# map -- status/progress/comment -- and crashed on the real payload with "cannot convert
# the given list to a string". It was only caught by running it against the live API.
#
# The module is EXTRACTED from the script rather than copied, so the two cannot drift.
#
# Usage: elixir test/ovh-status-test.exs

script = Path.join([__DIR__, "..", "scripts", "ovh-status.exs"]) |> Path.expand()

unless File.exists?(script) do
  IO.puts("FATAL: #{script} not found")
  System.halt(1)
end

mod =
  case Regex.run(~r/^defmodule OvhStatus do$.*?^end$/ms, File.read!(script)) do
    [m] -> m
    _ -> nil
  end

unless mod do
  IO.puts("FATAL: could not extract the OvhStatus module from #{script}")
  System.halt(1)
end

tmp = Path.join(System.tmp_dir!(), "ovh-status-mod-#{:erlang.unique_integer([:positive])}.exs")
File.write!(tmp, mod)
Code.require_file(tmp)
File.rm(tmp)

defmodule Checker do
  def check(st, desc, expected, actual) do
    if expected == actual do
      IO.puts("  ok    #{desc}")
      %{st | pass: st.pass + 1}
    else
      IO.puts("""
        FAIL  #{desc}
              expected: #{inspect(expected)}
              actual:   #{inspect(actual)}
      """)

      %{st | fail: st.fail + 1}
    end
  end
end

capture = fn fun -> ExUnit.CaptureIO.capture_io(fun) end

# The literal payload observed from the live endpoint mid-deploy: 2 done, 1 doing, rest todo.
real = [
  %{"comment" => "Checking BIOS version", "error" => "", "status" => "done"},
  %{"comment" => "Checking BIOS version", "error" => "", "status" => "done"},
  %{"comment" => "Running Hardware Reboot", "error" => "", "status" => "doing"},
  %{"comment" => "Setting up hardware raid", "error" => "", "status" => "todo"},
  %{"comment" => "Preparing disks for new Partitioning", "error" => "", "status" => "todo"},
  %{"comment" => "Cleaning Partitioning", "error" => "", "status" => "todo"},
  %{"comment" => "Processing Partitioning", "error" => "", "status" => "todo"},
  %{"comment" => "Applying Partitioning", "error" => "", "status" => "todo"},
  %{"comment" => "Processing Post-installation configuration", "error" => "", "status" => "todo"},
  %{"comment" => "Pre-configuring Post-installation", "error" => "", "status" => "todo"},
  %{"comment" => "Downloading OS image", "error" => "", "status" => "todo"},
  %{"comment" => "Deploying OS on disks", "error" => "", "status" => "todo"},
  %{"comment" => "Checking Partitioning", "error" => "", "status" => "todo"},
  %{"comment" => "Running BYOLinux Configure", "error" => "", "status" => "todo"},
  %{"comment" => "Switching boot", "error" => "", "status" => "todo"},
  %{"comment" => "Running Last Hardware Reboot", "error" => "", "status" => "todo"},
  %{"comment" => "Sending end of installation mail", "error" => "", "status" => "todo"}
]

st = %{pass: 0, fail: 0}

IO.puts("=== steps/1 accepts every shape the endpoint has returned ===")
st = Checker.check(st, "envelope %{progress: [...]} unwraps", length(real), length(OvhStatus.steps(%{"elapsedTime" => 74, "progress" => real})))
st = Checker.check(st, "bare list passes through", length(real), length(OvhStatus.steps(real)))
st = Checker.check(st, "flat map -> empty (unrecognised)", [], OvhStatus.steps(%{"status" => "doing"}))
st = Checker.check(st, "nil -> empty", [], OvhStatus.steps(nil))
st = Checker.check(st, "empty progress -> empty", [], OvhStatus.steps(%{"progress" => []}))

IO.puts("\n=== render/2 on the envelope (what the API actually sends) ===")
out_env = capture.(fn -> OvhStatus.render(%{"elapsedTime" => 74, "progress" => real}, 999) end)
st = Checker.check(st, "shows the API's own elapsedTime", true, String.contains?(out_env, "74s"))
st = Checker.check(st, "does not show the local elapsed when the API supplies one", false, String.contains?(out_env, "999s"))
st = Checker.check(st, "counts done steps", true, String.contains?(out_env, "2/17"))

IO.puts("\n=== render/2 on the real step list ===")
out = capture.(fn -> OvhStatus.render(real, 137) end)
st = Checker.check(st, "counts done steps", true, String.contains?(out, "2/17"))
st = Checker.check(st, "shows elapsed time", true, String.contains?(out, "137s"))
st = Checker.check(st, "names the running step", true, String.contains?(out, "Running Hardware Reboot"))
st = Checker.check(st, "lists the steps", true, String.contains?(out, "Downloading OS image"))
st = Checker.check(st, "includes the hook step", true, String.contains?(out, "Running BYOLinux Configure"))

IO.puts("\n=== the failure this project has hit twice ===")
failed =
  List.replace_at(real, 13, %{
    "comment" => "Running BYOLinux Configure",
    "error" => "The script did not end properly",
    "status" => "error"
  })

out2 = capture.(fn -> OvhStatus.render(failed, 1800) end)
st = Checker.check(st, "marks the failed step", true, String.contains?(out2, "ERR"))
st = Checker.check(st, "shows the reason", true, String.contains?(out2, "did not end properly"))
st = Checker.check(st, "names the step that failed", true, String.contains?(out2, "BYOLinux Configure"))

IO.puts("\n=== terminal?/1 decides when --watch stops ===")
st = Checker.check(st, "mid-deploy -> keep polling", false, OvhStatus.terminal?(real))
st = Checker.check(st, "envelope mid-deploy -> keep polling", false, OvhStatus.terminal?(%{"elapsedTime" => 74, "progress" => real}))
st = Checker.check(st, "envelope with a failure -> stop", true, OvhStatus.terminal?(%{"progress" => failed}))
st = Checker.check(st, "a failed step -> stop", true, OvhStatus.terminal?(failed))
st = Checker.check(st, "all done -> stop", true, OvhStatus.terminal?(Enum.map(real, &%{&1 | "status" => "done"})))
st = Checker.check(st, "empty list -> keep polling", false, OvhStatus.terminal?([]))
st = Checker.check(st, "nil -> keep polling", false, OvhStatus.terminal?(nil))

IO.puts("\n=== must not crash on a shape it does not know ===")
# This is the regression: the previous renderer crashed on the real payload.
st = Checker.check(st, "flat map renders without raising", true,
  (try do
     capture.(fn -> OvhStatus.render(%{"status" => "doing"}, 5) end)
     true
   rescue
     _ -> false
   end))
st = Checker.check(st, "nil renders without raising", true,
  (try do
     capture.(fn -> OvhStatus.render(nil, 5) end)
     true
   rescue
     _ -> false
   end))
st = Checker.check(st, "steps/1 on a non-list is empty", [], OvhStatus.steps(%{"a" => 1}))

IO.puts("\n=== signing (same algorithm as ovh-reinstall.exs) ===")
sig = OvhStatus.signature("as", "ck", "GET", "https://eu.api.ovh.com/1.0/x", "", "1700000000")
st = Checker.check(st, "shaped like an OVHcloud signature", true, Regex.match?(~r/^\$1\$[0-9a-f]{40}$/, sig))
st = Checker.check(st, "covers the URL", false,
  sig == OvhStatus.signature("as", "ck", "GET", "https://eu.api.ovh.com/1.0/y", "", "1700000000"))

IO.puts("\npassed: #{st.pass}  failed: #{st.fail}")
if st.fail > 0, do: System.halt(1)
